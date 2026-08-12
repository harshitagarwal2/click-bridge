namespace ClickBridge.Core.Wire;

/// <summary>
/// Base for every message in mac/ClickBridgeMac/WireMessage.swift's WireMessage
/// enum. There is no auto-generated JSON mapping on purpose: WireCodec both
/// validates and constructs these directly from a parsed JsonElement, so the
/// validation rules and the field list can never drift apart the way a
/// separate "raw validate, then Codable-decode" pass could.
/// </summary>
public abstract record WireMessage
{
    public abstract string Type { get; }
    public int V { get; init; } = Constants.ProtocolVersion;
}

public sealed record Hello : WireMessage
{
    public override string Type => "hello";
    public required WireRole Role { get; init; }
    public required string Token { get; init; }
}

public sealed record HelloOk : WireMessage
{
    public override string Type => "hello.ok";
    public required WireRole Role { get; init; }
}

public sealed record HeartbeatRequest : WireMessage
{
    public override string Type => "heartbeat.request";
    public required int Sequence { get; init; }
}

public sealed record HeartbeatAck : WireMessage
{
    public override string Type => "heartbeat.ack";
    public required int Sequence { get; init; }
}

public sealed record TimeSyncRequest : WireMessage
{
    public override string Type => "time.sync.request";
    public required string SyncId { get; init; }
    public required double PhoneSendUnixMs { get; init; }
}

public sealed record TimeSyncResponse : WireMessage
{
    public override string Type => "time.sync.response";
    public required string SyncId { get; init; }
    public required double PhoneSendUnixMs { get; init; }
    public required double MacReceiveUnixMs { get; init; }
    public required double MacSendUnixMs { get; init; }
}

public sealed record DiagnosticsRequest : WireMessage
{
    public override string Type => "diagnostics.request";
    public required string RequestId { get; init; }
}

public sealed record DiagnosticsCounters : WireMessage
{
    public override string Type => "diagnostics.counters";
    public required string RequestId { get; init; }
    public required int MouseDownPostCount { get; init; }
    public required int MouseUpPostCount { get; init; }
}

public sealed record MacState : WireMessage
{
    public override string Type => "mac.state";
    public required bool RemoteEnabled { get; init; }
    public required PermissionState Permission { get; init; }
}

/// <summary>Wire type "state" — mirrors Swift's PhoneState struct.</summary>
public sealed record PhoneState : WireMessage
{
    public override string Type => "state";
    public required bool MacOnline { get; init; }
    public required bool RemoteEnabled { get; init; }
    public required PermissionState Permission { get; init; }
}

public sealed record ActionRequest : WireMessage
{
    public override string Type => "action.request";
    public required string ActionId { get; init; }
    public required string Action { get; init; }
    public required double IssuedAtUnixMs { get; init; }
    public required double ExpiresAtUnixMs { get; init; }

    public string Fingerprint => $"{Action}|{IssuedAtUnixMs}|{ExpiresAtUnixMs}";
}

public sealed record RelayAck : WireMessage
{
    public override string Type => "relay.ack";
    public required string ActionId { get; init; }
    public required RelayAckStatus Status { get; init; }
    public required RelayAckReason Reason { get; init; }
    public required double RelayProcessingUs { get; init; }
}

public sealed record ActionResult : WireMessage
{
    public override string Type => "action.result";
    public required string ActionId { get; init; }
    public required ResultStatus Status { get; init; }
    public required ResultReason Reason { get; init; }
    public required ActionIngress AcceptedVia { get; init; }
    public required double MacProcessingUs { get; init; }
    public double? MouseDownPostedUnixMs { get; init; }
}

public sealed partial record PairCreate : WireMessage
{
    public override string Type => "pair.create";
    public required string RequestId { get; init; }
    public int PairingVersion { get; init; } = Constants.PairingVersion;
}

public sealed partial record PairStatusRequest : WireMessage
{
    public override string Type => "pair.status.request";
    public required string RequestId { get; init; }
    public int PairingVersion { get; init; } = Constants.PairingVersion;
}

public sealed partial record PairCreated : WireMessage
{
    public override string Type => "pair.created";
    public required string RequestId { get; init; }
    public required string Reference { get; init; }
    public required long ExpiresAtUnixMs { get; init; }
}

public sealed partial record PairStatus : WireMessage
{
    public override string Type => "pair.status";
    public required string RequestId { get; init; }
    public required PairingEnrollmentState EnrollmentState { get; init; }
    public required int ActivePhoneCredentialVersion { get; init; }

    public bool RequiresReplacementConfirmation => EnrollmentState is PairingEnrollmentState.Legacy or PairingEnrollmentState.Paired;
}

public sealed partial record PairCancel : WireMessage
{
    public override string Type => "pair.cancel";
    public required string RequestId { get; init; }
}

public sealed partial record PairClaimedMac : WireMessage
{
    public override string Type => "pair.claimed.mac";
    public required string RequestId { get; init; }
    public required string ClaimId { get; init; }
    public required string ConfirmationCode { get; init; }
    public required long ExpiresAtUnixMs { get; init; }
    public required PairingClientKind ClientKind { get; init; }
}

public sealed partial record PairApprove : WireMessage
{
    public override string Type => "pair.approve";
    public required string RequestId { get; init; }
    public required string ClaimId { get; init; }
}

public sealed partial record PairDeny : WireMessage
{
    public override string Type => "pair.deny";
    public required string RequestId { get; init; }
    public required string ClaimId { get; init; }
}

public sealed partial record PairCompleted : WireMessage
{
    public override string Type => "pair.completed";
    public required string RequestId { get; init; }
    public required string ClaimId { get; init; }
    public required int ActivePhoneCredentialVersion { get; init; }
}

/// <summary>
/// requestId/claimId are each independently optional but at least one must
/// be present — matches relay/public/wire-protocol.js's validatePairFailed
/// and contracts/fixtures/pair.failed.claimant.json (claimId-only, no
/// requestId, sent to a claimant before it has a requestId). Note: as
/// observed while porting, mac/ClickBridgeMac/StrictWireDecoder.swift
/// currently requires requestId unconditionally, which appears to reject
/// that canonical fixture — flagged separately for a fix there.
/// </summary>
public sealed partial record PairFailed : WireMessage
{
    public override string Type => "pair.failed";
    public string? RequestId { get; init; }
    public string? ClaimId { get; init; }
    public required PairingFailureReason Reason { get; init; }
}
