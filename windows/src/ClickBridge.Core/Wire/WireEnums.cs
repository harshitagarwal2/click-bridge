namespace ClickBridge.Core.Wire;

// Each enum below mirrors a Swift String-backed enum in WireMessage.swift.
// Wire encoding/decoding always goes through ToWire/FromWire rather than a
// generic attribute-driven converter, so the mapping stays explicit and
// easy to diff against the Swift rawValue list.

public enum WireRole { Phone, Mac }

public static class WireRoleWire
{
    public static string ToWire(this WireRole value) => value switch
    {
        WireRole.Phone => "phone",
        WireRole.Mac => "mac",
        _ => throw new ArgumentOutOfRangeException(nameof(value)),
    };

    public static bool TryFromWire(string value, out WireRole role)
    {
        switch (value)
        {
            case "phone": role = WireRole.Phone; return true;
            case "mac": role = WireRole.Mac; return true;
            default: role = default; return false;
        }
    }
}

public enum PermissionState { Ready, Required, Unknown }

public static class PermissionStateWire
{
    public static string ToWire(this PermissionState value) => value switch
    {
        PermissionState.Ready => "ready",
        PermissionState.Required => "required",
        PermissionState.Unknown => "unknown",
        _ => throw new ArgumentOutOfRangeException(nameof(value)),
    };

    public static bool TryFromWire(string value, out PermissionState state)
    {
        switch (value)
        {
            case "ready": state = PermissionState.Ready; return true;
            case "required": state = PermissionState.Required; return true;
            case "unknown": state = PermissionState.Unknown; return true;
            default: state = default; return false;
        }
    }
}

public enum ResultStatus { Posted, Rejected }

public static class ResultStatusWire
{
    public static string ToWire(this ResultStatus value) => value switch
    {
        ResultStatus.Posted => "posted",
        ResultStatus.Rejected => "rejected",
        _ => throw new ArgumentOutOfRangeException(nameof(value)),
    };

    public static bool TryFromWire(string value, out ResultStatus status)
    {
        switch (value)
        {
            case "posted": status = ResultStatus.Posted; return true;
            case "rejected": status = ResultStatus.Rejected; return true;
            default: status = default; return false;
        }
    }
}

public enum ResultReason
{
    Ok,
    PermissionRequired,
    RemoteDisabled,
    IdConflict,
    Expired,
    CapacityExceeded,
    EventCreationFailed,
    InvalidRequest,
}

public static class ResultReasonWire
{
    public static string ToWire(this ResultReason value) => value switch
    {
        ResultReason.Ok => "ok",
        ResultReason.PermissionRequired => "permission_required",
        ResultReason.RemoteDisabled => "remote_disabled",
        ResultReason.IdConflict => "id_conflict",
        ResultReason.Expired => "expired",
        ResultReason.CapacityExceeded => "capacity_exceeded",
        ResultReason.EventCreationFailed => "event_creation_failed",
        ResultReason.InvalidRequest => "invalid_request",
        _ => throw new ArgumentOutOfRangeException(nameof(value)),
    };

    public static bool TryFromWire(string value, out ResultReason reason)
    {
        switch (value)
        {
            case "ok": reason = ResultReason.Ok; return true;
            case "permission_required": reason = ResultReason.PermissionRequired; return true;
            case "remote_disabled": reason = ResultReason.RemoteDisabled; return true;
            case "id_conflict": reason = ResultReason.IdConflict; return true;
            case "expired": reason = ResultReason.Expired; return true;
            case "capacity_exceeded": reason = ResultReason.CapacityExceeded; return true;
            case "event_creation_failed": reason = ResultReason.EventCreationFailed; return true;
            case "invalid_request": reason = ResultReason.InvalidRequest; return true;
            default: reason = default; return false;
        }
    }
}

public enum RelayAckStatus { Forwarded, MacOffline, Rejected }

public static class RelayAckStatusWire
{
    public static string ToWire(this RelayAckStatus value) => value switch
    {
        RelayAckStatus.Forwarded => "forwarded",
        RelayAckStatus.MacOffline => "mac_offline",
        RelayAckStatus.Rejected => "rejected",
        _ => throw new ArgumentOutOfRangeException(nameof(value)),
    };

    public static bool TryFromWire(string value, out RelayAckStatus status)
    {
        switch (value)
        {
            case "forwarded": status = RelayAckStatus.Forwarded; return true;
            case "mac_offline": status = RelayAckStatus.MacOffline; return true;
            case "rejected": status = RelayAckStatus.Rejected; return true;
            default: status = default; return false;
        }
    }
}

public enum RelayAckReason { Ok, MacOffline, Expired, InvalidRequest }

