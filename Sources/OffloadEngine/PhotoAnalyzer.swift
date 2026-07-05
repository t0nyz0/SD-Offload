import Foundation
import Vision
import ImageIO
import OffloadCore

/// On-device photo content analysis with Apple's Vision framework — free, fully
/// offline, no API tokens. Runs scene/object classification plus animal
/// recognition (so a chihuahua tags as "Dog"). Analyzes a downsized embedded
/// preview, not the full RAW, so it stays fast and reads little over SMB.
public struct PhotoAnalyzer: Sendable {
    public init() {}

    public struct Result: Sendable {
        public let labels: [PhotoLabel]
        public let animals: [String]
    }

    public func analyze(url: URL, maxLabels: Int = 10, minConfidence: Float = 0.20) -> Result? {
        // Downsize via ImageIO first (embedded preview ≈ KBs over SMB).
        let thumbOpts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceThumbnailMaxPixelSize: 800,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOpts as CFDictionary) else {
            return nil
        }

        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        let classify = VNClassifyImageRequest()
        let animalsReq = VNRecognizeAnimalsRequest()
        do {
            try handler.perform([classify, animalsReq])
        } catch {
            return nil
        }

        let labels: [PhotoLabel] = (classify.results ?? [])
            .filter { $0.confidence >= minConfidence }
            .prefix(maxLabels)
            .map { PhotoLabel(name: $0.identifier, confidence: Double($0.confidence)) }

        var animalSet: [String] = []
        for obs in animalsReq.results ?? [] {
            for label in obs.labels where label.confidence >= 0.5 {
                let name = label.identifier.capitalized
                if !animalSet.contains(name) { animalSet.append(name) }
            }
        }

        guard !labels.isEmpty || !animalSet.isEmpty else { return nil }
        return Result(labels: Array(labels), animals: animalSet)
    }
}
