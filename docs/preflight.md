# OCI deployment preflight

Verified on 2026-08-12 UTC. This file intentionally contains no authentication
tokens or private OCI identifiers.

## Always Free footprint

| Item | Verified value |
|---|---|
| Region | `us-sanjose-1` (SJC) |
| Instance | `clickbridge-relay` |
| Shape | `VM.Standard.A1.Flex` (Arm64) |
| Allocation | 1 OCPU, 6 GB RAM |
| Boot volume | 50 GB |
| Operating system | Oracle Linux 9.8 |
| Architecture | `aarch64` |
| Public IPv4 | `146.235.216.172` (ephemeral, attached to the instance) |
| Hostname | `clickbridge-sjc.duckdns.org` |
| Network security group | `clickbridge-nsg` |

The allocation is below Oracle's current Always Free limits for Ampere A1
(2 OCPUs and 12 GB RAM total) and Block Volume (200 GB total). Always Free
compute must be in the tenancy's home region. See Oracle's
[Always Free resource details](https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm).

## Host and runtime

- SSH user: `opc`
- Pinned SSH host-key fingerprint:
  `SHA256:T2L3jMtysYcL/2O9XO6bYXaE4C04eEzuDLUczhNna7s`
- Docker Engine: 29.7.2, Arm64
- Docker Compose plugin: 5.4.0
- Release: `20260812T020129Z`
- Secret file: `/opt/click-bridge/deploy/oci/.env`, owner `opc:opc`, mode
  `0600`

`PHONE_TOKEN` and `MAC_TOKEN` are distinct 64-character lowercase hexadecimal
values. Their values are deliberately stored only on the VM and in the paired
clients.

## Verified network path

- DuckDNS authoritative DNS, Cloudflare, Google, the local system resolver,
  and the VM all resolved the hostname to `146.235.216.172`.
- OCI ingress and Oracle Linux `firewalld` allow TCP 80 and 443.
- TCP 8080 is not published by Docker, is not allowed by `firewalld`, and timed
  out from the public internet.
- HTTP redirects to HTTPS with status 308.
- HTTPS returns status 200 over HTTP/2 with successful certificate validation.
- The certificate names only `clickbridge-sjc.duckdns.org` and is issued by
  Let's Encrypt.

## Application verification

- Local relay check: 198/198 tests passed with 0 skips.
- Relay container: healthy, runs as the unprivileged `node` user, restart policy
  `unless-stopped`.
- Caddy container: running, restart policy `unless-stopped`.
- End-to-end authenticated `wss://` smoke: 11/11 checks passed.
- Runtime logs and the built image contain neither token; Caddy receives neither
  token in its environment.
- Chrome loaded the production page with the title `Click Bridge` and the
  expected unpaired state.

The public IP survives ordinary instance stops but is released if its private
IP/VNIC or the instance is terminated. Update the DuckDNS record after any
replacement.