public static class RelayAckReasonWire
{
    public static string ToWire(this RelayAckReason value) => value switch
    {
        RelayAckReason.Ok => "ok",
        RelayAckReason.MacOffline => "mac_offline",
        RelayAckReason.Expired => "expired",
        RelayAckReason.InvalidRequest => "invalid_request",
        _ => throw new ArgumentOutOfRangeException(nameof(value)),
    };

    public static bool TryFromWire(string value, out RelayAckReason reason)
    {
        switch (value)
        {
            case "ok": reason = RelayAckReason.Ok; return true;
            case "mac_offline": reason = RelayAckReason.MacOffline; return true;
            case "expired": reason = RelayAckReason.Expired; return true;
            case "invalid_request": reason = RelayAckReason.InvalidRequest; return true;
            default: reason = default; return false;
        }
    }
}

/// <summary>ActionIngress mirrors mac/ClickBridgeMac/ActionIngress.swift.</summary>
public enum ActionIngress { Oci, Tailscale }

public static class ActionIngressWire
{
    public static string ToWire(this ActionIngress value) => value switch
    {
        ActionIngress.Oci => "oci",
        ActionIngress.Tailscale => "tailscale",
        _ => throw new ArgumentOutOfRangeException(nameof(value)),
    };

    public static bool TryFromWire(string value, out ActionIngress ingress)
    {
        switch (value)
        {
            case "oci": ingress = ActionIngress.Oci; return true;
            case "tailscale": ingress = ActionIngress.Tailscale; return true;
            default: ingress = default; return false;
        }
    }
}

public enum PairingClientKind { Ios, Pwa }

public static class PairingClientKindWire
{
    public static string ToWire(this PairingClientKind value) => value switch
    {
        PairingClientKind.Ios => "ios",
        PairingClientKind.Pwa => "pwa",
        _ => throw new ArgumentOutOfRangeException(nameof(value)),
    };

    public static bool TryFromWire(string value, out PairingClientKind kind)
    {
        switch (value)
        {
            case "ios": kind = PairingClientKind.Ios; return true;
            case "pwa": kind = PairingClientKind.Pwa; return true;
            default: kind = default; return false;
        }
    }
}

public enum PairingEnrollmentState { Legacy, Paired }

public static class PairingEnrollmentStateWire
{
    public static string ToWire(this PairingEnrollmentState value) => value switch
    {
        PairingEnrollmentState.Legacy => "legacy",
        PairingEnrollmentState.Paired => "paired",
        _ => throw new ArgumentOutOfRangeException(nameof(value)),
    };

    public static bool TryFromWire(string value, out PairingEnrollmentState state)
    {
        switch (value)
        {
            case "legacy": state = PairingEnrollmentState.Legacy; return true;
            case "paired": state = PairingEnrollmentState.Paired; return true;
            default: state = default; return false;
        }
    }
}

public enum PairingFailureReason
{
    Expired,
    Used,
    Cancelled,
    Denied,
    MacOffline,
    StorageFailed,
    ActivationFailed,
    InvalidRequest,
    Replaced,
    Unsupported,
}

public static class PairingFailureReasonWire
{
    public static string ToWire(this PairingFailureReason value) => value switch
    {
        PairingFailureReason.Expired => "expired",
        PairingFailureReason.Used => "used",
        PairingFailureReason.Cancelled => "cancelled",
        PairingFailureReason.Denied => "denied",
        PairingFailureReason.MacOffline => "mac_offline",
        PairingFailureReason.StorageFailed => "storage_failed",
        PairingFailureReason.ActivationFailed => "activation_failed",
        PairingFailureReason.InvalidRequest => "invalid_request",
        PairingFailureReason.Replaced => "replaced",
        PairingFailureReason.Unsupported => "unsupported",
        _ => throw new ArgumentOutOfRangeException(nameof(value)),
    };

    public static bool TryFromWire(string value, out PairingFailureReason reason)
    {
        switch (value)
        {
            case "expired": reason = PairingFailureReason.Expired; return true;
            case "used": reason = PairingFailureReason.Used; return true;
            case "cancelled": reason = PairingFailureReason.Cancelled; return true;
            case "denied": reason = PairingFailureReason.Denied; return true;
            case "mac_offline": reason = PairingFailureReason.MacOffline; return true;
            case "storage_failed": reason = PairingFailureReason.StorageFailed; return true;
            case "activation_failed": reason = PairingFailureReason.ActivationFailed; return true;
            case "invalid_request": reason = PairingFailureReason.InvalidRequest; return true;
            case "replaced": reason = PairingFailureReason.Replaced; return true;
            case "unsupported": reason = PairingFailureReason.Unsupported; return true;
            default: reason = default; return false;
        }
    }
}
