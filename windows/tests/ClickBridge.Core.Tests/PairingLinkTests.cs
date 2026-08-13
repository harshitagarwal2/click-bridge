using ClickBridge.Core.Pairing;
using Xunit;

namespace ClickBridge.Core.Tests;

public sealed class PairingLinkTests
{
    private const string Reference = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";

    [Fact]
    public void MakeProducesCanonicalHttpsInvitationWithDefaultPortOmitted()
    {
        var relay = new Uri("wss://example.com/ws");
        var link = PairingLink.Make(relay, Reference);

        Assert.Equal($"https://example.com/pair#v=1&r={Reference}", link.AbsoluteUri);
    }

    [Fact]
    public void MakeKeepsExplicitNonDefaultPort()
    {
        var relay = new Uri("wss://example.com:9443/ws");
        var link = PairingLink.Make(relay, Reference);

        Assert.Equal($"https://example.com:9443/pair#v=1&r={Reference}", link.AbsoluteUri);
    }

    [Fact]
    public void SessionScopedRelayPreservesItsSessionInPairingUrl()
    {
        var session = "AbCdEfGhIjKlMnOpQrStUv";
        var link = PairingLink.Make(new Uri($"wss://example.com/ws/{session}"), Reference);

        Assert.Equal($"https://example.com/pair/{session}#v=1&r={Reference}", link.AbsoluteUri);
        Assert.Equal($"https://example.com/pair/web/{session}#v=1&r={Reference}",
            PairingLink.MakeWebInvitation(link).AbsoluteUri);
    }

    [Fact]
    public void ValidateInvitationRoundTripsWithMake()
    {
        var relay = new Uri("wss://example.com/ws");
        var link = PairingLink.Make(relay, Reference);

        var canonical = PairingLink.ValidateInvitation(link);

        Assert.Equal(link.AbsoluteUri, canonical.AbsoluteUri);
    }

    [Fact]
    public void MakeWebInvitationSwapsPathAndKeepsFragment()
    {
        var relay = new Uri("wss://example.com/ws");
        var link = PairingLink.Make(relay, Reference);

        var web = PairingLink.MakeWebInvitation(link);

        Assert.Equal($"https://example.com/pair/web#v=1&r={Reference}", web.AbsoluteUri);
    }

    [Theory]
    [InlineData("ws://example.com/ws")]
    [InlineData("wss://example.com/other")]
    [InlineData("wss://user@example.com/ws")]
    public void MakeRejectsNonCanonicalRelayUrl(string relayUrl)
    {
        Assert.Throws<PairingLinkException>(() => PairingLink.Make(new Uri(relayUrl), Reference));
    }

    [Theory]
    [InlineData("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAB")] // 43 chars but the last char isn't a valid base64url padding-bit value for 32 bytes
    [InlineData("short")]
    public void MakeRejectsNonCanonicalReference(string reference)
    {
        Assert.Throws<PairingLinkException>(() => PairingLink.Make(new Uri("wss://example.com/ws"), reference));
    }

    [Fact]
    public void ValidateInvitationRejectsWrongScheme()
    {
        var tampered = new Uri($"http://example.com/pair#v=1&r={Reference}");
        Assert.Throws<PairingLinkException>(() => PairingLink.ValidateInvitation(tampered));
    }
}
