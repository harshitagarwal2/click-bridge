import AppKit
import CoreImage

enum QRCodeRenderer {
    struct Layout: Equatable {
        let symbolModules: Int
        let quietZoneModules: Int
        let integerScale: Int
        let pixelDimension: Int
        let displayDimension: CGFloat
    }

    static let quietZoneModules = 4
    static let minimumProductionDisplayDimension: CGFloat = 280

    private static let context = CIContext()

    static func payload(for pairingLink: URL) throws -> String {
        try PairingLink.validateInvitation(pairingLink).absoluteString
    }

    static func layout(for pairingLink: URL) -> Layout? {
        guard let symbol = symbol(for: pairingLink) else { return nil }
        return productionLayout(symbolModules: symbol.modules)
    }

    static func layout(for pairingLink: URL, scale: Int) -> Layout? {
        guard let symbol = symbol(for: pairingLink) else { return nil }
        return makeLayout(symbolModules: symbol.modules, scale: scale)
    }

    static func image(for pairingLink: URL) -> NSImage? {
        guard let symbol = symbol(for: pairingLink),
              let layout = productionLayout(symbolModules: symbol.modules) else {
            return nil
        }
        return materialize(symbol: symbol.image, layout: layout)
    }

    static func image(for pairingLink: URL, scale: Int) -> NSImage? {
        guard let symbol = symbol(for: pairingLink),
              let layout = makeLayout(symbolModules: symbol.modules, scale: scale) else {
            return nil
        }
        return materialize(symbol: symbol.image, layout: layout)
    }

    static func image(for pairingLink: URL, scale: CGFloat) -> NSImage? {
        guard scale.isFinite,
              scale > 0,
              scale.rounded(.towardZero) == scale,
              scale < CGFloat(Int.max) else {
            return nil
        }
        return image(for: pairingLink, scale: Int(scale))
    }

    private static func symbol(for pairingLink: URL) -> (image: CIImage, modules: Int)? {
        guard let payload = try? payload(for: pairingLink) else { return nil }
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(payload.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")

        guard let output = filter.outputImage else { return nil }
        let extent = output.extent
        guard extent == extent.integral,
              extent.width == extent.height,
              extent.width > 0,
              extent.width <= CGFloat(Int.max),
              CGFloat(Int(extent.width)) == extent.width else {
            return nil
        }

        guard let bounds = blackModuleBounds(in: output, extent: extent) else { return nil }
        let moduleCount = Int(bounds.width)
        guard bounds.width == bounds.height,
              moduleCount >= 21,
              (moduleCount - 21).isMultiple(of: 4) else {
            return nil
        }

        let normalized = output
            .cropped(to: bounds)
            .transformed(by: CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
        return (normalized, moduleCount)
    }

    private static func blackModuleBounds(in image: CIImage, extent: CGRect) -> CGRect? {
        guard let cgImage = context.createCGImage(image, from: extent) else { return nil }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        var minimumX = bitmap.pixelsWide
        var minimumY = bitmap.pixelsHigh
        var maximumX = -1
        var maximumY = -1

        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      color.redComponent < 0.5 else {
                    continue
                }
                minimumX = min(minimumX, x)
                minimumY = min(minimumY, y)
                maximumX = max(maximumX, x)
                maximumY = max(maximumY, y)
            }
        }

        guard maximumX >= minimumX, maximumY >= minimumY else { return nil }
        let width = CGFloat(maximumX - minimumX + 1)
        let height = CGFloat(maximumY - minimumY + 1)
        return CGRect(
            x: extent.minX + CGFloat(minimumX),
            y: extent.minY + CGFloat(minimumY),
            width: width,
            height: height
        )
    }

    private static func productionLayout(symbolModules: Int) -> Layout? {
        let unscaledDimension = symbolModules + (quietZoneModules * 2)
        let scale = max(
            1,
            Int(ceil(minimumProductionDisplayDimension / CGFloat(unscaledDimension)))
        )
        return makeLayout(symbolModules: symbolModules, scale: scale)
    }

    private static func makeLayout(symbolModules: Int, scale: Int) -> Layout? {
        guard scale > 0 else { return nil }
        let unscaledDimension = symbolModules + (quietZoneModules * 2)
        guard unscaledDimension <= Int.max / scale else { return nil }
        let pixelDimension = unscaledDimension * scale
        return Layout(
            symbolModules: symbolModules,
            quietZoneModules: quietZoneModules,
            integerScale: scale,
            pixelDimension: pixelDimension,
            displayDimension: CGFloat(pixelDimension)
        )
    }

    private static func materialize(symbol: CIImage, layout: Layout) -> NSImage? {
        let unscaledDimension = layout.symbolModules + (layout.quietZoneModules * 2)
        let unscaledExtent = CGRect(
            x: 0,
            y: 0,
            width: unscaledDimension,
            height: unscaledDimension
        )
        let whiteBackground = CIImage(color: CIColor.white).cropped(to: unscaledExtent)
        let translatedSymbol = symbol.transformed(by: CGAffineTransform(
            translationX: CGFloat(layout.quietZoneModules),
            y: CGFloat(layout.quietZoneModules)
        ))
        let composed = translatedSymbol
            .composited(over: whiteBackground)
            .cropped(to: unscaledExtent)
        let scale = CGFloat(layout.integerScale)
        let scaled = composed.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let pixelExtent = CGRect(
            x: 0,
            y: 0,
            width: layout.pixelDimension,
            height: layout.pixelDimension
        )

        guard let cgImage = context.createCGImage(scaled, from: pixelExtent) else {
            return nil
        }

        let representation = NSBitmapImageRep(cgImage: cgImage)
        representation.size = NSSize(
            width: layout.displayDimension,
            height: layout.displayDimension
        )
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }
}
