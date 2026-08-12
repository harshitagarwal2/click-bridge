# Install and run the macOS receiver

This runbook builds the reviewed XcodeGen project, installs the menu-bar app at
a stable path, connects it to the WSS relay, and keeps updates recoverable. It
does not satisfy the physical acceptance gate: Accessibility-authorized Octo
clicking is still **NOT RUN** in [`physical-smoke-test.md`](physical-smoke-test.md).

## Requirements

- macOS 13 or newer, full Xcode 15 or newer selected as the active developer
  directory, and XcodeGen 2.46.0. Apple's standalone Command Line Tools package
  is not sufficient for this app's Xcode project and SwiftUI macro build.
- An operator-bootstrapped connection to a trusted relay. The bootstrap uses a
  relay URL in the exact form `wss://<host>/ws` and the relay's 64-character
  lowercase hexadecimal `MAC_TOKEN`; it must not expose that token in a URL,
  command argument, log, screenshot, or repository file.

The default project uses deterministic ad-hoc signing and needs no Apple
account. For a stable development signature, copy
`mac/Config/Local.xcconfig.example` to the ignored
`mac/Config/Local.xcconfig`, then set `DEVELOPMENT_TEAM` and
`CODE_SIGN_IDENTITY`. Never commit that local file. An ad-hoc rebuild changes
the app's code identity and can require Accessibility permission again.

## Build and verify the Release app

From the repository root:

```bash
xcode-select -p
xcodebuild -version
xcodegen --version
(cd mac && xcodegen generate)
xcodebuild \
  -project mac/ClickBridgeMac.xcodeproj \
  -scheme ClickBridgeMac \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath build \
  build
codesign --verify --strict build/Build/Products/Release/ClickBridgeMac.app
codesign -d --entitlements - build/Build/Products/Release/ClickBridgeMac.app
```

Expected: XcodeGen reports version 2.46.0, the Release build succeeds, signature
verification succeeds, and the ordinary locally installed build has no App
Sandbox entitlement. Release automation has separate signing rules; do not copy
its App Store or notarization credentials into local configuration.

`xcode-select -p` must identify a full Xcode developer directory such as
`/Applications/Xcode.app/Contents/Developer`, not
`/Library/Developer/CommandLineTools`. If needed, select the installed Xcode
before building:

```bash
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
```

## Install at the stable path

1. If Click Bridge is running, choose **Quit** from its menu-bar item.
2. Before an update, move the existing exact signed bundle to a dated backup
   outside `/Applications`; leave the destination absent and do not overwrite
   the only known-good copy.
3. Copy the verified Release bundle to the stable path:

   ```bash
   ditto build/Build/Products/Release/ClickBridgeMac.app \
     /Applications/ClickBridgeMac.app
   codesign --verify --strict /Applications/ClickBridgeMac.app
   open /Applications/ClickBridgeMac.app
   ```

Click Bridge is a menu-bar app and intentionally has no Dock icon or main
window. Always launch and grant permission to the installed
`/Applications/ClickBridgeMac.app`, not a DerivedData or build-directory copy.

## Connect the receiver

