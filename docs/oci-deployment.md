# Deploying the relay on OCI

## 0. Prerequisites

Recorded in `docs/preflight.md` before anything else:

- OCI instance architecture (`uname -m`) — **build on the VM**, an M1-built
  image will not run on an x86_64 shape
- stable public IPv4
- the hostname you will use

## 1. Choose a hostname

Public HTTPS needs a hostname; a bare IP will not do. An HTTPS page can only
open `wss://` sockets, and Add to Home Screen requires a secure context.

| Option | Verdict |
|---|---|
| A domain you own | **Best.** ~$10–15/yr, an A record at the OCI IP |
| A DuckDNS name | Free and reliable — it is on the Public Suffix List, so it gets its own Let's Encrypt rate-limit bucket |
| sslip.io / nip.io | **Do not use for anything permanent.** Their certificate quota is shared across all users worldwide and is routinely exhausted |
| Bare-IP certificate | Let's Encrypt issues these now, but they are six-day certs and Caddy's automatic flow is hostname-based. Not worth a second ACME client |

Verify DNS **before** starting Caddy — a failed ACME challenge triggers backoff:

```bash
export CLICK_BRIDGE_DOMAIN='your.host.name'
dig +short "$CLICK_BRIDGE_DOMAIN"     # must be exactly the OCI public IPv4
```

## 2. Open the ports — both layers

The VCN security list is **not enough**. Oracle's Ubuntu and Oracle Linux
images ship iptables rules that drop 80/443 regardless. This is the single most
common OCI web-server failure.

```bash
sudo iptables -I INPUT 6 -m state --state NEW -p tcp --dport 80 -j ACCEPT
sudo iptables -I INPUT 6 -m state --state NEW -p tcp --dport 443 -j ACCEPT
sudo netfilter-persistent save
```

Port 8080 must **not** be public — it stays on the private compose network.

## 3. Generate tokens

```bash
openssl rand -hex 32   # PHONE_TOKEN
openssl rand -hex 32   # MAC_TOKEN
```

Independent values. The relay refuses to start if they match.

`DIRECT_TOKEN` is generated only when Milestone 2 begins and never appears in
the relay's environment.

## 4. Transfer and build on the VM

```bash
export OCI_SSH_TARGET='ubuntu@YOUR_OCI_IP'
export CLICK_BRIDGE_RELEASE="$(date -u +%Y%m%dT%H%M%SZ)"

ssh "$OCI_SSH_TARGET" 'sudo mkdir -p /opt/click-bridge && \
  sudo chown "$USER":"$USER" /opt/click-bridge && \
  docker version && docker compose version'

rsync -az --exclude .git --exclude node_modules --exclude build \
  --exclude DerivedData --exclude deploy/oci/.env \
  ./ "$OCI_SSH_TARGET":/opt/click-bridge/
```

On the VM, write `/opt/click-bridge/deploy/oci/.env` from `.env.example`,
`chmod 0600`, then:

```bash
cd /opt/click-bridge
docker compose --env-file deploy/oci/.env -f deploy/oci/compose.yaml build --pull
docker compose --env-file deploy/oci/.env -f deploy/oci/compose.yaml up -d
docker compose --env-file deploy/oci/.env -f deploy/oci/compose.yaml ps
```

Exactly one relay container and one Caddy container. No database.

## 5. Verify

```bash
curl -fsS "https://${CLICK_BRIDGE_DOMAIN}/healthz"     # -> ok

PHONE_TOKEN=<hex> MAC_TOKEN=<hex> \
  node relay/scripts/smoke-relay.mjs "wss://${CLICK_BRIDGE_DOMAIN}/ws"
```

Then confirm:

- trusted HTTPS, no certificate warning on the phone
- the token appears in **no** URL and no log line
- only 80/443 reachable from outside

## 6. Rollback

Before each later deploy, keep the working release selector:

```bash
cd /opt/click-bridge && cp deploy/oci/.env deploy/oci/.env.previous
```

If a new release fails its smoke test:

```bash
cp deploy/oci/.env.previous deploy/oci/.env
docker compose --env-file deploy/oci/.env -f deploy/oci/compose.yaml up -d --no-build
```

## 7. Recovery

Oracle documents that idle Always Free compute may be reclaimed. Do **not**
manufacture fake load to dodge that policy. Instead keep this recoverable: the
full path back is source (`rsync` again) + `.env` + `docker compose up -d`.
Nothing else is stateful — there is no database and no volume other than
Caddy's certificate cache, which regenerates.
