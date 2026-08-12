#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
BOOTSTRAP="$SCRIPT_DIR/bootstrap-owner-mac.sh"
HELPER="$SCRIPT_DIR/bootstrap-owner-keychain.swift"
TEST_ROOT="$(mktemp -d)"
FAKE_BIN="$TEST_ROOT/bin"
FAKE_LOG="$TEST_ROOT/fake.log"
TOKEN_TMP="$TEST_ROOT/token-tmp"
TOKEN='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'

cleanup() { rm -rf "$TEST_ROOT"; }
trap cleanup EXIT INT TERM
mkdir -p "$FAKE_BIN"
mkdir -p "$TOKEN_TMP"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

wait_for_file() {
  local path="$1"
  local description="$2"
  for _ in {1..500}; do
    test -e "$path" && return 0
    sleep 0.01
  done
  fail "timed out waiting for $description"
}

assert_token_tmp_empty() {
  test -z "$(find "$TOKEN_TMP" ! -path "$TOKEN_TMP" -print -quit)" ||
    fail 'temporary credential path survived cleanup'
}

file_mode() {
  stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null
}

cat > "$FAKE_BIN/mkdir" <<'FAKE_MKDIR'
#!/usr/bin/env bash
set -Eeuo pipefail
if test -z "${FAKE_CREATE_READY_FILE:-}"; then
  exec /bin/mkdir "$@"
fi
/bin/mkdir "$@"
: > "$FAKE_CREATE_READY_FILE"
while test ! -e "$FAKE_CREATE_RELEASE_FILE"; do sleep 0.01; done
FAKE_MKDIR
chmod +x "$FAKE_BIN/mkdir"

cat > "$FAKE_BIN/chmod" <<'FAKE_CHMOD'
#!/usr/bin/env bash
set -Eeuo pipefail
if test -z "${FAKE_CHMOD_READY_FILE:-}"; then
  exec /bin/chmod "$@"
fi
: > "$FAKE_CHMOD_READY_FILE"
while test ! -e "$FAKE_CHMOD_RELEASE_FILE"; do sleep 0.01; done
exec /bin/chmod "$@"
FAKE_CHMOD
chmod +x "$FAKE_BIN/chmod"

cat > "$FAKE_BIN/swift" <<'FAKE_SWIFT'
#!/usr/bin/env bash
set -Eeuo pipefail
token="$(tr -d '\n')"
test "$token" = "$EXPECTED_TOKEN"
printf 'swift-args=%s\n' "$*" >> "$FAKE_LOG"
printf '%s\n' "$EXPECTED_TOKEN"
printf '%s\n' "$EXPECTED_TOKEN" >&2
if test -n "${FAKE_SWIFT_READY_FILE:-}"; then
  trap ': > "$FAKE_SWIFT_TERM_FILE"; while test ! -e "$FAKE_SWIFT_RELEASE_FILE"; do sleep 0.01; done; exit 0' TERM
  trap ': > "$FAKE_SWIFT_EXIT_FILE"' EXIT
  printf '%s\n' "$$" > "$FAKE_SWIFT_PID_FILE"
  : > "$FAKE_SWIFT_READY_FILE"
  while :; do sleep 0.01; done
fi
if test -n "${FAKE_SWIFT_DELAY:-}"; then sleep "$FAKE_SWIFT_DELAY"; fi
test "${FAKE_SWIFT_FAIL:-0}" != 1
FAKE_SWIFT
chmod +x "$FAKE_BIN/swift"

cat > "$FAKE_BIN/ssh" <<'FAKE_SSH'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'ssh-args=%s\n' "$*" >> "$FAKE_LOG"
printf '%s\n' "$EXPECTED_TOKEN"
if test "${FAKE_SSH_LEAK_STDERR:-0}" = 1; then printf '%s\n' "$EXPECTED_TOKEN" >&2; fi
FAKE_SSH
chmod +x "$FAKE_BIN/ssh"

run_bootstrap() {
  local -a command=(env PATH="$FAKE_BIN:/usr/bin:/bin" EXPECTED_TOKEN="$TOKEN" FAKE_LOG="$FAKE_LOG" TMPDIR="$TOKEN_TMP" \
    FAKE_SWIFT_FAIL="${FAKE_SWIFT_FAIL:-0}" FAKE_SWIFT_DELAY="${FAKE_SWIFT_DELAY:-}" \
    FAKE_SWIFT_READY_FILE="${FAKE_SWIFT_READY_FILE:-}" \
    FAKE_SWIFT_TERM_FILE="${FAKE_SWIFT_TERM_FILE:-}" \
    FAKE_SWIFT_RELEASE_FILE="${FAKE_SWIFT_RELEASE_FILE:-}" \
    FAKE_SWIFT_EXIT_FILE="${FAKE_SWIFT_EXIT_FILE:-}" \
    FAKE_SWIFT_PID_FILE="${FAKE_SWIFT_PID_FILE:-}" \
    FAKE_CREATE_READY_FILE="${FAKE_CREATE_READY_FILE:-}" \
    FAKE_CREATE_RELEASE_FILE="${FAKE_CREATE_RELEASE_FILE:-}" \
    FAKE_CHMOD_READY_FILE="${FAKE_CHMOD_READY_FILE:-}" \
    FAKE_CHMOD_RELEASE_FILE="${FAKE_CHMOD_RELEASE_FILE:-}" \
    FAKE_SSH_LEAK_STDERR="${FAKE_SSH_LEAK_STDERR:-0}" \
    bash "$BOOTSTRAP" "$@")
  if test "${RUN_BOOTSTRAP_EXEC:-0}" = 1; then
    exec /usr/bin/perl -e '$SIG{INT} = $SIG{TERM} = $SIG{HUP} = "DEFAULT"; exec @ARGV' -- "${command[@]}"
  fi
  "${command[@]}"
}

