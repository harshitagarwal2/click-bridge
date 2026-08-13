import AppKit
import ImageIO
import Vision
import XCTest
@testable import ClickBridgeMac

final class QRCodeRendererTests: XCTestCase {
    func testPayloadContainsOnlyTheCanonicalPairingLink() throws {
        let reference = Self.reference
        let link = try Self.makeInvitation()

        XCTAssertEqual(try QRCodeRenderer.payload(for: link),
                       "https://relay.example/pair#v=1&r=\(reference)")
        XCTAssertFalse(try QRCodeRenderer.payload(for: link).contains("token"))
    }

    func testLayoutAddsFourQuietZoneModulesAndUsesExactIntegerDimensions() throws {
        let link = try Self.makeInvitation()
        let scale = 7

        let layout = try XCTUnwrap(QRCodeRenderer.layout(for: link, scale: scale))

        XCTAssertEqual(layout.quietZoneModules, 4)
        XCTAssertEqual(layout.integerScale, scale)
        XCTAssertEqual(layout.pixelDimension, (layout.symbolModules + 8) * scale)
        XCTAssertEqual(layout.displayDimension, CGFloat(layout.pixelDimension))
    }

    func testRenderedBitmapHasWhiteQuietZoneOnEveryEdgeAndBlackSymbolModules() throws {
        let link = try Self.makeInvitation()
        let scale = 7
        let image = try XCTUnwrap(QRCodeRenderer.image(for: link, scale: scale))
        let layout = try XCTUnwrap(QRCodeRenderer.layout(for: link, scale: scale))
        let bitmap = try XCTUnwrap(image.representations.compactMap { $0 as? NSBitmapImageRep }.first)

        XCTAssertEqual(bitmap.pixelsWide, layout.pixelDimension)
        XCTAssertEqual(bitmap.pixelsHigh, layout.pixelDimension)
        XCTAssertEqual(image.size, NSSize(width: layout.displayDimension, height: layout.displayDimension))

        let quietZonePixels = layout.quietZoneModules * layout.integerScale
        let lastPixel = layout.pixelDimension - 1
        for offset in 0..<quietZonePixels {
            for position in 0..<layout.pixelDimension {
                XCTAssertTrue(Self.isWhite(bitmap.colorAt(x: position, y: offset)),
                              "bottom quiet zone was not white at (\(position), \(offset))")
                XCTAssertTrue(Self.isWhite(bitmap.colorAt(x: position, y: lastPixel - offset)),
                              "top quiet zone was not white at (\(position), \(lastPixel - offset))")
                XCTAssertTrue(Self.isWhite(bitmap.colorAt(x: offset, y: position)),
                              "left quiet zone was not white at (\(offset), \(position))")
                XCTAssertTrue(Self.isWhite(bitmap.colorAt(x: lastPixel - offset, y: position)),
                              "right quiet zone was not white at (\(lastPixel - offset), \(position))")
            }
        }

        let symbolRange = quietZonePixels..<(layout.pixelDimension - quietZonePixels)
        let firstSymbolBand = quietZonePixels..<(quietZonePixels + layout.integerScale)
        let lastSymbolBand = (layout.pixelDimension - quietZonePixels - layout.integerScale)..<(layout.pixelDimension - quietZonePixels)
        let hasBlackModuleTouchingQuietZone = symbolRange.contains { position in
            firstSymbolBand.contains { edge in
                Self.isBlack(bitmap.colorAt(x: position, y: edge))
                    || Self.isBlack(bitmap.colorAt(x: position, y: lastPixel - edge))
                    || Self.isBlack(bitmap.colorAt(x: edge, y: position))
                    || lastSymbolBand.contains { oppositeEdge in
                        Self.isBlack(bitmap.colorAt(x: oppositeEdge, y: position))
                    }
            }
        }
        XCTAssertTrue(hasBlackModuleTouchingQuietZone,
                      "a black symbol module should begin immediately after exactly four quiet-zone modules")
        let hasBlackModule = symbolRange.contains { y in
            symbolRange.contains { x in Self.isBlack(bitmap.colorAt(x: x, y: y)) }
        }
        XCTAssertTrue(hasBlackModule)
    }

    func testRendererRejectsNonpositiveAndFractionalScales() throws {
        let link = try Self.makeInvitation()

        XCTAssertNil(QRCodeRenderer.layout(for: link, scale: 0))
        XCTAssertNil(QRCodeRenderer.layout(for: link, scale: -1))
        XCTAssertNil(QRCodeRenderer.image(for: link, scale: 0))
        XCTAssertNil(QRCodeRenderer.image(for: link, scale: -1))
        XCTAssertNil(QRCodeRenderer.image(for: link, scale: CGFloat(2.5)))
        XCTAssertNil(QRCodeRenderer.image(for: link, scale: CGFloat.infinity))
    }

    func testVisionDecodesFinalRenderedBitmapToExactInvitationURL() throws {
        let link = try Self.makeInvitation()
        let image = try XCTUnwrap(QRCodeRenderer.image(for: link))
        let bitmap = try XCTUnwrap(image.representations.compactMap { $0 as? NSBitmapImageRep }.first)
        let cgImage = try XCTUnwrap(bitmap.cgImage)
        let request = VNDetectBarcodesRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up)

