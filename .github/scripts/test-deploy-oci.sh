#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
DEPLOY_SCRIPT="$SCRIPT_DIR/deploy-oci.sh"
TEST_ROOT="$(mktemp -d)"
FAKE_BIN="$TEST_ROOT/fake-bin"
FAKE_DOCKER_LOG="$TEST_ROOT/docker.log"

cleanup() {
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT INT TERM

mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/docker" <<'FAKE_DOCKER'
#!/usr/bin/env bash
set -eu
printf 'release=%s docker %s\n' "${CLICK_BRIDGE_RELEASE:-unset}" "$*" >> "$FAKE_DOCKER_LOG"
case "$*" in
  *"run --detach"*) printf '%s\n' fake-candidate-id ;;
  *"exec click-bridge-relay-candidate"*) test "${FAKE_CANDIDATE_FAIL:-0}" != 1 ;;
  *"scripts/smoke-relay.mjs"*) test "${FAKE_SMOKE_FAIL_RELEASE:-}" != "${CLICK_BRIDGE_RELEASE:-}" ;;
  *) exit 0 ;;
esac
FAKE_DOCKER
chmod +x "$FAKE_BIN/docker"

cat > "$FAKE_BIN/sleep" <<'FAKE_SLEEP'
#!/usr/bin/env bash
exit 0
FAKE_SLEEP
chmod +x "$FAKE_BIN/sleep"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_file_equals() {
  local file="$1"
  local expected="$2"
  test -f "$file" || fail "missing $file"
  test "$(tr -d '\n' < "$file")" = "$expected" || fail "$file did not contain $expected"
}

assert_log_contains() {
  grep -F "$1" "$FAKE_DOCKER_LOG" >/dev/null || fail "docker log missing: $1"
}

assert_log_not_contains() {
  if grep -F "$1" "$FAKE_DOCKER_LOG" >/dev/null; then
    fail "docker log unexpectedly contained: $1"
  fi
}

new_case_root() {
  local name="$1"
  local root="$TEST_ROOT/$name"
  mkdir -p "$root/releases" "$root/shared"
  printf '%s\n' \
    'PHONE_TOKEN=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
    'MAC_TOKEN=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' \
    'CLICK_BRIDGE_DOMAIN=clickbridge.example.test' \
    > "$root/shared/secrets.env"
  chmod 600 "$root/shared/secrets.env"
  printf '%s\n' "$root"
}

add_release() {
  local root="$1"
  local release="$2"
  mkdir -p "$root/releases/$release/deploy/oci" "$root/releases/$release/relay/scripts"
  printf '%s\n' 'services: {}' > "$root/releases/$release/deploy/oci/compose.yaml"
  printf '%s\n' 'console.log("smoke fixture")' > "$root/releases/$release/relay/scripts/smoke-relay.mjs"
}

run_deploy() {
  local root="$1"
  local release="$2"
  shift 2
  env \
    PATH="$FAKE_BIN:/usr/bin:/bin" \
    CLICK_BRIDGE_ROOT="$root" \
    CLICK_BRIDGE_RELEASE="$release" \
    CANDIDATE_HEALTH_ATTEMPTS=2 \
    PUBLIC_HEALTH_ATTEMPTS=2 \
    FAKE_DOCKER_LOG="$FAKE_DOCKER_LOG" \
    "$@" \
    bash "$DEPLOY_SCRIPT"
}

test -f "$DEPLOY_SCRIPT" || fail 'deploy-oci.sh does not exist'

SHA_A='1111111111111111111111111111111111111111'
SHA_B='2222222222222222222222222222222222222222'

root="$(new_case_root first-success)"
add_release "$root" "$SHA_A"
: > "$FAKE_DOCKER_LOG"
run_deploy "$root" "$SHA_A"
assert_file_equals "$root/current-release" "$SHA_A"
test ! -e "$root/previous-release" || fail 'first deployment created previous-release'
assert_log_contains "release=$SHA_A docker compose"
assert_log_contains 'docker run --detach --name click-bridge-relay-candidate'
assert_log_contains 'scripts/smoke-relay.mjs'

root="$(new_case_root replacement-success)"
add_release "$root" "$SHA_A"
add_release "$root" "$SHA_B"
printf '%s\n' "$SHA_A" > "$root/current-release"
: > "$FAKE_DOCKER_LOG"
run_deploy "$root" "$SHA_B"
assert_file_equals "$root/current-release" "$SHA_B"
assert_file_equals "$root/previous-release" "$SHA_A"

root="$(new_case_root candidate-failure)"
add_release "$root" "$SHA_A"
add_release "$root" "$SHA_B"
printf '%s\n' "$SHA_A" > "$root/current-release"
: > "$FAKE_DOCKER_LOG"
if run_deploy "$root" "$SHA_B" FAKE_CANDIDATE_FAIL=1; then
  fail 'candidate health failure unexpectedly succeeded'
fi
assert_file_equals "$root/current-release" "$SHA_A"
assert_log_not_contains "release=$SHA_B docker compose -p oci --env-file $root/shared/secrets.env -f $root/releases/$SHA_B/deploy/oci/compose.yaml up"

root="$(new_case_root post-switch-failure)"
add_release "$root" "$SHA_A"
add_release "$root" "$SHA_B"
printf '%s\n' "$SHA_A" > "$root/current-release"
: > "$FAKE_DOCKER_LOG"
if run_deploy "$root" "$SHA_B" FAKE_SMOKE_FAIL_RELEASE="$SHA_B"; then
  fail 'post-switch smoke failure unexpectedly succeeded'
fi
assert_file_equals "$root/current-release" "$SHA_A"
assert_log_contains "release=$SHA_B docker compose"
assert_log_contains "release=$SHA_A docker compose"

root="$(new_case_root invalid-release)"
: > "$FAKE_DOCKER_LOG"
if run_deploy "$root" not-a-sha; then
  fail 'invalid release unexpectedly succeeded'
fi

root="$(new_case_root bad-secret-mode)"
add_release "$root" "$SHA_A"
chmod 644 "$root/shared/secrets.env"
: > "$FAKE_DOCKER_LOG"
if run_deploy "$root" "$SHA_A"; then
  fail 'unsafe secret mode unexpectedly succeeded'
fi

printf '%s\n' 'OCI deployment script tests passed'
