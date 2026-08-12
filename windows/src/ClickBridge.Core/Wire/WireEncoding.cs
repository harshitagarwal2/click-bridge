using System.Text.Json;

namespace ClickBridge.Core.Wire;

/// <summary>
/// A message that must additionally satisfy the same wire-shape invariants
/// the decoder enforces before it is allowed onto the socket — mirrors the
/// WireEncodingValidatable conformances on the pairing message structs in
/// WireMessage.swift (only pairing messages need this: everything else is
/// unconditionally valid once it type-checks).
/// </summary>
internal interface IWireEncodingValidatable
{
    void ValidateForWireEncoding();
}

internal static class WireEncoding
{
    public static void Write(Utf8JsonWriter writer, WireMessage message)
    {
        writer.WriteStartObject();
        writer.WriteString("type", message.Type);
        writer.WriteNumber("v", message.V);
        switch (message)
        {
            case Hello m:
                writer.WriteString("role", m.Role.ToWire());
                writer.WriteString("token", m.Token);
                break;
            case HelloOk m:
                writer.WriteString("role", m.Role.ToWire());
                break;
            case HeartbeatRequest m:
                writer.WriteNumber("sequence", m.Sequence);
                break;
            case HeartbeatAck m:
                writer.WriteNumber("sequence", m.Sequence);
                break;
            case TimeSyncRequest m:
                writer.WriteString("syncId", m.SyncId);
                writer.WriteNumber("phoneSendUnixMs", m.PhoneSendUnixMs);
                break;
            case TimeSyncResponse m:
                writer.WriteString("syncId", m.SyncId);
                writer.WriteNumber("phoneSendUnixMs", m.PhoneSendUnixMs);
                writer.WriteNumber("macReceiveUnixMs", m.MacReceiveUnixMs);
                writer.WriteNumber("macSendUnixMs", m.MacSendUnixMs);
                break;
            case DiagnosticsRequest m:
                writer.WriteString("requestId", m.RequestId);
                break;
            case DiagnosticsCounters m:
                writer.WriteString("requestId", m.RequestId);
                writer.WriteNumber("mouseDownPostCount", m.MouseDownPostCount);
                writer.WriteNumber("mouseUpPostCount", m.MouseUpPostCount);
                break;
            case MacState m:
                writer.WriteBoolean("remoteEnabled", m.RemoteEnabled);
                writer.WriteString("permission", m.Permission.ToWire());
                break;
            case PhoneState m:
                writer.WriteBoolean("macOnline", m.MacOnline);
                writer.WriteBoolean("remoteEnabled", m.RemoteEnabled);
                writer.WriteString("permission", m.Permission.ToWire());
                break;
            case ActionRequest m:
                writer.WriteString("actionId", m.ActionId);
                writer.WriteString("action", m.Action);
                writer.WriteNumber("issuedAtUnixMs", m.IssuedAtUnixMs);
                writer.WriteNumber("expiresAtUnixMs", m.ExpiresAtUnixMs);
                break;
            case RelayAck m:
                writer.WriteString("actionId", m.ActionId);
                writer.WriteString("status", m.Status.ToWire());
                writer.WriteString("reason", m.Reason.ToWire());
                writer.WriteNumber("relayProcessingUs", m.RelayProcessingUs);
                break;
            case ActionResult m:
                writer.WriteString("actionId", m.ActionId);
                writer.WriteString("status", m.Status.ToWire());
                writer.WriteString("reason", m.Reason.ToWire());
                writer.WriteString("acceptedVia", m.AcceptedVia.ToWire());
                writer.WriteNumber("macProcessingUs", m.MacProcessingUs);
                if (m.MouseDownPostedUnixMs is { } posted)
                {
                    writer.WriteNumber("mouseDownPostedUnixMs", posted);
                }
                break;
            case PairCreate m:
                writer.WriteString("requestId", m.RequestId);
                writer.WriteNumber("pairingVersion", m.PairingVersion);
                break;
            case PairStatusRequest m:
                writer.WriteString("requestId", m.RequestId);
                writer.WriteNumber("pairingVersion", m.PairingVersion);
                break;
            case PairCreated m:
                writer.WriteString("requestId", m.RequestId);
                writer.WriteString("reference", m.Reference);
                writer.WriteNumber("expiresAtUnixMs", m.ExpiresAtUnixMs);
                break;
            case PairStatus m:
                writer.WriteString("requestId", m.RequestId);
                writer.WriteString("enrollmentState", m.EnrollmentState.ToWire());
                writer.WriteNumber("activePhoneCredentialVersion", m.ActivePhoneCredentialVersion);
                break;
            case PairCancel m:
                writer.WriteString("requestId", m.RequestId);
                break;
            case PairClaimedMac m:
                writer.WriteString("requestId", m.RequestId);
                writer.WriteString("claimId", m.ClaimId);
                writer.WriteString("confirmationCode", m.ConfirmationCode);
                writer.WriteNumber("expiresAtUnixMs", m.ExpiresAtUnixMs);
                writer.WriteString("clientKind", m.ClientKind.ToWire());
                break;
            case PairApprove m:
                writer.WriteString("requestId", m.RequestId);
                writer.WriteString("claimId", m.ClaimId);
                break;
            case PairDeny m:
                writer.WriteString("requestId", m.RequestId);
                writer.WriteString("claimId", m.ClaimId);
                break;
            case PairCompleted m:
                writer.WriteString("requestId", m.RequestId);
                writer.WriteString("claimId", m.ClaimId);
                writer.WriteNumber("activePhoneCredentialVersion", m.ActivePhoneCredentialVersion);
                break;
            case PairFailed m:
                if (m.RequestId is { } requestId)
                {
                    writer.WriteString("requestId", requestId);
                }
                if (m.ClaimId is { } claimId)
                {
                    writer.WriteString("claimId", claimId);
                }
                writer.WriteString("reason", m.Reason.ToWire());
                break;
            default:
                throw new ArgumentOutOfRangeException(nameof(message), message.GetType().Name, "Unhandled WireMessage type");
        }
        writer.WriteEndObject();
    }
}

