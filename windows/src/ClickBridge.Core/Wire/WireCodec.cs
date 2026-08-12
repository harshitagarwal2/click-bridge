using System.Text;
using System.Text.Json;

namespace ClickBridge.Core.Wire;

/// <summary>
/// Port of mac/ClickBridgeMac/StrictWireDecoder.swift + the encode half of
/// Wire in WireMessage.swift. Decode validates field-exactness and every
/// scalar's shape in the same pass that constructs the strongly-typed
/// message, so there is exactly one source of truth for "what does a valid
/// message of this type look like" (see WireMessages.cs for why this
/// differs from the Swift file's separate validate-then-Codable-decode
/// passes).
/// </summary>
public static class WireCodec
{
    public static WireMessage Decode(string text, WireRole? role = null)
    {
        if (Encoding.UTF8.GetByteCount(text) > Constants.MaxMessageBytes)
        {
            throw WireException.TooLarge();
        }

        JsonDocument document;
        try
        {
            document = JsonDocument.Parse(text);
        }
        catch (JsonException)
        {
            throw WireException.NotJsonObject();
        }
        using (document)
        {
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object)
            {
                throw WireException.NotJsonObject();
            }

            var type = JsonReading.GetString(root, "type");
            if (JsonReading.GetNumber(root, "v") != Constants.ProtocolVersion)
            {
                throw WireException.UnsupportedVersion();
            }

            WireMessage message;
            try
            {
                message = Construct(root, type);
            }
            catch (WireException)
            {
                throw;
            }
            catch (Exception)
            {
                throw WireException.DecodeFailed(type);
            }

            if (role is { } requiredRole)
            {
                ValidateAllowedForRole(message, requiredRole);
            }
            return message;
        }
    }

    private static WireMessage Construct(JsonElement m, string type)
    {
        switch (type)
        {
            case "hello":
            {
                JsonReading.RequireExactFields(m, ["type", "v", "role", "token"]);
                var roleValue = JsonReading.GetString(m, "role");
                JsonReading.RequireOneOf(roleValue, "phone", "mac");
                var token = JsonReading.GetString(m, "token");
                if (!PairingCanonical.IsToken(token))
                {
                    throw WireException.InvalidValue();
                }
                WireRoleWire.TryFromWire(roleValue, out var role);
                return new Hello { Role = role, Token = token };
            }
            case "hello.ok":
            {
                JsonReading.RequireExactFields(m, ["type", "v", "role"]);
                var roleValue = JsonReading.GetString(m, "role");
                JsonReading.RequireOneOf(roleValue, "phone", "mac");
                WireRoleWire.TryFromWire(roleValue, out var role);
                return new HelloOk { Role = role };
            }
            case "heartbeat.request":
            {
                JsonReading.RequireExactFields(m, ["type", "v", "sequence"]);
                var sequence = JsonReading.GetNonNegativeInteger(m, "sequence");
                return new HeartbeatRequest { Sequence = sequence };
            }
            case "heartbeat.ack":
            {
                JsonReading.RequireExactFields(m, ["type", "v", "sequence"]);
                var sequence = JsonReading.GetNonNegativeInteger(m, "sequence");
                return new HeartbeatAck { Sequence = sequence };
            }
            case "time.sync.request":
            {
                JsonReading.RequireExactFields(m, ["type", "v", "syncId", "phoneSendUnixMs"]);
                var syncId = JsonReading.RequireUuid(m, "syncId");
                var phoneSend = JsonReading.GetNumber(m, "phoneSendUnixMs");
                if (phoneSend <= 0)
                {
                    throw WireException.InvalidValue();
                }
                return new TimeSyncRequest { SyncId = syncId, PhoneSendUnixMs = phoneSend };
            }
            case "time.sync.response":
            {
                JsonReading.RequireExactFields(m,
                    ["type", "v", "syncId", "phoneSendUnixMs", "macReceiveUnixMs", "macSendUnixMs"]);
                var syncId = JsonReading.RequireUuid(m, "syncId");
                var phoneSend = JsonReading.GetNumber(m, "phoneSendUnixMs");
                var macReceive = JsonReading.GetNumber(m, "macReceiveUnixMs");
                var macSend = JsonReading.GetNumber(m, "macSendUnixMs");
                if (phoneSend <= 0 || macReceive <= 0 || macSend <= 0 || macSend < macReceive)
                {
                    throw WireException.InvalidValue();
                }
                return new TimeSyncResponse
                {
                    SyncId = syncId,
                    PhoneSendUnixMs = phoneSend,
                    MacReceiveUnixMs = macReceive,
                    MacSendUnixMs = macSend,
                };
            }
            case "diagnostics.request":
            {
                JsonReading.RequireExactFields(m, ["type", "v", "requestId"]);
                var requestId = JsonReading.RequireUuid(m, "requestId");
                return new DiagnosticsRequest { RequestId = requestId };
            }
            case "diagnostics.counters":
            {
                JsonReading.RequireExactFields(m,
                    ["type", "v", "requestId", "mouseDownPostCount", "mouseUpPostCount"]);
                var requestId = JsonReading.RequireUuid(m, "requestId");
                var down = JsonReading.GetNonNegativeInteger(m, "mouseDownPostCount");
                var up = JsonReading.GetNonNegativeInteger(m, "mouseUpPostCount");
                return new DiagnosticsCounters { RequestId = requestId, MouseDownPostCount = down, MouseUpPostCount = up };
            }
            case "mac.state":
            {
                JsonReading.RequireExactFields(m, ["type", "v", "remoteEnabled", "permission"]);
                var remoteEnabled = JsonReading.GetBool(m, "remoteEnabled");
                var permission = JsonReading.RequirePermission(m);
                return new MacState { RemoteEnabled = remoteEnabled, Permission = permission };
            }
            case "state":
            {
                JsonReading.RequireExactFields(m, ["type", "v", "macOnline", "remoteEnabled", "permission"]);
                var macOnline = JsonReading.GetBool(m, "macOnline");
                var remoteEnabled = JsonReading.GetBool(m, "remoteEnabled");
                var permission = JsonReading.RequirePermission(m);
                return new PhoneState { MacOnline = macOnline, RemoteEnabled = remoteEnabled, Permission = permission };
            }
            case "action.request":
            {
                JsonReading.RequireExactFields(m,
                    ["type", "v", "actionId", "action", "issuedAtUnixMs", "expiresAtUnixMs"]);
                var actionId = JsonReading.RequireUuid(m, "actionId");
                var action = JsonReading.GetString(m, "action");
                JsonReading.RequireOneOf(action, "click");
                var issued = JsonReading.GetNumber(m, "issuedAtUnixMs");
                var expires = JsonReading.GetNumber(m, "expiresAtUnixMs");
                if (issued <= 0 || expires - issued != Constants.ActionLifetimeMs)
                {
                    throw WireException.InvalidValue();
                }
                return new ActionRequest
                {
                    ActionId = actionId,
                    Action = action,
                    IssuedAtUnixMs = issued,
                    ExpiresAtUnixMs = expires,
                };
            }
            case "relay.ack":
            {
                JsonReading.RequireExactFields(m,
                    ["type", "v", "actionId", "status", "reason", "relayProcessingUs"]);
                var actionId = JsonReading.RequireUuid(m, "actionId");
                var statusValue = JsonReading.GetString(m, "status");
                var reasonValue = JsonReading.GetString(m, "reason");
                JsonReading.RequireOneOf(statusValue, "forwarded", "mac_offline", "rejected");
                JsonReading.RequireOneOf(reasonValue, "ok", "mac_offline", "expired", "invalid_request");
                var processingUs = JsonReading.GetNumber(m, "relayProcessingUs");
                if (processingUs < 0)
                {
                    throw WireException.InvalidValue();
                }
                var valid = (statusValue == "forwarded" && reasonValue == "ok")
                    || (statusValue == "mac_offline" && reasonValue == "mac_offline")
                    || (statusValue == "rejected" && (reasonValue == "expired" || reasonValue == "invalid_request"));
                if (!valid)
                {
                    throw WireException.InvalidValue();
                }
                RelayAckStatusWire.TryFromWire(statusValue, out var status);
                RelayAckReasonWire.TryFromWire(reasonValue, out var reason);
                return new RelayAck { ActionId = actionId, Status = status, Reason = reason, RelayProcessingUs = processingUs };
            }
            case "action.result":
            {
                var statusValue = JsonReading.GetString(m, "status");
                JsonReading.RequireOneOf(statusValue, "posted", "rejected");
                List<string> fields = ["type", "v", "actionId", "status", "reason", "acceptedVia", "macProcessingUs"];
                if (statusValue == "posted")
                {
                    fields.Add("mouseDownPostedUnixMs");
                }
                JsonReading.RequireExactFields(m, fields);
                var actionId = JsonReading.RequireUuid(m, "actionId");
                var reasonValue = JsonReading.GetString(m, "reason");
                JsonReading.RequireOneOf(reasonValue, ResultReasonAllWireValues);
                var acceptedViaValue = JsonReading.GetString(m, "acceptedVia");
                JsonReading.RequireOneOf(acceptedViaValue, "oci", "tailscale");
                var macProcessingUs = JsonReading.GetNumber(m, "macProcessingUs");
                if (macProcessingUs < 0)
                {
                    throw WireException.InvalidValue();
                }
                double? mouseDownPostedUnixMs = null;
                if (statusValue == "posted")
                {
                    if (reasonValue != "ok")
                    {
                        throw WireException.InvalidValue();
                    }
                    var posted = JsonReading.GetNumber(m, "mouseDownPostedUnixMs");
                    if (posted <= 0)
                    {
                        throw WireException.InvalidValue();
                    }
                    mouseDownPostedUnixMs = posted;
                }
                else if (reasonValue == "ok")
                {
                    throw WireException.InvalidValue();
                }
                ResultStatusWire.TryFromWire(statusValue, out var status);
                ResultReasonWire.TryFromWire(reasonValue, out var reason);
                ActionIngressWire.TryFromWire(acceptedViaValue, out var acceptedVia);
                return new ActionResult
                {
                    ActionId = actionId,
                    Status = status,
                    Reason = reason,
                    AcceptedVia = acceptedVia,
                    MacProcessingUs = macProcessingUs,
                    MouseDownPostedUnixMs = mouseDownPostedUnixMs,
                };
            }
            case "pair.create":
            {
                JsonReading.RequireExactFields(m, ["type", "v", "requestId", "pairingVersion"]);
                var requestId = JsonReading.RequireUuid(m, "requestId");
                JsonReading.RequirePairingVersion(m);
                return new PairCreate { RequestId = requestId };
            }
            case "pair.status.request":
            {
                JsonReading.RequireExactFields(m, ["type", "v", "requestId", "pairingVersion"]);
                var requestId = JsonReading.RequireUuid(m, "requestId");
                JsonReading.RequirePairingVersion(m);
                return new PairStatusRequest { RequestId = requestId };
            }
            case "pair.created":
            {
                JsonReading.RequireExactFields(m, ["type", "v", "requestId", "reference", "expiresAtUnixMs"]);
                var requestId = JsonReading.RequireUuid(m, "requestId");
                var reference = JsonReading.GetString(m, "reference");
                if (!PairingCanonical.IsCanonicalReference(reference))
                {
                    throw WireException.InvalidValue();
                }
                JsonReading.RequirePositiveInteger(m, "expiresAtUnixMs");
                var expiresAt = JsonReading.GetSafeNonNegativeInteger(m, "expiresAtUnixMs");
                return new PairCreated { RequestId = requestId, Reference = reference, ExpiresAtUnixMs = expiresAt };
            }
            case "pair.status":
            {
                JsonReading.RequireExactFields(m,
                    ["type", "v", "requestId", "enrollmentState", "activePhoneCredentialVersion"]);
                var requestId = JsonReading.RequireUuid(m, "requestId");
                var enrollmentValue = JsonReading.GetString(m, "enrollmentState");
                JsonReading.RequireOneOf(enrollmentValue, "legacy", "paired");
                var credentialVersion = JsonReading.GetSafeNonNegativeInteger(m, "activePhoneCredentialVersion");
                var consistent = enrollmentValue == "legacy"
                    ? credentialVersion == Constants.LegacyPhoneCredentialVersion
                    : credentialVersion > Constants.LegacyPhoneCredentialVersion;
                if (!consistent)
                {
                    throw WireException.InvalidValue();
                }
                PairingEnrollmentStateWire.TryFromWire(enrollmentValue, out var enrollmentState);
                return new PairStatus
                {
                    RequestId = requestId,
                    EnrollmentState = enrollmentState,
                    ActivePhoneCredentialVersion = (int)credentialVersion,
                };
            }
            case "pair.cancel":
            {
                JsonReading.RequireExactFields(m, ["type", "v", "requestId"]);
                var requestId = JsonReading.RequireUuid(m, "requestId");
                return new PairCancel { RequestId = requestId };
            }
            case "pair.claimed.mac":
            {
                JsonReading.RequireExactFields(m,
                    ["type", "v", "requestId", "claimId", "confirmationCode", "expiresAtUnixMs", "clientKind"]);
                var requestId = JsonReading.RequireUuid(m, "requestId");
                var claimId = JsonReading.RequireUuid(m, "claimId");
                var code = JsonReading.GetString(m, "confirmationCode");
                if (!PairingCanonical.IsConfirmationCode(code))
                {
                    throw WireException.InvalidValue();
                }
                JsonReading.RequirePositiveInteger(m, "expiresAtUnixMs");
                var expiresAt = JsonReading.GetSafeNonNegativeInteger(m, "expiresAtUnixMs");
                var clientKindValue = JsonReading.GetString(m, "clientKind");
                JsonReading.RequireOneOf(clientKindValue, "ios", "pwa");
                PairingClientKindWire.TryFromWire(clientKindValue, out var clientKind);
                return new PairClaimedMac
                {
                    RequestId = requestId,
                    ClaimId = claimId,
                    ConfirmationCode = code,
                    ExpiresAtUnixMs = expiresAt,
                    ClientKind = clientKind,
                };
            }
            case "pair.approve":
            {
                JsonReading.RequireExactFields(m, ["type", "v", "requestId", "claimId"]);
                var requestId = JsonReading.RequireUuid(m, "requestId");
                var claimId = JsonReading.RequireUuid(m, "claimId");
                return new PairApprove { RequestId = requestId, ClaimId = claimId };
            }
            case "pair.deny":
            {
                JsonReading.RequireExactFields(m, ["type", "v", "requestId", "claimId"]);
                var requestId = JsonReading.RequireUuid(m, "requestId");
                var claimId = JsonReading.RequireUuid(m, "claimId");
                return new PairDeny { RequestId = requestId, ClaimId = claimId };
            }
            case "pair.completed":
            {
                JsonReading.RequireExactFields(m,
                    ["type", "v", "requestId", "claimId", "activePhoneCredentialVersion"]);
                var requestId = JsonReading.RequireUuid(m, "requestId");
                var claimId = JsonReading.RequireUuid(m, "claimId");
                var credentialVersion = JsonReading.GetSafeNonNegativeInteger(m, "activePhoneCredentialVersion");
                if (credentialVersion <= 0)
                {
                    throw WireException.InvalidValue();
                }
                return new PairCompleted
                {
                    RequestId = requestId,
                    ClaimId = claimId,
                    ActivePhoneCredentialVersion = (int)credentialVersion,
                };
            }
            case "pair.failed":
            {
                var hasRequest = m.TryGetProperty("requestId", out _);
                var hasClaim = m.TryGetProperty("claimId", out _);
                if (!hasRequest && !hasClaim)
                {
                    throw WireException.InvalidValue();
                }
                List<string> fields = ["type", "v", "reason"];
                if (hasRequest) fields.Add("requestId");
                if (hasClaim) fields.Add("claimId");
                JsonReading.RequireExactFields(m, fields);
                var requestId = hasRequest ? JsonReading.RequireUuid(m, "requestId") : null;
                var claimId = hasClaim ? JsonReading.RequireUuid(m, "claimId") : null;
                var reasonValue = JsonReading.GetString(m, "reason");
                JsonReading.RequireOneOf(reasonValue, PairingFailureReasonAllWireValues);
                PairingFailureReasonWire.TryFromWire(reasonValue, out var reason);
                return new PairFailed { RequestId = requestId, ClaimId = claimId, Reason = reason };
            }
            case "pair.claim":
            case "pair.claimed.phone":
            case "pair.credential":
            case "pair.credential.ack":
            case "pair.active":
            case "pair.cancel.claim":
                throw WireException.MessageNotAllowed();
            default:
                throw WireException.UnknownType(type);
        }
    }

    private static void ValidateAllowedForRole(WireMessage message, WireRole role)
    {
        var allowed = (role, message) switch
        {
            (WireRole.Mac, HelloOk hello) => hello.Role == WireRole.Mac,
            (WireRole.Mac, HeartbeatAck) => true,
            (WireRole.Mac, ActionRequest) => true,
            (WireRole.Mac, TimeSyncRequest) => true,
            (WireRole.Mac, DiagnosticsRequest) => true,
            (WireRole.Mac, PairCreated) => true,
            (WireRole.Mac, PairStatus) => true,
            (WireRole.Mac, PairClaimedMac) => true,
            (WireRole.Mac, PairCompleted) => true,
            (WireRole.Mac, PairFailed) => true,
            (WireRole.Phone, HelloOk hello) => hello.Role == WireRole.Phone,
            (WireRole.Phone, HeartbeatAck) => true,
            (WireRole.Phone, PhoneState) => true,
            (WireRole.Phone, RelayAck) => true,
            (WireRole.Phone, ActionResult) => true,
            (WireRole.Phone, TimeSyncResponse) => true,
            (WireRole.Phone, DiagnosticsCounters) => true,
            _ => false,
        };
        if (!allowed)
        {
            throw WireException.MessageNotAllowed();
        }
    }

    private static readonly string[] ResultReasonAllWireValues =
    [
        "ok", "permission_required", "remote_disabled", "expired", "capacity_exceeded",
        "id_conflict", "event_creation_failed", "invalid_request",
    ];

    private static readonly string[] PairingFailureReasonAllWireValues =
    [
        "expired", "used", "cancelled", "denied", "mac_offline", "storage_failed",
        "activation_failed", "invalid_request", "replaced", "unsupported",
    ];

    public static string Encode(WireMessage message)
    {
        if (message is IWireEncodingValidatable validatable)
        {
            validatable.ValidateForWireEncoding();
        }

        var options = new JsonWriterOptions { Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping };
        using var stream = new MemoryStream();
        using (var writer = new Utf8JsonWriter(stream, options))
        {
            WireEncoding.Write(writer, message);
        }
        if (stream.Length > Constants.MaxMessageBytes)
        {
            throw WireException.TooLarge();
        }
        return Encoding.UTF8.GetString(stream.ToArray());
    }
}
