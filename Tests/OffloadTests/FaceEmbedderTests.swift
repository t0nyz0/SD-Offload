import XCTest
import CoreGraphics
@testable import OffloadEngine
@testable import OffloadCore

/// Exercises the real Vision feature-print path (macOS-only target), validating
/// the float extraction, normalization, and that distances behave sanely.
final class FaceEmbedderTests: XCTestCase {
    private func image(size: Int = 128, _ draw: (CGContext, CGRect) -> Void) -> CGImage {
        let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        draw(ctx, CGRect(x: 0, y: 0, width: size, height: size))
        return ctx.makeImage()!
    }

    func testFeaturePrintNormalizedAndDiscriminating() throws {
        let embedder = VisionFeaturePrintEmbedder()
        let red = image { ctx, r in
            ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); ctx.fill(r)
        }
        let checker = image { ctx, r in
            ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1)); ctx.fill(r)
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: r.width / 2, height: r.height / 2))
            ctx.fill(CGRect(x: r.width / 2, y: r.height / 2, width: r.width / 2, height: r.height / 2))
        }

        let a = try XCTUnwrap(embedder.embed(red), "feature print returned nil")
        let b = try XCTUnwrap(embedder.embed(checker))
        XCTAssertGreaterThan(a.count, 0)
        XCTAssertEqual(a.count, b.count)

        let norm = a.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        XCTAssertEqual(norm, 1, accuracy: 1e-3, "embeddings must be L2-normalized")

        let different = try XCTUnwrap(FaceMath.cosineDistance(a, b))
        XCTAssertGreaterThan(different, 0.01, "distinct images should differ")

        let a2 = try XCTUnwrap(embedder.embed(red))
        let same = try XCTUnwrap(FaceMath.cosineDistance(a, a2))
        XCTAssertEqual(same, 0, accuracy: 1e-3, "the same image should embed identically")
    }
}
