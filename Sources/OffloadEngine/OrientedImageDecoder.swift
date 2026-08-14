import Foundation
import CoreGraphics
import ImageIO

/// Full-resolution viewer decoding that applies the image's EXIF orientation.
/// Thumbnail call sites already ask ImageIO for this transform; the full viewer
/// historically used `CGImageSourceCreateImageAtIndex`, which returns raw stored
/// pixels and therefore displayed portrait JPEGs sideways.
public enum OrientedImageDecoder {
    public static func decode(url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
        let maxPixel = max(width, height)

        // The thumbnail API is ImageIO's orientation-aware decode path. Asking it
        // to always decode at the source's full longest dimension preserves full
        // viewer resolution while applying mirrored/rotated EXIF orientations.
        if maxPixel > 0 {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            if let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                return image
            }
        }

        // Unusual formats may omit dimensions or reject thumbnail creation. Keep
        // the previous full-image fallback so they remain viewable.
        let options: CFDictionary = [
            kCGImageSourceShouldCache: true,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary
        return CGImageSourceCreateImageAtIndex(source, 0, options)
    }

    /// Rotate an already orientation-correct image by 90-degree increments.
    /// Used only for the viewer's non-destructive manual correction controls.
    public static func rotated(_ image: CGImage, quarterTurns rawTurns: Int) -> CGImage? {
        let turns = ((rawTurns % 4) + 4) % 4
        guard turns != 0 else { return image }

        let sourceWidth = image.width
        let sourceHeight = image.height
        let swapsAxes = turns == 1 || turns == 3
        let destinationWidth = swapsAxes ? sourceHeight : sourceWidth
        let destinationHeight = swapsAxes ? sourceWidth : sourceHeight
        let sourceColorSpace = image.colorSpace
        let isMonochrome = sourceColorSpace?.model == .monochrome
        let colorSpace = isMonochrome
            ? (sourceColorSpace ?? CGColorSpaceCreateDeviceGray())
            : (sourceColorSpace?.model == .rgb ? sourceColorSpace! : CGColorSpaceCreateDeviceRGB())
        let bitmapInfo = isMonochrome
            ? CGImageAlphaInfo.none.rawValue
            : CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: nil,
            width: destinationWidth,
            height: destinationHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return nil }

        let sourceRect = CGRect(x: 0, y: 0, width: sourceWidth, height: sourceHeight)
        switch turns {
        case 1: // clockwise
            context.translateBy(x: CGFloat(destinationWidth), y: 0)
            context.rotate(by: .pi / 2)
        case 2:
            context.translateBy(x: CGFloat(destinationWidth), y: CGFloat(destinationHeight))
            context.rotate(by: .pi)
        case 3: // counter-clockwise
            context.translateBy(x: 0, y: CGFloat(destinationHeight))
            context.rotate(by: -.pi / 2)
        default:
            break
        }
        context.interpolationQuality = .high
        context.draw(image, in: sourceRect)
        return context.makeImage()
    }
}
