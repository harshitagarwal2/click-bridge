using ClickBridge.Core.Pairing;

namespace ClickBridge.Windows.Pairing;

/// <summary>Stands in for NSPasteboard in PairingController.swift's copyWebInvitation.</summary>
public sealed class WindowsClipboard : IClipboard
{
    public bool SetText(string value)
    {
        try
        {
            System.Windows.Forms.Clipboard.SetText(value);
            return true;
        }
        catch (System.Runtime.InteropServices.ExternalException)
        {
            // The clipboard can be transiently locked by another process on
            // Windows; Clipboard.SetText throws in that case instead of
            // returning false the way NSPasteboard.setString(_:forType:) does.
            return false;
        }
    }
}
