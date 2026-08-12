# Deploy Click Bridge on the existing OCI SJC instance

This runbook deploys one stateless Node relay and one Caddy reverse proxy under
the fixed Compose project name `oci`. The fixed name preserves the live
`oci_caddy_data` and `oci_caddy_config` certificate volumes while migrating from
the original flat layout to immutable releases. The relay has no database, no
application volume, and no public port. Caddy is the only public service and
publishes TCP 80 and 443.

The commands assume the repository has passed Tasks 1 through 7 in
`FINAL-PLAN.md`. The live hostname and SSH target are recorded below; replace
only the explicit release placeholders with the release being operated. Never
paste deployment tokens into a URL, command argument visible to another user,
tracked file, or log.

## Deployment evidence record

Fill this table from the read-only preflight before changing the VM.

| Item | Required value | Recorded value |
|---|---|---|
| OCI region | `us-sanjose-1` | `us-sanjose-1` |
| SSH target | Approved operator SSH target | `opc@146.235.216.172` |
| Shape | Existing Always Free shape | `VM.Standard.A1.Flex`, 1 OCPU, 6 GB RAM |
| Architecture | `amd64` or `arm64` | `aarch64` / Arm64 |
| Operating system | Ubuntu 22.04/24.04, or an already-working supported runtime gate | Oracle Linux 9.8; existing runtime gate passed |
| Docker Engine | Version and architecture | 29.7.2, Arm64 |
| Compose v2 | Version | 5.4.0 |
| Buildx | Version | Verified on the VM during the native image build |
| Public IPv4 | Attached address with a documented replacement path | `146.235.216.172`, ephemeral |
| Hostname | Owned subdomain or dedicated DuckDNS name | `clickbridge-sjc.duckdns.org` |
| VNIC/NSG | Public subnet, IGW/default route, only 80/443 application ingress | Verified; relay TCP 8080 is not public |
| Host firewall | Active tool and 80/443 rules | `firewalld`; HTTP/HTTPS enabled on the external zone |
| Active release | UTC release identifier | `20260812T020129Z` (legacy flat-layout release; replacement pending reviewed commit) |

Do not continue to a mutating step while a prerequisite in the same section is
unknown.

The verified live host currently uses `/opt/click-bridge/{relay,deploy}`, a
release-local `deploy/oci/.env`, and Compose project `oci`. It has no
`releases/`, `shared/secrets.env`, `current-release`, or `previous-release` yet.
The first rollout from this runbook is therefore a migration: preserve the flat
tree as the emergency fallback, copy its mode-0600 environment to the shared
path without printing or rotating tokens, build in a new immutable directory,
and keep project name `oci`. Never try to bind a second Compose project to
ports 80 and 443 alongside the live one.

## 1. Inspect the VM and network without changing them

On the Mac:

```bash
export OCI_SSH_TARGET='opc@146.235.216.172'
ssh "$OCI_SSH_TARGET" 'set -eu; uname -m; cat /etc/os-release; ip route; command -v rsync || true; docker version 2>/dev/null || true; docker compose version 2>/dev/null || true; docker buildx version 2>/dev/null || true; systemctl is-enabled docker 2>/dev/null || true; sudo ss -ltnp | awk "NR == 1 || \$4 ~ /:(80|443|8080)$/"'
```

The runtime gate passes only when one of these is true:

1. the VM is Ubuntu 22.04 or 24.04 LTS and can use Docker's official Ubuntu
   repository; or
2. another OS already passes all of `docker version`, `docker compose version`,
   `docker buildx version`, `docker run --rm hello-world`, `rsync --version`,
   and `systemctl is-enabled docker` without replacing its engine.

Docker's supported-platform matrix does not list Oracle Linux. Do not install
the RHEL repository on Oracle Linux and call it supported. If neither gate
passes, stop. Select an Ubuntu instance or separately review a Podman/Quadlet
deployment; do not reimage or terminate the existing VM automatically.

In the OCI console, verify the primary VNIC is in a public subnet with an
Internet Gateway and a `0.0.0.0/0` route to that gateway.