test -f "$BOOTSTRAP" || fail 'bootstrap-owner-mac.sh is missing'
test -f "$HELPER" || fail 'bootstrap-owner-keychain.swift is missing'

secrets="$TEST_ROOT/secrets.env"
printf 'MAC_TOKEN=%s\n' "$TOKEN" > "$secrets"
chmod 600 "$secrets"
: > "$FAKE_LOG"
output="$(run_bootstrap --relay-url wss://relay.example.test/ws --secrets-file "$secrets" 2>&1)"
test -z "$output" || fail 'bootstrap emitted output on success'
grep -Fq "swift-args=$HELPER --relay-url wss://relay.example.test/ws" "$FAKE_LOG" ||
  fail 'Swift helper did not receive only helper path and relay URL arguments'
if grep -Fq "$TOKEN" "$FAKE_LOG"; then fail 'token leaked into helper arguments or log'; fi
assert_token_tmp_empty

: > "$FAKE_LOG"
output="$(run_bootstrap --relay-url https://relay.example.test --ssh-host opc@relay.example.test 2>&1)"
test -z "$output" || fail 'SSH bootstrap emitted output on success'
grep -Fq 'ssh-args=' "$FAKE_LOG" || fail 'SSH source was not used'
if grep -Fq "$TOKEN" "$FAKE_LOG"; then fail 'token leaked into SSH arguments or log'; fi

output="$(FAKE_SSH_LEAK_STDERR=1 run_bootstrap \
  --relay-url https://relay.example.test --ssh-host opc@relay.example.test 2>&1)"
test -z "$output" || fail 'SSH bootstrap forwarded credential-bearing helper stderr'

if output="$(FAKE_SWIFT_FAIL=1 run_bootstrap --relay-url wss://relay.example.test/ws \
    --secrets-file "$secrets" 2>&1)"; then
  fail 'failed Swift helper unexpectedly succeeded'
fi
case "$output" in *"$TOKEN"*) fail 'token leaked during helper failure' ;; esac
assert_token_tmp_empty

assert_helper_signal() {
  local first_signal="$1"
  local second_signal="$2"
  local label="$first_signal-$second_signal"
  local swift_ready="$TEST_ROOT/swift-$label-ready"
  local swift_term="$TEST_ROOT/swift-$label-term"
  local swift_release="$TEST_ROOT/swift-$label-release"
  local swift_exit="$TEST_ROOT/swift-$label-exit"
  local swift_pid_file="$TEST_ROOT/swift-$label-pid"
  local credential_file token_dir
  local bootstrap_pid bootstrap_status

  RUN_BOOTSTRAP_EXEC=1 FAKE_SWIFT_READY_FILE="$swift_ready" FAKE_SWIFT_TERM_FILE="$swift_term" \
    FAKE_SWIFT_RELEASE_FILE="$swift_release" FAKE_SWIFT_EXIT_FILE="$swift_exit" \
    FAKE_SWIFT_PID_FILE="$swift_pid_file" \
    run_bootstrap --relay-url wss://relay.example.test/ws --secrets-file "$secrets" \
    >"$TEST_ROOT/swift-$label.stdout" 2>"$TEST_ROOT/swift-$label.stderr" &
  bootstrap_pid=$!
  wait_for_file "$swift_ready" "Swift helper readiness for $label"
  credential_file="$(find "$TOKEN_TMP" -type f -name credential -print -quit)"
  test -n "$credential_file" || fail "temporary credential file missing for $label"
  token_dir="$(dirname "$credential_file")"
  test "$(file_mode "$token_dir")" = 700 || fail "temporary credential directory mode was not 0700 for $label"
  test "$(file_mode "$credential_file")" = 600 || fail "temporary credential file mode was not 0600 for $label"
  kill -"$first_signal" "$bootstrap_pid"
  wait_for_file "$swift_term" "Swift helper termination for $label"
  kill -"$second_signal" "$bootstrap_pid"
  for _ in {1..20}; do
    kill -0 "$bootstrap_pid" 2>/dev/null || break
    sleep 0.01
  done
  if ! kill -0 "$bootstrap_pid" 2>/dev/null; then
    : > "$swift_release"
    fail "bootstrap exited before reaping the Swift helper after $label"
  fi
  : > "$swift_release"
  set +e
  wait "$bootstrap_pid"
  bootstrap_status=$?
  set -e
  test "$bootstrap_status" -eq 130 || fail "$label during Swift helper exited $bootstrap_status instead of 130"
  wait_for_file "$swift_exit" "Swift helper exit after $label"
  test ! -s "$TEST_ROOT/swift-$label.stdout" || fail "$label during Swift helper emitted stdout"
  test ! -s "$TEST_ROOT/swift-$label.stderr" || fail "$label during Swift helper emitted stderr"
  assert_token_tmp_empty
}

