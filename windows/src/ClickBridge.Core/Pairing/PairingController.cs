using ClickBridge.Core.Relay;
using ClickBridge.Core.Wire;

namespace ClickBridge.Core.Pairing;

/// <summary>
/// Port of mac/ClickBridgeMac/PairingController.swift's PairingController.
/// Swift marks this @MainActor (all calls serialized on the UI thread); the
/// Windows app is expected to use it the same way — from the UI thread only
/// — so, unlike RelayClient, this class holds no lock of its own.
/// </summary>
public sealed class PairingController
{
    private enum RetryAction { None, Status, Create, StartAgain }

    private sealed record SendOwnership(ulong Operation, string? RequestId, string? ClaimId, PairingState State);

    private readonly IPairingTransport _transport;
    private readonly Uri _relayUrl;
    private readonly Func<string> _requestId;
    private readonly Func<DateTimeOffset> _now;

    private string? _currentRequestId;
    private string? _currentClaimId;
    private PairStatus? _enrollment;
    private bool _capabilityAvailable;
    private ulong _operationEpoch;
    private RetryAction _retryAction = RetryAction.None;

    public PairingState State { get; private set; } = new PairingState.Unavailable();

    public event Action? StateChanged;

    public PairingController(
        IPairingTransport transport,
        Uri relayUrl,
        Func<string>? requestId = null,
        Func<DateTimeOffset>? now = null)
    {
        _transport = transport;
        _relayUrl = relayUrl;
        _requestId = requestId ?? (() => Guid.NewGuid().ToString().ToLowerInvariant());
        _now = now ?? (() => DateTimeOffset.UtcNow);
    }

    public PairingRecoveryAction? RecoveryAction => _retryAction switch
    {
        RetryAction.Status or RetryAction.Create => PairingRecoveryAction.Retry,
        RetryAction.StartAgain => PairingRecoveryAction.StartAgain,
        _ => null,
    };

    public async Task RefreshStatusAsync(bool capabilityAvailable)
    {
        if (!capabilityAvailable)
        {
            _capabilityAvailable = false;
            _enrollment = null;
            _retryAction = RetryAction.None;
            Reset(new PairingState.Unavailable());
            return;
        }
        _capabilityAvailable = true;
        _enrollment = null;
        _retryAction = RetryAction.None;
        var identifier = _requestId();
        _currentRequestId = identifier;
        _currentClaimId = null;
        var ownership = BeginSend(new PairingState.CheckingStatus());
        try
        {
            await _transport.SendPairingAsync(new PairStatusRequest { RequestId = identifier }).ConfigureAwait(false);
            if (!Owns(ownership)) return;
        }
        catch
        {
            if (!Owns(ownership)) return;
            _retryAction = RetryAction.Status;
            Reset(new PairingState.Failed());
        }
    }

    public Task BeginPairingAsync()
    {
        if (!_capabilityAvailable || _enrollment?.RequiresReplacementConfirmation != true ||
            State is not PairingState.Ready)
        {
            return Task.CompletedTask;
        }
        Transition(new PairingState.ReplacementConfirmation());
        return Task.CompletedTask;
    }

    public Task ConfirmReplacementAsync() =>
        State is PairingState.ReplacementConfirmation ? CreateInvitationAsync() : Task.CompletedTask;

    public async Task RegenerateAsync()
    {
        if (!_capabilityAvailable) return;
        switch (State, _retryAction)
        {
            case (PairingState.Failed, RetryAction.Status):
            case (PairingState.CancelFailed, RetryAction.Status):
                await RefreshStatusAsync(true).ConfigureAwait(false);
                break;
            case (PairingState.Failed, RetryAction.Create):
            case (PairingState.Expired, RetryAction.Create):
                await CreateInvitationAsync().ConfigureAwait(false);
                break;
            case (PairingState.Failed, RetryAction.StartAgain):
            case (PairingState.Denied, RetryAction.StartAgain):
            case (PairingState.Expired, RetryAction.StartAgain):
                await RefreshStatusAsync(true).ConfigureAwait(false);
                break;
        }
    }

    private async Task CreateInvitationAsync()
    {
        if (!_capabilityAvailable || _enrollment?.RequiresReplacementConfirmation != true) return;
        var identifier = _requestId();
        _currentRequestId = identifier;
        _currentClaimId = null;
        _retryAction = RetryAction.None;
        var ownership = BeginSend(new PairingState.Creating());
        try
        {
            await _transport.SendPairingAsync(new PairCreate { RequestId = identifier }).ConfigureAwait(false);
            if (!Owns(ownership)) return;
        }
        catch
        {
            if (!Owns(ownership)) return;
            _retryAction = RetryAction.Create;
            Reset(new PairingState.Failed());
        }
    }

