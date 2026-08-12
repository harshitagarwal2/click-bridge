using System.Diagnostics;
using ClickBridge.Core.Wire;

namespace ClickBridge.Core.Actions;

/// <summary>
/// Port of mac/ClickBridgeMac/ActionProcessor.swift. Swift uses an `actor`
/// for automatic serialized access; here a single lock around all mutable
/// state gives the same "one request processed at a time, no torn reads"
/// guarantee without needing actor isolation.
/// </summary>
public sealed class ActionProcessor : IActionRequestSink, IDiagnosticCounterReading
{
    private abstract record Entry
    {
        public sealed record Processing : Entry;
        public sealed record Completed(string Fingerprint, ActionResult Result, double CompletedAtMilliseconds) : Entry;
    }

    private readonly IInputPosting _poster;
    private readonly IPostEventPermissionChecking _permission;
    private readonly Func<double> _nowMilliseconds;
    private readonly double _ttlMilliseconds;
    private readonly int _capacity;
    private readonly double _skewToleranceMilliseconds;
    private readonly object _gate = new();

    private bool _remoteEnabled;
    private ActionAuthorizationLease? _newestAuthorizationLease;
    private ActionAuthorizationLease? _activeAuthorizationLease;
    private readonly Dictionary<string, Entry> _entries = new();
    private readonly List<string> _order = new();

