using ClickBridge.Core.Wire;

namespace ClickBridge.Core.Actions;

/// <summary>Mirrors ActionIngress.swift's ActionRequestSink protocol.</summary>
public interface IActionRequestSink
{
    Task<ActionAuthorizationLease> ActivateAuthorizationLeaseAsync(ActionAuthorizationGeneration generation);
    Task RevokeAuthorizationLeaseAsync(ActionAuthorizationLease lease);
    Task<ActionResult> ReceiveAsync(ActionRequest request, ActionIngress ingress, ActionAuthorizationLease authorization);
}

/// <summary>Mirrors ActionIngress.swift's DiagnosticCounterReading protocol.</summary>
public interface IDiagnosticCounterReading
{
    Task<InputPostCounts> DiagnosticPostCountsAsync();
}