internal static class WireEncodingValidation
{
    public static void ValidateEnvelope(string type, string expectedType, int v)
    {
        if (type != expectedType || v != Constants.ProtocolVersion)
        {
            throw WireException.InvalidValue();
        }
    }
}

partial record PairCreate : IWireEncodingValidatable
{
    void IWireEncodingValidatable.ValidateForWireEncoding()
    {
        WireEncodingValidation.ValidateEnvelope(Type, "pair.create", V);
        if (!PairingCanonical.IsUuid(RequestId)) throw WireException.InvalidValue();
        if (PairingVersion != Constants.PairingVersion) throw WireException.InvalidValue();
    }
}

partial record PairStatusRequest : IWireEncodingValidatable
{
    void IWireEncodingValidatable.ValidateForWireEncoding()
    {
        WireEncodingValidation.ValidateEnvelope(Type, "pair.status.request", V);
        if (!PairingCanonical.IsUuid(RequestId)) throw WireException.InvalidValue();
        if (PairingVersion != Constants.PairingVersion) throw WireException.InvalidValue();
    }
}

partial record PairCreated : IWireEncodingValidatable
{
    void IWireEncodingValidatable.ValidateForWireEncoding()
    {
        WireEncodingValidation.ValidateEnvelope(Type, "pair.created", V);
        if (!PairingCanonical.IsUuid(RequestId)) throw WireException.InvalidValue();
        if (!PairingCanonical.IsCanonicalReference(Reference)) throw WireException.InvalidValue();
        if (ExpiresAtUnixMs <= 0 || ExpiresAtUnixMs > Constants.MaximumSafeInteger) throw WireException.InvalidValue();
    }
}

partial record PairStatus : IWireEncodingValidatable
{
    void IWireEncodingValidatable.ValidateForWireEncoding()
    {
        WireEncodingValidation.ValidateEnvelope(Type, "pair.status", V);
        if (!PairingCanonical.IsUuid(RequestId)) throw WireException.InvalidValue();
        if (ActivePhoneCredentialVersion < 0) throw WireException.InvalidValue();
        var consistent = EnrollmentState == PairingEnrollmentState.Legacy
            ? ActivePhoneCredentialVersion == Constants.LegacyPhoneCredentialVersion
            : ActivePhoneCredentialVersion > Constants.LegacyPhoneCredentialVersion;
        if (!consistent) throw WireException.InvalidValue();
    }
}

partial record PairCancel : IWireEncodingValidatable
{
    void IWireEncodingValidatable.ValidateForWireEncoding()
    {
        WireEncodingValidation.ValidateEnvelope(Type, "pair.cancel", V);
        if (!PairingCanonical.IsUuid(RequestId)) throw WireException.InvalidValue();
    }
}

partial record PairClaimedMac : IWireEncodingValidatable
{
    void IWireEncodingValidatable.ValidateForWireEncoding()
    {
        WireEncodingValidation.ValidateEnvelope(Type, "pair.claimed.mac", V);
        if (!PairingCanonical.IsUuid(RequestId)) throw WireException.InvalidValue();
        if (!PairingCanonical.IsUuid(ClaimId)) throw WireException.InvalidValue();
        if (!PairingCanonical.IsConfirmationCode(ConfirmationCode)) throw WireException.InvalidValue();
        if (ExpiresAtUnixMs <= 0 || ExpiresAtUnixMs > Constants.MaximumSafeInteger) throw WireException.InvalidValue();
    }
}

partial record PairApprove : IWireEncodingValidatable
{
    void IWireEncodingValidatable.ValidateForWireEncoding()
    {
        WireEncodingValidation.ValidateEnvelope(Type, "pair.approve", V);
        if (!PairingCanonical.IsUuid(RequestId)) throw WireException.InvalidValue();
        if (!PairingCanonical.IsUuid(ClaimId)) throw WireException.InvalidValue();
    }
}

partial record PairDeny : IWireEncodingValidatable
{
    void IWireEncodingValidatable.ValidateForWireEncoding()
    {
        WireEncodingValidation.ValidateEnvelope(Type, "pair.deny", V);
        if (!PairingCanonical.IsUuid(RequestId)) throw WireException.InvalidValue();
        if (!PairingCanonical.IsUuid(ClaimId)) throw WireException.InvalidValue();
    }
}

partial record PairCompleted : IWireEncodingValidatable
{
    void IWireEncodingValidatable.ValidateForWireEncoding()
    {
        WireEncodingValidation.ValidateEnvelope(Type, "pair.completed", V);
        if (!PairingCanonical.IsUuid(RequestId)) throw WireException.InvalidValue();
        if (!PairingCanonical.IsUuid(ClaimId)) throw WireException.InvalidValue();
        if (ActivePhoneCredentialVersion <= 0) throw WireException.InvalidValue();
    }
}

partial record PairFailed : IWireEncodingValidatable
{
    void IWireEncodingValidatable.ValidateForWireEncoding()
    {
        WireEncodingValidation.ValidateEnvelope(Type, "pair.failed", V);
        if (RequestId is null && ClaimId is null) throw WireException.InvalidValue();
        if (RequestId is { } requestId && !PairingCanonical.IsUuid(requestId)) throw WireException.InvalidValue();
        if (ClaimId is { } claimId && !PairingCanonical.IsUuid(claimId)) throw WireException.InvalidValue();
    }
}
