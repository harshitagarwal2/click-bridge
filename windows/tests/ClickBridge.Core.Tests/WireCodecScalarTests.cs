using System.Text;
using ClickBridge.Core.Wire;
using Xunit;

namespace ClickBridge.Core.Tests;

/// <summary>Hand-written edge cases mirroring the non-fixture-driven tests in WireMessageTests.swift.</summary>
public sealed class WireCodecScalarTests
{
    [Fact]
    public void UnknownKeyIsRejected()
    {
        var text = """{"type":"heartbeat.ack","v":1,"sequence":7,"extra":true}""";
        var ex = Assert.Throws<WireException>(() => WireCodec.Decode(text));
        Assert.Equal(WireErrorKind.UnknownKeys, ex.Kind);
    }

    [Fact]
    public void UnknownRoleInHelloIsRejected()
    {
        var text = """{"type":"hello","v":1,"role":"server","token":"abc"}""";
        Assert.Throws<WireException>(() => WireCodec.Decode(text));
    }

    [Fact]
    public void OversizedTextIsRejectedByUtf8ByteCount()
    {
        var text = new string('é', 2_049);
        var ex = Assert.Throws<WireException>(() => WireCodec.Decode(text));
        Assert.Equal(WireErrorKind.TooLarge, ex.Kind);
    }

    [Fact]
    public void Exact4096ByteFramePassesAnd4097Fails()
    {
        const string baseText = """{"type":"heartbeat.ack","v":1,"sequence":7}""";
        var padded = baseText + new string(' ', Constants.MaxMessageBytes - Encoding.UTF8.GetByteCount(baseText));
        Assert.Equal(4096, Encoding.UTF8.GetByteCount(padded));
        WireCodec.Decode(padded, WireRole.Phone);

        var ex = Assert.Throws<WireException>(() => WireCodec.Decode(padded + " ", WireRole.Phone));
        Assert.Equal(WireErrorKind.TooLarge, ex.Kind);
    }

    [Fact]
    public void PairingSafeIntegerOverflowFailsClosed()
    {
        var text = """{"type":"pair.status","v":1,"requestId":"018f63f5-6f3d-7d21-88bc-9ef561f030e0","enrollmentState":"paired","activePhoneCredentialVersion":9223372036854775808}""";
        var ex = Assert.Throws<WireException>(() => WireCodec.Decode(text, WireRole.Mac));
        Assert.Equal(WireErrorKind.InvalidValue, ex.Kind);
    }

    [Fact]
    public void CredentialRotationRejectsLegacyVersionZero()
    {
        var text = """{"type":"pair.completed","v":1,"requestId":"018f63f5-6f3d-7d21-88bc-9ef561f030e1","claimId":"018f63f5-6f3d-7d21-88bc-9ef561f030e2","activePhoneCredentialVersion":0}""";
        var ex = Assert.Throws<WireException>(() => WireCodec.Decode(text, WireRole.Mac));
        Assert.Equal(WireErrorKind.InvalidValue, ex.Kind);
    }

    [Theory]
    [InlineData("""{"type":"hello","v":1,"role":"mac","token":"ABC"}""")]
    [InlineData("""{"type":"heartbeat.ack","v":1,"sequence":-1}""")]
    [InlineData("""{"type":"heartbeat.ack","v":1,"sequence":1.5}""")]
    [InlineData("""{"type":"time.sync.request","v":1,"syncId":"not-a-uuid","phoneSendUnixMs":1}""")]
    [InlineData("""{"type":"time.sync.request","v":1,"syncId":"018f63f5-6f3d-7d21-88bc-9ef561f030aa","phoneSendUnixMs":0}""")]
    [InlineData("""{"type":"time.sync.response","v":1,"syncId":"018f63f5-6f3d-7d21-88bc-9ef561f030aa","phoneSendUnixMs":1,"macReceiveUnixMs":3,"macSendUnixMs":2}""")]
    [InlineData("""{"type":"diagnostics.counters","v":1,"requestId":"018f63f5-6f3d-7d21-88bc-9ef561f030ab","mouseDownPostCount":-1,"mouseUpPostCount":0}""")]
    [InlineData("""{"type":"action.request","v":1,"actionId":"bad","action":"click","issuedAtUnixMs":1,"expiresAtUnixMs":2001}""")]
    [InlineData("""{"type":"action.request","v":1,"actionId":"018f63f5-6f3d-7d21-88bc-9ef561f030de","action":"move","issuedAtUnixMs":1,"expiresAtUnixMs":2001}""")]
    [InlineData("""{"type":"relay.ack","v":1,"actionId":"018f63f5-6f3d-7d21-88bc-9ef561f030de","status":"forwarded","reason":"ok","relayProcessingUs":-1}""")]
    [InlineData("""{"type":"action.result","v":1,"actionId":"018f63f5-6f3d-7d21-88bc-9ef561f030de","status":"rejected","reason":"expired","acceptedVia":"oci","macProcessingUs":1,"mouseDownPostedUnixMs":null}""")]
    [InlineData("""{"type":"action.result","v":1,"actionId":"018f63f5-6f3d-7d21-88bc-9ef561f030de","status":"posted","reason":"ok","acceptedVia":"oci","macProcessingUs":1,"mouseDownPostedUnixMs":0}""")]
    public void ScalarAndConditionalParityWithBrowserParser(string text)
    {
        Assert.ThrowsAny<Exception>(() => WireCodec.Decode(text));
    }

    [Fact]
    public void ActionFingerprintExcludesOnlyActionId()
    {
        var first = new ActionRequest { ActionId = "a", Action = "click", IssuedAtUnixMs = 10, ExpiresAtUnixMs = 2_010 };
        var duplicate = new ActionRequest { ActionId = "b", Action = "click", IssuedAtUnixMs = 10, ExpiresAtUnixMs = 2_010 };
        var conflict = new ActionRequest { ActionId = "a", Action = "click", IssuedAtUnixMs = 11, ExpiresAtUnixMs = 2_011 };
        Assert.Equal(first.Fingerprint, duplicate.Fingerprint);
        Assert.NotEqual(first.Fingerprint, conflict.Fingerprint);
    }
}
