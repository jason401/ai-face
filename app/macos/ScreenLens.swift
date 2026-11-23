// Screen lens: a round ring on the screen; what is inside it is captured with ScreenCaptureKit
// and streamed to the board (240x240). At 240 screen pixels across it is 1:1; a smaller ring
// magnifies, a bigger one shrinks. Drag the ring to move it, scroll on it to resize it, or let
// it follow the mouse. Needs the Screen Recording permission.
import Cocoa
import CoreMedia
import ScreenCaptureKit

/// The ring itself: transparent inside (clicks go through to what is below), a thick edge to
/// grab. Dragging moves it, scrolling resizes it; it never makes AI Face the active app.
final class ScreenLensRingView: NSView {
    static let edge: CGFloat = 9
    var onScroll: ((CGFloat) -> Void)?

    override func draw(_ dirtyRect: NSRect) {
        let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
        ring.appendOval(in: bounds.insetBy(dx: ScreenLensRingView.edge, dy: ScreenLensRingView.edge))
        ring.windingRule = .evenOdd
        NSColor(calibratedRed: 1, green: 0.42, blue: 0.62, alpha: 0.9).setFill()
        ring.fill()
        NSColor(white: 1, alpha: 0.9).setStroke()
        let inner = NSBezierPath(ovalIn: bounds.insetBy(dx: ScreenLensRingView.edge - 0.5, dy: ScreenLensRingView.edge - 0.5))
        inner.lineWidth = 1
        inner.stroke()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        let r = hypot(p.x - bounds.midX, p.y - bounds.midY), outer = bounds.width / 2
        return r <= outer && r >= outer - ScreenLensRingView.edge - 2 ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    override func scrollWheel(with event: NSEvent) {
        let d = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 8
        if d != 0 { onScroll?(d) }
    }
}

/// The ring window and the capture of what is inside it. Frames arrive on a background queue;
/// the window reads the newest one with `preview()` / `rgb565()` on the main thread.
final class ScreenLens: NSObject, SCStreamOutput, SCStreamDelegate {
    static let n = 240
    static let sizes = 120...960                  // inside of the ring, in screen pixels
    var follow = false { didSet { window?.ignoresMouseEvents = follow } }
    var pixels = 240 { didSet { pixels = min(max(pixels, ScreenLens.sizes.lowerBound), ScreenLens.sizes.upperBound) } }
    var onError: ((String) -> Void)?
    var onResize: ((Int) -> Void)?                // the ring was resized by scrolling on it
    private var window: NSPanel?
    private var stream: SCStream?                 // set once capture really started
    private var display: CGDirectDisplayID?
    private var applied: CGRect?, updating = false, generation = 0
    private let queue = DispatchQueue(label: "AIFace.ScreenLens")
    private let lock = NSLock()
    private var active: SCStream?                 // under `lock`: frames from other streams are dropped
    private var bgra = [UInt8](repeating: 0, count: ScreenLens.n * ScreenLens.n * 4)
    private var fresh = false

    /// Asks for the permission when it is missing (the system shows its prompt once).
    static func permitted() -> Bool {
        CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess()
    }

    static var permissionText: String {
        L("Allow AI Face in System Settings → Privacy & Security → Screen & System Audio Recording, then quit and reopen AI Face.")
    }

    func start() {
        if window == nil { makeWindow() }
        window?.orderFrontRegardless()
        update()
    }

    func stop() {
        halt()
        window?.orderOut(nil)
        window = nil
    }

    /// Ends the capture (the ring stays); old frames still on their way are ignored.
    private func halt() {
        generation += 1
        stream?.stopCapture { _ in }
        stream = nil
        display = nil
        applied = nil
        updating = false
        lock.lock()
        active = nil
        bgra = [UInt8](repeating: 0, count: ScreenLens.n * ScreenLens.n * 4)
        fresh = false
        lock.unlock()
    }

