import Foundation
import Vision
import ImageIO
import CoreGraphics
import OffloadCore

/// Finds faces and pets in a photo and produces an identity embedding for each,
/// feeding the suggest-and-confirm labeling flow. Faces need a bigger decode than
/// the 800px content-analysis thumbnail (tiny crops embed poorly), so this does
/// its own ~1600px decode — meaning the face pass is heavier than base Analyze
/// and is exposed as its own opt-in action.
public struct FaceDetector: Sendable {
    let embedder: FaceEmbedder

    public init(embedder: FaceEmbedder = VisionFeaturePrintEmbedder()) { self.embedder = embedder }

    public struct Config: Sendable {
        public var decodePixels = 1600
        public var minFaceQuality: Float = 0.35      // Vision face capture-quality gate
        public var minFaceFraction: Double = 0.03    // short side ≥ 3% of the image
        public var minAnimalConfidence: Float = 0.7
        public var maxDetections = 20
        public init() {}
    }

    public func detect(url: URL, config: Config = Config()) -> [Detection] {
        guard let full = Self.decode(url: url, maxPixels: config.decodePixels) else { return [] }
        let handler = VNImageRequestHandler(cgImage: full, options: [:])
        let quality = VNDetectFaceCaptureQualityRequest()   // its observations carry both bbox + quality
        let animals = VNRecognizeAnimalsRequest()
        do { try handler.perform([quality, animals]) } catch { return [] }

        var out: [Detection] = []

        for face in (quality.results ?? []) {
            let q = Double(face.faceCaptureQuality ?? 0)
            let bb = face.boundingBox
            guard q >= Double(config.minFaceQuality),
                  min(bb.width, bb.height) >= config.minFaceFraction,
                  let crop = Self.crop(full, normRect: bb, expand: 0.3),
                  let emb = embedder.embed(crop) else { continue }
            out.append(Detection(kind: .face, bbox: Self.norm(bb), embedding: emb,
                                 embedderID: embedder.identifier, quality: q))
        }

        for obs in (animals.results ?? []) {
            let conf = obs.labels.first?.confidence ?? 0
            let bb = obs.boundingBox
            guard conf >= config.minAnimalConfidence,
                  let crop = Self.crop(full, normRect: bb, expand: 0.12),
                  let emb = embedder.embed(crop) else { continue }
            out.append(Detection(kind: .pet, bbox: Self.norm(bb), embedding: emb,
                                 embedderID: embedder.identifier, quality: Double(conf)))
        }

        // Best-quality first, capped.
        return Array(out.sorted { $0.quality > $1.quality }.prefix(config.maxDetections))
    }

    // MARK: - Image helpers

    private static func decode(url: URL, maxPixels: Int) -> CGImage? {
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailFromImageAlways: true,   // prefer a real large decode for face detail
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceCreateThumbnailWithTransform: true,     // honor EXIF orientation
        ]
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    /// Crop a CGImage to a Vision-normalized rect (origin bottom-left), expanded
    /// by `expand` on each side and clamped to the image. Converts to the pixel,
    /// top-left coordinate space CGImage.cropping expects.
    private static func crop(_ image: CGImage, normRect bb: CGRect, expand: Double) -> CGImage? {
        let w = Double(image.width), h = Double(image.height)
        let ex = bb.width * expand, ey = bb.height * expand
        let minX = max(0, bb.minX - ex), maxX = min(1, bb.maxX + ex)
        let minY = max(0, bb.minY - ey), maxY = min(1, bb.maxY + ey)
        let px = minX * w
        let py = (1 - maxY) * h                         // flip: Vision bottom-left → CGImage top-left
        let pw = (maxX - minX) * w
        let ph = (maxY - minY) * h
        guard pw >= 1, ph >= 1 else { return nil }
        return image.cropping(to: CGRect(x: px, y: py, width: pw, height: ph))
    }

    private static func norm(_ r: CGRect) -> NormRect {
        NormRect(x: r.minX, y: r.minY, w: r.width, h: r.height)
    }
}
