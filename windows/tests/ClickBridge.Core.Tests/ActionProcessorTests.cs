using ClickBridge.Core.Actions;
using ClickBridge.Core.Wire;
using Xunit;

namespace ClickBridge.Core.Tests;

public sealed class ActionProcessorTests
{
    private sealed class FakePoster : IInputPosting
    {
        public int Calls;
        public bool FailNext;
        private double _clock;

        public InputPostOutcome PostLeftClickAtCurrentCursor()
        {
            Calls++;
            if (FailNext)
            {
                FailNext = false;
                return new InputPostOutcome.CreationFailed();
            }
            _clock += 1;
            return new InputPostOutcome.Posted(_clock);
        }

        public InputPostCounts DiagnosticPostCounts() => new(Calls * 3, Calls * 3);
    }

    private sealed class FakePermission : IPostEventPermissionChecking
    {
        public bool Granted = true;
        public bool IsGranted() => Granted;
    }

    private static ActionRequest MakeRequest(string actionId, double issuedAt) => new()
    {
        ActionId = actionId,
        Action = "click",
        IssuedAtUnixMs = issuedAt,
        ExpiresAtUnixMs = issuedAt + Constants.ActionLifetimeMs,
    };

    [Fact]
    public async Task PostsWhenRemoteEnabledAndPermissionGranted()
    {
        var poster = new FakePoster();
        var processor = new ActionProcessor(poster, new FakePermission(), () => 1_000);
        processor.SetRemoteEnabled(true);

        var result = await processor.ReceiveTrustedAsync(MakeRequest("018f63f5-6f3d-7d21-88bc-9ef561f030e1", 1_000), ActionIngress.Oci);

        Assert.Equal(ResultStatus.Posted, result.Status);
        Assert.Equal(ResultReason.Ok, result.Reason);
        Assert.Equal(1, poster.Calls);
    }

    [Fact]
    public async Task RejectsWhenRemoteDisabled()
    {
        var processor = new ActionProcessor(new FakePoster(), new FakePermission(), () => 1_000);
        processor.SetRemoteEnabled(false);

        var result = await processor.ReceiveTrustedAsync(MakeRequest("018f63f5-6f3d-7d21-88bc-9ef561f030e2", 1_000), ActionIngress.Oci);

        Assert.Equal(ResultStatus.Rejected, result.Status);
        Assert.Equal(ResultReason.RemoteDisabled, result.Reason);
    }

    [Fact]
    public async Task DuplicateActionIdWithSameFingerprintReturnsCachedResultWithoutReposting()
    {
        var poster = new FakePoster();
        var processor = new ActionProcessor(poster, new FakePermission(), () => 1_000);
        processor.SetRemoteEnabled(true);
        var request = MakeRequest("018f63f5-6f3d-7d21-88bc-9ef561f030e3", 1_000);

        var first = await processor.ReceiveTrustedAsync(request, ActionIngress.Oci);
        var second = await processor.ReceiveTrustedAsync(request, ActionIngress.Oci);

        Assert.Equal(1, poster.Calls);
        Assert.Equal(first, second);
    }

    [Fact]
    public async Task DuplicateActionIdWithDifferentFingerprintIsRejectedAsIdConflict()
    {
        var processor = new ActionProcessor(new FakePoster(), new FakePermission(), () => 1_000);
        processor.SetRemoteEnabled(true);
        var actionId = "018f63f5-6f3d-7d21-88bc-9ef561f030e4";

        await processor.ReceiveTrustedAsync(MakeRequest(actionId, 1_000), ActionIngress.Oci);
        var conflicting = await processor.ReceiveTrustedAsync(MakeRequest(actionId, 2_000), ActionIngress.Oci);

        Assert.Equal(ResultStatus.Rejected, conflicting.Status);
        Assert.Equal(ResultReason.IdConflict, conflicting.Reason);
    }

    [Fact]
    public async Task ExpiredRequestIsRejected()
    {
        var processor = new ActionProcessor(new FakePoster(), new FakePermission(), () => 10_000);
        processor.SetRemoteEnabled(true);

        var result = await processor.ReceiveTrustedAsync(MakeRequest("018f63f5-6f3d-7d21-88bc-9ef561f030e5", 1_000), ActionIngress.Oci);

        Assert.Equal(ResultStatus.Rejected, result.Status);
        Assert.Equal(ResultReason.Expired, result.Reason);
    }

    [Fact]
    public async Task MissingPermissionIsRejectedBeforePosting()
    {
        var poster = new FakePoster();
        var permission = new FakePermission { Granted = false };
        var processor = new ActionProcessor(poster, permission, () => 1_000);
        processor.SetRemoteEnabled(true);

        var result = await processor.ReceiveTrustedAsync(MakeRequest("018f63f5-6f3d-7d21-88bc-9ef561f030e6", 1_000), ActionIngress.Oci);

        Assert.Equal(ResultReason.PermissionRequired, result.Reason);
        Assert.Equal(0, poster.Calls);
    }

    [Fact]
    public async Task UnauthorizedRemoteRequestIsRejectedWithoutAnActiveLease()
    {
        var processor = new ActionProcessor(new FakePoster(), new FakePermission(), () => 1_000);
        processor.SetRemoteEnabled(true);
        var staleLease = new ActionAuthorizationLease(new ActionAuthorizationGeneration(0, 0));

        var result = await processor.ReceiveAsync(MakeRequest("018f63f5-6f3d-7d21-88bc-9ef561f030e7", 1_000), ActionIngress.Oci, staleLease);

        Assert.Equal(ResultReason.RemoteDisabled, result.Reason);
    }

    [Fact]
    public async Task ActiveAuthorizationLeaseIsAccepted()
    {
        var processor = new ActionProcessor(new FakePoster(), new FakePermission(), () => 1_000);
        processor.SetRemoteEnabled(true);
        var generation = new ActionAuthorizationGeneration(0, 0);
        var lease = await processor.ActivateAuthorizationLeaseAsync(generation);

        var result = await processor.ReceiveAsync(MakeRequest("018f63f5-6f3d-7d21-88bc-9ef561f030e8", 1_000), ActionIngress.Oci, lease);

        Assert.Equal(ResultStatus.Posted, result.Status);
    }
}