    public async Task ApproveAsync()
    {
        if (_currentRequestId is not { } requestId || _currentClaimId is not { } claimId) return;
        if (State is not PairingState.ApprovalState) return;
        _retryAction = RetryAction.None;
        var ownership = BeginSend(new PairingState.Approving());
        try
        {
            await _transport.SendPairingAsync(new PairApprove { RequestId = requestId, ClaimId = claimId }).ConfigureAwait(false);
            if (!Owns(ownership)) return;
        }
        catch
        {
            if (!Owns(ownership)) return;
            _retryAction = RetryAction.StartAgain;
            Reset(new PairingState.Failed());
        }
    }

    public Task DenyAsync() => RejectClaimAsync(new PairingState.Denied());

    public Task CodesDoNotMatchAsync() => RejectClaimAsync(new PairingState.Denied());

    public async Task CancelAsync()
    {
        if (_currentRequestId is not { } requestId) return;
        if (State is not (PairingState.Creating or PairingState.InvitationState or PairingState.ApprovalState)) return;
        var ownership = BeginSend(new PairingState.Cancelling());
        try
        {
            await _transport.SendPairingAsync(new PairCancel { RequestId = requestId }).ConfigureAwait(false);
            if (!Owns(ownership)) return;
            _retryAction = RetryAction.None;
            Reset(new PairingState.Ready());
        }
        catch
        {
            if (!Owns(ownership)) return;
            _enrollment = null;
            _retryAction = RetryAction.Status;
            Reset(new PairingState.CancelFailed());
        }
    }

    public bool CopyWebInvitation(PairingInvitation expected, IClipboard clipboard)
    {
        if (State is not PairingState.InvitationState { Invitation: var current } || current != expected ||
            _now() >= current.ExpiresAt)
        {
            return false;
        }
        Uri webInvitation;
        try
        {
            webInvitation = PairingLink.MakeWebInvitation(current.Url);
        }
        catch
        {
            return false;
        }
        return clipboard.SetText(webInvitation.AbsoluteUri);
    }

    public async Task RefreshExpiryAsync()
    {
        DateTimeOffset? expiresAt;
        bool canRegenerateInvitation;
        switch (State)
        {
            case PairingState.InvitationState invitation:
                expiresAt = invitation.Invitation.ExpiresAt;
                canRegenerateInvitation = true;
                break;
            case PairingState.ApprovalState approval:
                expiresAt = approval.Approval.ExpiresAt;
                canRegenerateInvitation = false;
                break;
            default:
                expiresAt = null;
                canRegenerateInvitation = false;
                break;
        }
        if (expiresAt is not { } deadline || _now() < deadline) return;

        if (_currentRequestId is { } requestId)
        {
            var ownership = BeginSend(new PairingState.Cancelling());
            try
            {
                await _transport.SendPairingAsync(new PairCancel { RequestId = requestId }).ConfigureAwait(false);
                if (!Owns(ownership)) return;
            }
            catch
            {
                if (!Owns(ownership)) return;
                _enrollment = null;
                _retryAction = RetryAction.Status;
                Reset(new PairingState.CancelFailed());
                return;
            }
        }
        _retryAction = canRegenerateInvitation ? RetryAction.Create : RetryAction.StartAgain;
        Reset(new PairingState.Expired());
    }

    public Task ReceiveAsync(WireMessage message)
    {
        switch (message)
        {
            case PairStatus status when State is PairingState.CheckingStatus && status.RequestId == _currentRequestId:
                _enrollment = status;
                _retryAction = RetryAction.None;
                Reset(new PairingState.Ready());
                break;
            case PairCreated created when State is PairingState.Creating && created.RequestId == _currentRequestId:
                Uri link;
                try
                {
                    link = PairingLink.Make(_relayUrl, created.Reference);
                }
                catch
                {
                    _retryAction = RetryAction.Create;
                    Reset(new PairingState.Failed());
                    break;
                }
                _retryAction = RetryAction.Create;
                Transition(new PairingState.InvitationState(new PairingInvitation(
                    link, DateTimeOffset.FromUnixTimeMilliseconds(created.ExpiresAtUnixMs))));
                break;
            case PairClaimedMac claimed when CanAcceptClaim && claimed.RequestId == _currentRequestId:
                _currentClaimId = claimed.ClaimId;
                Transition(new PairingState.ApprovalState(new PairingApproval(
                    claimed.ConfirmationCode, claimed.ClientKind,
                    DateTimeOffset.FromUnixTimeMilliseconds(claimed.ExpiresAtUnixMs))));
                break;
            case PairCompleted completed when State is PairingState.Approving &&
                completed.RequestId == _currentRequestId && completed.ClaimId == _currentClaimId:
                _retryAction = RetryAction.None;
                Reset(new PairingState.Completed(completed.ActivePhoneCredentialVersion));
                break;
            case PairFailed failed when failed.RequestId == _currentRequestId:
                ReceivePairingFailure(failed);
                break;
        }
        return Task.CompletedTask;
    }

