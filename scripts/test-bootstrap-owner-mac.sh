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

cat > "$FAKE_BIN/swift" <<'FAKE_SWIFT'
#!/usr/bin/env bash
set -Eeuo pipefail
token="$(tr -d '\n')"
test "$token" = "$EXPECTED_TOKEN"
printf 'swift-args=%s\n' "$*" >> "$FAKE_LOG"
printf '%s\n' "$EXPECTED_TOKEN"
printf '%s\n' "$EXPECTED_TOKEN" >&2
if test -n "${FAKE_SWIFT_DELAY:-}"; then sleep "$FAKE_SWIFT_DELAY"; fi
test "${FAKE_SWIFT_FAIL:-0}" != 1
FAKE_SWIFT
chmod +x "$FAKE_BIN/swift"

cat > "$FAKE_BIN/ssh" <<'FAKE_SSH'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'ssh-args=%s\n' "$*" >> "$FAKE_LOG"
printf '%s\n' "$EXPECTED_TOKEN"
FAKE_SSH
chmod +x "$FAKE_BIN/ssh"

run_bootstrap() {
  env PATH="$FAKE_BIN:/usr/bin:/bin" EXPECTED_TOKEN="$TOKEN" FAKE_LOG="$FAKE_LOG" TMPDIR="$TOKEN_TMP" \
    FAKE_SWIFT_FAIL="${FAKE_SWIFT_FAIL:-0}" FAKE_SWIFT_DELAY="${FAKE_SWIFT_DELAY:-}" \
    bash "$BOOTSTRAP" "$@"
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
test -z "$(find "$TOKEN_TMP" -type f -print -quit)" || fail 'temporary token survived success'

: > "$FAKE_LOG"
output="$(run_bootstrap --relay-url https://relay.example.test --ssh-host opc@relay.example.test 2>&1)"
test -z "$output" || fail 'SSH bootstrap emitted output on success'
grep -Fq 'ssh-args=' "$FAKE_LOG" || fail 'SSH source was not used'
if grep -Fq "$TOKEN" "$FAKE_LOG"; then fail 'token leaked into SSH arguments or log'; fi

if output="$(FAKE_SWIFT_FAIL=1 run_bootstrap --relay-url wss://relay.example.test/ws \
    --secrets-file "$secrets" 2>&1)"; then
  fail 'failed Swift helper unexpectedly succeeded'
fi
case "$output" in *"$TOKEN"*) fail 'token leaked during helper failure' ;; esac
test -z "$(find "$TOKEN_TMP" -type f -print -quit)" || fail 'temporary token survived failure'

FAKE_SWIFT_DELAY=0.2 run_bootstrap --relay-url wss://relay.example.test/ws \
  --secrets-file "$secrets" >/dev/null 2>&1 &
bootstrap_pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
  test -n "$(find "$TOKEN_TMP" -type f -print -quit)" && break
  sleep 0.01
done
kill -TERM "$bootstrap_pid"
wait "$bootstrap_pid" 2>/dev/null || true
sleep 0.3
test -z "$(find "$TOKEN_TMP" -type f -print -quit)" || fail 'temporary token survived TERM'

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
