# Install and run the Windows receiver

This runbook builds the Windows tray-app receiver (`windows/ClickBridgeWindows.sln`),
installs it, connects it to the WSS relay, and pairs a phone. Like the macOS
receiver, it does not satisfy the physical acceptance gate: end-to-end
clicking against a real target is still **NOT RUN** — see
[`physical-smoke-test.md`](physical-smoke-test.md).

> The wire protocol calls the desktop receiver role `"mac"` (`hello.role`,
> `action.result.acceptedVia`, etc.) for historical reasons — that is a
> protocol-level name, not a platform restriction. This Windows client
> authenticates as that same `mac` role and is a full peer of the macOS
> receiver from the relay's point of view; nothing about the relay or the
> phone clients needs to change.

## Requirements

- Windows 10 or later (x64), and the [.NET 8 SDK](https://dotnet.microsoft.com/download/dotnet/8.0).
- An operator-bootstrapped connection to a trusted relay: a relay URL in the
  exact form `wss://<host>/ws` and the relay's 64-character lowercase
  hexadecimal `MAC_TOKEN`. Never place that token in a URL, command
  argument, log, screenshot, or repository file — the same rule the macOS
  runbook follows.

## Build and publish

From the repository root:

```bash
cd windows
dotnet build ClickBridgeWindows.sln
dotnet test tests/ClickBridge.Core.Tests/ClickBridge.Core.Tests.csproj
dotnet publish src/ClickBridge.Windows/ClickBridge.Windows.csproj -c Release -r win-x64 --self-contained true
```

The publish step produces a single self-contained executable at
`src/ClickBridge.Windows/bin/Release/net8.0-windows/win-x64/publish/ClickBridge.exe`
— no separate .NET runtime install is required on the target machine.

`ClickBridge.Core` and its test suite are platform-agnostic and build on any
OS; only `ClickBridge.Windows` needs a Windows-targeted build. If you are
compile-checking `ClickBridge.Windows` from a non-Windows machine (for
example during development), pass
`-p:EnableWindowsTargeting=true -r win-x64` to `dotnet build`; publishing a
runnable exe still requires either a Windows host or letting NuGet fetch the
`Microsoft.WindowsDesktop.App` win-x64 runtime pack, which `dotnet publish`
does automatically.

## Install and run

Click Bridge on Windows is a tray-only app: it has no taskbar window and no
Alt-Tab entry, the same "menu-bar app" posture as the macOS build.

1. Copy `ClickBridge.exe` to a stable location, e.g. `%LOCALAPPDATA%\ClickBridge\ClickBridge.exe`.
2. Run it. A tray icon appears; there is no visible window on launch.
3. Right-click (or double-click) the tray icon to open the menu: connection
   status, input status, **Remote control enabled** toggle, last result,
   **Reconnect**, **Settings…**, and **Quit**.

There is no Windows equivalent of granting macOS Accessibility permission —
Windows has no consent gate for posting synthetic input from a normal user
process. `SendInput` can still fail silently in one situation: **UIPI**
(User Interface Privilege Isolation) blocks input from a lower-integrity
process into a higher-integrity (elevated) foreground window. Click Bridge
runs at normal user privilege by default, matching the macOS build's
unsandboxed-but-unprivileged posture; if the click target is an elevated app,
either run Click Bridge elevated too, or run the target normally. A blocked
`SendInput` call surfaces as an `event_creation_failed` action result, not as
a permission state — there is nothing to "grant" in Settings.

## Connect the receiver

1. Open **Settings…** from the tray menu and expand **Advanced legacy
   connection**.
2. Enter the exact `wss://<host>/ws` relay URL and paste the matching
   `MAC_TOKEN`, then choose **Save**. This stores the token via Windows Data
   Protection API (DPAPI, `CurrentUser` scope) under
   `%LOCALAPPDATA%\ClickBridge\macToken.secret` — decryptable only by the
   same Windows user account on the same machine, with no cross-device sync.
   The relay URL and the **Remote control enabled** flag are stored in
   plaintext JSON at `%APPDATA%\ClickBridge\settings.json` (matching what the
   macOS build keeps in `UserDefaults` — neither field is a secret).
3. Turn on **Remote control enabled** only when remote input is intended.
   Turning it off rejects remote actions without posting input, the same
   emergency-stop behavior as macOS.

## Pair or replace a phone

Identical flow to the macOS receiver's **Settings… → Pair Phone / Replace
Phone**:

1. Choose **Pair Phone** (or **Replace Phone** if one is already enrolled,
   confirming the replacement).
2. Scan the QR code with the iPhone app, or use **Copy Invitation** /
   **Copy PWA Invitation** to send the single-use HTTPS link to a phone
   anywhere on the internet.
3. Verify the same six-digit confirmation code appears on the phone and on
   Windows, then **Approve**. Do not approve a mismatch.

The invitation expires after five minutes and can be claimed only once.

## Recover safely

- **Disconnected:** confirm a token is stored, the WSS URL is exact, and the
  public relay is healthy; then choose **Reconnect**.
- **Secret store unavailable:** the receiver fails closed for the rest of
  that run (DPAPI reads/writes are refused until relaunch) — the Settings
  dialog's storage-error line explains why. Relaunch after the underlying
  Windows profile/DPAPI issue is resolved.
- **Emergency stop:** turn **Remote control enabled** off. For a full
  disconnect, choose **Clear** in Settings (removes the DPAPI-protected
  token) or quit the app.
- **UIPI-blocked clicks:** see the elevation note above.
- **Relay or VM recovery:** unchanged from the macOS side — see
  [`oci-recovery.md`](oci-recovery.md).

## Verify without overstating success

Exactly like the macOS build: a `Posted` result only records that
`SendInput` was called for all three down/up pairs. Windows provides no
delivery acknowledgement either. Only an observed target-side counter change
of exactly `+3` proves the physical target received the burst — record that
result through [`physical-smoke-test.md`](physical-smoke-test.md). Until a
real phone, the public relay, an installed Windows receiver, and a physical
target session are run and recorded together, physical and latency
acceptance remain **NOT RUN** for this platform too.
