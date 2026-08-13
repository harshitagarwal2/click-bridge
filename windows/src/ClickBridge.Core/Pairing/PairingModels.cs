using ClickBridge.Core.Wire;

namespace ClickBridge.Core.Pairing;

public sealed record PairingInvitation(Uri Url, DateTimeOffset ExpiresAt)
{
    public string QrPayload => Url.AbsoluteUri;
    public string SharePayload => Url.AbsoluteUri;
    public string AccessibilityLabel => "Pairing QR code. Expires in five minutes.";
}

public sealed record PairingApproval(string ConfirmationCode, PairingClientKind ClientKind, DateTimeOffset ExpiresAt)
{
    public string AccessibilityCode => $"Confirmation code {ConfirmationCode}";
}

/// <summary>Port of mac/ClickBridgeMac/PairingController.swift's PairingController.State enum.</summary>
public abstract record PairingState
{
    public sealed record Unavailable : PairingState;
    public sealed record CheckingStatus : PairingState;
    public sealed record Ready : PairingState;
    public sealed record ReplacementConfirmation : PairingState;
    public sealed record Creating : PairingState;
    public sealed record InvitationState(PairingInvitation Invitation) : PairingState;
    public sealed record ApprovalState(PairingApproval Approval) : PairingState;
    public sealed record Approving : PairingState;
    public sealed record Denying : PairingState;
    public sealed record Cancelling : PairingState;
    public sealed record CancelFailed : PairingState;
    public sealed record Completed(int ActivePhoneCredentialVersion) : PairingState;
    public sealed record Denied : PairingState;
    public sealed record Expired : PairingState;
    public sealed record Failed : PairingState;
}

public enum PairingRecoveryAction { Retry, StartAgain }

/// <summary>Port of PairingActionPresentation from mac/ClickBridgeMac/AppState.swift.</summary>
public sealed record PairingActionPresentation(string Title, bool RequiresReplacementConfirmation)
{
    public static PairingActionPresentation From(PairStatus? status)
    {
        _ = status;
        return new PairingActionPresentation("Add Phone", false);
    }
}
