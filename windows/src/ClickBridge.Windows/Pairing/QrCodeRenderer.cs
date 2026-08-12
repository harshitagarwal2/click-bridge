using System.Drawing;
using ClickBridge.Core.Pairing;
using QRCoder;

namespace ClickBridge.Windows.Pairing;

/// <summary>Port of mac/ClickBridgeMac/QRCodeRenderer.swift, using QRCoder instead of CoreImage's CIQRCodeGenerator.</summary>
public static class QrCodeRenderer
{
    public static string Payload(Uri pairingLink) => PairingLink.ValidateInvitation(pairingLink).AbsoluteUri;

    public static Bitmap? Image(Uri pairingLink, int pixelsPerModule = 8)
    {
        string payload;
        try
        {
            payload = Payload(pairingLink);
        }
        catch (PairingLinkException)
        {
            return null;
        }

        using var generator = new QRCodeGenerator();
        using var data = generator.CreateQrCode(payload, QRCodeGenerator.ECCLevel.M);
        using var renderer = new QRCode(data);
        return renderer.GetGraphic(pixelsPerModule);
    }
}
