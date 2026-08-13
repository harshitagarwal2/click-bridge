using System.Net.Http.Json;
using System.Text.RegularExpressions;

namespace ClickBridge.Core.Relay;

public sealed record DesktopEnrollment(string RelayUrl, string Token);

public static class SessionEnrollmentService
{
    private static readonly Uri Endpoint = new("https://clickbridge-sjc.duckdns.org/v1/sessions");

    public static async Task<DesktopEnrollment> EnrollAsync(HttpClient? client = null)
    {
        using var ownedClient = client is null ? new HttpClient() : null;
        var http = client ?? ownedClient!;
        using var request = new HttpRequestMessage(HttpMethod.Post, Endpoint);
        request.Headers.Accept.ParseAdd("application/json");
        using var response = await http.SendAsync(request).ConfigureAwait(false);
        if ((int)response.StatusCode != 201) throw new InvalidOperationException("Private relay enrollment is unavailable.");
        var body = await response.Content.ReadFromJsonAsync<Response>().ConfigureAwait(false);
        if (body is null || !Regex.IsMatch(body.Token ?? "", "^[0-9a-f]{64}$", RegexOptions.CultureInvariant))
            throw new InvalidOperationException("Private relay enrollment returned invalid credentials.");
        _ = RelayEndpoint.Validated(body.RelayURL ?? "", allowLocalSimulator: false);
        return new DesktopEnrollment(body.RelayURL, body.Token);
    }

    private sealed record Response(string RelayURL, string Token);
}