## 2. Install or verify Docker on Ubuntu

Always install the ordinary prerequisites:

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl rsync
```

If any of `sudo docker version`, `docker compose version`, or
`docker buildx version` is missing, use Docker's official Ubuntu repository:

```bash
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
. /etc/os-release
ARCHITECTURE="$(dpkg --print-architecture)"
CODENAME="${UBUNTU_CODENAME:-$VERSION_CODENAME}"
printf 'Types: deb\nURIs: https://download.docker.com/linux/ubuntu\nSuites: %s\nComponents: stable\nArchitectures: %s\nSigned-By: /etc/apt/keyrings/docker.asc\n' "$CODENAME" "$ARCHITECTURE" | sudo tee /etc/apt/sources.list.d/docker.sources >/dev/null
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
```

Enable Docker and grant the login user access:

```bash
sudo systemctl enable --now docker
sudo usermod -aG docker "$USER"
```

Reconnect once, then require every command to pass without `sudo`:

```bash
docker version
docker compose version
docker buildx version
docker run --rm hello-world
rsync --version
```

## 3. Choose the address durability and narrow OCI ingress

The current personal deployment uses the instance's attached ephemeral IPv4,
`146.235.216.172`. This survives ordinary stops and starts, so it is sufficient
for Milestone 1. It is released if the instance, VNIC, or primary private IP is
replaced; in that case update DuckDNS before starting Caddy on the replacement.

For a later reserved-IP migration, use the OCI console steps below. The
migration is optional for this personal v1 and must not block application
rollout:

In the OCI console:

1. Create a regional reserved IPv4 under **Networking > IP management >
   Reserved public IPs** in the instance compartment.
2. Open the instance's primary VNIC and edit its primary private IP.
3. Remove the ephemeral public assignment, if present, and attach the reserved
   address to the same private IP. Do not detach the VNIC.
4. Attach an instance-scoped Network Security Group to that VNIC.
5. Add two stateful ingress rules from `0.0.0.0/0`: TCP destination 80 and TCP
   destination 443. Source ports remain all.
6. Audit every attached NSG and subnet security list. Remove or narrow public
   TCP 8080, all-port, all-protocol, or other broad application ingress. Keep
   SSH restricted to the operator's source CIDR.

Milestone 1 is IPv4-only. Do not add an OCI 8080 rule or publish an AAAA record.

## 4. Choose the hostname before starting Caddy

Use a subdomain you own. A dedicated DuckDNS hostname is the free fallback.
Do not use `sslip.io` or `nip.io` for a permanent deployment, and do not add a
second ACME client for short-lived bare-IP certificates.

Point one A record at the selected attached IPv4, then verify from the Mac:

```bash
export CLICK_BRIDGE_DOMAIN='clickbridge-sjc.duckdns.org'
export OCI_PUBLIC_IP='146.235.216.172'
test "$(dig +short A "$CLICK_BRIDGE_DOMAIN" | sort -u)" = "$OCI_PUBLIC_IP"
test -z "$(dig +short AAAA "$CLICK_BRIDGE_DOMAIN")"
```

Do not start Caddy until both assertions pass; repeated failed ACME challenges
create avoidable issuance backoff.

## 5. Verify the host firewall and port owners

Inspect listeners first:

```bash
sudo ss -ltnp | awk 'NR == 1 || $4 ~ /:(80|443|8080)$/'
```

Stop if another process owns 80 or 443. Identify it deliberately; do not kill
an unknown service from this runbook.

On Ubuntu, change UFW only if it is active:

```bash
sudo ufw status verbose
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw status verbose
```

On a reused Oracle Linux VM whose existing Docker runtime already passed the
gate, derive the external firewalld zone from the default-route interface and
explicitly reject Docker's zone:

```bash
sudo firewall-cmd --state
sudo firewall-cmd --get-active-zones
DEFAULT_ROUTE_INTERFACE="$(ip route show default | awk 'NR == 1 {print $5}')"
test -n "$DEFAULT_ROUTE_INTERFACE"
ACTIVE_ZONE="$(sudo firewall-cmd --get-zone-of-interface="$DEFAULT_ROUTE_INTERFACE")"
test -n "$ACTIVE_ZONE"
test "$ACTIVE_ZONE" != 'no zone'
test "$ACTIVE_ZONE" != 'docker'
sudo firewall-cmd --permanent --zone="$ACTIVE_ZONE" --add-service=http
sudo firewall-cmd --permanent --zone="$ACTIVE_ZONE" --add-service=https
sudo firewall-cmd --reload
test "$(sudo firewall-cmd --get-zone-of-interface="$DEFAULT_ROUTE_INTERFACE")" = "$ACTIVE_ZONE"
sudo firewall-cmd --zone="$ACTIVE_ZONE" --list-services
```

If neither UFW nor firewalld is the active tool, stop and identify the real
firewall before changing rules. Published Docker ports can bypass UFW; the
actual boundary is OCI permitting only 80/443 plus Compose publishing only
Caddy's 80/443.

## 6. Verify the repository container locally

Use fixed test tokens only:

```bash
cd /Users/harshitagarwal/Desktop/clicker
cp deploy/oci/.env.example deploy/oci/.env
```

Set `CLICK_BRIDGE_DOMAIN=example.test`, `CLICK_BRIDGE_RELEASE=local`, and the
two Task 3 test tokens in the ignored file, then run:

```bash
docker build -f deploy/oci/Dockerfile -t click-bridge-relay:local .
docker compose --env-file deploy/oci/.env -f deploy/oci/compose.yaml config --quiet
docker compose --env-file deploy/oci/.env -f deploy/oci/compose.yaml config --services
docker compose --env-file deploy/oci/.env -f deploy/oci/compose.yaml config --images
```

The model must contain exactly `relay` and `caddy`; relay has no `ports` key,
and Caddy publishes 80 and 443. Do not start production-domain Caddy locally.

For relay-only health:

```bash
cleanup_local_smoke() { docker rm -f click-bridge-relay-smoke >/dev/null 2>&1 || true; }
trap cleanup_local_smoke EXIT INT TERM
cleanup_local_smoke
docker run --detach --name click-bridge-relay-smoke -p 127.0.0.1:18080:8080 \
  -e PHONE_TOKEN=1111111111111111111111111111111111111111111111111111111111111111 \
  -e MAC_TOKEN=2222222222222222222222222222222222222222222222222222222222222222 \
  -e CLICK_BRIDGE_DOMAIN=example.test click-bridge-relay:local
