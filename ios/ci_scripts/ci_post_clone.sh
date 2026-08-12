#!/bin/sh
set -eu

xcodegen_version='2.46.0'
xcodegen_sha256='4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806'
xcodegen_url='https://github.com/yonaskolb/XcodeGen/releases/download/2.46.0/xcodegen.zip'
ios_directory="$(
  CDPATH=''
  export CDPATH
  cd -- "$(dirname -- "$0")/.."
  pwd
)"

if command -v xcodegen >/dev/null 2>&1 &&
  test "$(xcodegen --version)" = "Version: ${xcodegen_version}"; then
  xcodegen_binary="$(command -v xcodegen)"
else
  temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/click-bridge-xcodegen.XXXXXX")"
  archive="${temporary_directory}/xcodegen-${xcodegen_version}.zip"
  extracted="${temporary_directory}/source"
  install_root="${temporary_directory}/install"

  curl --fail --location --retry 3 --output "$archive" "$xcodegen_url"
  printf '%s  %s\n' "$xcodegen_sha256" "$archive" | shasum -a 256 -c -
  unzip -q "$archive" -d "$extracted"
  mkdir -p "$install_root"
  PREFIX="$install_root" "$extracted/xcodegen/install.sh"
  xcodegen_binary="${install_root}/bin/xcodegen"
  "$xcodegen_binary" --version | grep -Fx "Version: ${xcodegen_version}"
fi

cd "$ios_directory"
"$xcodegen_binary" generate
