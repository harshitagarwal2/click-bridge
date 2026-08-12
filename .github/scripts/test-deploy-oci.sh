#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
DEPLOY_SCRIPT="$SCRIPT_DIR/deploy-oci.sh"
REPOSITORY_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
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
readonly EXPECTED_PHONE_TOKEN='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
readonly EXPECTED_MAC_TOKEN='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
readonly EXPECTED_DOMAIN='clickbridge.example.test'
readonly EXPECTED_NODE='node:24-alpine@sha256:d32cdf619f63fe0471182d08996dd516c6275bb5fd31ae06e55a570bd9e1ad43'
readonly CANDIDATE_HEALTH_SCRIPT='fetch("http://127.0.0.1:8080/healthz").then(async response=>{if(!response.ok||(await response.text())!=="ok")process.exit(1)}).catch(()=>process.exit(1))'
readonly HEALTH_SCRIPT='fetch(`https://${process.env.CLICK_BRIDGE_DOMAIN}/healthz`).then(async response=>{if(!response.ok||(await response.text())!=="ok")process.exit(1)}).catch(()=>process.exit(1))'
readonly SMOKE_SCRIPT='cp -R /workspace/. .; npm ci --omit=dev --ignore-scripts >/dev/null; node scripts/smoke-relay.mjs "wss://${CLICK_BRIDGE_DOMAIN}/ws"'

fail_fake() {
  printf 'fake docker rejected verifier contract: %s\n' "$1" >&2
  exit 1
}

log_argv() {
  {
    printf 'release=%q docker' "${CLICK_BRIDGE_RELEASE:-unset}"
    printf ' %q' "$@"
    printf '\n'
  } >> "$FAKE_DOCKER_LOG"
}

assert_exact_args() {
  local description="$1"
  shift
  local -a expected=("$@")
  local index
  test "${#DOCKER_ARGS[@]}" -eq "${#expected[@]}" ||
    fail_fake "$description argument count"
  for index in "${!expected[@]}"; do
    test "${DOCKER_ARGS[$index]}" = "${expected[$index]}" ||
      fail_fake "$description argument $index"
  done
}

args_match() {
  local -a expected=("$@")
  local index
  test "${#DOCKER_ARGS[@]}" -eq "${#expected[@]}" || return 1
  for index in "${!expected[@]}"; do
    test "${DOCKER_ARGS[$index]}" = "${expected[$index]}" || return 1
  done
}

record_env_spec() {
  local env_spec="$1"
  [[ "$env_spec" =~ ^[A-Za-z_][A-Za-z0-9_]*(=.*)?$ ]] ||
    fail_fake 'malformed env option'
  RUN_ENVS+=("$env_spec")
}

require_env() {
  local name="$1"
  local expected="$2"
  test "${!name:-}" = "$expected" || {
    printf 'fake docker received unexpected %s\n' "$name" >&2
    exit 1
  }
}

require_env_absent() {
  local name="$1"
  test -z "${!name:-}" || {
    printf 'fake docker unexpectedly inherited %s\n' "$name" >&2
    exit 1
  }
}

for argument in "$@"; do
  case "$argument" in
    *"$EXPECTED_PHONE_TOKEN"*|*"$EXPECTED_MAC_TOKEN"*)
      fail_fake 'token value appeared in argv'
      ;;
  esac
done

DOCKER_ARGS=("$@")
RUN_KIND=''
RUN_IMAGE=''
RUN_ENV_FILE=0
RUN_ENVS=()
RUN_COMMAND=()

