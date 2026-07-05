import Foundation
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics

/// Shell helpers + fake-card / fake-NAS fixtures for the harness.
enum Sh {
    @discardableResult
    static func run(_ launch: String, _ args: [String]) -> (status: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launch)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try? p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

enum Fixtures {
    /// Try to create + attach a real exFAT DMG (most realistic). Returns nil if
    /// the environment forbids disk-image creation (sandboxes, CI) — the harness
    /// then falls back to a plain directory, which exercises the same engine
    /// code paths (we drive SessionRunner directly, not DiskArbitration).
    static func attachExFATCard(dmgPath: URL, volName: String, sizeMB: Int) -> (dev: String, mount: String)? {
        let create = Sh.run("/usr/bin/hdiutil", ["create", "-size", "\(sizeMB)m", "-fs", "ExFAT",
                                                 "-volname", volName, "-ov", dmgPath.path])
        guard create.status == 0 else { return nil }
        let (status, out) = Sh.run("/usr/bin/hdiutil", ["attach", dmgPath.path, "-nobrowse", "-plist"])
        guard status == 0, let data = out.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]] else { return nil }
        for e in entities {
            if let mount = e["mount-point"] as? String, let dev = e["dev-entry"] as? String {
                return (dev, mount)
            }
        }
        return nil
    }

    static func detach(dev: String) {
        _ = Sh.run("/usr/bin/hdiutil", ["detach", dev, "-force"])
    }

    /// Write a tiny JPEG carrying an EXIF DateTimeOriginal so date-routing is exercised.
    @discardableResult
    static func writeJPEG(to url: URL, captureDate: Date, seed: UInt8) throws -> String {
        let w = 24, h = 16
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw Err("CGContext failed")
        }
        ctx.setFillColor(CGColor(red: Double(seed) / 255, green: 0.4, blue: 0.6, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        // A few varied pixels so files differ byte-for-byte.
        ctx.setFillColor(CGColor(red: 0.1, green: Double(seed % 7) / 7, blue: 0.2, alpha: 1))
        ctx.fill(CGRect(x: Int(seed) % w, y: 0, width: 3, height: h))
        guard let image = ctx.makeImage() else { throw Err("makeImage failed") }

        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy:MM:dd HH:mm:ss"
        let exif: [CFString: Any] = [kCGImagePropertyExifDateTimeOriginal: df.string(from: captureDate)]
        let props: [CFString: Any] = [kCGImagePropertyExifDictionary: exif]

        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw Err("dest create failed for \(url.lastPathComponent)")
        }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw Err("finalize failed for \(url.lastPathComponent)") }
        return try sha256(url)
    }

    static func sha256(_ url: URL) throws -> String {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw Err("open \(url.path)") }
        defer { close(fd) }
        var hasher = SHA256()
        let bufSize = 1 << 20
        let buf = UnsafeMutableRawPointer.allocate(byteCount: bufSize, alignment: 1)
        defer { buf.deallocate() }
        while true {
            let n = read(fd, buf, bufSize)
            if n <= 0 { break }
            hasher.update(bufferPointer: UnsafeRawBufferPointer(start: buf, count: n))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

struct Err: Error, CustomStringConvertible {
    let m: String
    init(_ m: String) { self.m = m }
    var description: String { m }
}
