#!/usr/bin/env bash
set -Eeuo pipefail

CLICK_BRIDGE_ROOT="${CLICK_BRIDGE_ROOT:-/opt/click-bridge}"
CLICK_BRIDGE_RELEASE="${CLICK_BRIDGE_RELEASE:-}"
COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-oci}"
CANDIDATE_CONTAINER_NAME="${CANDIDATE_CONTAINER_NAME:-click-bridge-relay-candidate}"
CANDIDATE_HEALTH_ATTEMPTS="${CANDIDATE_HEALTH_ATTEMPTS:-30}"
PUBLIC_HEALTH_ATTEMPTS="${PUBLIC_HEALTH_ATTEMPTS:-30}"

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

validate_git_release() {
  [[ "$1" =~ ^[0-9a-f]{40}$ ]] ||
    die 'CLICK_BRIDGE_RELEASE must be a 40-character lowercase Git SHA'
}

validate_pointer_release() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] ||
    die 'release pointer contains unsafe characters'
}

secret_file_mode() {
  stat -c %a "$SHARED_ENV" 2>/dev/null || stat -f %Lp "$SHARED_ENV" 2>/dev/null
}

release_directory() {
  local release="$1"
  local expected="$RELEASES_ROOT/$release"
  local resolved

  validate_pointer_release "$release"
  [[ -d "$expected" ]] || die "release directory does not exist: $expected"
  resolved="$(cd "$expected" && pwd -P)"
  [[ "$resolved" = "$expected" ]] || die 'release directory escapes the immutable root'
  [[ -f "$resolved/deploy/oci/compose.yaml" ]] || die 'release compose file is missing'
  [[ -f "$resolved/relay/scripts/smoke-relay.mjs" ]] || die 'relay smoke script is missing'
  printf '%s\n' "$resolved"
}

read_pointer() {
  local name="$1"
  local path="$CLICK_BRIDGE_ROOT/$name"
  local release

  [[ -f "$path" ]] || return 1
  release="$(tr -d '\n' < "$path")"
  validate_pointer_release "$release"
  printf '%s\n' "$release"
}

write_pointer() {
  local name="$1"
  local release="$2"
  local temporary="$CLICK_BRIDGE_ROOT/.${name}.$$"

  validate_pointer_release "$release"
  umask 077
  printf '%s\n' "$release" > "$temporary"
  mv -f "$temporary" "$CLICK_BRIDGE_ROOT/$name"
}

compose_release() {
  local release="$1"
  shift
  local directory
  directory="$(release_directory "$release")"
  CLICK_BRIDGE_RELEASE="$release" docker compose \
    -p "$COMPOSE_PROJECT_NAME" \
    --env-file "$SHARED_ENV" \
    -f "$directory/deploy/oci/compose.yaml" \
    "$@"
}

cleanup_candidate() {
  docker rm -f "$CANDIDATE_CONTAINER_NAME" >/dev/null 2>&1 || true
}

verify_candidate() {
  local release="$1"
  local ready=0
  local attempt

  cleanup_candidate
  CLICK_BRIDGE_RELEASE="$release" docker run --detach \
    --name "$CANDIDATE_CONTAINER_NAME" \
    --publish 127.0.0.1:18080:8080 \
    --env-file "$SHARED_ENV" \
    --env PORT=8080 \
    --env HOST=0.0.0.0 \
    "click-bridge-relay:$release" >/dev/null

  for attempt in $(seq 1 "$CANDIDATE_HEALTH_ATTEMPTS"); do
    : "$attempt"
    if CLICK_BRIDGE_RELEASE="$release" docker exec "$CANDIDATE_CONTAINER_NAME" node -e \
      'fetch("http://127.0.0.1:8080/healthz").then(async response=>{if(!response.ok||(await response.text())!=="ok")process.exit(1)}).catch(()=>process.exit(1))'; then
      ready=1
      break
    fi
    sleep 1
  done

  if [[ "$ready" != 1 ]]; then
    docker logs --tail=100 "$CANDIDATE_CONTAINER_NAME" >&2 || true
    return 1
  fi
}

start_release() {
  compose_release "$1" up -d --no-build --force-recreate
}

verify_public_release() {
  local release="$1"
  local directory
  local ready=0
  local attempt
  directory="$(release_directory "$release")"

  for attempt in $(seq 1 "$PUBLIC_HEALTH_ATTEMPTS"); do
    : "$attempt"
    if CLICK_BRIDGE_RELEASE="$release" docker run --rm --network host \
      --add-host "$CLICK_BRIDGE_DOMAIN:127.0.0.1" \
      --env "CLICK_BRIDGE_DOMAIN=$CLICK_BRIDGE_DOMAIN" \
      node:24-alpine@sha256:d32cdf619f63fe0471182d08996dd516c6275bb5fd31ae06e55a570bd9e1ad43 node -e \
      'fetch(`https://${process.env.CLICK_BRIDGE_DOMAIN}/healthz`).then(async response=>{if(!response.ok||(await response.text())!=="ok")process.exit(1)}).catch(()=>process.exit(1))'; then
      ready=1
      break
    fi
    sleep 1
  done

  [[ "$ready" = 1 ]] || return 1

  CLICK_BRIDGE_RELEASE="$release" \
    PHONE_TOKEN="$PHONE_TOKEN" \
    MAC_TOKEN="$MAC_TOKEN" \
    docker run --rm --network host \
      --add-host "$CLICK_BRIDGE_DOMAIN:127.0.0.1" \
    --env "CLICK_BRIDGE_DOMAIN=$CLICK_BRIDGE_DOMAIN" \
    --env PHONE_TOKEN \
    --env MAC_TOKEN \
    --volume "$directory/relay:/workspace:ro" \
    --workdir /tmp/smoke \
    node:24-alpine@sha256:d32cdf619f63fe0471182d08996dd516c6275bb5fd31ae06e55a570bd9e1ad43 sh -euc \
    'cp -R /workspace/. .; npm ci --omit=dev --ignore-scripts >/dev/null; node scripts/smoke-relay.mjs "wss://${CLICK_BRIDGE_DOMAIN}/ws"'
}

