# Click Bridge

Click Bridge turns one accepted phone action into exactly **three independent
ordinary left clicks** at the Mac's current pointer location. Use either the
native iOS app (volume change, **Trigger 3 Clicks**, or App Shortcut) or the
installable PWA; the relay carries one logical `click` action to the macOS
menu-bar receiver.

> **Acceptance status:** automated tests and builds are recorded, but physical
> iPhone volume/haptic behavior, Accessibility-authorized clicking in Octo, and
> end-to-end latency are still **NOT RUN**. A `Posted` result means the Mac
> attempted the three `CGEvent` click pairs; only an observed Octo `+3` proves
> the physical target received them.

## Start here

1. **Relay:** use the existing trusted HTTPS/WSS endpoint, or follow the
   [OCI deployment runbook](docs/oci-deployment.md). Production clients require
   `wss://<host>/ws`. Keep `PHONE_TOKEN` and `MAC_TOKEN` out of URLs, logs,
   screenshots, and Git; the VM's canonical copy is the mode-`0600`
   `/opt/click-bridge/shared/secrets.env` file.
2. **Mac receiver:** follow [Install and run the macOS receiver](docs/install-macos.md),
   save the matching `MAC_TOKEN`, grant macOS Accessibility access, and turn on
   **Remote control enabled** from the Click Bridge menu-bar item.
3. **Phone — choose one live client:** in the native app, open **Settings**,
   enter the relay WSS URL and `PHONE_TOKEN`, save, and keep the app in the
   foreground. Or open the relay's HTTPS page, install the PWA from the browser
   menu, then use **Settings → Save / replace** for `PHONE_TOKEN`. Disconnect or
   background the native app before using the PWA, and keep the chosen client
   foreground-visible.
4. Wait for **Ready**, place the Mac pointer over the intended target, then use
   one phone trigger. One accepted logical action becomes three left-button
   down/up pairs; it is not one physical click and the phone supplies no cursor
   coordinates.

Turn **Remote control enabled** off before maintenance or whenever remote input
is not wanted. That switch and Accessibility permission are separate gates:
turning the switch on does not grant macOS permission. Quitting the Mac app
makes the phone report the Mac offline.

## Read the status before retrying

- **Ready:** phone authenticated; Mac online; remote control, Accessibility,
  and clock checks ready.
- **Not connected / Connecting:** open phone settings, verify the exact WSS URL
  and token, then reconnect.
- **Mac offline:** start Click Bridge on the Mac and use **Reconnect** if needed.
- **Mac not ready / Grant input permission / Enable remote control:** grant
  Accessibility and separately enable the Mac menu-bar toggle.
- **Checking clock / Clock check unavailable / Clock mismatch:** wait, use
  **Retry clock check**, or enable automatic date and time on both devices.
- **Sending / Forwarded:** one action is already in flight. Do not submit
  another. Forwarded is not a physical-success result.
- **Rejected / error:** follow the displayed reason; rejected actions do not
  become successful clicks.
- **Unknown:** a click may have occurred. Inspect the Mac/target before trying
  again; the client does not replay it.
- **Another phone took over:** stop the other client, then tap **Reconnect this
  phone** (iOS) or re-save the PWA token. Only one phone client is live.

## Token storage and replacement

Both role tokens are exactly 64 lowercase hexadecimal characters and are
different from each other.

- **OCI relay:** both tokens live in
  `/opt/click-bridge/shared/secrets.env`, mode `0600`. Install the replacement,
  force-recreate the active relay container, pass the public HTTPS/WSS smoke,
  then update both clients to match.
- **Mac receiver:** `MAC_TOKEN` is in Keychain; relay URL and remote toggle are
  in UserDefaults. **Settings → Save** replaces and reconnects; **Clear** removes
  the token and disconnects.
- **Native iOS:** `PHONE_TOKEN` is in Keychain; relay URL is in UserDefaults.
  Enter a replacement in Settings; leave it blank to retain the saved token.
- **PWA:** `PHONE_TOKEN` is in that browser profile's localStorage. Use
  **Save / replace** or **Clear**. PWA storage is not Keychain storage.

For a deliberate two-role rotation, keep the new tokens out of shell arguments
and output, then follow [Rotate role tokens](docs/install-macos.md#rotate-role-tokens).
The relay container must be recreated to load the new environment—a plain
restart keeps its old tokens. Update the saved Mac and phone tokens only after
the recreated relay passes its public health and WSS smoke checks.

## Recovery and proof

- Mac install, update, permission recovery, and bundle rollback:
  [docs/install-macos.md](docs/install-macos.md)
- Relay inspection, failed-candidate recovery, service restart, VM recovery,
  rollback, and roll-forward: [docs/oci-recovery.md](docs/oci-recovery.md)
- Public endpoint and immutable-release procedure:
  [docs/oci-deployment.md](docs/oci-deployment.md)
- Native iOS configuration and automated evidence:
  [docs/ios-acceptance.md](docs/ios-acceptance.md)
- Required physical matrix (**NOT RUN**):
  [docs/physical-smoke-test.md](docs/physical-smoke-test.md)
- Latency method and still-empty result (**NOT RUN**):
  [docs/benchmark.md](docs/benchmark.md) and
  [docs/latency-report.md](docs/latency-report.md)

`FINAL-PLAN.md` is the only active implementation plan. Older plans under
`archive/` are historical evidence, and Tailscale/hedged delivery remain off
until the physical Milestone 1 gate passes.
