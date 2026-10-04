// Pictures: any image file -> the board's 240x240 RGB565 format, and back for thumbnails.
import Cocoa
import ImageIO

let IMAGE_EXTENSIONS: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp", "tif", "tiff"]

/// Decodes an image file (JPEG, PNG, HEIC, ...) upright and no bigger than `maxPixels`.
func decodeImage(_ data: Data, maxPixels: Int) -> CGImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,   // EXIF orientation
        kCGImageSourceThumbnailMaxPixelSize: maxPixels,
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
}

func thumbnail(_ data: Data, size: Int = 240) -> NSImage? {
    guard let cg = decodeImage(data, maxPixels: size) else { return nil }
    return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
}

/// Fills the 240x240 square (the round screen cuts the corners) and converts to RGB565,
/// little-endian, with ordered dithering (hides 16-bit banding). Same as the old web app.
func boardPhoto(_ data: Data) -> Data? {
    guard let cg = decodeImage(data, maxPixels: 1200) else { return nil }
    let n = 240
    var px = [UInt8](repeating: 0, count: n * n * 4)
    let drawn: Bool = px.withUnsafeMutableBytes { buffer -> Bool in
        guard let ctx = CGContext(data: buffer.baseAddress, width: n, height: n, bitsPerComponent: 8,
                                  bytesPerRow: n * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: n, height: n))
        ctx.interpolationQuality = .high
        let w = Double(cg.width), h = Double(cg.height)
        let k = max(240 / w, 240 / h)
        ctx.draw(cg, in: CGRect(x: (240 - w * k) / 2, y: (240 - h * k) / 2, width: w * k, height: h * k))
        return true
    }
    if !drawn { return nil }
    let B: [Double] = [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5]
    var out = [UInt8](repeating: 0, count: n * n * 2)
    for y in 0..<n {
        for x in 0..<n {
            let i = (y * n + x) * 4
            let d = B[(y & 3) * 4 + (x & 3)] / 16 - 0.5
            let r = min(31, max(0, Int((Double(px[i]) / 255 * 31 + d).rounded())))
            let g = min(63, max(0, Int((Double(px[i + 1]) / 255 * 63 + d).rounded())))
            let b = min(31, max(0, Int((Double(px[i + 2]) / 255 * 31 + d).rounded())))
            let v = (r << 11) | (g << 5) | b
            out[(y * n + x) * 2] = UInt8(v & 255)
            out[(y * n + x) * 2 + 1] = UInt8(v >> 8)
        }
    }
    return Data(out)
}

/// A board photo (RGB565 little-endian, 240x240) as an image.
func imageFromBoardPhoto(_ bytes: Data) -> NSImage? {
    let n = 240
    guard bytes.count == n * n * 2 else { return nil }
    var px = [UInt8](repeating: 255, count: n * n * 4)
    bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
        for i in 0..<(n * n) {
            let v = Int(raw[i * 2]) | (Int(raw[i * 2 + 1]) << 8)
            px[i * 4] = UInt8((v >> 11) * 255 / 31)
            px[i * 4 + 1] = UInt8(((v >> 5) & 63) * 255 / 63)
            px[i * 4 + 2] = UInt8((v & 31) * 255 / 31)
        }
    }
    guard let provider = CGDataProvider(data: Data(px) as CFData),
          let cg = CGImage(width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: n * 4,
                           space: CGColorSpaceCreateDeviceRGB(),
                           bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                           provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    else { return nil }
    return NSImage(cgImage: cg, size: NSSize(width: n, height: n))
}