validate_git_release "$CLICK_BRIDGE_RELEASE"
[[ "$CLICK_BRIDGE_ROOT" = /* ]] || die 'CLICK_BRIDGE_ROOT must be absolute'
[[ "$CLICK_BRIDGE_ROOT" != / ]] || die 'CLICK_BRIDGE_ROOT cannot be /'
[[ -d "$CLICK_BRIDGE_ROOT/releases" ]] || die 'release root is missing'
[[ -d "$CLICK_BRIDGE_ROOT/shared" ]] || die 'shared root is missing'
CLICK_BRIDGE_ROOT="$(cd "$CLICK_BRIDGE_ROOT" && pwd -P)"
RELEASES_ROOT="$CLICK_BRIDGE_ROOT/releases"
SHARED_ENV="$CLICK_BRIDGE_ROOT/shared/secrets.env"

[[ -f "$SHARED_ENV" ]] || die "missing $SHARED_ENV"
[[ "$(secret_file_mode)" = 600 ]] || die "$SHARED_ENV must have mode 0600"
for required_key in PHONE_TOKEN MAC_TOKEN CLICK_BRIDGE_DOMAIN; do
  [[ "$(grep -c "^${required_key}=" "$SHARED_ENV")" = 1 ]] ||
    die "$SHARED_ENV must define $required_key exactly once"
done
CLICK_BRIDGE_DOMAIN="$(sed -n 's/^CLICK_BRIDGE_DOMAIN=//p' "$SHARED_ENV")"
PHONE_TOKEN="$(sed -n 's/^PHONE_TOKEN=//p' "$SHARED_ENV")"
MAC_TOKEN="$(sed -n 's/^MAC_TOKEN=//p' "$SHARED_ENV")"
[[ "$CLICK_BRIDGE_DOMAIN" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]$ ]] ||
  die 'CLICK_BRIDGE_DOMAIN is not a valid hostname'
release_directory "$CLICK_BRIDGE_RELEASE" >/dev/null

CURRENT_RELEASE=''
if CURRENT_RELEASE="$(read_pointer current-release)"; then
  release_directory "$CURRENT_RELEASE" >/dev/null
fi

if [[ "$CURRENT_RELEASE" = "$CLICK_BRIDGE_RELEASE" ]]; then
  verify_public_release "$CLICK_BRIDGE_RELEASE" ||
    die 'current release failed public verification'
  compose_release "$CLICK_BRIDGE_RELEASE" ps
  printf 'Release %s is already current and healthy\n' "$CLICK_BRIDGE_RELEASE"
  exit 0
fi

write_pointer candidate-release "$CLICK_BRIDGE_RELEASE"
compose_release "$CLICK_BRIDGE_RELEASE" config --quiet
compose_release "$CLICK_BRIDGE_RELEASE" build --pull relay

trap cleanup_candidate EXIT INT TERM
verify_candidate "$CLICK_BRIDGE_RELEASE" ||
  die "candidate image failed health checks: $CLICK_BRIDGE_RELEASE"
cleanup_candidate
trap - EXIT INT TERM

if ! start_release "$CLICK_BRIDGE_RELEASE" || ! verify_public_release "$CLICK_BRIDGE_RELEASE"; then
  if [[ -n "$CURRENT_RELEASE" ]]; then
    printf 'Candidate failed after switch; restoring %s\n' "$CURRENT_RELEASE" >&2
    start_release "$CURRENT_RELEASE"
    verify_public_release "$CURRENT_RELEASE" ||
      die "automatic rollback verification failed for $CURRENT_RELEASE"
  else
    printf 'First candidate failed after switch; stopping failed stack\n' >&2
    compose_release "$CLICK_BRIDGE_RELEASE" down || true
  fi
  die "release failed public verification: $CLICK_BRIDGE_RELEASE"
fi

if [[ -n "$CURRENT_RELEASE" ]]; then
  write_pointer previous-release "$CURRENT_RELEASE"
fi
write_pointer current-release "$CLICK_BRIDGE_RELEASE"
rm -f "$CLICK_BRIDGE_ROOT/candidate-release"
compose_release "$CLICK_BRIDGE_RELEASE" ps
printf 'Release %s is healthy and current\n' "$CLICK_BRIDGE_RELEASE"
