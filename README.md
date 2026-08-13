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
   `wss://<host>/ws`. The relay operator owns its credentials; phone users and
   testers do not copy tokens during normal setup.
2. **Mac receiver:** follow [Install and run the macOS receiver](docs/install-macos.md),
   have the operator bootstrap its relay connection, grant macOS Accessibility
   access, and turn on **Remote control enabled** from the menu-bar item.
3. **Pair a phone:** on the connected Mac, open **Settings…** and choose
   **Pair Phone**. If a phone is already enrolled, choose **Replace Phone…** and
   confirm. Scan the nearby QR code with the iPhone app, or choose **Share Secure
   Setup Link…** to send the HTTPS link to a phone anywhere on the internet.
   The invitation is single-use and expires after five minutes. Compare the
   six-digit code on both devices and approve it on the Mac; do not approve a
   mismatch. The phone user never enters the relay WSS URL or a token.
4. **Browser fallback:** without the native app, use **Other Ways to Connect →
   Copy Browser Invitation Link** on the Mac and open that HTTPS link on the
   phone. It uses the same single-use, five-minute invitation and Mac owner code
   comparison and approval, but opens `/pair/web` so Universal Links cannot
   divert it into the native app. Disconnect or background the native app before
   using the browser; only one phone client can be live.
5. Wait for **Ready**, place the Mac pointer over the intended target, then use
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
- **Not connected / Connecting:** open a fresh invitation from the Mac and pair
  again. Verify the WSS URL and token only for an **Advanced Legacy** deployment.
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
  phone** (iOS) or choose **Pair Again** in the PWA. Only one phone client is live.

## Advanced legacy and operator recovery

The fields below are not part of normal phone pairing. Use them only for an
alternate/self-hosted deployment or operator-led credential recovery. Keep
`PHONE_TOKEN` and `MAC_TOKEN` out of URLs, logs, screenshots, and Git; the VM's
canonical copy is the mode-`0600` `/opt/click-bridge/shared/secrets.env` file.

Both role tokens are exactly 64 lowercase hexadecimal characters and are
different from each other.

- **OCI relay:** both tokens live in
  `/opt/click-bridge/shared/secrets.env`, mode `0600`. Install the replacement,
  force-recreate the active relay container, pass the public HTTPS/WSS smoke,
  then update both clients to match.
- **Mac receiver:** `MAC_TOKEN` is in Keychain; relay URL and remote toggle are
  in UserDefaults. **Settings → Save & Reconnect** applies the advanced
  connection changes and reconnects; **Remove Saved Credential…** removes the
  token and disconnects after confirmation.
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
