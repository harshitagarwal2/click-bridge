namespace ClickBridge.Core.Pairing;

/// <summary>
/// Stands in for NSPasteboard in PairingController.swift's copyWebInvitation.
/// The Windows app implements this with System.Windows.Forms.Clipboard.
/// </summary>
public interface IClipboard
{
    bool SetText(string value);
}
