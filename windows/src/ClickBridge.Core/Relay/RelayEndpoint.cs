namespace ClickBridge.Core.Relay;

public enum RelayEndpointErrorKind { InvalidUrl, InvalidScheme, InvalidPath, ForbiddenComponents }

public sealed class RelayEndpointException(RelayEndpointErrorKind kind) : Exception(kind.ToString())
{
    public RelayEndpointErrorKind Kind { get; } = kind;
}

/// <summary>Mirrors mac/ClickBridgeMac/RelayClient.swift's RelayEndpoint enum.</summary>
public static class RelayEndpoint
{
    public static Uri Validated(string value, bool allowLocalSimulator)
    {
        if (!Uri.TryCreate(value, UriKind.Absolute, out var uri) || string.IsNullOrEmpty(uri.Host))
        {
            throw new RelayEndpointException(RelayEndpointErrorKind.InvalidUrl);
        }
        var scheme = uri.Scheme.ToLowerInvariant();
        var host = uri.Host.ToLowerInvariant();
        var isLocal = host is "localhost" or "127.0.0.1";
        var schemeOk = scheme == "wss" || (allowLocalSimulator && isLocal && scheme == "ws");
        if (!schemeOk)
        {
            throw new RelayEndpointException(RelayEndpointErrorKind.InvalidScheme);
        }
        if (uri.AbsolutePath != "/ws" && !System.Text.RegularExpressions.Regex.IsMatch(
                uri.AbsolutePath, "^/ws/[A-Za-z0-9_-]{22}$", System.Text.RegularExpressions.RegexOptions.CultureInvariant))
        {
            throw new RelayEndpointException(RelayEndpointErrorKind.InvalidPath);
        }
        if (!string.IsNullOrEmpty(uri.UserInfo) || !string.IsNullOrEmpty(uri.Query) || !string.IsNullOrEmpty(uri.Fragment))
        {
            throw new RelayEndpointException(RelayEndpointErrorKind.ForbiddenComponents);
        }
        return uri;
    }
}
