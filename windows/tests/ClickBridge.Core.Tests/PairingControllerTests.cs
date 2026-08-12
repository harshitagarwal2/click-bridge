using ClickBridge.Core.Pairing;
using ClickBridge.Core.Relay;
using ClickBridge.Core.Wire;
using Xunit;

namespace ClickBridge.Core.Tests;

public sealed class PairingControllerTests
{
    private sealed class FakeTransport : IPairingTransport
    {
        public readonly List<WireMessage> Sent = new();
        public Func<WireMessage, Exception?>? FailWhen;

        public Task SendPairingAsync(WireMessage message)
        {
            if (FailWhen?.Invoke(message) is { } failure)
            {
                throw failure;
            }
            Sent.Add(message);
            return Task.CompletedTask;
        }
    }

    private static PairingController MakeController(FakeTransport transport, out Queue<string> ids)
    {
        var idQueue = new Queue<string>(new[]
        {
            "018f63f5-6f3d-7d21-88bc-9ef561f030e1",
            "018f63f5-6f3d-7d21-88bc-9ef561f030e2",
            "018f63f5-6f3d-7d21-88bc-9ef561f030e3",
        });
        ids = idQueue;
        var controller = new PairingController(
            transport,
            new Uri("wss://example.com/ws"),
            requestId: () => idQueue.Dequeue());
        return controller;
    }

    [Fact]
    public async Task RefreshStatusMovesToReadyOnLegacyStatus()
    {
        var transport = new FakeTransport();
        var controller = MakeController(transport, out _);

        var task = controller.RefreshStatusAsync(true);
        await task;
        Assert.IsType<PairingState.CheckingStatus>(controller.State);

        var requestId = ((PairStatusRequest)transport.Sent.Single()).RequestId;
        await controller.ReceiveAsync(new PairStatus
        {
            RequestId = requestId,
            EnrollmentState = PairingEnrollmentState.Legacy,
            ActivePhoneCredentialVersion = 0,
        });

        Assert.IsType<PairingState.Ready>(controller.State);
    }

    [Fact]
    public async Task FullPairingFlowReachesCompleted()
    {
        var transport = new FakeTransport();
        var controller = MakeController(transport, out _);

        await controller.RefreshStatusAsync(true);
        var statusRequestId = ((PairStatusRequest)transport.Sent.Single()).RequestId;
        await controller.ReceiveAsync(new PairStatus
        {
            RequestId = statusRequestId,
            EnrollmentState = PairingEnrollmentState.Legacy,
            ActivePhoneCredentialVersion = 0,
        });
        Assert.IsType<PairingState.Ready>(controller.State);

        await controller.BeginPairingAsync();
        Assert.IsType<PairingState.ReplacementConfirmation>(controller.State);

        await controller.ConfirmReplacementAsync();
        var createRequestId = ((PairCreate)transport.Sent.Last()).RequestId;
        Assert.IsType<PairingState.Creating>(controller.State);

        await controller.ReceiveAsync(new PairCreated
        {
            RequestId = createRequestId,
            Reference = new string('A', 43),
            ExpiresAtUnixMs = DateTimeOffset.UtcNow.AddMinutes(5).ToUnixTimeMilliseconds(),
        });
        var invitationState = Assert.IsType<PairingState.InvitationState>(controller.State);
        Assert.Equal("example.com", invitationState.Invitation.Url.Host);

        await controller.ReceiveAsync(new PairClaimedMac
        {
            RequestId = createRequestId,
            ClaimId = "018f63f5-6f3d-7d21-88bc-9ef561f030f0",
            ConfirmationCode = "482 917",
            ExpiresAtUnixMs = DateTimeOffset.UtcNow.AddMinutes(5).ToUnixTimeMilliseconds(),
            ClientKind = PairingClientKind.Ios,
        });
        var approvalState = Assert.IsType<PairingState.ApprovalState>(controller.State);
        Assert.Equal("482 917", approvalState.Approval.ConfirmationCode);

        await controller.ApproveAsync();
        Assert.IsType<PairingState.Approving>(controller.State);

        await controller.ReceiveAsync(new PairCompleted
        {
            RequestId = createRequestId,
            ClaimId = "018f63f5-6f3d-7d21-88bc-9ef561f030f0",
            ActivePhoneCredentialVersion = 1,
        });
        var completed = Assert.IsType<PairingState.Completed>(controller.State);
        Assert.Equal(1, completed.ActivePhoneCredentialVersion);
    }

    [Fact]
    public async Task TransportFailureDuringStatusCheckMarksFailedWithRetry()
    {
        var transport = new FakeTransport { FailWhen = _ => new InvalidOperationException("offline") };
        var controller = MakeController(transport, out _);

        await controller.RefreshStatusAsync(true);

        Assert.IsType<PairingState.Failed>(controller.State);
        Assert.Equal(PairingRecoveryAction.Retry, controller.RecoveryAction);
    }

    [Fact]
    public async Task CapabilityUnavailableResetsToUnavailable()
    {
        var transport = new FakeTransport();
        var controller = MakeController(transport, out _);

        await controller.RefreshStatusAsync(false);

        Assert.IsType<PairingState.Unavailable>(controller.State);
    }
}
