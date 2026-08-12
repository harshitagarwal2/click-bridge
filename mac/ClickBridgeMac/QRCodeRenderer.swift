import AppKit
import CoreImage

enum QRCodeRenderer {
    static func payload(for pairingLink: URL) throws -> String {
        try PairingLink.validateInvitation(pairingLink).absoluteString
    }

    static func image(for pairingLink: URL, scale: CGFloat = 8) -> NSImage? {
        guard let payload = try? payload(for: pairingLink) else { return nil }
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(payload.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) else {
            return nil
        }
        let representation = NSCIImageRep(ciImage: output)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }
}
