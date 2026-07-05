import Foundation
import ImageIO
import OffloadCore

/// Viewer-grade metadata for one photo, read from the file header in a single
/// ImageIO pass (no full decode). Cached in memory with bounded concurrency so
/// paging through the viewer doesn't hammer the NAS.
struct PhotoMeta: Sendable {
    var pixelWidth: Int?
    var pixelHeight: Int?
    var make: String?
    var model: String?
    var lens: String?
    var dateTaken: Date?
    var exif = ExifInfo()          // iso / aperture / shutter / focal
    var gps: GeoPoint?

    var dimensions: String? {
        guard let w = pixelWidth, let h = pixelHeight, w > 0, h > 0 else { return nil }
        return "\(w) × \(h)"
    }
    var megapixels: String? {
        guard let w = pixelWidth, let h = pixelHeight, w > 0, h > 0 else { return nil }
        return "\(Int((Double(w * h) / 1_000_000).rounded())) MP"
    }
    /// "FUJIFILM X-T5" — de-duplicated so a model that already includes the make
    /// doesn't read "FUJIFILM FUJIFILM X-T5".
    var cameraName: String? {
        switch (make?.trimmed, model?.trimmed) {
        case let (m?, mod?): return mod.localizedCaseInsensitiveContains(m) ? mod : "\(m) \(mod)"
        case (_, let mod?):  return mod
        case (let m?, _):    return m
        default:             return nil
        }
    }
    var dateText: String? {
        guard let d = dateTaken else { return nil }
        let f = DateFormatter()
        f.locale = .current
        f.setLocalizedDateFormatFromTemplate("EEE MMM d yyyy jmm")
        return f.string(from: d)
    }
    var gpsText: String? {
        guard let g = gps else { return nil }
        return String(format: "%.5f, %.5f", g.lat, g.lon)
    }
    var mapsURL: URL? {
        guard let g = gps else { return nil }
        return URL(string: "https://maps.apple.com/?ll=\(g.lat),\(g.lon)&q=Photo")
    }
}

private extension String {
    var trimmed: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

private final class MetaBox { let meta: PhotoMeta; init(_ m: PhotoMeta) { meta = m } }

final class PhotoMetaCache: @unchecked Sendable {
    static let shared = PhotoMetaCache()

    private let mem: NSCache<NSString, MetaBox> = {
        let c = NSCache<NSString, MetaBox>(); c.countLimit = 1500; return c
    }()
    private let limiter = ThumbLimiter(limit: 4)

    private static let exifDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f
    }()

    func meta(url: URL, mtime: Date) async -> PhotoMeta {
        let key = "\(url.path)|\(Int(mtime.timeIntervalSince1970))" as NSString
        if let box = mem.object(forKey: key) { return box.meta }
        await limiter.acquire()
        defer { Task { await limiter.release() } }
        let meta = await Task.detached(priority: .userInitiated) { Self.read(url) }.value
        mem.setObject(MetaBox(meta), forKey: key)
        return meta
    }

    private static func read(_ url: URL) -> PhotoMeta {
        var m = PhotoMeta()
        let opts = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithURL(url as CFURL, opts),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, opts) as? [CFString: Any] else { return m }

        m.pixelWidth = props[kCGImagePropertyPixelWidth] as? Int
        m.pixelHeight = props[kCGImagePropertyPixelHeight] as? Int

        if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            m.make = tiff[kCGImagePropertyTIFFMake] as? String
            m.model = tiff[kCGImagePropertyTIFFModel] as? String
        }
        if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            m.lens = exif[kCGImagePropertyExifLensModel] as? String
            if let raw = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
                m.dateTaken = exifDateFormatter.date(from: raw)
            }
            if let arr = exif[kCGImagePropertyExifISOSpeedRatings] as? [Int], let iso = arr.first {
                m.exif.iso = iso
            } else if let iso = exif[kCGImagePropertyExifISOSpeedRatings] as? Int {
                m.exif.iso = iso
            }
            // Keep only finite, positive values — a malformed 0/∞/NaN would trap
            // the Int conversions in ExifInfo.shutter/caption on render.
            if let a = exif[kCGImagePropertyExifFNumber] as? Double, a.isFinite, a > 0 { m.exif.aperture = a }
            if let s = exif[kCGImagePropertyExifExposureTime] as? Double, s.isFinite, s > 0 { m.exif.shutter = s }
            if let f = exif[kCGImagePropertyExifFocalLength] as? Double, f.isFinite, f > 0 { m.exif.focalLength = f }
        }
        if let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any],
           var lat = gps[kCGImagePropertyGPSLatitude] as? Double,
           var lon = gps[kCGImagePropertyGPSLongitude] as? Double {
            if let ref = gps[kCGImagePropertyGPSLatitudeRef] as? String, ref.uppercased() == "S" { lat = -lat }
            if let ref = gps[kCGImagePropertyGPSLongitudeRef] as? String, ref.uppercased() == "W" { lon = -lon }
            if (-90...90).contains(lat), (-180...180).contains(lon),
               !(abs(lat) < 0.0001 && abs(lon) < 0.0001) {
                m.gps = GeoPoint(lat: lat, lon: lon)
            }
        }
        return m
    }
}
