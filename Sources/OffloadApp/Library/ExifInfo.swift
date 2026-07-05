import Foundation
import ImageIO

/// The basic shooting settings shown under a thumbnail.
struct ExifInfo: Sendable {
    var iso: Int?
    var aperture: Double?     // f-number
    var shutter: Double?      // seconds
    var focalLength: Double?  // mm

    /// e.g. "ISO 400 · ƒ2.8 · 1/250" — omits anything the file didn't record.
    var caption: String {
        var parts: [String] = []
        if let iso { parts.append("ISO \(iso)") }
        if let aperture { parts.append(String(format: "ƒ%.1f", aperture)) }
        if let shutter { parts.append(Self.shutter(shutter)) }
        if let focalLength { parts.append("\(Int(focalLength.rounded()))mm") }
        return parts.joined(separator: " · ")
    }

    var hasAny: Bool { iso != nil || aperture != nil || shutter != nil || focalLength != nil }

    static func shutter(_ s: Double) -> String {
        // Malformed EXIF can carry 0, ∞, or NaN (0/1 is a legal rational some
        // cameras write). Guard before any Double→Int conversion, which traps on
        // non-finite input and would crash the whole grid on one bad file.
        guard s.isFinite, s > 0 else { return "—" }
        if s >= 1 { return s == s.rounded() ? "\(Int(s))s" : String(format: "%.1fs", s) }
        let denom = (1 / s).rounded()
        guard denom.isFinite, denom <= Double(Int.max) else { return "—" }
        return "1/\(Int(denom))"
    }
}

private final class ExifBox { let info: ExifInfo; init(_ i: ExifInfo) { info = i } }

/// Lazily reads EXIF metadata (header only — no image decode) with a small
/// in-memory cache and bounded concurrency, so the grid can show shooting info
/// without hammering the NAS.
final class ExifCache: @unchecked Sendable {
    static let shared = ExifCache()

    private let mem: NSCache<NSString, ExifBox> = {
        let c = NSCache<NSString, ExifBox>(); c.countLimit = 3000; return c
    }()
    private let limiter = ThumbLimiter(limit: 6)

    func info(url: URL, mtime: Date) async -> ExifInfo? {
        let key = "\(url.path)|\(Int(mtime.timeIntervalSince1970))" as NSString
        if let box = mem.object(forKey: key) { return box.info.hasAny ? box.info : nil }
        await limiter.acquire()
        defer { Task { await limiter.release() } }
        let info = await Task.detached(priority: .utility) { Self.read(url) }.value
        mem.setObject(ExifBox(info ?? ExifInfo()), forKey: key)   // cache negatives too
        return (info?.hasAny ?? false) ? info : nil
    }

    private static func read(_ url: URL) -> ExifInfo? {
        let opts = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithURL(url as CFURL, opts),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, opts) as? [CFString: Any] else { return nil }
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        var info = ExifInfo()
        if let arr = exif?[kCGImagePropertyExifISOSpeedRatings] as? [Int], let iso = arr.first {
            info.iso = iso
        } else if let iso = exif?[kCGImagePropertyExifISOSpeedRatings] as? Int {
            info.iso = iso
        }
        // Only keep finite, positive values — a malformed 0/∞/NaN would otherwise
        // reach the caption (and trap the Int conversions in shutter/focalLength).
        if let a = exif?[kCGImagePropertyExifFNumber] as? Double, a.isFinite, a > 0 { info.aperture = a }
        if let s = exif?[kCGImagePropertyExifExposureTime] as? Double, s.isFinite, s > 0 { info.shutter = s }
        if let f = exif?[kCGImagePropertyExifFocalLength] as? Double, f.isFinite, f > 0 { info.focalLength = f }
        return info.hasAny ? info : nil
    }
}
