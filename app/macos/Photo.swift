// Pictures: any image file -> the board's 240x240 RGB565 format, and back for thumbnails.
import Cocoa
import ImageIO
import UniformTypeIdentifiers

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

/// Pictures from a drop. Finder hands over file URLs; the Photos app hands over promised files
/// (written when they are dropped, after an iCloud download if needed) or only image data. Those
/// are copied into a temporary folder first: `done(urls, folder)` on the main thread, and the
/// caller removes `folder` once it has read the files.
enum PictureDrop {
    static func receive(_ providers: [NSItemProvider], done: @escaping ([URL], URL?) -> Void) {
        let pasteboard = NSPasteboard(name: .drag)   // still the dropped items while SwiftUI's drop runs
        let files = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !files.isEmpty { done(files, nil); return }

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("AI Face drop " + UUID().uuidString)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var found: [URL] = []
        let lock = NSLock()
        let group = DispatchGroup()
        func keep(_ url: URL) { lock.lock(); found.append(url); lock.unlock() }

        let promises = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver] ?? []
        if !promises.isEmpty {
            let queue = OperationQueue()
            for promise in promises {
                var waiting = max(1, promise.fileTypes.count)   // the reader runs once per promised file
                for _ in 0..<waiting { group.enter() }
                promise.receivePromisedFiles(atDestination: folder, options: [:], operationQueue: queue) { url, error in
                    if error == nil { keep(url) }
                    lock.lock(); let leave = waiting > 0; waiting -= 1; lock.unlock()
                    if leave { group.leave() }
                }
            }
        } else {
            for provider in providers {
                guard let type = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .image) == true }) else { continue }
                group.enter()
                provider.loadFileRepresentation(forTypeIdentifier: type) { url, _ in
                    defer { group.leave() }
                    guard let url = url else { return }   // removed when this returns: copy it now
                    let ext = UTType(type)?.preferredFilenameExtension ?? url.pathExtension
                    let name = (provider.suggestedName ?? url.deletingPathExtension().lastPathComponent) + "." + ext
                    let copy = folder.appendingPathComponent(String(UUID().uuidString.prefix(8)) + " " + name)
                    if (try? FileManager.default.copyItem(at: url, to: copy)) != nil { keep(copy) }
                }
            }
        }
        // Give up on anything that has not arrived after a minute (a stuck iCloud download).
        var finished = false
        let finish = {
            if finished { return }
            finished = true
            lock.lock(); let urls = found; lock.unlock()
            done(urls, folder)
        }
        group.notify(queue: .main, execute: finish)
        DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: finish)
    }
}