1. Have the relay operator run the secure owner-Mac bootstrap described in
   [Pairing persistence and owner-Mac bootstrap](oci-deployment.md#pairing-persistence-and-owner-mac-bootstrap).
   It installs `MAC_TOKEN` in Keychain and stores the relay URL without placing
   the credential in an argument or log.
2. Open the **Click Bridge** menu-bar item and choose **Settings…**. The normal
   phone flow is **Pair Phone**, or **Replace Phone** when one is enrolled.
3. If the menu says **Input permission: required**, choose
   **Grant Input Permission…**, allow Click Bridge under **System Settings →
   Privacy & Security → Accessibility**, then return to or relaunch the app.
4. Turn on **Remote control enabled** only when remote input is intended. This
   toggle does not grant Accessibility permission. Turn it off to reject remote
   actions without posting input.

For an alternate/self-hosted deployment or operator recovery, expand
**Advanced legacy connection**. Enter the exact `wss://<host>/ws` relay URL,
paste the matching `MAC_TOKEN`, and choose **Save**. **Clear** removes the
Keychain token and disconnects the receiver. These fields are not required for
normal phone pairing.

## Pair or replace a phone

1. In Mac **Settings…**, choose **Pair Phone**. If a phone is already enrolled,
   choose **Replace Phone** and confirm the replacement.
2. For a nearby iPhone, scan the QR code in Click Bridge. For a phone anywhere
   else on the internet, choose **Copy Invitation** or **Share…** and send the
   single-use HTTPS link through a trusted channel. The devices do not need to
   share a LAN.
3. Open the invitation in the native iOS app. Without the app, it opens the web
   claimant; to force the PWA, change only `/pair` to `/pair/web` and preserve
   the `#v=1&r=...` fragment.
4. Verify that the same six-digit confirmation code appears on the phone and
   Mac, then approve on the Mac. Do not approve a mismatch.

The invitation expires after five minutes and can be claimed only once. Create
a fresh invitation after expiry, cancellation, or a failed claim.

The Mac menu shows **Connected**, **Connecting…**, or **Disconnected** and the
last terminal result. The phone becomes **Ready** only after the relay sees this
Mac online with both remote control and Accessibility ready and completes its
clock check.

## Rotate role tokens

Before replacing the shared environment, open a shell on the VM and make one
fail-closed rollback copy. The fixed backup name deliberately blocks a second
rotation while an earlier one is unresolved:

```bash
set -Eeuo pipefail
umask 077
SECRET_FILE=/opt/click-bridge/shared/secrets.env
SECRET_BACKUP=/opt/click-bridge/shared/secrets.env.pre-rotation
validate_secret_file() {
  local file=$1 phone_token mac_token domain_pattern
  test -f "$file"
  test ! -L "$file"
  test "$(stat -c '%a' "$file")" = 600
  test "$(awk 'END { print NR }' "$file")" = 3
  test "$(tail -c 1 "$file" | od -An -tu1 | tr -d '[:space:]')" = 10
  test "$(grep -c '^CLICK_BRIDGE_DOMAIN=' "$file")" = 1
  test "$(grep -c '^PHONE_TOKEN=' "$file")" = 1
  test "$(grep -c '^MAC_TOKEN=' "$file")" = 1
  domain_pattern='^CLICK_BRIDGE_DOMAIN=([A-Za-z0-9]'
  domain_pattern+='([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+'
  domain_pattern+='[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$'
  grep -Eq "$domain_pattern" "$file"
  grep -Eq '^PHONE_TOKEN=[0-9a-f]{64}$' "$file"
  grep -Eq '^MAC_TOKEN=[0-9a-f]{64}$' "$file"
  phone_token=$(sed -n 's/^PHONE_TOKEN=//p' "$file")
  mac_token=$(sed -n 's/^MAC_TOKEN=//p' "$file")
  test "$phone_token" != "$mac_token"
}
validate_secret_file "$SECRET_FILE"
test ! -e "$SECRET_BACKUP"
install -m 0600 "$SECRET_FILE" "$SECRET_BACKUP"
validate_secret_file "$SECRET_BACKUP"
cmp -s "$SECRET_FILE" "$SECRET_BACKUP"
```

Do not use the fixed transfer-file commands in the general OCI installation
guide for rotation. Keep one interactive Mac shell open for the entire
rotation and run the next block directly in that shell, not in a subshell or
standalone script. It registers cleanup before generating either token, creates
the transfer file exclusively inside a private random directory, validates it,
uses a random remote staging file, and validates the VM files and immutable
release before recreating the relay. Replace only the two explicit operator
values before running it:

```bash
set -Eeuo pipefail
export OCI_SSH_TARGET='opc@146.235.216.172'
export CLICK_BRIDGE_DOMAIN='clickbridge-sjc.duckdns.org'
ROTATION_SECRET_DIR=''
LOCAL_SECRET_FILE=''
REMOTE_SECRET_FILE=''
cleanup_local_rotation_secrets() {
  local status=$?
  trap - EXIT ERR HUP INT TERM
  unset PHONE_TOKEN MAC_TOKEN
  if [[ -n "${REMOTE_SECRET_FILE:-}" ]]; then
    if ! ssh "$OCI_SSH_TARGET" "rm -f -- '$REMOTE_SECRET_FILE'"; then
      status=1
    fi
  fi
  if [[ -n "${LOCAL_SECRET_FILE:-}" ]]; then
    if ! rm -f -- "$LOCAL_SECRET_FILE"; then
      status=1
    fi
  fi
  if [[ -n "${ROTATION_SECRET_DIR:-}" ]]; then
    if ! rmdir -- "$ROTATION_SECRET_DIR"; then
      status=1
    fi
  fi
  return "$status"
}
trap cleanup_local_rotation_secrets EXIT
trap 'status=$?; exit "$status"' ERR
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
test -n "$OCI_SSH_TARGET"
ROTATION_SECRET_DIR=$(mktemp -d /private/tmp/click-bridge-rotation.XXXXXX)
test ! -L "$ROTATION_SECRET_DIR"
test "$(stat -f '%Lp' "$ROTATION_SECRET_DIR")" = 700
LOCAL_SECRET_FILE="$ROTATION_SECRET_DIR/secrets.env"
(umask 077; set -C; : > "$LOCAL_SECRET_FILE")
test -f "$LOCAL_SECRET_FILE"
test ! -L "$LOCAL_SECRET_FILE"
test "$(stat -f '%Lp' "$LOCAL_SECRET_FILE")" = 600
PHONE_TOKEN=$(openssl rand -hex 32)
MAC_TOKEN=$(openssl rand -hex 32)
test "$PHONE_TOKEN" != "$MAC_TOKEN"
{
  printf 'CLICK_BRIDGE_DOMAIN=%s\n' "$CLICK_BRIDGE_DOMAIN"
  printf 'PHONE_TOKEN=%s\n' "$PHONE_TOKEN"
  printf 'MAC_TOKEN=%s\n' "$MAC_TOKEN"
} > "$LOCAL_SECRET_FILE"
validate_local_secret_file() {
  local file=$1 phone_token mac_token domain_pattern
  test -f "$file"
  test ! -L "$file"
  test "$(stat -f '%Lp' "$file")" = 600
  test "$(awk 'END { print NR }' "$file")" = 3
  test "$(tail -c 1 "$file" | od -An -tu1 | tr -d '[:space:]')" = 10
  test "$(grep -c '^CLICK_BRIDGE_DOMAIN=' "$file")" = 1
  test "$(grep -c '^PHONE_TOKEN=' "$file")" = 1
  test "$(grep -c '^MAC_TOKEN=' "$file")" = 1
  domain_pattern='^CLICK_BRIDGE_DOMAIN=([A-Za-z0-9]'
  domain_pattern+='([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+'
  domain_pattern+='[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$'
  grep -Eq "$domain_pattern" "$file"
  grep -Eq '^PHONE_TOKEN=[0-9a-f]{64}$' "$file"
  grep -Eq '^MAC_TOKEN=[0-9a-f]{64}$' "$file"
  phone_token=$(sed -n 's/^PHONE_TOKEN=//p' "$file")
  mac_token=$(sed -n 's/^MAC_TOKEN=//p' "$file")
  test "$phone_token" != "$mac_token"
}
validate_local_secret_file "$LOCAL_SECRET_FILE"
remote_secret_candidate=$(
  ssh "$OCI_SSH_TARGET" \
    'umask 077; mktemp /tmp/click-bridge-secrets.XXXXXX'
)
[[ "$remote_secret_candidate" =~ ^/tmp/click-bridge-secrets\.[A-Za-z0-9]+$ ]]
REMOTE_SECRET_FILE=$remote_secret_candidate
unset remote_secret_candidate
scp "$LOCAL_SECRET_FILE" "$OCI_SSH_TARGET:$REMOTE_SECRET_FILE"
ssh "$OCI_SSH_TARGET" 'bash -se' -- "$REMOTE_SECRET_FILE" <<'REMOTE'
set -Eeuo pipefail
REMOTE_SECRET_FILE=$1
SECRET_FILE=/opt/click-bridge/shared/secrets.env
SECRET_BACKUP=/opt/click-bridge/shared/secrets.env.pre-rotation
cleanup_remote_secret() {
  local status=$?
  trap - EXIT ERR HUP INT TERM
  rm -f -- "$REMOTE_SECRET_FILE" || status=1
  return "$status"
}
trap cleanup_remote_secret EXIT
trap 'status=$?; exit "$status"' ERR
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
validate_secret_file() {
  local file=$1 phone_token mac_token domain_pattern
  test -f "$file"
  test ! -L "$file"
  test "$(stat -c '%a' "$file")" = 600
  test "$(awk 'END { print NR }' "$file")" = 3
  test "$(tail -c 1 "$file" | od -An -tu1 | tr -d '[:space:]')" = 10
  test "$(grep -c '^CLICK_BRIDGE_DOMAIN=' "$file")" = 1
  test "$(grep -c '^PHONE_TOKEN=' "$file")" = 1
  test "$(grep -c '^MAC_TOKEN=' "$file")" = 1
  domain_pattern='^CLICK_BRIDGE_DOMAIN=([A-Za-z0-9]'
  domain_pattern+='([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+'
  domain_pattern+='[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$'
  grep -Eq "$domain_pattern" "$file"
  grep -Eq '^PHONE_TOKEN=[0-9a-f]{64}$' "$file"
  grep -Eq '^MAC_TOKEN=[0-9a-f]{64}$' "$file"
  phone_token=$(sed -n 's/^PHONE_TOKEN=//p' "$file")
  mac_token=$(sed -n 's/^MAC_TOKEN=//p' "$file")
  test "$phone_token" != "$mac_token"
}
validate_secret_file "$REMOTE_SECRET_FILE"
validate_secret_file "$SECRET_FILE"
validate_secret_file "$SECRET_BACKUP"
cmp -s "$SECRET_FILE" "$SECRET_BACKUP"
if cmp -s "$REMOTE_SECRET_FILE" "$SECRET_BACKUP"; then
  printf 'Replacement tokens match the rollback copy; refusing rotation.\n' >&2
  exit 1
else
  CMP_STATUS=$?
fi
test "$CMP_STATUS" = 1
install -m 0600 "$REMOTE_SECRET_FILE" "$SECRET_FILE"
validate_secret_file "$SECRET_FILE"
cmp -s "$REMOTE_SECRET_FILE" "$SECRET_FILE"
export ACTIVE_RELEASE="$(tr -d '\n' < /opt/click-bridge/current-release)"
[[ "$ACTIVE_RELEASE" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || exit 1
RELEASE_DIR="/opt/click-bridge/releases/$ACTIVE_RELEASE"
COMPOSE_FILE="$RELEASE_DIR/deploy/oci/compose.yaml"
test -d "$RELEASE_DIR"
test -f "$COMPOSE_FILE"
export CLICK_BRIDGE_RELEASE="$ACTIVE_RELEASE"
cd "$RELEASE_DIR"
docker compose -p oci \
  --env-file "$SECRET_FILE" \
  -f "$COMPOSE_FILE" \
  config --quiet
docker compose -p oci \
  --env-file "$SECRET_FILE" \
  -f "$COMPOSE_FILE" \
  up -d --no-build --force-recreate relay
docker compose -p oci \
  --env-file "$SECRET_FILE" \
  -f "$COMPOSE_FILE" \
  ps
REMOTE
REMOTE_SECRET_FILE=''
```

A plain `docker compose restart` is not a rotation: it preserves the old
container environment. Run the complete external HTTPS/WSS smoke in
[OCI deployment step 10](oci-deployment.md#10-prove-the-public-application-before-marking-it-current)
with `"$LOCAL_SECRET_FILE"` substituted for that guide's fixed-path transfer
file. Only after smoke succeeds, save the new `MAC_TOKEN` in the receiver and
the new `PHONE_TOKEN` in the chosen phone client. Confirm the Mac is
**Connected** and the phone returns to **Ready**, then remove the VM rollback
copy and the private local transfer directory without reading either. Run this
in the same Mac shell; its final assertions prove the token variables are no
longer exported or set:

```bash
set -Eeuo pipefail
declare -F cleanup_local_rotation_secrets >/dev/null
test -n "${ROTATION_SECRET_DIR:-}"
test -n "${LOCAL_SECRET_FILE:-}"
test -n "${OCI_SSH_TARGET:-}"
ssh "$OCI_SSH_TARGET" 'bash -se' <<'REMOTE'
set -Eeuo pipefail
SECRET_FILE=/opt/click-bridge/shared/secrets.env
SECRET_BACKUP=/opt/click-bridge/shared/secrets.env.pre-rotation
validate_secret_file() {
  local file=$1 phone_token mac_token domain_pattern
  test -f "$file"
  test ! -L "$file"
  test "$(stat -c '%a' "$file")" = 600
  test "$(awk 'END { print NR }' "$file")" = 3
  test "$(tail -c 1 "$file" | od -An -tu1 | tr -d '[:space:]')" = 10
  test "$(grep -c '^CLICK_BRIDGE_DOMAIN=' "$file")" = 1
  test "$(grep -c '^PHONE_TOKEN=' "$file")" = 1
  test "$(grep -c '^MAC_TOKEN=' "$file")" = 1
  domain_pattern='^CLICK_BRIDGE_DOMAIN=([A-Za-z0-9]'
  domain_pattern+='([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+'
  domain_pattern+='[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$'
  grep -Eq "$domain_pattern" "$file"
  grep -Eq '^PHONE_TOKEN=[0-9a-f]{64}$' "$file"
  grep -Eq '^MAC_TOKEN=[0-9a-f]{64}$' "$file"
  phone_token=$(sed -n 's/^PHONE_TOKEN=//p' "$file")
  mac_token=$(sed -n 's/^MAC_TOKEN=//p' "$file")
  test "$phone_token" != "$mac_token"
}
validate_secret_file "$SECRET_FILE"
validate_secret_file "$SECRET_BACKUP"
rm -f -- "$SECRET_BACKUP"
test ! -e "$SECRET_BACKUP"
REMOTE
cleanup_local_rotation_secrets
trap - EXIT ERR HUP INT TERM
test ! -e "$LOCAL_SECRET_FILE"
test ! -e "$ROTATION_SECRET_DIR"
test -z "${PHONE_TOKEN+x}"
test -z "${MAC_TOKEN+x}"
unset ROTATION_SECRET_DIR LOCAL_SECRET_FILE REMOTE_SECRET_FILE
```

If recreation or public smoke fails, do not update the clients. Restore and
verify the prior environment on the VM:

```bash
set -Eeuo pipefail
SECRET_FILE=/opt/click-bridge/shared/secrets.env
SECRET_BACKUP=/opt/click-bridge/shared/secrets.env.pre-rotation
validate_secret_file() {
  local file=$1 phone_token mac_token domain_pattern
  test -f "$file"
  test ! -L "$file"
  test "$(stat -c '%a' "$file")" = 600
  test "$(awk 'END { print NR }' "$file")" = 3
  test "$(tail -c 1 "$file" | od -An -tu1 | tr -d '[:space:]')" = 10
  test "$(grep -c '^CLICK_BRIDGE_DOMAIN=' "$file")" = 1
  test "$(grep -c '^PHONE_TOKEN=' "$file")" = 1
  test "$(grep -c '^MAC_TOKEN=' "$file")" = 1
  domain_pattern='^CLICK_BRIDGE_DOMAIN=([A-Za-z0-9]'
  domain_pattern+='([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+'
  domain_pattern+='[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$'
  grep -Eq "$domain_pattern" "$file"
  grep -Eq '^PHONE_TOKEN=[0-9a-f]{64}$' "$file"
  grep -Eq '^MAC_TOKEN=[0-9a-f]{64}$' "$file"
  phone_token=$(sed -n 's/^PHONE_TOKEN=//p' "$file")
  mac_token=$(sed -n 's/^MAC_TOKEN=//p' "$file")
  test "$phone_token" != "$mac_token"
}
validate_secret_file "$SECRET_BACKUP"
install -m 0600 "$SECRET_BACKUP" "$SECRET_FILE"
validate_secret_file "$SECRET_BACKUP"
validate_secret_file "$SECRET_FILE"
cmp -s "$SECRET_BACKUP" "$SECRET_FILE"
```

Recreate the relay with a separate recovery guard that requires the restored
file to match the rollback copy:

```bash
set -Eeuo pipefail
SECRET_FILE=/opt/click-bridge/shared/secrets.env
SECRET_BACKUP=/opt/click-bridge/shared/secrets.env.pre-rotation
validate_secret_file() {
  local file=$1 phone_token mac_token domain_pattern
  test -f "$file"
  test ! -L "$file"
  test "$(stat -c '%a' "$file")" = 600
  test "$(awk 'END { print NR }' "$file")" = 3
  test "$(tail -c 1 "$file" | od -An -tu1 | tr -d '[:space:]')" = 10
  test "$(grep -c '^CLICK_BRIDGE_DOMAIN=' "$file")" = 1
  test "$(grep -c '^PHONE_TOKEN=' "$file")" = 1
  test "$(grep -c '^MAC_TOKEN=' "$file")" = 1
  domain_pattern='^CLICK_BRIDGE_DOMAIN=([A-Za-z0-9]'
  domain_pattern+='([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+'
  domain_pattern+='[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$'
  grep -Eq "$domain_pattern" "$file"
  grep -Eq '^PHONE_TOKEN=[0-9a-f]{64}$' "$file"
  grep -Eq '^MAC_TOKEN=[0-9a-f]{64}$' "$file"
  phone_token=$(sed -n 's/^PHONE_TOKEN=//p' "$file")
  mac_token=$(sed -n 's/^MAC_TOKEN=//p' "$file")
  test "$phone_token" != "$mac_token"
}
validate_secret_file "$SECRET_FILE"
validate_secret_file "$SECRET_BACKUP"
cmp -s "$SECRET_BACKUP" "$SECRET_FILE"
export ACTIVE_RELEASE="$(tr -d '\n' < /opt/click-bridge/current-release)"
[[ "$ACTIVE_RELEASE" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || exit 1
RELEASE_DIR="/opt/click-bridge/releases/$ACTIVE_RELEASE"
COMPOSE_FILE="$RELEASE_DIR/deploy/oci/compose.yaml"
test -d "$RELEASE_DIR"
test -f "$COMPOSE_FILE"
export CLICK_BRIDGE_RELEASE="$ACTIVE_RELEASE"
cd "$RELEASE_DIR"
docker compose -p oci \
  --env-file "$SECRET_FILE" \
  -f "$COMPOSE_FILE" \
  config --quiet
docker compose -p oci \
  --env-file "$SECRET_FILE" \
  -f "$COMPOSE_FILE" \
  up -d --no-build --force-recreate relay
docker compose -p oci \
  --env-file "$SECRET_FILE" \
  -f "$COMPOSE_FILE" \
  ps
```

Repeat the external smoke. Keep the rollback copy until recovery passes; remove
it and the local transfer file with the cleanup block above only after the old
clients are working again. Run that block in the original Mac shell so its trap
is disarmed, its private directory is removed, and `PHONE_TOKEN` and `MAC_TOKEN`
are unset on the rollback path too. Exiting or interrupting that shell earlier
runs the same cleanup automatically.

## Recover safely

- **Disconnected:** confirm a token is stored, the WSS URL is exact, and the
  public relay is healthy; then choose **Reconnect**.
- **Input permission: required:** reopen Accessibility settings with
  **Grant Input Permission…**. If a rebuild used a different ad-hoc identity,
  remove the stale entry if necessary and grant the installed bundle again.
- **Keychain error:** the receiver fails closed. Retry after Keychain access is
  available; do not move the token into plaintext preferences or source files.
- **Emergency stop:** turn **Remote control enabled** off. For a full disconnect,
  choose **Clear** in Settings or quit the app.
- **Bundle rollback:** turn remote control off, quit the app, move the faulty
  bundle aside, restore the preserved known-good signed bundle to
  `/Applications/ClickBridgeMac.app`, verify it with `codesign --verify
  --strict`, and relaunch it. Re-grant Accessibility only if macOS no longer
  recognizes that exact bundle identity.
- **Relay or VM recovery:** use [`oci-recovery.md`](oci-recovery.md); it preserves
  the shared mode-`0600` token file and switches only after external smoke tests.

## Verify without overstating success

With the Mac unlocked and awake, automatic date and time enabled, remote control
on, and the pointer over the harmless target, one accepted logical action should
produce three left-button down/up pairs. A Mac `Posted` result records attempted
`CGEvent.post` calls; Core Graphics provides no delivery acknowledgement. Only
an observed Octo counter change of exactly `+3` proves the physical target
received the burst.

Record that result through [`physical-smoke-test.md`](physical-smoke-test.md).
Until the real phone, public relay, installed receiver, and Octo session are run
and recorded together, physical and latency acceptance remain **NOT RUN**.
