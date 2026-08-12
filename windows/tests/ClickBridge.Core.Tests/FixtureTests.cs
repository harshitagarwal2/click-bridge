using System.Text.Json;
using ClickBridge.Core.Wire;
using Xunit;

namespace ClickBridge.Core.Tests;

/// <summary>
/// Validates WireCodec against the same canonical, cross-language fixtures
/// mac/ClickBridgeMacTests/WireMessageTests.swift asserts against (see
/// contracts/fixtures). Mirrors that file's two fixture-driven tests:
/// - every ordinary fixture decodes and round-trips
/// - every contracts/fixtures/invalid/*.json descriptor is rejected
/// </summary>
public sealed class FixtureTests
{
    private static readonly string FixturesRoot = Path.Combine(AppContext.BaseDirectory, "fixtures");
    private static readonly string InvalidRoot = Path.Combine(FixturesRoot, "invalid");

    /// <summary>
    /// Message types the relay/phone side may use but a mac-role client must
    /// never accept — mirrors StrictWireDecoder.swift's messageNotAllowed
    /// switch cases.
    /// </summary>
    private static readonly string[] RelayInternalOnlyFixtures =
    [
        "pair.active.json", "pair.claim.json", "pair.claimed.phone.json",
        "pair.credential.json", "pair.credential.ack.json", "pair.cancel.claim.json",
    ];

    private static readonly string[] MacRolePairingFixtures =
    [
        "pair.create.json", "pair.created.json", "pair.status.request.json", "pair.status.json",
        "pair.cancel.json", "pair.claimed.mac.json", "pair.approve.json", "pair.deny.json",
        "pair.completed.json", "pair.failed.mac-before-claim.json", "pair.failed.mac-after-claim.json",
    ];

    private static string ReadFixture(string name) => File.ReadAllText(Path.Combine(FixturesRoot, name));

    [Fact]
    public void FixturesDirectoryIsPopulated()
    {
        Assert.True(Directory.Exists(FixturesRoot), $"expected fixtures copied to {FixturesRoot}");
        Assert.NotEmpty(Directory.GetFiles(FixturesRoot, "*.json"));
        Assert.True(Directory.Exists(InvalidRoot));
        Assert.NotEmpty(Directory.GetFiles(InvalidRoot, "*.json"));
    }

    [Fact]
    public void EveryOrdinaryFixtureDecodesAndRoundTrips()
    {
        var excluded = new HashSet<string>(RelayInternalOnlyFixtures.Concat(MacRolePairingFixtures)
            .Append("pair.failed.claimant.json"));
        var files = Directory.GetFiles(FixturesRoot, "*.json")
            .Select(Path.GetFileName)
            .Where(name => name is not null && !excluded.Contains(name))
            .Cast<string>()
            .ToList();
        Assert.NotEmpty(files);

        foreach (var name in files)
        {
            var text = ReadFixture(name);
            var decoded = WireCodec.Decode(text);
            var reEncoded = WireCodec.Encode(decoded);
            var reDecoded = WireCodec.Decode(reEncoded);
            Assert.Equal(decoded, reDecoded);
        }
    }

    /// <summary>
    /// Mirrors WireMessageTests.swift's testMacPairingFixturesStrictlyDecodeForMacAndRoundTrip,
    /// which decodes these fixtures with no role filter — the list mixes
    /// messages the Mac sends (pair.create, pair.status.request, pair.cancel,
    /// pair.approve, pair.deny) with ones it receives, and role validation
    /// only constrains what a role may receive.
    /// </summary>
    [Fact]
    public void MacRolePairingFixturesDecodeAndRoundTrip()
    {
        foreach (var name in MacRolePairingFixtures)
        {
            var text = ReadFixture(name);
            var decoded = WireCodec.Decode(text);
            var reDecoded = WireCodec.Decode(WireCodec.Encode(decoded));
            Assert.Equal(decoded, reDecoded);
        }
    }

    private static readonly string[] MacIncomingPairingFixtures =
    [
        "pair.created.json", "pair.status.json", "pair.claimed.mac.json",
        "pair.completed.json", "pair.failed.mac-before-claim.json", "pair.failed.mac-after-claim.json",
    ];

    private static readonly string[] MacOutgoingOnlyPairingFixtures =
    [
        "pair.create.json", "pair.status.request.json", "pair.cancel.json",
        "pair.approve.json", "pair.deny.json",
    ];

