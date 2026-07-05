import Foundation
import ImageIO
import OffloadCore

public protocol CaptureDating: Sendable {
    /// Best capture date: EXIF DateTimeOriginal → TIFF DateTime → file creation → mtime.
    func captureDate(of url: URL, creationDate: Date?, mtime: Date) -> Date
}

/// ImageIO metadata-only read (~0.5–2 ms/file); works for RAF/ARW/CR3 etc. via
/// the system RAW codecs. Returns the fallback chain for videos and unknowns.
public struct CaptureDater: CaptureDating {
    public init() {}

    private static let exifFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        f.timeZone = .current   // camera-local wall time interpreted locally
        return f
    }()

    public func captureDate(of url: URL, creationDate: Date?, mtime: Date) -> Date {
        if let exif = exifDate(of: url) { return exif }
        return creationDate ?? mtime
    }

    private func exifDate(of url: URL) -> Date? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any] else {
            return nil
        }
        if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let raw = exif[kCGImagePropertyExifDateTimeOriginal] as? String,
           let date = Self.exifFormatter.date(from: raw) {
            return date
        }
        if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
           let raw = tiff[kCGImagePropertyTIFFDateTime] as? String,
           let date = Self.exifFormatter.date(from: raw) {
            return date
        }
        return nil
    }
}