if test "${1:-}" = run; then
  index=1
  while test "$index" -lt "${#DOCKER_ARGS[@]}"; do
    argument="${DOCKER_ARGS[$index]}"
    case "$argument" in
      -e)
        next=$((index + 1))
        test "$next" -lt "${#DOCKER_ARGS[@]}" || fail_fake '-e is missing a value'
        record_env_spec "${DOCKER_ARGS[$next]}"
        index=$((index + 2))
        ;;
      -e?*)
        compact_env="${argument#-e}"
        record_env_spec "$compact_env"
        index=$((index + 1))
        ;;
      --detach|--rm)
        index=$((index + 1))
        ;;
      --add-host|--env|--env-file|--name|--network|--publish|--volume|--workdir)
        next=$((index + 1))
        test "$next" -lt "${#DOCKER_ARGS[@]}" || fail_fake "$argument is missing a value"
        if test "$argument" = --env; then
          record_env_spec "${DOCKER_ARGS[$next]}"
        elif test "$argument" = --env-file; then
          RUN_ENV_FILE=1
        fi
        index=$((index + 2))
        ;;
      --*=*)
        case "$argument" in
          --env=*) record_env_spec "${argument#--env=}" ;;
          --env-file=*) RUN_ENV_FILE=1 ;;
          *) fail_fake "undeclared docker run option ${argument%%=*}" ;;
        esac
        index=$((index + 1))
        ;;
      --*)
        fail_fake "undeclared docker run option $argument"
        ;;
      -*)
        fail_fake "undeclared docker run option $argument"
        ;;
      *)
        RUN_IMAGE="$argument"
        RUN_COMMAND=("${DOCKER_ARGS[@]:$((index + 1))}")
        break
        ;;
    esac
  done
  test -n "$RUN_IMAGE" || fail_fake 'docker run image is missing'

  if test "${RUN_COMMAND[0]:-}" = node && test "${RUN_COMMAND[1]:-}" = -e; then
    RUN_KIND=health
    test "$RUN_ENV_FILE" -eq 0 || fail_fake 'health verifier used env-file'
    test "${#RUN_ENVS[@]}" -eq 1 || fail_fake 'health verifier env allowlist'
    test "${RUN_ENVS[0]}" = "CLICK_BRIDGE_DOMAIN=$EXPECTED_DOMAIN" ||
      fail_fake 'health verifier env allowlist'
    require_env_absent PHONE_TOKEN
    require_env_absent MAC_TOKEN
    assert_exact_args health \
      run --rm --network host \
      --add-host "$EXPECTED_DOMAIN:127.0.0.1" \
      --env "CLICK_BRIDGE_DOMAIN=$EXPECTED_DOMAIN" \
      "$EXPECTED_NODE" node -e "$HEALTH_SCRIPT"
  elif test "${RUN_COMMAND[0]:-}" = sh && test "${RUN_COMMAND[1]:-}" = -euc; then
    RUN_KIND=smoke
    test "$RUN_ENV_FILE" -eq 0 || fail_fake 'smoke verifier used env-file'
    test "${#RUN_ENVS[@]}" -eq 3 || fail_fake 'smoke verifier env allowlist'
    test "${RUN_ENVS[0]}" = "CLICK_BRIDGE_DOMAIN=$EXPECTED_DOMAIN" ||
      fail_fake 'smoke verifier env allowlist'
    test "${RUN_ENVS[1]}" = PHONE_TOKEN || fail_fake 'smoke verifier env allowlist'
    test "${RUN_ENVS[2]}" = MAC_TOKEN || fail_fake 'smoke verifier env allowlist'
    require_env PHONE_TOKEN "$EXPECTED_PHONE_TOKEN"
    require_env MAC_TOKEN "$EXPECTED_MAC_TOKEN"
    test "${CLICK_BRIDGE_ROOT:-}" != '' || fail_fake 'smoke verifier release root is missing'
    expected_relay_mount="$CLICK_BRIDGE_ROOT/releases/$CLICK_BRIDGE_RELEASE/relay:/workspace:ro"
    test "${DOCKER_ARGS[13]:-}" = "$expected_relay_mount" ||
      fail_fake 'smoke verifier volume'
    assert_exact_args smoke \
      run --rm --network host \
      --add-host "$EXPECTED_DOMAIN:127.0.0.1" \
      --env "CLICK_BRIDGE_DOMAIN=$EXPECTED_DOMAIN" \
      --env PHONE_TOKEN \
      --env MAC_TOKEN \
      --volume "$expected_relay_mount" \
      --workdir /tmp/smoke \
      "$EXPECTED_NODE" sh -euc "$SMOKE_SCRIPT"
  elif test "${#RUN_COMMAND[@]}" -eq 0; then
    RUN_KIND=candidate
    require_env_absent PHONE_TOKEN
    require_env_absent MAC_TOKEN
    assert_exact_args candidate \
      run --detach \
      --name click-bridge-relay-candidate \
      --publish 127.0.0.1:18080:8080 \
      --env-file "$CLICK_BRIDGE_ROOT/shared/secrets.env" \
      --env PORT=8080 \
      --env HOST=0.0.0.0 \
      "click-bridge-relay:$CLICK_BRIDGE_RELEASE"
  else
    fail_fake 'unrecognized docker run command'
  fi