    public ActionProcessor(
        IInputPosting poster,
        IPostEventPermissionChecking permission,
        Func<double>? nowMilliseconds = null,
        double ttlSeconds = Constants.CompletedActionTtlSeconds,
        int capacity = Constants.CompletedActionCap,
        double skewToleranceSeconds = Constants.ClockSkewToleranceMs / 1000.0)
    {
        _poster = poster;
        _permission = permission;
        _nowMilliseconds = nowMilliseconds ?? (() => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
        _ttlMilliseconds = ttlSeconds * 1000;
        _capacity = capacity;
        _skewToleranceMilliseconds = skewToleranceSeconds * 1000;
    }

    public void SetRemoteEnabled(bool enabled)
    {
        lock (_gate) { _remoteEnabled = enabled; }
    }

    public Task<ActionAuthorizationLease> ActivateAuthorizationLeaseAsync(ActionAuthorizationGeneration generation)
    {
        lock (_gate)
        {
            if (_newestAuthorizationLease is { } newest)
            {
                if (generation == newest.Generation)
                {
                    return Task.FromResult(newest);
                }
                if (!(generation > newest.Generation))
                {
                    return Task.FromResult(new ActionAuthorizationLease(generation));
                }
            }
            var lease = new ActionAuthorizationLease(generation);
            _newestAuthorizationLease = lease;
            _activeAuthorizationLease = lease;
            return Task.FromResult(lease);
        }
    }

    public Task RevokeAuthorizationLeaseAsync(ActionAuthorizationLease lease)
    {
        lock (_gate)
        {
            if (ReferenceEquals(_activeAuthorizationLease, lease))
            {
                _activeAuthorizationLease = null;
            }
        }
        return Task.CompletedTask;
    }

    /// <summary>Trusted local call path — mirrors the Swift overload with no authorization lease.</summary>
    public Task<ActionResult> ReceiveTrustedAsync(ActionRequest request, ActionIngress ingress) =>
        Task.FromResult(Receive(request, ingress, trustedLocalRequest: true, authorization: null));

    public Task<ActionResult> ReceiveAsync(ActionRequest request, ActionIngress ingress, ActionAuthorizationLease authorization) =>
        Task.FromResult(Receive(request, ingress, trustedLocalRequest: false, authorization: authorization));

    public Task<InputPostCounts> DiagnosticPostCountsAsync() => Task.FromResult(_poster.DiagnosticPostCounts());

    public int TrackedActionCount()
    {
        lock (_gate) { return _entries.Count; }
    }

    private ActionResult Receive(
        ActionRequest request,
        ActionIngress ingress,
        bool trustedLocalRequest,
        ActionAuthorizationLease? authorization)
    {
        var started = Stopwatch.GetTimestamp();

        if (request.Action != "click" || request.ExpiresAtUnixMs - request.IssuedAtUnixMs != Constants.ActionLifetimeMs)
        {
            return Rejected(request.ActionId, ResultReason.InvalidRequest, ingress, started);
        }

        var currentMilliseconds = _nowMilliseconds();
        if (request.IssuedAtUnixMs > currentMilliseconds + _skewToleranceMilliseconds)
        {
            return Rejected(request.ActionId, ResultReason.InvalidRequest, ingress, started);
        }
        if (currentMilliseconds > request.ExpiresAtUnixMs + _skewToleranceMilliseconds)
        {
            return Rejected(request.ActionId, ResultReason.Expired, ingress, started);
        }

        lock (_gate)
        {
            if (!trustedLocalRequest && !ReferenceEquals(authorization, _activeAuthorizationLease))
            {
                return Rejected(request.ActionId, ResultReason.RemoteDisabled, ingress, started);
            }

            PruneExpired(currentMilliseconds);
            var fingerprint = request.Fingerprint;
            if (_entries.TryGetValue(request.ActionId, out var existing))
            {
                switch (existing)
                {
                    case Entry.Processing:
                        return Rejected(request.ActionId, ResultReason.IdConflict, ingress, started);
                    case Entry.Completed completed:
                        if (completed.Fingerprint != fingerprint)
                        {
                            return Rejected(request.ActionId, ResultReason.IdConflict, ingress, started);
                        }
                        return completed.Result;
                }
            }

            if (_entries.Count >= _capacity)
            {
                return Rejected(request.ActionId, ResultReason.CapacityExceeded, ingress, started);
            }

            _entries[request.ActionId] = new Entry.Processing();
            _order.Add(request.ActionId);

            ActionResult result;
            if (!_remoteEnabled)
            {
                result = Rejected(request.ActionId, ResultReason.RemoteDisabled, ingress, started);
            }
            else if (!_permission.IsGranted())
            {
                result = Rejected(request.ActionId, ResultReason.PermissionRequired, ingress, started);
            }
            else
            {
                var outcome = _poster.PostLeftClickAtCurrentCursor();
                result = outcome switch
                {
                    InputPostOutcome.Posted posted => new ActionResult
                    {
                        ActionId = request.ActionId,
                        Status = ResultStatus.Posted,
                        Reason = ResultReason.Ok,
                        AcceptedVia = ingress,
                        MacProcessingUs = ElapsedMicroseconds(started),
                        MouseDownPostedUnixMs = posted.MouseDownUnixMs,
                    },
                    _ => Rejected(request.ActionId, ResultReason.EventCreationFailed, ingress, started),
                };
            }

            _entries[request.ActionId] = new Entry.Completed(fingerprint, result, _nowMilliseconds());
            return result;
        }
    }

    private void PruneExpired(double nowMilliseconds)
    {
        var cutoff = nowMilliseconds - _ttlMilliseconds;
        _order.RemoveAll(id =>
        {
            if (!_entries.TryGetValue(id, out var entry))
            {
                return true;
            }
            switch (entry)
            {
                case Entry.Processing:
                    return false;
                case Entry.Completed completed when completed.CompletedAtMilliseconds > cutoff:
                    return false;
                default:
                    _entries.Remove(id);
                    return true;
            }
        });
    }

    private static ActionResult Rejected(string id, ResultReason reason, ActionIngress ingress, long started) =>
        new()
        {
            ActionId = id,
            Status = ResultStatus.Rejected,
            Reason = reason,
            AcceptedVia = ingress,
            MacProcessingUs = ElapsedMicroseconds(started),
            MouseDownPostedUnixMs = null,
        };

    private static double ElapsedMicroseconds(long startTimestamp) =>
        Stopwatch.GetElapsedTime(startTimestamp).TotalMicroseconds;
}
