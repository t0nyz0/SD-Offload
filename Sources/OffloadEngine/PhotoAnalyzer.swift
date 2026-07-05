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
        public let location: GeoPoint?
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
        // GPS lives in the SOURCE metadata, not the thumbnail we hand to Vision.
        let location = Self.gps(from: src)

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

        guard !labels.isEmpty || !animalSet.isEmpty || location != nil else { return nil }
        return Result(labels: Array(labels), animals: animalSet, location: location)
    }

    /// Cheap GPS-only read (header, no decode, no Vision) — used to backfill
    /// coordinates onto photos analyzed before GPS support. Returns nil if the
    /// file carries no coordinate.
    public func gpsOnly(url: URL) -> GeoPoint? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return Self.gps(from: src)
    }

    /// Parse a coordinate from an image source's GPS dictionary, applying the
    /// N/S and E/W reference signs. Rejects the (0,0) null-island and out-of-range
    /// junk some files write.
    static func gps(from src: CGImageSource) -> GeoPoint? {
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any],
              var lat = gps[kCGImagePropertyGPSLatitude] as? Double,
              var lon = gps[kCGImagePropertyGPSLongitude] as? Double else { return nil }
        if let ref = gps[kCGImagePropertyGPSLatitudeRef] as? String, ref.uppercased() == "S" { lat = -lat }
        if let ref = gps[kCGImagePropertyGPSLongitudeRef] as? String, ref.uppercased() == "W" { lon = -lon }
        guard (-90...90).contains(lat), (-180...180).contains(lon),
              !(abs(lat) < 0.0001 && abs(lon) < 0.0001) else { return nil }
        return GeoPoint(lat: lat, lon: lon)
    }
}
