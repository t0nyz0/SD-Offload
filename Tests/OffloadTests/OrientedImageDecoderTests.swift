import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import OffloadEngine

final class OrientedImageDecoderTests: XCTestCase {
    func testDecodeAppliesPortraitEXIFOrientationAtFullResolution() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("oriented-\(UUID()).jpg")
        defer { try? FileManager.default.removeItem(at: file) }

        let source = try makeImage(width: 40, height: 20)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            file as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, source,
                                   [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let decoded = try XCTUnwrap(OrientedImageDecoder.decode(url: file))
        XCTAssertEqual(decoded.width, 20)
        XCTAssertEqual(decoded.height, 40)
    }

    func testManualQuarterTurnRotationSwapsAxesAndCanReverse() throws {
        let source = try makeImage(width: 40, height: 20)
        let clockwise = try XCTUnwrap(OrientedImageDecoder.rotated(source, quarterTurns: 1))
        XCTAssertEqual(clockwise.width, 20)
        XCTAssertEqual(clockwise.height, 40)

        let restored = try XCTUnwrap(OrientedImageDecoder.rotated(clockwise, quarterTurns: -1))
        XCTAssertEqual(restored.width, 40)
        XCTAssertEqual(restored.height, 20)
    }

    private func makeImage(width: Int, height: Int) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }
}
