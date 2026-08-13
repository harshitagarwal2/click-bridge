using System.Text;
using ClickBridge.Core.Wire;

namespace ClickBridge.Core.Pairing;

public enum PairingLinkErrorKind { InvalidRelayUrl, InvalidReference }

public sealed class PairingLinkException(PairingLinkErrorKind kind) : Exception(kind.ToString())
{
    public PairingLinkErrorKind Kind { get; } = kind;
}

/// <summary>Port of mac/ClickBridgeMac/PairingController.swift's PairingLink enum.</summary>
public static class PairingLink
{
    private const int MaxLinkBytes = 512;

    public static Uri Make(Uri relayUrl, string reference)
    {
        if (relayUrl.Scheme != "wss" || (relayUrl.AbsolutePath != "/ws" && !System.Text.RegularExpressions.Regex.IsMatch(relayUrl.AbsolutePath, "^/ws/[A-Za-z0-9_-]{22}$", System.Text.RegularExpressions.RegexOptions.CultureInvariant)) ||
            !string.IsNullOrEmpty(relayUrl.UserInfo) || !string.IsNullOrEmpty(relayUrl.Query) ||
            !string.IsNullOrEmpty(relayUrl.Fragment) || string.IsNullOrEmpty(relayUrl.Host))
        {
            throw new PairingLinkException(PairingLinkErrorKind.InvalidRelayUrl);
        }
        if (!PairingCanonical.IsCanonicalReference(reference))
        {
            throw new PairingLinkException(PairingLinkErrorKind.InvalidReference);
        }

        var builder = new UriBuilder
        {
            Scheme = "https",
            Host = relayUrl.Host,
            Port = relayUrl.Port,
            Path = relayUrl.AbsolutePath == "/ws" ? "/pair" : "/pair/" + relayUrl.AbsolutePath["/ws/".Length..],
            Fragment = $"v=1&r={reference}",
        };
        var link = builder.Uri;
        if (Encoding.UTF8.GetByteCount(link.AbsoluteUri) > MaxLinkBytes)
        {
            throw new PairingLinkException(PairingLinkErrorKind.InvalidRelayUrl);
        }
        return link;
    }

    public static Uri ValidateInvitation(Uri invitation)
    {
        var fragment = StripFragmentHash(invitation.Fragment);
        if (invitation.Scheme != "https" || (invitation.AbsolutePath != "/pair" && !System.Text.RegularExpressions.Regex.IsMatch(invitation.AbsolutePath, "^/pair/[A-Za-z0-9_-]{22}$", System.Text.RegularExpressions.RegexOptions.CultureInvariant)) ||
            !string.IsNullOrEmpty(invitation.UserInfo) || !string.IsNullOrEmpty(invitation.Query) ||
            string.IsNullOrEmpty(invitation.Host) || !fragment.StartsWith("v=1&r=", StringComparison.Ordinal))
        {
            throw new PairingLinkException(PairingLinkErrorKind.InvalidRelayUrl);
        }
        var reference = fragment["v=1&r=".Length..];
        if (reference.Contains('&'))
        {
            throw new PairingLinkException(PairingLinkErrorKind.InvalidReference);
        }

        var relayBuilder = new UriBuilder
        {
            Scheme = "wss",
            Host = invitation.Host,
            Port = invitation.Port,
            Path = invitation.AbsolutePath == "/pair" ? "/ws" : "/ws/" + invitation.AbsolutePath["/pair/".Length..],
        };
        var canonical = Make(relayBuilder.Uri, reference);
        if (canonical.AbsoluteUri != invitation.AbsoluteUri)
        {
            throw new PairingLinkException(PairingLinkErrorKind.InvalidRelayUrl);
        }
        return canonical;
    }

    public static Uri MakeWebInvitation(Uri invitation)
    {
        var canonical = ValidateInvitation(invitation);
        var builder = new UriBuilder
        {
            Scheme = canonical.Scheme,
            Host = canonical.Host,
            Port = canonical.Port,
            Path = canonical.AbsolutePath == "/pair" ? "/pair/web" : "/pair/web/" + canonical.AbsolutePath["/pair/".Length..],
            Fragment = StripFragmentHash(canonical.Fragment),
        };
        var webInvitation = builder.Uri;
        if (Encoding.UTF8.GetByteCount(webInvitation.AbsoluteUri) > MaxLinkBytes)
        {
            throw new PairingLinkException(PairingLinkErrorKind.InvalidRelayUrl);
        }
        return webInvitation;
    }

    private static string StripFragmentHash(string fragment) =>
        fragment.StartsWith('#') ? fragment[1..] : fragment;
}
