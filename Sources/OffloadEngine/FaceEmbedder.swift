import Foundation
import Vision
import CoreGraphics
import OffloadCore

/// Produces an identity embedding for a tight face/animal crop. Deliberately a
/// protocol: the v1 backend is Vision's general feature-print, and a bundled
/// ArcFace/MobileFaceNet Core ML model can replace it later WITHOUT touching any
/// caller. Every vector is stamped with `identifier`, and vectors from different
/// identifiers are never compared — so swapping the backend can't silently
/// corrupt distances against already-stored embeddings.
public protocol FaceEmbedder: Sendable {
    var identifier: String { get }
    /// A normalized embedding for the crop, or nil if it couldn't be produced.
    func embed(_ image: CGImage) -> [Float]?
}

/// v1 backend — Vision's `VNGenerateImageFeaturePrintRequest`, which runs on the
/// Neural Engine. This is a general scene descriptor, NOT a face-tuned model, so
/// it's honestly mediocre at "same person across pose/lighting": good for rough
/// grouping the user confirms, not for silent auto-tagging. That's why the whole
/// feature is suggest-only. The ArcFace upgrade slots in behind this protocol.
public struct VisionFeaturePrintEmbedder: FaceEmbedder {
    public let identifier = "vision-featureprint-v1"
    public init() {}

    public func embed(_ image: CGImage) -> [Float]? {
        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do { try handler.perform([request]) } catch { return nil }
        guard let obs = request.results?.first as? VNFeaturePrintObservation,
              let raw = Self.floats(from: obs) else { return nil }
        return FaceMath.normalized(raw)
    }

    /// Extract the raw vector from a feature-print observation. The element width
    /// is detected from data.count / elementCount so we handle Float32, Float16,
    /// and Double regardless of how the OS revision reports elementType.
    static func floats(from obs: VNFeaturePrintObservation) -> [Float]? {
        let count = obs.elementCount
        let data = obs.data
        guard count > 0, data.count % count == 0 else { return nil }
        let stride = data.count / count
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> [Float]? in
            switch stride {
            case 4: return Array(raw.bindMemory(to: Float.self).prefix(count))
            case 8: let b = raw.bindMemory(to: Double.self); return (0..<count).map { Float(b[$0]) }
            case 2: let b = raw.bindMemory(to: Float16.self); return (0..<count).map { Float(b[$0]) }
            default: return nil
            }
        }
    }
}
