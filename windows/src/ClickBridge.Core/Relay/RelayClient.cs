using ClickBridge.Core.Actions;
using ClickBridge.Core.Wire;

namespace ClickBridge.Core.Relay;

/// <summary>
/// Port of mac/ClickBridgeMac/RelayClient.swift. Swift models this as an
/// `actor`, which serializes synchronous state access automatically but
/// stays reentrant across `await` points (another call can run while one is
/// suspended) — hence the Swift source's `guard isCurrent(expected)` checks
/// after nearly every await. Here the same property is reproduced with a
/// plain lock around short, synchronous state reads/writes (never held
/// across an await) plus the identical generation-number and
/// credential-mutation-epoch fencing, so a response or callback that
/// arrives after the world has moved on is always discarded rather than
/// acted on.
/// </summary>
public sealed class RelayClient : IPairingTransport
{
    public enum Status { Disconnected, Connecting, Connected }

    public readonly record struct StatusEvent(Status Status, ulong CredentialRevision, ulong Sequence);

    private readonly record struct CredentialMutation(ulong Revision, ulong Epoch);

    public delegate Task SleepDelegate(TimeSpan duration, CancellationToken cancellationToken);
    public delegate TimeSpan JitterDelegate(TimeSpan ceiling);

    private readonly IActionRequestSink _actionSink;
    private readonly IDiagnosticCounterReading _diagnostics;
    private readonly Func<IWebSocketTransport> _makeTransport;
    private readonly SleepDelegate _sleep;
    private readonly JitterDelegate _jitter;
    private readonly Func<double> _wallClockMilliseconds;

    private readonly object _gate = new();

    private Uri? _endpoint;
    private string? _token;
    private IWebSocketTransport? _transport;
    private CancellationTokenSource? _generationCts;
    private CancellationTokenSource? _reconnectCts;
    private int _generation;
    private int? _authenticatedGeneration;
    private ActionAuthorizationLease? _authenticatedActionAuthorization;
    private Task<ActionAuthorizationLease>? _authorizationActivationTask;
    private int _reconnectAttempt;
    private int _sequence;
    private int? _pendingHeartbeat;
    private bool _running;
    private ulong _highestCredentialOperation;
    private ulong _credentialMutationEpoch;
    private ulong? _configuredMutationEpoch;
    private Status _status = Status.Disconnected;
    private MacState _advertisedState = new() { RemoteEnabled = false, Permission = PermissionState.Unknown };
    private ulong _statusSequence;
    private ulong _statusCredentialRevision;

    private Action<StatusEvent>? _statusHandler;
    private Action<ActionResult>? _resultHandler;
    private Func<WireMessage, Task>? _pairingHandler;