fi

case "${1:-}" in
  run)
    ;;
  compose)
    compose_file="$CLICK_BRIDGE_ROOT/releases/$CLICK_BRIDGE_RELEASE/deploy/oci/compose.yaml"
    if args_match compose -p oci --env-file "$CLICK_BRIDGE_ROOT/shared/secrets.env" \
        -f "$compose_file" config --quiet ||
      args_match compose -p oci --env-file "$CLICK_BRIDGE_ROOT/shared/secrets.env" \
        -f "$compose_file" build --pull relay ||
      args_match compose -p oci --env-file "$CLICK_BRIDGE_ROOT/shared/secrets.env" \
        -f "$compose_file" up -d --no-build --force-recreate ||
      args_match compose -p oci --env-file "$CLICK_BRIDGE_ROOT/shared/secrets.env" \
        -f "$compose_file" down ||
      args_match compose -p oci --env-file "$CLICK_BRIDGE_ROOT/shared/secrets.env" \
        -f "$compose_file" ps; then
      :
    else
      fail_fake 'compose argument contract'
    fi
    ;;
  rm)
    assert_exact_args rm rm -f click-bridge-relay-candidate
    ;;
  exec)
    assert_exact_args exec \
      exec click-bridge-relay-candidate node -e "$CANDIDATE_HEALTH_SCRIPT"
    ;;
  logs)
    assert_exact_args logs logs --tail=100 click-bridge-relay-candidate
    ;;
  *)
    fail_fake "unsupported top-level Docker invocation: ${1:-missing}"
    ;;
esac

log_argv "$@"

if test "${1:-}" = run && test "$RUN_KIND" = health; then
  exit 0
fi
if test "${1:-}" = run && test "$RUN_KIND" = smoke; then
  test "${FAKE_SMOKE_FAIL_RELEASE:-}" != "${CLICK_BRIDGE_RELEASE:-}"
  exit
fi
if test "${1:-}" = run && test "$RUN_KIND" = candidate; then
  printf '%s\n' fake-candidate-id
  exit 0
fi
if test "${1:-}" = exec && test "${2:-}" = click-bridge-relay-candidate; then
  test "${FAKE_CANDIDATE_FAIL:-0}" != 1
  exit
fi
exit 0
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
  mkdir -p "$root/releases" "$root/shared/auth"
  chmod 700 "$root/shared/auth"
  printf '%s\n' \
    'PHONE_TOKEN=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
    'MAC_TOKEN=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' \
    'CLICK_BRIDGE_DOMAIN=clickbridge.example.test' \
    'PAIRING_ENABLED=0' \
    'PHONE_AUTH_RECORD=/var/lib/click-bridge/auth/phone-auth.json' \
    > "$root/shared/secrets.env"
  chmod 600 "$root/shared/secrets.env"
  printf '%s\n' "$root"
}

