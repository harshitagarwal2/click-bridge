using System.Net.WebSockets;
using System.Text;

namespace ClickBridge.Core.Relay;

public enum WebSocketTransportErrorKind { NotConnected, BinaryFrame }

public sealed class WebSocketTransportException(WebSocketTransportErrorKind kind) : Exception(kind.ToString())
{
    public WebSocketTransportErrorKind Kind { get; } = kind;
}

/// <summary>Mirrors mac/ClickBridgeMac/RelayClient.swift's WebSocketTransport protocol.</summary>
public interface IWebSocketTransport
{
    Task ConnectAsync(Uri url, CancellationToken cancellationToken);
    Task SendTextAsync(string text, CancellationToken cancellationToken);
    Task<string> ReceiveTextAsync(CancellationToken cancellationToken);
    Task CloseAsync();
}

/// <summary>
/// Mirrors URLSessionWebSocketTransport, backed by ClientWebSocket — which
/// is cross-platform in .NET, so this class (and everything above it) can
/// build and unit-test on any OS even though the app it ships in is
/// Windows-only.
/// </summary>
public sealed class ClientWebSocketTransport : IWebSocketTransport
{
    private ClientWebSocket? _socket;

    public async Task ConnectAsync(Uri url, CancellationToken cancellationToken)
    {
        var socket = new ClientWebSocket();
        await socket.ConnectAsync(url, cancellationToken).ConfigureAwait(false);
        _socket = socket;
    }

    public async Task SendTextAsync(string text, CancellationToken cancellationToken)
    {
        if (_socket is not { State: WebSocketState.Open } socket)
        {
            throw new WebSocketTransportException(WebSocketTransportErrorKind.NotConnected);
        }
        var bytes = Encoding.UTF8.GetBytes(text);
        await socket.SendAsync(bytes, WebSocketMessageType.Text, endOfMessage: true, cancellationToken)
            .ConfigureAwait(false);
    }

    public async Task<string> ReceiveTextAsync(CancellationToken cancellationToken)
    {
        if (_socket is not { } socket)
        {
            throw new WebSocketTransportException(WebSocketTransportErrorKind.NotConnected);
        }
        using var stream = new MemoryStream();
        var buffer = new byte[8192];
        WebSocketReceiveResult result;
        do
        {
            result = await socket.ReceiveAsync(buffer, cancellationToken).ConfigureAwait(false);
            if (result.MessageType == WebSocketMessageType.Close)
            {
                throw new WebSocketTransportException(WebSocketTransportErrorKind.NotConnected);
            }
            if (result.MessageType == WebSocketMessageType.Binary)
            {
                throw new WebSocketTransportException(WebSocketTransportErrorKind.BinaryFrame);
            }
            stream.Write(buffer, 0, result.Count);
        } while (!result.EndOfMessage);
        return Encoding.UTF8.GetString(stream.ToArray());
    }

    public async Task CloseAsync()
    {
        if (_socket is { State: WebSocketState.Open } socket)
        {
            try
            {
                await socket.CloseAsync(WebSocketCloseStatus.NormalClosure, null, CancellationToken.None)
                    .ConfigureAwait(false);
            }
            catch
            {
                // Best-effort, matching URLSessionWebSocketTask.cancel(with:reason:) — the
                // Swift side never surfaces a close failure either.
            }
        }
        _socket?.Dispose();
        _socket = null;
    }
}
