import XCTest
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics
@testable import OffloadEngine

/// Smoke test: the Vision pipeline runs end-to-end on a real image file without
/// crashing or throwing. We can't assert "chihuahua → Dog" from a synthetic
/// image (that's validated on real photos), but this proves the analyzer wiring,
/// the ImageIO downsize path, and the request handling all work.
final class PhotoAnalyzerTests: XCTestCase {
    func testAnalyzeRunsOnAGeneratedImage() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("analyzer-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: url) }

        let w = 256, h = 192
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.4, green: 0.6, blue: 0.3, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(red: 0.7, green: 0.5, blue: 0.2, alpha: 1))
        ctx.fill(CGRect(x: 40, y: 40, width: 120, height: 90))
        let image = ctx.makeImage()!
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))

        // The contract: analyze returns without throwing. It may return nil (no
        // confident labels on an abstract image) or a Result — both are valid.
        let result = PhotoAnalyzer().analyze(url: url)
        if let result {
            XCTAssertFalse(result.labels.isEmpty && result.animals.isEmpty,
                           "a non-nil result must carry at least one label or animal")
        }
    }

    func testAnalyzeReturnsNilForMissingFile() {
        let missing = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).jpg")
        XCTAssertNil(PhotoAnalyzer().analyze(url: missing))
    }
}