LOCAL_READY=0
for ATTEMPT in $(seq 1 30); do
  if docker exec click-bridge-relay-smoke node -e 'fetch("http://127.0.0.1:8080/healthz").then(async response => { if (!response.ok || (await response.text()) !== "ok") process.exit(1) }).catch(() => process.exit(1))'; then
    LOCAL_READY=1
    break
  fi
  sleep 1
done
if test "$LOCAL_READY" != 1; then
  docker logs --tail=100 click-bridge-relay-smoke
  exit 1
fi
cleanup_local_smoke
trap - EXIT INT TERM
```

## 7. Install the one shared role-token environment

For the verified first migration, preserve the already-paired tokens. Copy only
the domain and two role tokens from the live mode-0600 file into the new shared
location without printing them:

```bash
export OCI_SSH_TARGET='opc@146.235.216.172'
ssh "$OCI_SSH_TARGET" 'set -eu; test "$(stat -c %a /opt/click-bridge/deploy/oci/.env)" = 600; install -d -m 0700 /opt/click-bridge/shared; umask 077; grep -E "^(CLICK_BRIDGE_DOMAIN|PHONE_TOKEN|MAC_TOKEN)=" /opt/click-bridge/deploy/oci/.env > /opt/click-bridge/shared/secrets.env; test "$(wc -l < /opt/click-bridge/shared/secrets.env)" = 3; grep -Eq "^PHONE_TOKEN=[0-9a-f]{64}$" /opt/click-bridge/shared/secrets.env; grep -Eq "^MAC_TOKEN=[0-9a-f]{64}$" /opt/click-bridge/shared/secrets.env; test "$(stat -c %a /opt/click-bridge/shared/secrets.env)" = 600'
```

Do not delete or edit the legacy `.env` until the new immutable release and its
rollback test pass. For a genuinely new installation or deliberate two-role
rotation, generate a temporary mode-0600 transfer file on the Mac without
printing the tokens:

```bash
umask 077
export CLICK_BRIDGE_DOMAIN='clickbridge-sjc.duckdns.org'
PHONE_TOKEN="$(openssl rand -hex 32)"
MAC_TOKEN="$(openssl rand -hex 32)"
{
  printf 'CLICK_BRIDGE_DOMAIN=%s\n' "$CLICK_BRIDGE_DOMAIN"
  printf 'PHONE_TOKEN=%s\n' "$PHONE_TOKEN"
  printf 'MAC_TOKEN=%s\n' "$MAC_TOKEN"
} > /private/tmp/click-bridge-secrets.env
test "$(wc -l < /private/tmp/click-bridge-secrets.env | tr -d ' ')" = 3
```

Install the new/rotated canonical VM copy outside every release:

```bash
export OCI_SSH_TARGET='opc@146.235.216.172'
scp /private/tmp/click-bridge-secrets.env "$OCI_SSH_TARGET:/tmp/click-bridge-secrets.env"
ssh "$OCI_SSH_TARGET" 'sudo install -d -m 0700 -o "$USER" -g "$(id -gn)" /opt/click-bridge/shared && install -m 0600 /tmp/click-bridge-secrets.env /opt/click-bridge/shared/secrets.env && rm -f /tmp/click-bridge-secrets.env && test "$(stat -c %a /opt/click-bridge/shared/secrets.env)" = 600'
```

Configure the phone with `PHONE_TOKEN` and the Mac Keychain with `MAC_TOKEN`.
Do not generate `DIRECT_TOKEN` unless Task 10 begins.

## 8. Transfer one immutable release

```bash
export OCI_SSH_TARGET='opc@146.235.216.172'
export CLICK_BRIDGE_RELEASE="$(date -u +%Y%m%dT%H%M%SZ)"
[[ "$CLICK_BRIDGE_RELEASE" =~ ^[0-9]{8}T[0-9]{6}Z$ ]] || exit 1
ssh "$OCI_SSH_TARGET" 'sudo mkdir -p /opt/click-bridge/releases /opt/click-bridge/shared && sudo chown -R "$USER":"$USER" /opt/click-bridge && command -v rsync && rsync --version >/dev/null && docker version && docker compose version && docker buildx version && test -f /opt/click-bridge/shared/secrets.env'
ssh "$OCI_SSH_TARGET" "test ! -e /opt/click-bridge/releases/$CLICK_BRIDGE_RELEASE && mkdir /opt/click-bridge/releases/$CLICK_BRIDGE_RELEASE"
rsync -az --delete \
  --exclude .git --exclude node_modules --exclude build --exclude DerivedData \
  --exclude deploy/oci/.env --exclude archive --exclude _to_delete \
  --exclude benchmarks /Users/harshitagarwal/Desktop/clicker/ \
  "$OCI_SSH_TARGET:/opt/click-bridge/releases/$CLICK_BRIDGE_RELEASE/"