    private async Task RejectClaimAsync(PairingState terminalState)
    {
        if (_currentRequestId is not { } requestId || _currentClaimId is not { } claimId) return;
        if (State is not PairingState.ApprovalState) return;
        var ownership = BeginSend(new PairingState.Denying());
        try
        {
            await _transport.SendPairingAsync(new PairDeny { RequestId = requestId, ClaimId = claimId }).ConfigureAwait(false);
        }
        catch
        {
            if (!Owns(ownership)) return;
            _retryAction = RetryAction.StartAgain;
            Reset(new PairingState.Failed());
            return;
        }
        if (!Owns(ownership)) return;
        _retryAction = RetryAction.StartAgain;
        Reset(terminalState);
    }

    private bool CanAcceptClaim => State is PairingState.InvitationState;

    private void ReceivePairingFailure(PairFailed failed)
    {
        switch (State)
        {
            case PairingState.CheckingStatus when failed.ClaimId is null:
                _retryAction = RetryAction.Status;
                Reset(new PairingState.Failed());
                break;
            case PairingState.Creating when failed.ClaimId is null:
            case PairingState.InvitationState when failed.ClaimId is null:
                ApplyRequestScopedFailure(failed.Reason);
                break;
            case PairingState.ApprovalState when failed.ClaimId == _currentClaimId:
            case PairingState.Approving when failed.ClaimId == _currentClaimId:
                ApplyClaimScopedFailure(failed.Reason);
                break;
            case PairingState.Denying when failed.ClaimId == _currentClaimId:
                ApplyClaimScopedFailure(failed.Reason);
                break;
            case PairingState.Cancelling when failed.ClaimId is null || failed.ClaimId == _currentClaimId:
                if (failed.Reason == PairingFailureReason.Cancelled)
                {
                    _retryAction = RetryAction.None;
                    Reset(new PairingState.Ready());
                }
                else
                {
                    _enrollment = null;
                    _retryAction = RetryAction.Status;
                    Reset(new PairingState.CancelFailed());
                }
                break;
        }
    }

    private void ApplyRequestScopedFailure(PairingFailureReason reason)
    {
        _retryAction = reason == PairingFailureReason.Expired ? RetryAction.Create : RetryAction.None;
        switch (reason)
        {
            case PairingFailureReason.Expired:
                Reset(new PairingState.Expired());
                break;
            case PairingFailureReason.Cancelled:
                _retryAction = RetryAction.None;
                Reset(new PairingState.Ready());
                break;
            default:
                _retryAction = RetryAction.StartAgain;
                Reset(new PairingState.Failed());
                break;
        }
    }

    private void ApplyClaimScopedFailure(PairingFailureReason reason)
    {
        _retryAction = RetryAction.StartAgain;
        switch (reason)
        {
            case PairingFailureReason.Denied:
                Reset(new PairingState.Denied());
                break;
            case PairingFailureReason.Cancelled:
                _retryAction = RetryAction.None;
                Reset(new PairingState.Ready());
                break;
            case PairingFailureReason.Expired:
                Reset(new PairingState.Expired());
                break;
            default:
                Reset(new PairingState.Failed());
                break;
        }
    }

    private void Reset(PairingState state)
    {
        _operationEpoch += 1;
        _currentRequestId = null;
        _currentClaimId = null;
        if (state is PairingState.Unavailable)
        {
            _enrollment = null;
        }
        State = state;
        StateChanged?.Invoke();
    }

    private void Transition(PairingState state)
    {
        _operationEpoch += 1;
        State = state;
        StateChanged?.Invoke();
    }

    private SendOwnership BeginSend(PairingState state)
    {
        _operationEpoch += 1;
        State = state;
        StateChanged?.Invoke();
        return new SendOwnership(_operationEpoch, _currentRequestId, _currentClaimId, state);
    }

    private bool Owns(SendOwnership ownership) =>
        _operationEpoch == ownership.Operation &&
        _currentRequestId == ownership.RequestId &&
        _currentClaimId == ownership.ClaimId &&
        State == ownership.State;
}
