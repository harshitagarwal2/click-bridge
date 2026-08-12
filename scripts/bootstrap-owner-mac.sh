#!/usr/bin/env bash
set -Eeuo pipefail

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

file_mode() {
  stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null
}

relay_url=''
secrets_file=''
ssh_host=''
while (($#)); do
  case "$1" in
    --relay-url)
      (($# >= 2)) || die '--relay-url requires a value'
      relay_url="$2"; shift 2 ;;
    --secrets-file)
      (($# >= 2)) || die '--secrets-file requires a value'
      secrets_file="$2"; shift 2 ;;
    --ssh-host)
      (($# >= 2)) || die '--ssh-host requires a value'
      ssh_host="$2"; shift 2 ;;
    *) die 'usage: bootstrap-owner-mac.sh --relay-url URL (--secrets-file FILE | --ssh-host USER@HOST)' ;;
  esac
done

[[ $- != *x* ]] || die 'xtrace must be disabled for credential bootstrap'
[[ "$relay_url" =~ ^(wss|https)://[A-Za-z0-9][A-Za-z0-9.-]*(:[0-9]{1,5})?(/[^[:space:]#]*)?$ ]] ||
  die 'relay URL must use wss:// or https:// without a fragment'
if [[ -n "$secrets_file" && -n "$ssh_host" ]] || [[ -z "$secrets_file" && -z "$ssh_host" ]]; then
  die 'provide exactly one of --secrets-file or --ssh-host'
fi

umask 077
token_dir="${TMPDIR:-/tmp}/click-bridge-owner-token.$$.$RANDOM.$RANDOM"
token_file="$token_dir/credential"
helper_pid=''
cleanup() {
  rm -f -- "$token_file"
  rmdir "$token_dir" 2>/dev/null || true
}
on_signal() {
  trap '' INT TERM HUP
  if [[ -n "$helper_pid" ]]; then
    kill -TERM -- "$helper_pid" 2>/dev/null || true
    wait "$helper_pid" 2>/dev/null || true
    helper_pid=''
  fi
  cleanup
  exit 130
}
trap on_signal INT TERM HUP
mkdir -m 700 -- "$token_dir"
trap cleanup EXIT
: > "$token_file"
chmod 600 "$token_file"

if [[ -n "$secrets_file" ]]; then
  [[ -f "$secrets_file" && ! -L "$secrets_file" ]] || die 'secrets file must be a regular file'
  [[ "$(file_mode "$secrets_file")" = 600 ]] || die 'secrets file must have mode 0600'
  [[ "$(grep -c '^MAC_TOKEN=' "$secrets_file")" = 1 ]] ||
    die 'secrets file must define MAC_TOKEN exactly once'
  awk -F= '$1 == "MAC_TOKEN" { print substr($0, index($0, "=") + 1) }' \
    "$secrets_file" > "$token_file"
else
  [[ "$ssh_host" =~ ^[a-z_][a-z0-9_-]*@[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]$ ]] ||
    die 'SSH host must be USER@HOST'
  ssh -o BatchMode=yes -- "$ssh_host" \
    'set -eu; f=/opt/click-bridge/shared/secrets.env; test -f "$f"; test ! -L "$f"; test "$(stat -c %a "$f")" = 600; test "$(grep -c "^MAC_TOKEN=" "$f")" = 1; awk -F= '\''$1 == "MAC_TOKEN" { print substr($0, index($0, "=") + 1) }'\'' "$f"' \
    > "$token_file" 2>/dev/null || die 'could not retrieve the owner credential'
fi

[[ "$(file_mode "$token_file")" = 600 ]] || die 'temporary credential file is unsafe'
grep -Eq '^[0-9a-f]{64}$' "$token_file" || die 'MAC_TOKEN is invalid'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
swift "$SCRIPT_DIR/bootstrap-owner-keychain.swift" --relay-url "$relay_url" \
  < "$token_file" >/dev/null 2>&1 &
helper_pid=$!
if ! wait "$helper_pid"; then
  die 'could not configure the owner Mac'
fi
helper_pid=''

cleanup
trap - EXIT INT TERM HUP
