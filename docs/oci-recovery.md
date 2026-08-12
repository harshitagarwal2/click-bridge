# OCI recovery and rollback

Click Bridge has no application database or persistent relay state. Recovery
needs four durable inputs: the Git source, a retained immutable release,
`/opt/click-bridge/shared/secrets.env`, and the hostname's DNS record. Caddy's
named volumes retain certificate state but can be regenerated when necessary.

All commands use the fixed Compose project name `oci`, matching the original
deployment and preserving its existing Caddy volumes through migration.

Never copy the shared environment into a release. Never delete a failed release
or its logs while diagnosing it.

## Inspect without changing the running stack

```bash
test -f /opt/click-bridge/shared/secrets.env
test "$(stat -c %a /opt/click-bridge/shared/secrets.env)" = 600
cat /opt/click-bridge/current-release
test ! -f /opt/click-bridge/previous-release || cat /opt/click-bridge/previous-release
docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'
docker volume ls --filter label=com.docker.compose.project=oci
```

## One-time flat-layout migration fallback

Until the first immutable release has passed rollback and roll-forward, retain
the original `/opt/click-bridge/{relay,deploy}` tree, its mode-0600
`deploy/oci/.env`, and its old image. If the first immutable cutover fails:

```bash
set -eu
test -f /opt/click-bridge/candidate-release
FAILED_RELEASE="$(cat /opt/click-bridge/candidate-release)"
case "$FAILED_RELEASE" in
  [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z) ;;
  *) printf 'Invalid migration release ID.\n' >&2; exit 1 ;;
esac
test -d "/opt/click-bridge/releases/$FAILED_RELEASE"
cd "/opt/click-bridge/releases/$FAILED_RELEASE"
export CLICK_BRIDGE_RELEASE="$FAILED_RELEASE"
docker compose -p oci --env-file /opt/click-bridge/shared/secrets.env \
  -f deploy/oci/compose.yaml down
cd /opt/click-bridge
unset CLICK_BRIDGE_RELEASE
docker compose -p oci --env-file deploy/oci/.env \
  -f deploy/oci/compose.yaml up -d --no-build --force-recreate
docker compose -p oci --env-file deploy/oci/.env \
  -f deploy/oci/compose.yaml ps
```

Re-run HTTPS/WSS/port-isolation smoke against the restored legacy service. Do
not write `current-release` until the immutable candidate passes. After a
successful rollback and roll-forward, keep the legacy tree until a second
immutable release establishes the normal `previous-release` path.

## Failed candidate before it becomes current

`current-release` still names the last known-good release. Do not derive
`FAILED_RELEASE` from that file.

```bash
export FAILED_RELEASE='ACTUAL_FAILED_CANDIDATE_RELEASE'
export RECOVERY_RELEASE="$(cat /opt/click-bridge/current-release)"
test -n "$RECOVERY_RELEASE"
test "$RECOVERY_RELEASE" != "$FAILED_RELEASE"
export CLICK_BRIDGE_RELEASE="$RECOVERY_RELEASE"
cd "/opt/click-bridge/releases/$RECOVERY_RELEASE"
docker compose -p oci --env-file /opt/click-bridge/shared/secrets.env \
  -f deploy/oci/compose.yaml up -d --no-build --force-recreate
docker compose -p oci --env-file /opt/click-bridge/shared/secrets.env \
  -f deploy/oci/compose.yaml ps
```

Rerun the full external HTTPS, WSS, CSP, log, and public-port smoke from
`docs/oci-deployment.md`. Do not rewrite `current-release` unless that smoke
passes. If this was the first-ever candidate, no previous application exists:
leave `current-release` absent, preserve the failed release/logs, fix the cause,
and deploy a new timestamped release.

## Rebuild the active release in place

Use this for first-release recovery or lost containers/images:

```bash
export ACTIVE_RELEASE="$(cat /opt/click-bridge/current-release)"
test -n "$ACTIVE_RELEASE"
export CLICK_BRIDGE_RELEASE="$ACTIVE_RELEASE"
cd "/opt/click-bridge/releases/$ACTIVE_RELEASE"
docker compose -p oci --env-file /opt/click-bridge/shared/secrets.env \
  -f deploy/oci/compose.yaml build
docker compose -p oci --env-file /opt/click-bridge/shared/secrets.env \
  -f deploy/oci/compose.yaml up -d --force-recreate
docker compose -p oci --env-file /opt/click-bridge/shared/secrets.env \
  -f deploy/oci/compose.yaml ps
```

Run the full external smoke before calling recovery successful.

## Prove rollback and roll-forward

Deploy a second verified timestamped release first. Step 9 of the deployment
runbook copies the old `current-release` into `previous-release` before
starting the candidate and marks the new release current only after public
smoke passes.

Rollback:

```bash
export FORWARD_RELEASE="$(cat /opt/click-bridge/current-release)"
export ROLLBACK_RELEASE="$(cat /opt/click-bridge/previous-release)"
test -n "$ROLLBACK_RELEASE"
test "$ROLLBACK_RELEASE" != "$FORWARD_RELEASE"
export CLICK_BRIDGE_RELEASE="$ROLLBACK_RELEASE"
cd "/opt/click-bridge/releases/$ROLLBACK_RELEASE"
docker compose -p oci --env-file /opt/click-bridge/shared/secrets.env \
  -f deploy/oci/compose.yaml up -d --no-build --force-recreate
docker compose -p oci --env-file /opt/click-bridge/shared/secrets.env \
  -f deploy/oci/compose.yaml ps
```

Run full external smoke, then and only then:

```bash
printf '%s\n' "$ROLLBACK_RELEASE" > /opt/click-bridge/current-release
```

Roll forward to the already-built candidate:

```bash
export CLICK_BRIDGE_RELEASE="$FORWARD_RELEASE"
cd "/opt/click-bridge/releases/$FORWARD_RELEASE"
docker compose -p oci --env-file /opt/click-bridge/shared/secrets.env \
  -f deploy/oci/compose.yaml up -d --no-build --force-recreate
docker compose -p oci --env-file /opt/click-bridge/shared/secrets.env \
  -f deploy/oci/compose.yaml ps
```

Run full external smoke again, then:

```bash
printf '%s\n' "$FORWARD_RELEASE" > /opt/click-bridge/current-release
printf '%s\n' "$ROLLBACK_RELEASE" > /opt/click-bridge/previous-release
```

## Restart each service independently

```bash
export ACTIVE_RELEASE="$(cat /opt/click-bridge/current-release)"
export CLICK_BRIDGE_RELEASE="$ACTIVE_RELEASE"
cd "/opt/click-bridge/releases/$ACTIVE_RELEASE"
docker compose -p oci --env-file /opt/click-bridge/shared/secrets.env \
  -f deploy/oci/compose.yaml restart relay
docker compose -p oci --env-file /opt/click-bridge/shared/secrets.env \
  -f deploy/oci/compose.yaml ps
```

Run full external smoke, then repeat for Caddy:

```bash
docker compose -p oci --env-file /opt/click-bridge/shared/secrets.env \
  -f deploy/oci/compose.yaml restart caddy
docker compose -p oci --env-file /opt/click-bridge/shared/secrets.env \
  -f deploy/oci/compose.yaml ps
```

After each restart both clients reconnect, no old action executes, `/healthz`
returns `ok`, and exactly one relay replica is running.

## Controlled VM reboot

From the Mac, require a different boot ID before declaring success:

```bash
export OCI_SSH_TARGET='opc@146.235.216.172'
PRE_BOOT_ID="$(ssh "$OCI_SSH_TARGET" 'cat /proc/sys/kernel/random/boot_id')"
test -n "$PRE_BOOT_ID"
ssh "$OCI_SSH_TARGET" 'sudo systemctl reboot'
VM_READY=0
for ATTEMPT in $(seq 1 60); do
  CURRENT_BOOT_ID="$(ssh -o ConnectTimeout=5 "$OCI_SSH_TARGET" 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null || true)"
  if test -n "$CURRENT_BOOT_ID" && test "$CURRENT_BOOT_ID" != "$PRE_BOOT_ID"; then
    if ssh -o ConnectTimeout=5 "$OCI_SSH_TARGET" 'docker version >/dev/null && docker compose version >/dev/null'; then
      VM_READY=1
      break
    fi
  fi
  sleep 5
done
if test "$VM_READY" != 1; then
  printf 'VM did not return with a new boot ID and working Docker within five minutes.\n' >&2
  exit 1
fi
ssh "$OCI_SSH_TARGET" 'set -eu; ACTIVE_RELEASE="$(cat /opt/click-bridge/current-release)"; export CLICK_BRIDGE_RELEASE="$ACTIVE_RELEASE"; cd "/opt/click-bridge/releases/$ACTIVE_RELEASE"; docker compose -p oci --env-file /opt/click-bridge/shared/secrets.env -f deploy/oci/compose.yaml ps'
```

Run full external smoke one last time. Docker must be enabled, both containers
must return through `restart: unless-stopped`, relay 8080 must remain private,
and exactly one relay replica must be running.

## VM replacement after OCI Always Free reclamation

1. Provision/select an Ubuntu 22.04 or 24.04 VM in `us-sanjose-1`.
2. Recreate the NSG/firewall boundary from the deployment runbook. Reattach the
   old address if OCI still offers it; otherwise use the replacement address.
3. Point the DuckDNS hostname's single A record at the attached address before
   starting Caddy.
4. Reinstall Docker/Compose/Buildx and rsync through the gated path.
5. Recreate `/opt/click-bridge/shared/secrets.env` at mode 0600 using retained
   client tokens, or rotate both roles deliberately and reconfigure both clients.
6. Transfer a fresh immutable release from Git, build, candidate-smoke, start,
   and run the complete public/recovery acceptance sequence.

Do not generate artificial load to evade OCI's idle-resource policy.