assert_helper_signal TERM INT
assert_helper_signal INT HUP
assert_helper_signal HUP TERM

chmod_ready="$TEST_ROOT/chmod-ready"
chmod_release="$TEST_ROOT/chmod-release"
RUN_BOOTSTRAP_EXEC=1 FAKE_CHMOD_READY_FILE="$chmod_ready" FAKE_CHMOD_RELEASE_FILE="$chmod_release" \
  run_bootstrap --relay-url wss://relay.example.test/ws --secrets-file "$secrets" \
  >"$TEST_ROOT/chmod.stdout" 2>"$TEST_ROOT/chmod.stderr" &
bootstrap_pid=$!
wait_for_file "$chmod_ready" 'temporary credential mode barrier'
credential_file="$(find "$TOKEN_TMP" -type f -name credential -print -quit)"
test -n "$credential_file" || fail 'temporary credential file missing at mode barrier'
token_dir="$(dirname "$credential_file")"
test "$(file_mode "$token_dir")" = 700 || fail 'temporary credential directory was not created mode 0700'
test "$(file_mode "$credential_file")" = 600 || fail 'temporary credential file was not created mode 0600'
: > "$chmod_release"
wait "$bootstrap_pid"
test ! -s "$TEST_ROOT/chmod.stdout" || fail 'permission-path bootstrap emitted stdout'
test ! -s "$TEST_ROOT/chmod.stderr" || fail 'permission-path bootstrap emitted stderr'
assert_token_tmp_empty

assert_creation_signal() {
  local signal="$1"
  local create_ready="$TEST_ROOT/create-$signal-ready"
  local create_release="$TEST_ROOT/create-$signal-release"
  local bootstrap_pid bootstrap_status

  RUN_BOOTSTRAP_EXEC=1 FAKE_CREATE_READY_FILE="$create_ready" FAKE_CREATE_RELEASE_FILE="$create_release" \
    run_bootstrap --relay-url wss://relay.example.test/ws --secrets-file "$secrets" \
    >"$TEST_ROOT/create-$signal.stdout" 2>"$TEST_ROOT/create-$signal.stderr" &
  bootstrap_pid=$!
  wait_for_file "$create_ready" "temporary credential creation barrier for $signal"
  kill -"$signal" "$bootstrap_pid"
  : > "$create_release"
  set +e
  wait "$bootstrap_pid"
  bootstrap_status=$?
  set -e
  test "$bootstrap_status" -eq 130 || fail "$signal during credential creation exited $bootstrap_status instead of 130"
  test ! -s "$TEST_ROOT/create-$signal.stdout" || fail "$signal during credential creation emitted stdout"
  test ! -s "$TEST_ROOT/create-$signal.stderr" || fail "$signal during credential creation emitted stderr"
  assert_token_tmp_empty
}

assert_creation_signal TERM
assert_creation_signal INT
assert_creation_signal HUP

if run_bootstrap --relay-url wss://relay.example.test/ws --secrets-file "$secrets" \
    --ssh-host opc@relay.example.test >/dev/null 2>&1; then
  fail 'multiple secret sources unexpectedly succeeded'
fi
if run_bootstrap --relay-url http://relay.example.test --secrets-file "$secrets" >/dev/null 2>&1; then
  fail 'unsafe relay URL unexpectedly succeeded'
fi
chmod 644 "$secrets"
if run_bootstrap --relay-url wss://relay.example.test/ws --secrets-file "$secrets" >/dev/null 2>&1; then
  fail 'unsafe secrets-file mode unexpectedly succeeded'
fi

grep -Fq 'private let service = "com.clickbridge.mac"' "$HELPER" ||
  fail 'helper does not target the Mac Keychain service'
grep -Fq 'private let account = "macToken"' "$HELPER" ||
  fail 'helper does not target the macToken account'
grep -Fq 'setPersistentDomain' "$HELPER" || fail 'helper does not persist the relay URL for the app'
grep -Fq 'configurationChanged' "$HELPER" || fail 'helper does not publish a configuration notification'

printf '%s\n' 'Owner Mac bootstrap tests passed'