add_release() {
  local root="$1"
  local release="$2"
  mkdir -p "$root/releases/$release/deploy/oci" "$root/releases/$release/relay/scripts"
  printf '%s\n' \
    'services:' \
    '  relay:' \
    '    env_file:' \
    '      - ${CLICK_BRIDGE_SECRETS_FILE}' \
    '    environment:' \
    '      PHONE_AUTH_RECORD: /var/lib/click-bridge/auth/phone-auth.json' \
    '    volumes:' \
    '      - /opt/click-bridge/shared/auth:/var/lib/click-bridge/auth' \
    > "$root/releases/$release/deploy/oci/compose.yaml"
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
grep -Fq '${CLICK_BRIDGE_SECRETS_FILE:-/opt/click-bridge/shared/secrets.env}' \
  "$REPOSITORY_ROOT/deploy/oci/compose.yaml" || fail 'Compose does not inject the shared environment'
grep -Fq '/opt/click-bridge/shared/auth:/var/lib/click-bridge/auth' "$REPOSITORY_ROOT/deploy/oci/compose.yaml" ||
  fail 'Compose does not bind the persistent auth directory'
grep -Fxq 'PAIRING_ENABLED=0' "$REPOSITORY_ROOT/deploy/oci/.env.example" ||
  fail '.env.example does not default pairing off'
grep -Fxq 'PHONE_AUTH_RECORD=/var/lib/click-bridge/auth/phone-auth.json' \
  "$REPOSITORY_ROOT/deploy/oci/.env.example" || fail '.env.example lacks the canonical auth record path'

SHA_A='1111111111111111111111111111111111111111'
SHA_B='2222222222222222222222222222222222222222'
NODE_VERIFIER='node:24-alpine@sha256:d32cdf619f63fe0471182d08996dd516c6275bb5fd31ae06e55a570bd9e1ad43'
# This must match the literal script passed to Node.
# shellcheck disable=SC2016
HEALTH_COMMAND='fetch(`https://${process.env.CLICK_BRIDGE_DOMAIN}/healthz`).then(async response=>{if(!response.ok||(await response.text())!=="ok")process.exit(1)}).catch(()=>process.exit(1))'
# This must match the literal candidate health script passed to Node.
CANDIDATE_HEALTH_COMMAND='fetch("http://127.0.0.1:8080/healthz").then(async response=>{if(!response.ok||(await response.text())!=="ok")process.exit(1)}).catch(()=>process.exit(1))'
# This must match the literal script run in the container.
# shellcheck disable=SC2016
SMOKE_COMMAND='cp -R /workspace/. .; npm ci --omit=dev --ignore-scripts >/dev/null; node scripts/smoke-relay.mjs "wss://${CLICK_BRIDGE_DOMAIN}/ws"'
root="$(new_case_root first-success)"
add_release "$root" "$SHA_A"

run_fake_health() {
  FAKE_DOCKER_LOG="$FAKE_DOCKER_LOG" CLICK_BRIDGE_ROOT="$root" \
    CLICK_BRIDGE_RELEASE="$SHA_A" PHONE_TOKEN='' MAC_TOKEN='' \
    "$FAKE_BIN/docker" run --rm --network host \
      --add-host clickbridge.example.test:127.0.0.1 \
      --env CLICK_BRIDGE_DOMAIN=clickbridge.example.test \
      "$@" \
      "$NODE_VERIFIER" node -e "$HEALTH_COMMAND"
}

run_fake_smoke() {
  FAKE_DOCKER_LOG="$FAKE_DOCKER_LOG" CLICK_BRIDGE_ROOT="$root" \
    CLICK_BRIDGE_RELEASE="$SHA_A" \
    PHONE_TOKEN=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    MAC_TOKEN=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
    "$FAKE_BIN/docker" run --rm --network host \
      --add-host clickbridge.example.test:127.0.0.1 \
      --env CLICK_BRIDGE_DOMAIN=clickbridge.example.test \
      --env PHONE_TOKEN \
      --env MAC_TOKEN \
      --volume "$root/releases/$SHA_A/relay:/workspace:ro" \
      "$@" \
      --workdir /tmp/smoke \
      "$NODE_VERIFIER" sh -euc "$SMOKE_COMMAND"
}

assert_fake_rejects_health_extra() {
  local description="$1"
  shift
  if run_fake_health "$@" 2>/dev/null; then
    fail "fake docker accepted $description on the health verifier"
  fi
}

assert_fake_rejects_smoke_extra() {
  local description="$1"
  shift
  if run_fake_smoke "$@" 2>/dev/null; then
    fail "fake docker accepted $description on the smoke verifier"
  fi
}

assert_fake_rejects_invocation() {
  local description="$1"
  shift
  if FAKE_DOCKER_LOG="$FAKE_DOCKER_LOG" CLICK_BRIDGE_ROOT="$root" \
    CLICK_BRIDGE_RELEASE="$SHA_A" PHONE_TOKEN='' MAC_TOKEN='' \
    "$FAKE_BIN/docker" "$@" 2>/dev/null; then
    fail "fake docker accepted $description"
  fi
}

: > "$FAKE_DOCKER_LOG"
run_fake_health
run_fake_smoke
assert_fake_rejects_health_extra 'an env outside its allowlist' --env HOME
assert_fake_rejects_health_extra \
  'a mount' \
  --volume "$root/shared/secrets.env:/tmp/secrets:ro"
assert_fake_rejects_smoke_extra 'an env-file' --env-file /tmp/decoy.env
assert_fake_rejects_smoke_extra \
  'a token value in argv' \
  --env PHONE_TOKEN=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
assert_fake_rejects_smoke_extra \
  'an extra volume' \
  --volume "$root/shared/secrets.env:/tmp/secrets:ro"
assert_fake_rejects_smoke_extra \
  'a short-form volume' \
  -v "$root/shared/secrets.env:/tmp/secrets:ro"
assert_fake_rejects_smoke_extra \
  'a compact short-form volume' \
  "-v$root/shared/secrets.env:/tmp/secrets:ro"
assert_fake_rejects_smoke_extra \
  'a compact inherited env' \
  -eHOME
assert_fake_rejects_smoke_extra \
  'a compact token value' \
  -ePHONE_TOKEN=inherited-phone
assert_fake_rejects_smoke_extra \
  'a malformed compact env' \
  -e=NAME
assert_fake_rejects_smoke_extra \
  'a missing compact env value' \
  -e
assert_fake_rejects_smoke_extra \
  'a missing long env value' \
  --env
assert_fake_rejects_smoke_extra \
  'a bind mount' \
  --mount="type=bind,source=$root/shared/secrets.env,target=/tmp/secrets,readonly"
assert_fake_rejects_smoke_extra \
  'a split bind mount' \
  --mount "type=bind,source=$root/shared/secrets.env,target=/tmp/secrets,readonly"
assert_fake_rejects_smoke_extra \
  'an inline env-file' \
  --env-file="$root/shared/secrets.env"
assert_fake_rejects_smoke_extra \
  'a device' \
  --device /dev/null
assert_fake_rejects_smoke_extra \
  'a secret option' \
  --secret "$root/shared/secrets.env"
assert_fake_rejects_smoke_extra \
  'an unknown privilege option' \
  --cap-add SYS_ADMIN
assert_fake_rejects_invocation \
  'a Docker global host option before run' \
  --host unix:///tmp/docker.sock run --rm "$NODE_VERIFIER" true
assert_fake_rejects_invocation \
  'an extra candidate secret volume' \
  run --detach \
  --name click-bridge-relay-candidate \
  --publish 127.0.0.1:18080:8080 \
  --env-file "$root/shared/secrets.env" \
  --env PORT=8080 \
  --env HOST=0.0.0.0 \
  --volume "$root/shared/secrets.env:/tmp/secrets:ro" \
  "click-bridge-relay:$SHA_A"
assert_fake_rejects_invocation \
  'an extra Compose argument' \
  compose -p oci \
  --env-file "$root/shared/secrets.env" \
  -f "$root/releases/$SHA_A/deploy/oci/compose.yaml" \
  config --quiet --profile hostile
assert_fake_rejects_invocation \
  'an extra rm target' \
  rm -f click-bridge-relay-candidate hostile-container
assert_fake_rejects_invocation \
  'an extra exec command' \
  exec click-bridge-relay-candidate node -e "$CANDIDATE_HEALTH_COMMAND" true
assert_fake_rejects_invocation \
  'an extra logs option' \
  logs --tail=100 click-bridge-relay-candidate --follow
assert_log_not_contains 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
assert_log_not_contains 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'

: > "$FAKE_DOCKER_LOG"
run_deploy "$root" "$SHA_A" PHONE_TOKEN=inherited-phone MAC_TOKEN=inherited-mac
assert_file_equals "$root/current-release" "$SHA_A"
test ! -e "$root/previous-release" || fail 'first deployment created previous-release'
assert_log_contains "release=$SHA_A docker compose"
assert_log_contains 'docker run --detach --name click-bridge-relay-candidate'
assert_log_contains 'scripts/smoke-relay.mjs'
assert_log_contains 'docker run --rm --network host --add-host clickbridge.example.test:127.0.0.1 --env CLICK_BRIDGE_DOMAIN=clickbridge.example.test node:24-alpine@sha256:d32cdf619f63fe0471182d08996dd516c6275bb5fd31ae06e55a570bd9e1ad43 node -e'
assert_log_contains 'docker run --rm --network host --add-host clickbridge.example.test:127.0.0.1 --env CLICK_BRIDGE_DOMAIN=clickbridge.example.test --env PHONE_TOKEN --env MAC_TOKEN --volume'
assert_log_contains 'node:24-alpine@sha256:d32cdf619f63fe0471182d08996dd516c6275bb5fd31ae06e55a570bd9e1ad43 sh -euc'
assert_log_not_contains "docker run --rm --network host --add-host clickbridge.example.test:127.0.0.1 --env-file $root/shared/secrets.env"
assert_log_not_contains 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
assert_log_not_contains 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
assert_log_not_contains 'inherited-phone'
assert_log_not_contains 'inherited-mac'

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

root="$(new_case_root invalid-pairing-flag)"
add_release "$root" "$SHA_A"
sed -i.bak 's/PAIRING_ENABLED=0/PAIRING_ENABLED=true/' "$root/shared/secrets.env"
rm -f "$root/shared/secrets.env.bak"
if run_deploy "$root" "$SHA_A"; then
  fail 'non-binary PAIRING_ENABLED unexpectedly succeeded'
fi

root="$(new_case_root pairing-without-team)"
add_release "$root" "$SHA_A"
sed -i.bak 's/PAIRING_ENABLED=0/PAIRING_ENABLED=1/' "$root/shared/secrets.env"
rm -f "$root/shared/secrets.env.bak"
if run_deploy "$root" "$SHA_A"; then
  fail 'enabled pairing without APPLE_TEAM_ID unexpectedly succeeded'
fi

root="$(new_case_root unsafe-auth-directory)"
add_release "$root" "$SHA_A"
chmod 755 "$root/shared/auth"
if run_deploy "$root" "$SHA_A"; then
  fail 'unsafe auth directory mode unexpectedly succeeded'
fi

root="$(new_case_root symlink-auth-record)"
add_release "$root" "$SHA_A"
printf '%s\n' '{"schemaVersion":1,"activePhoneCredentialVersion":0,"activePhoneVerifier":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"}' > "$root/shared/elsewhere.json"
chmod 600 "$root/shared/elsewhere.json"
ln -s "$root/shared/elsewhere.json" "$root/shared/auth/phone-auth.json"
if run_deploy "$root" "$SHA_A"; then
  fail 'symlinked auth record unexpectedly succeeded'
fi

root="$(new_case_root incompatible-active-record)"
add_release "$root" "$SHA_A"
printf '%s\n' '{"schemaVersion":1,"activePhoneCredentialVersion":1,"activePhoneVerifier":"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"}' > "$root/shared/auth/phone-auth.json"
chmod 600 "$root/shared/auth/phone-auth.json"
printf '%s\n' 'services: {}' > "$root/releases/$SHA_A/deploy/oci/compose.yaml"
: > "$FAKE_DOCKER_LOG"
if output="$(run_deploy "$root" "$SHA_A" 2>&1)"; then
  fail 'pairing-incompatible release unexpectedly succeeded with active rotated credential'
fi
case "$output" in
  *dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd*)
    fail 'auth verifier leaked in deployment error output' ;;