    private func makeWindow() {
        let w = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 140, height: 140), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.level = .floating
        w.hidesOnDeactivate = false
        w.becomesKeyOnlyIfNeeded = true
        w.isReleasedWhenClosed = false
        w.ignoresMouseEvents = follow
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let ring = ScreenLensRingView(frame: w.contentLayoutRect)
        ring.autoresizingMask = [.width, .height]
        ring.onScroll = { [weak self] d in
            guard let self else { return }
            self.pixels += Int((d * 2).rounded())
            self.onResize?(self.pixels)
            self.update()
        }
        w.contentView = ring
        window = w
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            place(on: screen, center: CGPoint(x: screen.frame.midX, y: screen.frame.midY))
        }
    }

    /// Sizes the ring for `pixels` on `screen` and centers it at `center`, kept so that the
    /// inside stays on that screen (ScreenCaptureKit only sees one screen at a time).
    private func place(on screen: NSScreen, center: CGPoint) {
        guard let w = window else { return }
        let inside = (CGFloat(pixels) / screen.backingScaleFactor).rounded(), side = inside + 2 * ScreenLensRingView.edge
        let f = screen.frame
        let x = min(max(center.x, f.minX + inside / 2), f.maxX - inside / 2)
        let y = min(max(center.y, f.minY + inside / 2), f.maxY - inside / 2)
        let frame = NSRect(x: (x - side / 2).rounded(), y: (y - side / 2).rounded(), width: side, height: side)
        if frame != w.frame { w.setFrame(frame, display: true) }
    }

    /// Called often (each tick): follows the mouse, keeps the ring's size and place right on its
    /// screen and points the capture at the inside of the ring.
    func update() {
        guard let w = window else { return }
        let center = follow ? NSEvent.mouseLocation : CGPoint(x: w.frame.midX, y: w.frame.midY)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) ?? w.screen ?? NSScreen.main,
              let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return }
        if NSEvent.pressedMouseButtons & 1 == 0 || follow { place(on: screen, center: center) }   // not while dragging
        let inside = w.frame.insetBy(dx: ScreenLensRingView.edge, dy: ScreenLensRingView.edge)
            .intersection(screen.frame)
        guard !inside.isEmpty else { return }
        // ScreenCaptureKit counts in points from the top-left corner of the display.
        let rect = CGRect(x: inside.minX - screen.frame.minX, y: screen.frame.maxY - inside.maxY,
                          width: inside.width, height: inside.height)
        if id != display {
            restart(display: id, rect: rect)
        } else if rect != applied, let stream, !updating {
            updating = true
            applied = rect
            let g = generation
            stream.updateConfiguration(configuration(rect)) { [weak self] error in
                DispatchQueue.main.async {
                    guard let self, self.generation == g else { return }
                    self.updating = false
                    if error != nil { self.applied = nil }   // try again next tick
                }
            }
        }
    }

    private func configuration(_ rect: CGRect) -> SCStreamConfiguration {
        let c = SCStreamConfiguration()
        c.width = ScreenLens.n
        c.height = ScreenLens.n
        c.sourceRect = rect
        c.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        c.pixelFormat = kCVPixelFormatType_32BGRA
        c.colorSpaceName = CGColorSpace.sRGB
        c.showsCursor = true
        c.queueDepth = 3
        return c
    }

    private func restart(display id: CGDirectDisplayID, rect: CGRect) {
        halt()
        display = id
        applied = rect
        let g = generation
        let number = window.flatMap { $0.windowNumber > 0 ? CGWindowID($0.windowNumber) : nil }
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { [weak self] content, error in
            DispatchQueue.main.async {
                guard let self, self.generation == g, self.window != nil else { return }
                guard let content, let screen = content.displays.first(where: { $0.displayID == id }) else {
                    self.fail(g, error == nil ? L("Could not find this screen.") : ScreenLens.permissionText)
                    return
                }
                // The ring itself never shows up in the picture.
                let mine = content.windows.filter { $0.windowID == number }
                let filter = SCContentFilter(display: screen, excludingWindows: mine)
                let s = SCStream(filter: filter, configuration: self.configuration(rect), delegate: self)
                do {
                    try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.queue)
                } catch {
                    self.fail(g, error.localizedDescription)
                    return
                }
                self.lock.lock()
                self.active = s
                self.lock.unlock()
                s.startCapture { error in
                    DispatchQueue.main.async {
                        guard self.generation == g else { s.stopCapture { _ in }; return }
                        if let error { self.fail(g, error.localizedDescription); return }
                        self.stream = s   // moves follow from now on (the next tick sends the newest place)
                    }
                }
            }
        }
    }

    private func fail(_ g: Int, _ message: String) {
        guard generation == g else { return }
        halt()
        onError?(message)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async {
            self.lock.lock()
            let mine = self.active === stream
            self.lock.unlock()
            if mine { self.fail(self.generation, error.localizedDescription) }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        // Only complete frames carry a picture; "idle" means nothing changed on screen.
        guard type == .screen, sampleBuffer.isValid,
              let info = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = info.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pixels = sampleBuffer.imageBuffer else { return }
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixels) else { return }
        let n = ScreenLens.n, row = CVPixelBufferGetBytesPerRow(pixels)
        let w = min(CVPixelBufferGetWidth(pixels), n), h = min(CVPixelBufferGetHeight(pixels), n)
        lock.lock()
        defer { lock.unlock() }
        guard active === stream else { return }
        bgra.withUnsafeMutableBytes { out in
            if w < n || h < n { memset(out.baseAddress!, 0, out.count) }
            for y in 0..<h {
                memcpy(out.baseAddress! + y * n * 4, base + y * row, w * 4)
            }
        }
        fresh = true
    }

    /// The newest picture for the pad (nil until the first one arrived).
    func preview() -> CGImage? {
        lock.lock()
        defer { lock.unlock() }
        guard fresh else { return nil }
        let n = ScreenLens.n
        guard let provider = CGDataProvider(data: Data(bgra) as CFData) else { return nil }
        return CGImage(width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: n * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// The newest picture in the board's format (RGB565, little-endian), nil until the first one.
    func rgb565() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard fresh else { return nil }
        let n = ScreenLens.n
        var out = [UInt8](repeating: 0, count: n * n * 2)
        for i in 0..<(n * n) {
            let b = UInt16(bgra[i * 4]) >> 3, g = UInt16(bgra[i * 4 + 1]) >> 2, r = UInt16(bgra[i * 4 + 2]) >> 3
            let v = (r << 11) | (g << 5) | b
            out[i * 2] = UInt8(v & 255)
            out[i * 2 + 1] = UInt8(v >> 8)
        }
        return Data(out)
    }
}
