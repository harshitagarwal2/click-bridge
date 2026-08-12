namespace ClickBridge.Core.Actions;

/// <summary>Mirrors mac/ClickBridgeMac/ActionIngress.swift's ActionAuthorizationGeneration.</summary>
public readonly record struct ActionAuthorizationGeneration(
    ulong CredentialMutationEpoch,
    int ConnectionGeneration) : IComparable<ActionAuthorizationGeneration>
{
    public int CompareTo(ActionAuthorizationGeneration other)
    {
        var epoch = CredentialMutationEpoch.CompareTo(other.CredentialMutationEpoch);
        return epoch != 0 ? epoch : ConnectionGeneration.CompareTo(other.ConnectionGeneration);
    }

    public static bool operator <(ActionAuthorizationGeneration left, ActionAuthorizationGeneration right) =>
        left.CompareTo(right) < 0;
    public static bool operator >(ActionAuthorizationGeneration left, ActionAuthorizationGeneration right) =>
        left.CompareTo(right) > 0;
    public static bool operator <=(ActionAuthorizationGeneration left, ActionAuthorizationGeneration right) =>
        left.CompareTo(right) <= 0;
    public static bool operator >=(ActionAuthorizationGeneration left, ActionAuthorizationGeneration right) =>
        left.CompareTo(right) >= 0;
}

/// <summary>
/// Mirrors ActionAuthorizationLease. Swift gives every lease a private
/// UUID so two leases with the same generation still compare unequal
/// unless they're literally the same instance; a plain reference-typed
/// class gives the identical behavior in C# via default reference
/// equality, with no UUID needed.
/// </summary>
public sealed class ActionAuthorizationLease
{
    public ActionAuthorizationGeneration Generation { get; }
    public ActionAuthorizationLease(ActionAuthorizationGeneration generation) => Generation = generation;
}
