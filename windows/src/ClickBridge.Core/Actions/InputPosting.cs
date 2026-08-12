namespace ClickBridge.Core.Actions;

/// <summary>Mirrors mac/ClickBridgeMac/ActionIngress.swift's InputPostCounts.</summary>
public readonly record struct InputPostCounts(int MouseDownPostCount, int MouseUpPostCount)
{
    public static readonly InputPostCounts Zero = new(0, 0);
}

public abstract record InputPostOutcome
{
    public sealed record Posted(double MouseDownUnixMs) : InputPostOutcome;
    public sealed record CreationFailed : InputPostOutcome;
}

/// <summary>
/// Mirrors mac/ClickBridgeMac/ActionProcessor.swift's InputPosting protocol.
/// Implemented on Windows by WindowsInputExecutor (SendInput), the way
/// MacInputExecutor implements it with CGEvent.
/// </summary>
public interface IInputPosting
{
    InputPostOutcome PostLeftClickAtCurrentCursor();
    InputPostCounts DiagnosticPostCounts();
}

/// <summary>
/// Mirrors PostEventPermissionChecking. Windows has no Accessibility-style
/// consent gate, so WindowsInputPermissionService always reports granted —
/// see windows/README or docs/install-windows.md for the UIPI caveat this
/// simplification carries.
/// </summary>
public interface IPostEventPermissionChecking
{
    bool IsGranted();
}