esac
assert_log_not_contains 'docker compose'

root="$(new_case_root rollback-refused-after-rotation)"
add_release "$root" "$SHA_A"
add_release "$root" "$SHA_B"
printf '%s\n' 'services: {}' > "$root/releases/$SHA_A/deploy/oci/compose.yaml"
printf '%s\n' "$SHA_A" > "$root/current-release"
printf '%s\n' '{"schemaVersion":1,"activePhoneCredentialVersion":2,"activePhoneVerifier":"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"}' > "$root/shared/auth/phone-auth.json"
chmod 600 "$root/shared/auth/phone-auth.json"
: > "$FAKE_DOCKER_LOG"
if output="$(run_deploy "$root" "$SHA_B" FAKE_SMOKE_FAIL_RELEASE="$SHA_B" 2>&1)"; then
  fail 'failed candidate unexpectedly rolled back to an incompatible release'
fi
case "$output" in
  *'automatic rollback refused: prior release is pairing-incompatible'*) ;;
  *) fail 'rollback incompatibility was not reported' ;;
esac
assert_log_not_contains "release=$SHA_A docker compose"
case "$output" in
  *eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee*)
    fail 'auth verifier leaked while refusing rollback' ;;
esac

printf '%s\n' 'OCI deployment script tests passed'