    public RelayClient(
        IActionRequestSink actionSink,
        IDiagnosticCounterReading diagnostics,
        Func<IWebSocketTransport>? makeTransport = null,
        SleepDelegate? sleep = null,
        JitterDelegate? jitter = null,
        Func<double>? wallClockMilliseconds = null)
    {
        _actionSink = actionSink;
        _diagnostics = diagnostics;
        _makeTransport = makeTransport ?? (() => new ClientWebSocketTransport());
        _sleep = sleep ?? ((duration, ct) => Task.Delay(duration, ct));
        _jitter = jitter ?? (ceiling => TimeSpan.FromSeconds(Random.Shared.NextDouble() * ceiling.TotalSeconds));
        _wallClockMilliseconds = wallClockMilliseconds ?? (() => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
    }

    public void SetStatusHandler(Action<StatusEvent>? handler)
    {
        lock (_gate) { _statusHandler = handler; }
    }

    public void SetResultHandler(Action<ActionResult>? handler)
    {
        lock (_gate) { _resultHandler = handler; }
    }

    public void SetPairingHandler(Func<WireMessage, Task>? handler)
    {
        lock (_gate) { _pairingHandler = handler; }
    }

    public Status CurrentStatus()
    {
        lock (_gate) { return _status; }
    }

    public async Task SendPairingAsync(WireMessage message)
    {
        IWebSocketTransport socket;
        int expected;
        lock (_gate)
        {
            if (!IsPairingRequest(message) || _status != Status.Connected ||
                _authenticatedGeneration != _generation || _transport is null)
            {
                throw new WebSocketTransportException(WebSocketTransportErrorKind.NotConnected);
            }
            socket = _transport;
            expected = _generation;
        }
        try
        {
            await SendAsync(message, socket, expected, requireAuthentication: true).ConfigureAwait(false);
        }
        catch
        {
            if (IsCurrent(expected))
            {
                await GenerationFailedAsync(expected, socket).ConfigureAwait(false);
            }
            throw;
        }
    }

    public async Task<bool> ConfigureAsync(
        string urlString,
        string token,
        bool allowLocalSimulator,
        ulong? credentialRevision = null)
    {
        CredentialMutation? mutation;
        lock (_gate) { mutation = ClaimCredentialMutationLocked(credentialRevision); }
        if (mutation is not { } claimed)
        {
            return false;
        }

        Uri validated;
        try
        {
            validated = RelayEndpoint.Validated(urlString, allowLocalSimulator);
        }
        catch
        {
            lock (_gate)
            {
                _running = false;
                _endpoint = null;
                _token = null;
            }
            await CancelGenerationAsync().ConfigureAwait(false);
            lock (_gate)
            {
                if (IsCurrentCredentialMutationLocked(claimed))
                {
                    SetStatusLocked(Status.Disconnected);
                }
            }
            throw;
        }

        await CancelGenerationAsync().ConfigureAwait(false);
        lock (_gate)
        {
            if (!IsCurrentCredentialMutationLocked(claimed))
            {
                return false;
            }
            _endpoint = validated;
            _token = token;
            _configuredMutationEpoch = claimed.Epoch;
            return true;
        }
    }

    public async Task UpdateAdvertisedStateAsync(MacState snapshot)
    {
        IWebSocketTransport? socket;
        int expected;
        lock (_gate)
        {
            _advertisedState = snapshot;
            if (_status != Status.Connected || _authenticatedGeneration != _generation || _transport is null)
            {
                return;
            }
            socket = _transport;
            expected = _generation;
        }
        try
        {
            await SendAsync(snapshot, socket!, expected, requireAuthentication: true).ConfigureAwait(false);
        }
        catch
        {
            await GenerationFailedAsync(expected, socket!).ConfigureAwait(false);
        }
    }

    public void Start(ulong? credentialRevision = null)
    {
        lock (_gate)
        {
            if (credentialRevision is { } requested && requested != _highestCredentialOperation)
            {
                return;
            }
            if (_configuredMutationEpoch != _credentialMutationEpoch)
            {
                return;
            }
            _running = true;
            if (_generationCts is not null)
            {
                return;
            }
            OpenGenerationLocked();
        }
    }

    public async Task<bool> StopAsync(ulong? credentialRevision = null)
    {
        CredentialMutation? mutation;
        lock (_gate) { mutation = ClaimCredentialMutationLocked(credentialRevision); }
        if (mutation is not { } claimed)
        {
            return false;
        }
        lock (_gate) { _running = false; }
        await CancelGenerationAsync().ConfigureAwait(false);
        lock (_gate)
        {
            if (!IsCurrentCredentialMutationLocked(claimed))
            {
                return false;
            }
            SetStatusLocked(Status.Disconnected);
            return true;
        }
    }

    public async Task<bool> ClearConfigurationAndStopAsync(ulong? credentialRevision = null)
    {
        CredentialMutation? mutation;
        lock (_gate) { mutation = ClaimCredentialMutationLocked(credentialRevision); }
        if (mutation is not { } claimed)
        {
            return false;
        }
        lock (_gate)
        {
            _running = false;
            _endpoint = null;
            _token = null;
        }
        await CancelGenerationAsync().ConfigureAwait(false);
        lock (_gate)
        {
            if (!IsCurrentCredentialMutationLocked(claimed))
            {
                return false;
            }
            SetStatusLocked(Status.Disconnected);
            return true;
        }
    }

    public async Task<bool> ReconnectAsync(ulong? credentialRevision = null)
    {
        CredentialMutation? mutation;
        lock (_gate) { mutation = ClaimCredentialMutationLocked(credentialRevision); }
        if (mutation is not { } claimed)
        {
            return false;
        }
        await CancelGenerationAsync().ConfigureAwait(false);
        lock (_gate)
        {
            if (!IsCurrentCredentialMutationLocked(claimed) || !_running)
            {
                return false;
            }
            _configuredMutationEpoch = claimed.Epoch;
            OpenGenerationLocked();
            return true;
        }
    }

    private async Task CancelGenerationAsync()
    {
        ActionAuthorizationLease? authorization;
        Task<ActionAuthorizationLease>? activatingAuthorization;
        IWebSocketTransport? old;
        CancellationTokenSource? generationCts;
        CancellationTokenSource? reconnectCts;
        lock (_gate)
        {
            authorization = _authenticatedActionAuthorization;
            activatingAuthorization = _authorizationActivationTask;
            _generation += 1;
            _authenticatedGeneration = null;
            _authenticatedActionAuthorization = null;
            _authorizationActivationTask = null;
            generationCts = _generationCts;
            _generationCts = null;
            reconnectCts = _reconnectCts;
            _reconnectCts = null;
            _pendingHeartbeat = null;
            old = _transport;
            _transport = null;
        }
        generationCts?.Cancel();
        generationCts?.Dispose();
        reconnectCts?.Cancel();
        reconnectCts?.Dispose();

        if (authorization is not null)
        {
            await _actionSink.RevokeAuthorizationLeaseAsync(authorization).ConfigureAwait(false);
        }
        if (activatingAuthorization is not null)
        {
            var activatingLease = await activatingAuthorization.ConfigureAwait(false);
            if (!ReferenceEquals(activatingLease, authorization))
            {
                await _actionSink.RevokeAuthorizationLeaseAsync(activatingLease).ConfigureAwait(false);
            }
        }
        if (old is not null)
        {
            await old.CloseAsync().ConfigureAwait(false);
        }
    }

    private CredentialMutation? ClaimCredentialMutationLocked(ulong? requestedRevision)
    {
        if (requestedRevision is { } requested)
        {
            if (requested < _highestCredentialOperation)
            {
                return null;
            }
            _highestCredentialOperation = requested;
        }
        else
        {
            _highestCredentialOperation += 1;
        }
        _credentialMutationEpoch += 1;
        _configuredMutationEpoch = null;
        return new CredentialMutation(_highestCredentialOperation, _credentialMutationEpoch);
    }

    private bool IsCurrentCredentialMutationLocked(CredentialMutation mutation) =>
        mutation.Revision == _highestCredentialOperation && mutation.Epoch == _credentialMutationEpoch;

    private void SetStatusLocked(Status value)
    {
        if (_status == value && _statusCredentialRevision == _highestCredentialOperation)
        {
            return;
        }
        _status = value;
        _statusCredentialRevision = _highestCredentialOperation;
        _statusSequence += 1;
        _statusHandler?.Invoke(new StatusEvent(value, _highestCredentialOperation, _statusSequence));
    }

    private void OpenGenerationLocked()
    {
        if (!_running || _endpoint is null || _token is null || _token.Length == 0)
        {
            SetStatusLocked(Status.Disconnected);
            return;
        }
        _generation += 1;
        _authenticatedGeneration = null;
        var expected = _generation;
        var socket = _makeTransport();
        _transport = socket;
        var cts = new CancellationTokenSource();
        _generationCts = cts;
        SetStatusLocked(Status.Connecting);
        var endpoint = _endpoint;
        var token = _token;
        _ = Task.Run(() => ReceiveLoopAsync(socket, expected, endpoint, token, cts.Token));
    }

    private async Task ReceiveLoopAsync(IWebSocketTransport socket, int expected, Uri endpoint, string token, CancellationToken ct)
    {
        try
        {
            await socket.ConnectAsync(endpoint, ct).ConfigureAwait(false);
            if (!IsCurrent(expected)) return;
            await socket.SendTextAsync(WireCodec.Encode(new Hello { Role = WireRole.Mac, Token = token }), ct)
                .ConfigureAwait(false);
            if (!IsCurrent(expected)) return;
            while (!ct.IsCancellationRequested)
            {
                var text = await socket.ReceiveTextAsync(ct).ConfigureAwait(false);
                if (!IsCurrent(expected)) return;
                await HandleAsync(text, expected, socket, ct).ConfigureAwait(false);
            }
        }
        catch
        {
            await GenerationFailedAsync(expected, socket).ConfigureAwait(false);
        }
    }

    private async Task HandleAsync(string text, int expected, IWebSocketTransport socket, CancellationToken ct)
    {
        if (!IsCurrent(expected))
        {
            throw new OperationCanceledException();
        }
        var message = WireCodec.Decode(text, WireRole.Mac);

        bool needsAuthentication;
        lock (_gate) { needsAuthentication = _authenticatedGeneration != expected; }
        if (needsAuthentication)
        {
            if (message is not HelloOk { Role: WireRole.Mac })
            {
                throw new WireException(WireErrorKind.MessageNotAllowed);
            }
            ActionAuthorizationGeneration authorizationGeneration;
            lock (_gate)
            {
                _authenticatedGeneration = expected;
                authorizationGeneration = new ActionAuthorizationGeneration(_credentialMutationEpoch, expected);
            }
            var activationTask = _actionSink.ActivateAuthorizationLeaseAsync(authorizationGeneration);
            lock (_gate) { _authorizationActivationTask = activationTask; }
            var authorization = await activationTask.ConfigureAwait(false);
            if (!IsAuthenticated(expected))
            {
                await _actionSink.RevokeAuthorizationLeaseAsync(authorization).ConfigureAwait(false);
                throw new OperationCanceledException();
            }
            MacState advertisedState;
            lock (_gate)
            {
                _authorizationActivationTask = null;
                _authenticatedActionAuthorization = authorization;
                _reconnectAttempt = 0;
                SetStatusLocked(Status.Connected);
                advertisedState = _advertisedState;
            }
            await SendAsync(advertisedState, socket, expected, requireAuthentication: true).ConfigureAwait(false);
            if (!IsAuthenticated(expected))
            {
                throw new OperationCanceledException();
            }
            StartHeartbeat(expected, socket, ct);
            return;
        }

        if (message is HelloOk)
        {
            throw new WireException(WireErrorKind.MessageNotAllowed);
        }

        switch (message)
        {
            case HeartbeatAck ack:
                lock (_gate)
                {
                    if (_pendingHeartbeat == ack.Sequence)
                    {
                        _pendingHeartbeat = null;
                    }
                }
                break;
            case ActionRequest request:
            {
                ActionAuthorizationLease? authorization;
                lock (_gate)
                {
                    authorization = IsAuthenticated(expected) ? _authenticatedActionAuthorization : null;
                }
                if (authorization is null)
                {
                    throw new OperationCanceledException();
                }
                var result = await _actionSink.ReceiveAsync(request, ActionIngress.Oci, authorization).ConfigureAwait(false);
                if (!IsAuthenticated(expected))
                {
                    throw new OperationCanceledException();
                }
                lock (_gate) { _resultHandler?.Invoke(result); }
                await SendAsync(result, socket, expected, requireAuthentication: true).ConfigureAwait(false);
                break;
            }
            case TimeSyncRequest request:
            {
                var received = _wallClockMilliseconds();
                await SendAsync(
                    new TimeSyncResponse
                    {
                        SyncId = request.SyncId,
                        PhoneSendUnixMs = request.PhoneSendUnixMs,
                        MacReceiveUnixMs = received,
                        MacSendUnixMs = _wallClockMilliseconds(),
                    },
                    socket, expected, requireAuthentication: true).ConfigureAwait(false);
                break;
            }
            case DiagnosticsRequest request:
            {
                var counts = await _diagnostics.DiagnosticPostCountsAsync().ConfigureAwait(false);
                if (!IsAuthenticated(expected))
                {
                    throw new OperationCanceledException();
                }
                await SendAsync(
                    new DiagnosticsCounters
                    {
                        RequestId = request.RequestId,
                        MouseDownPostCount = counts.MouseDownPostCount,
                        MouseUpPostCount = counts.MouseUpPostCount,
                    },
                    socket, expected, requireAuthentication: true).ConfigureAwait(false);
                break;
            }
            case PairStatus or PairCreated or PairClaimedMac or PairCompleted or PairFailed:
            {
                Func<WireMessage, Task>? handler;
                lock (_gate) { handler = _pairingHandler; }
                if (handler is not null)
                {
                    await handler(message).ConfigureAwait(false);
                }
                break;
            }
            default:
                throw new WireException(WireErrorKind.MessageNotAllowed);
        }
    }

    private async Task SendAsync(WireMessage value, IWebSocketTransport socket, int expected, bool requireAuthentication)
    {
        if (!IsCurrent(expected) || (requireAuthentication && !IsAuthenticated(expected)))
        {
            throw new OperationCanceledException();
        }
        await socket.SendTextAsync(WireCodec.Encode(value), CancellationToken.None).ConfigureAwait(false);
        if (!IsCurrent(expected) || (requireAuthentication && !IsAuthenticated(expected)))
        {
            throw new OperationCanceledException();
        }
    }

    private void StartHeartbeat(int expected, IWebSocketTransport socket, CancellationToken ct)
    {
        _ = Task.Run(async () =>
        {
            while (IsAuthenticated(expected))
            {
                try
                {
                    await _sleep(TimeSpan.FromSeconds(Constants.HeartbeatIntervalSeconds), ct)
                        .ConfigureAwait(false);
                }
                catch (OperationCanceledException)
                {
                    return;
                }
                if (!IsAuthenticated(expected)) return;
                await OriginateHeartbeatAsync(expected, socket, ct).ConfigureAwait(false);
            }
        }, ct);
    }

    private bool IsCurrent(int expected)
    {
        lock (_gate) { return _running && expected == _generation; }
    }

    private bool IsAuthenticated(int expected) =>
        IsCurrent(expected) && AuthenticatedGenerationMatches(expected);

    private bool AuthenticatedGenerationMatches(int expected)
    {
        lock (_gate) { return _authenticatedGeneration == expected; }
    }

    private async Task OriginateHeartbeatAsync(int expected, IWebSocketTransport socket, CancellationToken ct)
    {
        if (!IsAuthenticated(expected)) return;
        int sentSequence;
        lock (_gate)
        {
            _sequence += 1;
            sentSequence = _sequence;
            _pendingHeartbeat = sentSequence;
        }
        try
        {
            await SendAsync(new HeartbeatRequest { Sequence = sentSequence }, socket, expected, requireAuthentication: true)
                .ConfigureAwait(false);
        }
        catch
        {
            await GenerationFailedAsync(expected, socket).ConfigureAwait(false);
            return;
        }
        if (!IsAuthenticated(expected)) return;

        _ = Task.Run(async () =>
        {
            try
            {
                await _sleep(TimeSpan.FromSeconds(Constants.HeartbeatTimeoutSeconds), ct)
                    .ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                return;
            }
            await HeartbeatTimedOutAsync(sentSequence, expected, socket).ConfigureAwait(false);
        }, ct);
    }

    private async Task HeartbeatTimedOutAsync(int expectedSequence, int expected, IWebSocketTransport socket)
    {
        bool timedOut;
        lock (_gate) { timedOut = IsAuthenticated(expected) && _pendingHeartbeat == expectedSequence; }
        if (!timedOut) return;
        await GenerationFailedAsync(expected, socket).ConfigureAwait(false);
    }

    private async Task GenerationFailedAsync(int expected, IWebSocketTransport socket)
    {
        ActionAuthorizationLease? authorization;
        Task<ActionAuthorizationLease>? activatingAuthorization;
        CancellationTokenSource? generationCts;
        int reconnectGeneration;
        lock (_gate)
        {
            if (!_running || expected != _generation) return;
            _generation += 1;
            reconnectGeneration = _generation;
            authorization = _authenticatedActionAuthorization;
            activatingAuthorization = _authorizationActivationTask;
            _authenticatedGeneration = null;
            _authenticatedActionAuthorization = null;
            _authorizationActivationTask = null;
            generationCts = _generationCts;
            _generationCts = null;
            _pendingHeartbeat = null;
            _transport = null;
        }
        generationCts?.Cancel();
        generationCts?.Dispose();

        if (authorization is not null)
        {
            await _actionSink.RevokeAuthorizationLeaseAsync(authorization).ConfigureAwait(false);
        }
        if (activatingAuthorization is not null)
        {
            var activatingLease = await activatingAuthorization.ConfigureAwait(false);
            if (!ReferenceEquals(activatingLease, authorization))
            {
                await _actionSink.RevokeAuthorizationLeaseAsync(activatingLease).ConfigureAwait(false);
            }
        }
        await socket.CloseAsync().ConfigureAwait(false);

        TimeSpan delay;
        CancellationTokenSource reconnectCts;
        lock (_gate)
        {
            if (!_running || _generation != reconnectGeneration) return;
            SetStatusLocked(Status.Disconnected);
            _reconnectAttempt += 1;
            var ceilingSeconds = Math.Min(Constants.MacReconnectCapSeconds, 0.5 * Math.Pow(2, _reconnectAttempt - 1));
            delay = _jitter(TimeSpan.FromSeconds(ceilingSeconds));
            _reconnectCts?.Cancel();
            _reconnectCts?.Dispose();
            reconnectCts = new CancellationTokenSource();
            _reconnectCts = reconnectCts;
        }
        _ = Task.Run(async () =>
        {
            try
            {
                await _sleep(delay, reconnectCts.Token).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                return;
            }
            ResumeAfterBackoff(reconnectGeneration);
        });
    }

    private void ResumeAfterBackoff(int expected)
    {
        lock (_gate)
        {
            if (!_running || expected != _generation) return;
            _reconnectCts = null;
            OpenGenerationLocked();
        }
    }

    private static bool IsPairingRequest(WireMessage message) => message is
        PairStatusRequest or PairCreate or PairCancel or PairApprove or PairDeny;
}