ssh "$OCI_SSH_TARGET" "printf '%s\\n' '$CLICK_BRIDGE_RELEASE' > /opt/click-bridge/candidate-release"
```

The `--delete` target is the newly created, exact release directory. Never aim
it at `/opt/click-bridge`, a home directory, or an unresolved variable.

## 9. Build, test, and start the candidate on the VM

```bash
export CLICK_BRIDGE_RELEASE='ACTUAL_RELEASE_FROM_STEP_8'
cd "/opt/click-bridge/releases/$CLICK_BRIDGE_RELEASE"
test "$(stat -c %a /opt/click-bridge/shared/secrets.env)" = 600
docker compose -p oci --env-file /opt/click-bridge/shared/secrets.env -f deploy/oci/compose.yaml config --quiet
if test -f /opt/click-bridge/current-release; then
  cp /opt/click-bridge/current-release /opt/click-bridge/previous-release
fi
docker compose -p oci --env-file /opt/click-bridge/shared/secrets.env -f deploy/oci/compose.yaml build --pull
cleanup_candidate() { docker rm -f click-bridge-relay-candidate >/dev/null 2>&1 || true; }
trap cleanup_candidate EXIT INT TERM
cleanup_candidate
docker run --detach --name click-bridge-relay-candidate -p 127.0.0.1:18080:8080 \
  --env-file /opt/click-bridge/shared/secrets.env \
  "click-bridge-relay:${CLICK_BRIDGE_RELEASE}"
