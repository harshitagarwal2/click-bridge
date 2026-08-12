using ClickBridge.Core.Actions;

namespace ClickBridge.Windows.Input;

/// <summary>
/// Port of mac/ClickBridgeMac/PostEventPermissionService.swift. Windows has
/// no Accessibility-style consent gate for synthetic input, so this always
/// reports granted. The one real Windows failure mode — SendInput silently
/// blocked by UIPI when the foreground window runs at a higher integrity
/// level than this app — surfaces as an EventCreationFailed action result
/// from WindowsInputExecutor instead, not as a permission state. See
/// docs/install-windows.md.
/// </summary>
public sealed class WindowsInputPermissionService : IPostEventPermissionChecking
{
    public bool IsGranted() => true;
}
