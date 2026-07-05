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
    // Extra shooting + technical metadata (all optional — shown only when present).
    var focalLen35: Int?           // 35mm-equivalent focal length
    var exposureBias: Double?      // EV compensation
    var flashFired: Bool?
    var whiteBalanceAuto: Bool?    // true = auto, false = manual
    var meteringMode: Int?
    var exposureProgram: Int?
    var colorProfile: String?
    var software: String?          // camera firmware / editing software
    var altitude: Double?          // meters, signed (negative = below sea level)

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
    var altitudeText: String? {
        guard let a = altitude else { return nil }
        return String(format: "%.0f m%@", abs(a), a < -0.5 ? " below sea level" : "")
    }
    var focalLen35Text: String? { focalLen35.map { "\($0) mm" } }
    var exposureBiasText: String? {
        guard let ev = exposureBias, abs(ev) > 0.01 else { return nil }   // omit a plain 0
        return String(format: "%+.1f EV", ev)
    }
    var flashText: String? { flashFired.map { $0 ? "Fired" : "Did not fire" } }
    var whiteBalanceText: String? { whiteBalanceAuto.map { $0 ? "Auto" : "Manual" } }
    var meteringText: String? {
        switch meteringMode {
        case 1: return "Average"
        case 2: return "Center-weighted"
        case 3: return "Spot"
        case 4: return "Multi-spot"
        case 5: return "Multi-segment"
        case 6: return "Partial"
        default: return nil
        }
    }
    var exposureProgramText: String? {
        switch exposureProgram {
        case 1: return "Manual"
        case 2: return "Program"
        case 3: return "Aperture priority"
        case 4: return "Shutter priority"
        case 5: return "Creative (slow)"
        case 6: return "Action (fast)"
        case 7: return "Portrait"
        case 8: return "Landscape"
        default: return nil
        }
    }
    var colorProfileText: String? {
        guard let p = colorProfile else { return nil }
        if p.localizedCaseInsensitiveContains("Display P3") { return "Display P3" }
        if p.localizedCaseInsensitiveContains("sRGB") { return "sRGB" }
        if p.localizedCaseInsensitiveContains("Adobe RGB") { return "Adobe RGB" }
        return p
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
        m.colorProfile = props[kCGImagePropertyProfileName] as? String

        if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            m.make = tiff[kCGImagePropertyTIFFMake] as? String
            m.model = tiff[kCGImagePropertyTIFFModel] as? String
            m.software = tiff[kCGImagePropertyTIFFSoftware] as? String
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
            if let f35 = exif[kCGImagePropertyExifFocalLenIn35mmFilm] as? Int, f35 > 0 { m.focalLen35 = f35 }
            if let ev = exif[kCGImagePropertyExifExposureBiasValue] as? Double, ev.isFinite { m.exposureBias = ev }
            if let flash = exif[kCGImagePropertyExifFlash] as? Int { m.flashFired = (flash & 0x1) == 1 }
            if let wb = exif[kCGImagePropertyExifWhiteBalance] as? Int { m.whiteBalanceAuto = (wb == 0) }
            if let mm = exif[kCGImagePropertyExifMeteringMode] as? Int, mm != 0 { m.meteringMode = mm }
            if let ep = exif[kCGImagePropertyExifExposureProgram] as? Int, ep != 0 { m.exposureProgram = ep }
        }
        if let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any],
           var lat = gps[kCGImagePropertyGPSLatitude] as? Double,
           var lon = gps[kCGImagePropertyGPSLongitude] as? Double {
            if let ref = gps[kCGImagePropertyGPSLatitudeRef] as? String, ref.uppercased() == "S" { lat = -lat }
            if let ref = gps[kCGImagePropertyGPSLongitudeRef] as? String, ref.uppercased() == "W" { lon = -lon }
            if (-90...90).contains(lat), (-180...180).contains(lon),
               !(abs(lat) < 0.0001 && abs(lon) < 0.0001) {
                m.gps = GeoPoint(lat: lat, lon: lon)
                if let alt = gps[kCGImagePropertyGPSAltitude] as? Double, alt.isFinite {
                    let below = (gps[kCGImagePropertyGPSAltitudeRef] as? Int) == 1
                    m.altitude = below ? -alt : alt
                }
            }
        }
        return m
    }
}
