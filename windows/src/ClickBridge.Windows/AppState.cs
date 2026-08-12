using ClickBridge.Core.Actions;
using ClickBridge.Core.Pairing;
using ClickBridge.Core.Relay;
using ClickBridge.Core.Storage;
using ClickBridge.Core.Wire;

namespace ClickBridge.Windows;

/// <summary>
/// Port of mac/ClickBridgeMac/AppState.swift's glue logic. Swift's version
/// crosses several actor boundaries (RelayClient, ActionProcessor) so many
/// of its steps are individually awaited; here those callees are plain
/// synchronous methods, so the constructor wiring collapses to direct calls
/// and only the genuinely-async credential/connect flow stays as a
/// fire-and-forget Task, matching the same revision-fencing behavior.
/// Raises Changed after any property update so the UI layer (TrayApplicationContext)
/// can refresh — callers must marshal that back to the UI thread themselves.
/// </summary>
public sealed class AppState
{
    public RelayClient.Status Connection { get; private set; } = RelayClient.Status.Disconnected;
    public PermissionState Permission { get; private set; }
    public string LastResult { get; private set; } = "—";
    public string? Notice { get; private set; }
    public PairingController? Pairing { get; private set; }
    public PairingActionPresentation PairingAction { get; private set; } = PairingActionPresentation.From(null);

    public SettingsStore Settings { get; }

    public event Action? Changed;

    private readonly RelayClient _client;
    private readonly ActionProcessor _processor;
    private readonly IPostEventPermissionChecking _permissionService;

    private ulong _credentialRevision;
    private bool _credentialEligible = true;
    private ulong _lastStatusSequence;

    public AppState(
        SettingsStore settings,
        RelayClient client,
        ActionProcessor processor,
        IPostEventPermissionChecking permissionService,
        string? initialNotice = null)
    {
        Settings = settings;
        _client = client;
        _processor = processor;
        _permissionService = permissionService;
        Notice = initialNotice;
        Permission = permissionService.IsGranted() ? PermissionState.Ready : PermissionState.Required;

        client.SetStatusHandler(HandleStatusEvent);
        client.SetResultHandler(HandleResult);
        client.SetPairingHandler(ReceivePairingAsync);
        processor.SetRemoteEnabled(settings.RemoteEnabled);

        var initialCredentialRevision = BeginCredentialOperation();
        _ = InitializeAsync(initialCredentialRevision);
    }

    private async Task InitializeAsync(ulong initialCredentialRevision)
    {
        await PublishStateAsync().ConfigureAwait(false);
        if (initialCredentialRevision != _credentialRevision) return;
        await ConnectAsync(initialCredentialRevision).ConfigureAwait(false);
    }

    public Task ReconnectAsync() => ConnectAsync(BeginCredentialOperation());

    public Task PublishStateAsync() =>
        _client.UpdateAdvertisedStateAsync(new MacState { RemoteEnabled = Settings.RemoteEnabled, Permission = Permission });

    public void SetPersistedRemoteEnabled(bool enabled)
    {
        _ = Task.Run(async () =>
        {
            _processor.SetRemoteEnabled(enabled);
            Settings.RemoteEnabled = enabled;
            await PublishStateAsync().ConfigureAwait(false);
            RaiseChanged();
        });
    }

    public void RefreshPermission()
    {
        // Unlike macOS Accessibility, Windows has no permission that can be
        // revoked behind the app's back, so there is no "app became active"
        // hook to re-check here — WindowsInputPermissionService always
        // reports granted; a real SendInput failure surfaces per-action
        // instead (see WindowsInputExecutor).
        Permission = _permissionService.IsGranted() ? PermissionState.Ready : PermissionState.Required;
        _ = PublishStateAsync();
        RaiseChanged();
    }

    public void RequestPermission() => RefreshPermission();

    public void BeginPairing()
    {
        if (Pairing is { } pairing)
        {
            _ = pairing.BeginPairingAsync();
        }
    }

    public void ConfirmReplacement()
    {
        if (Pairing is not { } pairing) return;
        _ = Task.Run(async () =>
        {
            await pairing.BeginPairingAsync().ConfigureAwait(false);
            await pairing.ConfirmReplacementAsync().ConfigureAwait(false);
        });
    }

