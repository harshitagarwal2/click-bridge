# Install and run the macOS receiver

This runbook builds the reviewed XcodeGen project, installs the menu-bar app at
a stable path, connects it to the WSS relay, and keeps updates recoverable. It
does not satisfy the physical acceptance gate: Accessibility-authorized Octo
clicking is still **NOT RUN** in [`physical-smoke-test.md`](physical-smoke-test.md).

## Requirements

- macOS 13 or newer, full Xcode 15 or newer selected as the active developer
  directory, and XcodeGen 2.46.0. Apple's standalone Command Line Tools package
  is not sufficient for this app's Xcode project and SwiftUI macro build.
- A trusted relay URL in the exact form `wss://<host>/ws`. The receiver rejects
  insecure `ws://`, credentials, queries, fragments, and other paths.
- The relay's 64-character lowercase hexadecimal `MAC_TOKEN`. Do not put it in
  a URL, command argument, log, screenshot, or repository file.

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

1. Open the **Click Bridge** menu-bar item and choose **Settings…**.
2. Enter the relay URL as `wss://<host>/ws`.
3. Paste the matching `MAC_TOKEN` and choose **Save**. The token is stored in
   Keychain; the relay URL and remote-control preference are stored in
   UserDefaults. Saving a replacement token reconnects with the new credential.
   **Clear** removes the Keychain token and disconnects the receiver.
4. If the menu says **Input permission: required**, choose
   **Grant Input Permission…**, allow Click Bridge under **System Settings →
   Privacy & Security → Accessibility**, then return to or relaunch the app.
5. Turn on **Remote control enabled** only when remote input is intended. This
   toggle does not grant Accessibility permission. Turn it off to reject remote
   actions without posting input.

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
  test "$(wc -l < "$file" | tr -d '[:space:]')" = 3
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

Follow only the generation and VM-install commands in
[OCI deployment step 7](oci-deployment.md#7-install-the-one-shared-role-token-environment);
do not update either client yet. Keep the same interactive Mac shell open for
the entire rotation. In that shell, run the next block directly, not in a
subshell or standalone script. It validates the protected local transfer file,
registers cleanup for shell exit and interruption, then validates both VM files
and the immutable release before recreating the relay:

```bash
set -Eeuo pipefail
LOCAL_SECRET_FILE=/private/tmp/click-bridge-secrets.env
validate_local_secret_file() {
  local file=$1 phone_token mac_token domain_pattern
  test -f "$file"
  test ! -L "$file"
  test "$(stat -f '%Lp' "$file")" = 600
  test "$(wc -l < "$file" | tr -d '[:space:]')" = 3
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
cleanup_local_rotation_secrets() {
  local status=$?
  if ! rm -f -- "$LOCAL_SECRET_FILE"; then
    printf 'Could not remove %s\n' "$LOCAL_SECRET_FILE" >&2
    status=1
  fi
  unset PHONE_TOKEN MAC_TOKEN
  trap - EXIT
  return "$status"
}
validate_local_secret_file "$LOCAL_SECRET_FILE"
trap cleanup_local_rotation_secrets EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
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
  test "$(wc -l < "$file" | tr -d '[:space:]')" = 3
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
if cmp -s "$SECRET_FILE" "$SECRET_BACKUP"; then
  printf 'Replacement tokens match the rollback copy; refusing rotation.\n' >&2
  exit 1
else
  CMP_STATUS=$?
fi
test "$CMP_STATUS" = 1
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
```

A plain `docker compose restart` is not a rotation: it preserves the old
container environment. Run the complete external HTTPS/WSS smoke in
[OCI deployment step 10](oci-deployment.md#10-prove-the-public-application-before-marking-it-current)
with the new protected transfer file. Only after that succeeds, save the new
`MAC_TOKEN` in the receiver and the new `PHONE_TOKEN` in the chosen phone client.
Confirm the Mac is **Connected** and the phone returns to **Ready**, then remove
the VM rollback copy and the local transfer file without reading either. Run
this in the same Mac shell; its final assertions prove the token variables are
no longer exported or set:

```bash
set -Eeuo pipefail
LOCAL_SECRET_FILE=/private/tmp/click-bridge-secrets.env
cleanup_local_rotation_secrets() {
  local status=$?
  if ! rm -f -- "$LOCAL_SECRET_FILE"; then
    printf 'Could not remove %s\n' "$LOCAL_SECRET_FILE" >&2
    status=1
  fi
  unset PHONE_TOKEN MAC_TOKEN
  trap - EXIT
  return "$status"
}
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
  test "$(wc -l < "$file" | tr -d '[:space:]')" = 3
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
trap - HUP INT TERM
test ! -e "$LOCAL_SECRET_FILE"
test -z "${PHONE_TOKEN+x}"
test -z "${MAC_TOKEN+x}"
unset LOCAL_SECRET_FILE
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
  test "$(wc -l < "$file" | tr -d '[:space:]')" = 3
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
  test "$(wc -l < "$file" | tr -d '[:space:]')" = 3
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
is disarmed and `PHONE_TOKEN` and `MAC_TOKEN` are unset on the rollback path too.

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