CANDIDATE_READY=0
for ATTEMPT in $(seq 1 30); do
  if docker exec click-bridge-relay-candidate node -e 'fetch("http://127.0.0.1:8080/healthz").then(async response => { if (!response.ok || (await response.text()) !== "ok") process.exit(1) }).catch(() => process.exit(1))'; then
    CANDIDATE_READY=1
    break
  fi
  sleep 1
done
if test "$CANDIDATE_READY" != 1; then
  docker logs --tail=100 click-bridge-relay-candidate
  exit 1
fi
cleanup_candidate
trap - EXIT INT TERM
docker compose -p oci --env-file /opt/click-bridge/shared/secrets.env -f deploy/oci/compose.yaml up -d
docker compose -p oci --env-file /opt/click-bridge/shared/secrets.env -f deploy/oci/compose.yaml ps
docker compose -p oci --env-file /opt/click-bridge/shared/secrets.env -f deploy/oci/compose.yaml logs --tail=100 caddy relay
docker volume ls --filter label=com.docker.compose.project=oci
```

## 10. Prove the public application before marking it current

From the Mac:

```bash
export CLICK_BRIDGE_DOMAIN='clickbridge-sjc.duckdns.org'
curl -fsS "https://${CLICK_BRIDGE_DOMAIN}/healthz"
curl -fsS -I "http://${CLICK_BRIDGE_DOMAIN}/"
curl -fsS -D - -o /dev/null "https://${CLICK_BRIDGE_DOMAIN}/"
set -a
. /private/tmp/click-bridge-secrets.env
set +a
cd /Users/harshitagarwal/Desktop/clicker/relay
node scripts/smoke-relay.mjs "wss://${CLICK_BRIDGE_DOMAIN}/ws"
unset PHONE_TOKEN MAC_TOKEN
```

On the VM:

```bash
cd "/opt/click-bridge/releases/$CLICK_BRIDGE_RELEASE"
docker compose -p oci --env-file /opt/click-bridge/shared/secrets.env -f deploy/oci/compose.yaml ps
docker compose -p oci --env-file /opt/click-bridge/shared/secrets.env -f deploy/oci/compose.yaml logs --tail=100 caddy relay
sudo ss -ltnp | awk 'NR == 1 || $4 ~ /:(80|443|8080)$/'
```

Acceptance requires trusted HTTPS, HTTP-to-HTTPS redirect, successful WSS
request/result smoke, exactly one canonical CSP header, no token in URL/logs,
Caddy certificate success, and no host listener on relay port 8080.

Only after all checks pass:

```bash
printf '%s\n' "$CLICK_BRIDGE_RELEASE" > /opt/click-bridge/current-release
rm -f /opt/click-bridge/candidate-release
```

## 11. Exercise recovery before acceptance

Follow `docs/oci-recovery.md` to prove:

- first-release rebuild/recreate from its immutable directory;
- a second timestamped release;
- rollback to the first release and roll-forward to the second;
- relay restart, Caddy restart, and a controlled VM reboot whose boot ID changes;
- full HTTPS/WSS/CSP/port-boundary smoke after every transition.

Retain both releases and images until every recovery check passes. Then remove
the exact temporary transfer file and clear token variables:

```bash
unset PHONE_TOKEN MAC_TOKEN
rm -f /private/tmp/click-bridge-secrets.env
```

OCI may reclaim idle Always Free compute. Do not manufacture load to evade the
policy; recover from the immutable source, shared environment, DNS, and this
Compose runbook.
