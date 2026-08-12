using System.Threading.Channels;
using ClickBridge.Core.Actions;
using ClickBridge.Core.Relay;
using ClickBridge.Core.Wire;
using Xunit;

namespace ClickBridge.Core.Tests;

public sealed class RelayClientTests
{
    private sealed class FakeTransport : IWebSocketTransport
    {
        private readonly Channel<string> _incoming = Channel.CreateUnbounded<string>();
        public readonly List<string> Sent = new();
        public bool Closed;

        public Task ConnectAsync(Uri url, CancellationToken cancellationToken) => Task.CompletedTask;

        public Task SendTextAsync(string text, CancellationToken cancellationToken)
        {
            lock (Sent) { Sent.Add(text); }
            return Task.CompletedTask;
        }

        public async Task<string> ReceiveTextAsync(CancellationToken cancellationToken) =>
            await _incoming.Reader.ReadAsync(cancellationToken).ConfigureAwait(false);

        public Task CloseAsync()
        {
            Closed = true;
            return Task.CompletedTask;
        }

        public void Push(string text) => _incoming.Writer.TryWrite(text);

        public List<string> SentSnapshot()
        {
            lock (Sent) { return new List<string>(Sent); }
        }
    }

    private sealed class FakeActionSink : IActionRequestSink, IDiagnosticCounterReading
    {
        public Task<ActionAuthorizationLease> ActivateAuthorizationLeaseAsync(ActionAuthorizationGeneration generation) =>
            Task.FromResult(new ActionAuthorizationLease(generation));

        public Task RevokeAuthorizationLeaseAsync(ActionAuthorizationLease lease) => Task.CompletedTask;

        public Task<ActionResult> ReceiveAsync(ActionRequest request, ActionIngress ingress, ActionAuthorizationLease authorization) =>
            Task.FromResult(new ActionResult
            {
                ActionId = request.ActionId,
                Status = ResultStatus.Posted,
                Reason = ResultReason.Ok,
                AcceptedVia = ingress,
                MacProcessingUs = 1,
                MouseDownPostedUnixMs = 42,
            });

        public Task<InputPostCounts> DiagnosticPostCountsAsync() => Task.FromResult(InputPostCounts.Zero);
    }

    private static async Task WaitUntilAsync(Func<bool> predicate, int timeoutMs = 2000)
    {
        var deadline = DateTime.UtcNow.AddMilliseconds(timeoutMs);
        while (!predicate())
        {
            if (DateTime.UtcNow > deadline)
            {
                throw new TimeoutException("condition not met within timeout");
            }
            await Task.Delay(10);
        }
    }

    private static string Token() => new('a', 64);

    [Fact]
    public async Task HelloHandshakeReachesConnectedAndAdvertisesState()
    {
        var transport = new FakeTransport();
        var sink = new FakeActionSink();
        var client = new RelayClient(sink, sink, makeTransport: () => transport);

        RelayClient.Status? connectedStatus = null;
        client.SetStatusHandler(evt =>
        {
            if (evt.Status == RelayClient.Status.Connected) connectedStatus = evt.Status;
        });

        var configured = await client.ConfigureAsync("wss://example.com/ws", Token(), allowLocalSimulator: false);
        Assert.True(configured);
        client.Start();

        await WaitUntilAsync(() => transport.SentSnapshot().Count > 0);
        var hello = Assert.IsType<Hello>(WireCodec.Decode(transport.SentSnapshot()[0]));
        Assert.Equal(WireRole.Mac, hello.Role);
        Assert.Equal(Token(), hello.Token);

        transport.Push(WireCodec.Encode(new HelloOk { Role = WireRole.Mac }));

        await WaitUntilAsync(() => connectedStatus == RelayClient.Status.Connected);
        Assert.Equal(RelayClient.Status.Connected, client.CurrentStatus());

        // First post-hello send must be the advertised mac.state snapshot.
        await WaitUntilAsync(() => transport.SentSnapshot().Count > 1);
        Assert.IsType<MacState>(WireCodec.Decode(transport.SentSnapshot()[1]));
    }

    [Fact]
    public async Task ActionRequestIsForwardedToSinkAndResultIsSentBack()
    {
        var transport = new FakeTransport();
        var sink = new FakeActionSink();
        var client = new RelayClient(sink, sink, makeTransport: () => transport);
        ActionResult? observedResult = null;
        client.SetResultHandler(result => observedResult = result);

        await client.ConfigureAsync("wss://example.com/ws", Token(), allowLocalSimulator: false);
        client.Start();
        await WaitUntilAsync(() => transport.SentSnapshot().Count > 0);
        transport.Push(WireCodec.Encode(new HelloOk { Role = WireRole.Mac }));
        await WaitUntilAsync(() => client.CurrentStatus() == RelayClient.Status.Connected);

        var sentBefore = transport.SentSnapshot().Count;
        var request = new ActionRequest
        {
            ActionId = "018f63f5-6f3d-7d21-88bc-9ef561f030e1",
            Action = "click",
            IssuedAtUnixMs = 1_000,
            ExpiresAtUnixMs = 3_000,
        };
        transport.Push(WireCodec.Encode(request));

        await WaitUntilAsync(() => observedResult is not null);
        Assert.Equal(request.ActionId, observedResult!.ActionId);
        Assert.Equal(ResultStatus.Posted, observedResult.Status);

        await WaitUntilAsync(() => transport.SentSnapshot().Count > sentBefore);
        var sentResult = Assert.IsType<ActionResult>(WireCodec.Decode(transport.SentSnapshot().Last()));
        Assert.Equal(request.ActionId, sentResult.ActionId);
    }

    [Fact]
    public async Task TransportFailureDropsConnectionBackToDisconnected()
    {
        var transport = new FakeTransport();
        var sink = new FakeActionSink();
        // Instant "sleep" so reconnect backoff doesn't slow the test down.
        var client = new RelayClient(sink, sink, makeTransport: () => transport,
            sleep: (_, _) => Task.CompletedTask);

        var statuses = new List<RelayClient.Status>();
        client.SetStatusHandler(evt => { lock (statuses) statuses.Add(evt.Status); });

        await client.ConfigureAsync("wss://example.com/ws", Token(), allowLocalSimulator: false);
        client.Start();
        await WaitUntilAsync(() => transport.SentSnapshot().Count > 0);
        transport.Push(WireCodec.Encode(new HelloOk { Role = WireRole.Mac }));
        await WaitUntilAsync(() => client.CurrentStatus() == RelayClient.Status.Connected);

        // A garbled server message fails to decode, which drops the connection.
        transport.Push("{not-json");

        await WaitUntilAsync(() =>
        {
            lock (statuses) return statuses.Contains(RelayClient.Status.Disconnected);
        });
    }
}
