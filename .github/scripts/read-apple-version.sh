#!/bin/sh
set -eu

script_directory=$(
  CDPATH=
  export CDPATH
  cd -- "$(dirname -- "$0")"
  pwd
)
repository_root=$(cd -- "$script_directory/../.." && pwd)
version_file="$repository_root/Config/Version.xcconfig"

read_setting() {
  setting=$1
  awk -v setting="$setting" '
    /^[[:space:]]*\/\// { next }
    {
      line = $0
      sub(/[[:space:]]*\/\/.*$/, "", line)
      if (line ~ "^[[:space:]]*" setting "[[:space:]]*=") {
        sub("^[[:space:]]*" setting "[[:space:]]*=[[:space:]]*", "", line)
        sub(/[[:space:]]*$/, "", line)
        values[++count] = line
      }
    }
    END {
      if (count != 1 || values[1] == "") exit 1
      print values[1]
    }
  ' "$version_file"
}

marketing_version=$(read_setting MARKETING_VERSION)
build_number=$(read_setting CURRENT_PROJECT_VERSION)

printf '%s\n' "$marketing_version" | grep -Eq '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(\.(0|[1-9][0-9]*))?$'
printf '%s\n' "$build_number" | grep -Eq '^[1-9][0-9]*(\.[0-9]+){0,2}$'

case "${1:-}" in
  marketing) printf '%s\n' "$marketing_version" ;;
  build) printf '%s\n' "$build_number" ;;
  *) echo 'usage: read-apple-version.sh marketing|build' >&2; exit 64 ;;
esac