    [Fact]
    public void RoleValidationAcceptsOnlyMessagesTheMacRoleMayReceive()
    {
        foreach (var name in MacIncomingPairingFixtures)
        {
            WireCodec.Decode(ReadFixture(name), WireRole.Mac);
        }
        foreach (var name in MacOutgoingOnlyPairingFixtures)
        {
            var ex = Assert.Throws<WireException>(() => WireCodec.Decode(ReadFixture(name), WireRole.Mac));
            Assert.Equal(WireErrorKind.MessageNotAllowed, ex.Kind);
        }
    }

    [Fact]
    public void RelayInternalOnlyMessageTypesAreAlwaysRejected()
    {
        foreach (var name in RelayInternalOnlyFixtures)
        {
            var text = ReadFixture(name);
            var ex = Assert.Throws<WireException>(() => WireCodec.Decode(text));
            Assert.Equal(WireErrorKind.MessageNotAllowed, ex.Kind);
        }
    }

    /// <summary>
    /// contracts/fixtures/pair.failed.claimant.json is claimId-only (no
    /// requestId) — the canonical shape the relay actually sends a claimant
    /// before it has a requestId (see relay/public/wire-protocol.js's
    /// validatePairFailed and PairFailed's doc comment in WireMessages.cs).
    /// This must decode successfully, unlike the Swift decoder's stricter
    /// (buggy) unconditional requestId requirement.
    /// </summary>
    [Fact]
    public void ClaimantOnlyPairFailedDecodesSuccessfully()
    {
        var text = ReadFixture("pair.failed.claimant.json");
        var decoded = Assert.IsType<PairFailed>(WireCodec.Decode(text));
        Assert.Null(decoded.RequestId);
        Assert.NotNull(decoded.ClaimId);
        Assert.Equal(PairingFailureReason.ActivationFailed, decoded.Reason);

        var reDecoded = Assert.IsType<PairFailed>(WireCodec.Decode(WireCodec.Encode(decoded)));
        Assert.Equal(decoded, reDecoded);
    }

    [Fact]
    public void EveryInvalidFixtureDescriptorIsRejected()
    {
        var files = Directory.GetFiles(InvalidRoot, "*.json");
        Assert.NotEmpty(files);

        foreach (var path in files)
        {
            using var document = JsonDocument.Parse(File.ReadAllText(path));
            var root = document.RootElement;
            var kind = root.GetProperty("kind").GetString();
            WireRole? role = root.TryGetProperty("role", out var roleElement) && roleElement.ValueKind == JsonValueKind.String
                ? WireRoleWire.TryFromWire(roleElement.GetString()!, out var parsedRole) ? parsedRole : null
                : null;

            if (kind == "binary")
            {
                // Binary-frame rejection is enforced at the transport layer
                // (ClientWebSocketTransport throws WebSocketTransportException
                // on a Binary message), not in WireCodec — nothing to decode
                // here. Covered by inspection: see WebSocketTransport.cs.
                continue;
            }

            string text = kind switch
            {
                "raw" => root.GetProperty("raw").GetString()!,
                "fixture" => ReadFixture(root.GetProperty("fixture").GetString()!),
                "oversized" => BuildOversizedText(root),
                _ => root.GetProperty("message").GetRawText(),
            };

            Assert.ThrowsAny<Exception>(() => WireCodec.Decode(text, role));
        }
    }

    private static string BuildOversizedText(JsonElement descriptor)
    {
        var baseFixture = descriptor.GetProperty("baseFixture").GetString()!;
        using var baseDocument = JsonDocument.Parse(ReadFixture(baseFixture));
        var field = descriptor.GetProperty("field").GetString()!;
        var repeat = descriptor.GetProperty("repeat").GetString()!;
        var count = descriptor.GetProperty("count").GetInt32();

        var merged = new Dictionary<string, JsonElement>();
        foreach (var property in baseDocument.RootElement.EnumerateObject())
        {
            merged[property.Name] = property.Value;
        }
        using var stream = new MemoryStream();
        using (var writer = new Utf8JsonWriter(stream))
        {
            writer.WriteStartObject();
            foreach (var (key, value) in merged)
            {
                if (key == field) continue;
                writer.WritePropertyName(key);
                value.WriteTo(writer);
            }
            writer.WriteString(field, string.Concat(Enumerable.Repeat(repeat, count)));
            writer.WriteEndObject();
        }
        return System.Text.Encoding.UTF8.GetString(stream.ToArray());
    }
}