        try handler.perform([request])

        let decodedPayloads = (request.results ?? [])
            .filter { $0.symbology == .qr }
            .compactMap(\.payloadStringValue)
        XCTAssertEqual(decodedPayloads, [link.absoluteString])
    }

    func testProductionLayoutUsesNativeIntegerPixelsAtLeast280PointsWide() throws {
        let link = try Self.makeInvitation()

        let layout = try XCTUnwrap(QRCodeRenderer.layout(for: link))
        let image = try XCTUnwrap(QRCodeRenderer.image(for: link))

        XCTAssertGreaterThanOrEqual(layout.displayDimension, 280)
        XCTAssertEqual(layout.displayDimension, CGFloat(layout.pixelDimension))
        XCTAssertEqual(image.size.width, layout.displayDimension)
        XCTAssertEqual(image.size.height, layout.displayDimension)
    }

    func testProductionLayoutKeepsCanonicalMaximumInvitationReasonablySized() throws {
        let label = String(repeating: "a", count: 63)
        let host = Array(repeating: label, count: 7).joined(separator: ".")
        let link = try Self.makeInvitation(host: host)

        XCTAssertLessThanOrEqual(link.absoluteString.utf8.count, 512)
        let layout = try XCTUnwrap(QRCodeRenderer.layout(for: link))

        XCTAssertGreaterThanOrEqual(layout.displayDimension, 280)
        XCTAssertLessThanOrEqual(layout.displayDimension, 400)
        XCTAssertEqual(
            layout.pixelDimension,
            (layout.symbolModules + (layout.quietZoneModules * 2)) * layout.integerScale
        )
    }

    func testPairingLinkRejectsNonWebSocketRelayAndNonCanonicalReference() {
        XCTAssertThrowsError(try PairingLink.make(
            relayURL: URL(string: "https://relay.example/ws")!,
            reference: "A"
        ))
        XCTAssertThrowsError(try PairingLink.make(
            relayURL: URL(string: "wss://relay.example/ws")!,
            reference: String(repeating: "=", count: 43)
        ))
    }

    func testWebInvitationMapsCanonicalNativeInvitationWithoutChangingReference() throws {
        let reference = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        let native = URL(string: "https://relay.example:8443/pair#v=1&r=\(reference)")!

        let web = try PairingLink.makeWebInvitation(from: native)

        XCTAssertEqual(web.absoluteString,
                       "https://relay.example:8443/pair/web#v=1&r=\(reference)")
        XCTAssertEqual(web.fragment, native.fragment)
        XCTAssertEqual(native.absoluteString,
                       "https://relay.example:8443/pair#v=1&r=\(reference)")
    }

    func testWebInvitationRejectsHostileOrNonCanonicalSources() {
        let reference = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        let invalidLinks = [
            "http://relay.example/pair#v=1&r=\(reference)",
            "https://relay.example/pair/web#v=1&r=\(reference)",
            "https://relay.example/pair?token=secret#v=1&r=\(reference)",
            "https://user@relay.example/pair#v=1&r=\(reference)",
            "https://relay.example/pair#v=1&r=\(reference)&token=secret",
            "https://relay.example/pair#v=1&r=A"
        ]

        for rawValue in invalidLinks {
            XCTAssertThrowsError(try PairingLink.makeWebInvitation(
                from: URL(string: rawValue)!
            ), rawValue)
        }
    }

    func testRendererRejectsAnythingExceptTheCanonicalInvitationURL() {
        let reference = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        let invalidLinks = [
            "clickbridge://pair?token=secret",
            "https://relay.example/other#v=1&r=\(reference)",
            "https://relay.example/pair?token=secret#v=1&r=\(reference)",
            "https://user@relay.example/pair#v=1&r=\(reference)",
            "https://relay.example/pair#v=1&r=\(reference)&token=secret",
            "https://relay.example/pair#v=1&r=A"
        ]

        for rawValue in invalidLinks {
            let link = URL(string: rawValue)!
            XCTAssertThrowsError(try QRCodeRenderer.payload(for: link))
            XCTAssertNil(QRCodeRenderer.image(for: link))
        }
    }

    private static let reference = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"

    private static func makeInvitation(host: String = "relay.example") throws -> URL {
        try PairingLink.make(
            relayURL: URL(string: "wss://\(host)/ws")!,
            reference: reference
        )
    }

    private static func isWhite(_ color: NSColor?) -> Bool {
        guard let color = color?.usingColorSpace(.deviceRGB) else { return false }
        return color.redComponent > 0.99
            && color.greenComponent > 0.99
            && color.blueComponent > 0.99
            && color.alphaComponent > 0.99
    }

    private static func isBlack(_ color: NSColor?) -> Bool {
        guard let color = color?.usingColorSpace(.deviceRGB) else { return false }
        return color.redComponent < 0.01
            && color.greenComponent < 0.01
            && color.blueComponent < 0.01
            && color.alphaComponent > 0.99
    }
}