    public Task SaveTokenAsync(string token)
    {
        var revision = BeginCredentialOperation();
        try
        {
            Settings.SaveMacToken(token);
            _credentialEligible = true;
            Notice = "Token saved.";
            RaiseChanged();
            return ConnectAsync(revision);
        }
        catch
        {
            _credentialEligible = false;
            Notice = Settings.StorageError;
            RaiseChanged();
            return _client.ClearConfigurationAndStopAsync(revision);
        }
    }

    public async Task ClearTokenAsync()
    {
        var revision = BeginCredentialOperation();
        _credentialEligible = false;
        string? persistenceError = null;
        try
        {
            Settings.ClearMacToken();
        }
        catch
        {
            persistenceError = Settings.StorageError;
        }

        if (revision != _credentialRevision) return;
        var cleared = await _client.ClearConfigurationAndStopAsync(revision).ConfigureAwait(false);
        if (!cleared || revision != _credentialRevision) return;
        Notice = persistenceError ?? "Token cleared.";
        RaiseChanged();
    }

    private void HandleStatusEvent(RelayClient.StatusEvent evt)
    {
        if (evt.CredentialRevision != _credentialRevision || evt.Sequence <= _lastStatusSequence) return;
        _lastStatusSequence = evt.Sequence;
        Connection = evt.Status;
        RaiseChanged();

        if (Pairing is not { } pairing) return;
        var capabilityAvailable = evt.Status == RelayClient.Status.Connected;
        _ = Task.Run(async () =>
        {
            await pairing.RefreshStatusAsync(capabilityAvailable).ConfigureAwait(false);
            if (evt.CredentialRevision != _credentialRevision || evt.Sequence != _lastStatusSequence) return;
            RaiseChanged();
        });
    }

    private void HandleResult(ActionResult result)
    {
        LastResult = $"{result.Status.ToWire()}: {result.Reason.ToWire()}";
        RefreshPermission();
    }

    private async Task ReceivePairingAsync(WireMessage message)
    {
        if (Pairing is not { } pairing) return;
        var previousState = pairing.State;
        await pairing.ReceiveAsync(message).ConfigureAwait(false);
        if (message is PairStatus status && previousState is PairingState.CheckingStatus && pairing.State is PairingState.Ready)
        {
            PairingAction = PairingActionPresentation.From(status);
            RaiseChanged();
        }
    }

    private async Task ConnectAsync(ulong revision)
    {
        if (revision != _credentialRevision) return;
        if (!_credentialEligible)
        {
            await _client.ClearConfigurationAndStopAsync(revision).ConfigureAwait(false);
            return;
        }

        string token;
        try
        {
            var storedToken = Settings.MacToken();
            if (string.IsNullOrEmpty(storedToken))
            {
                if (revision != _credentialRevision || !_credentialEligible) return;
                Notice = "Save MAC_TOKEN in Settings before connecting.";
                RaiseChanged();
                return;
            }
            token = storedToken;
        }
        catch
        {
            if (revision != _credentialRevision) return;
            _credentialEligible = false;
            await _client.ClearConfigurationAndStopAsync(revision).ConfigureAwait(false);
            if (revision != _credentialRevision) return;
            Notice = Settings.StorageError;
            RaiseChanged();
            return;
        }

        if (revision != _credentialRevision || !_credentialEligible) return;
        try
        {
            var relayUrl = RelayEndpoint.Validated(Settings.RelayUrlString, allowLocalSimulator: false);
            var pairing = new PairingController(_client, relayUrl);
            Pairing = pairing;
            PairingAction = PairingActionPresentation.From(null);
            var configured = await _client.ConfigureAsync(Settings.RelayUrlString, token, allowLocalSimulator: false, revision)
                .ConfigureAwait(false);
            if (!configured) return;
            if (revision != _credentialRevision || !_credentialEligible) return;
            _client.Start(revision);
            RaiseChanged();
        }
        catch (Exception ex)
        {
            if (revision != _credentialRevision) return;
            Notice = $"Connection settings are invalid: {ex.Message}";
            RaiseChanged();
        }
    }

    private ulong BeginCredentialOperation()
    {
        _credentialRevision += 1;
        return _credentialRevision;
    }

    private void RaiseChanged() => Changed?.Invoke();
}
