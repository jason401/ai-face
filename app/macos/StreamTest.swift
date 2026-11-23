// Streaming test: a round pad drawn on this Mac and sent to the board picture by picture.
// The pad shows exactly the picture that goes out; the server sends only what changed
// (core/aiface/stream.py), and the board shows it as it arrives. "Screen" mode sends what is
// inside a ring on the real screen instead (ScreenLens.swift).
import Cocoa

/// The 240x240 picture: background, what the mouse drew, a fading trail and the mouse arrow,
/// a dot going round the edge (pictures keep flowing even when nothing moves) and the speed.
final class StreamCanvas {
    static let n = 240
    private(set) var rgba = [UInt8](repeating: 0, count: StreamCanvas.n * StreamCanvas.n * 4)
    private let paint: CGContext?      // what the mouse has drawn (kept until Clear)
    var cursor: CGPoint?               // board coordinates: top-left origin, 0-240
    var trail: [(CGPoint, CFTimeInterval)] = []
    var stats = ""
    private var hue: CGFloat = 0

    init() {
        let n = StreamCanvas.n
        paint = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        paint?.translateBy(x: 0, y: CGFloat(n))   // top-left origin, like the board
        paint?.scaleBy(x: 1, y: -1)
        paint?.setLineCap(.round)
        paint?.setLineJoin(.round)
        paint?.setLineWidth(7)
    }

    func stroke(from a: CGPoint, to b: CGPoint) {
        hue = (hue + 0.004).truncatingRemainder(dividingBy: 1)
        paint?.setStrokeColor(NSColor(hue: hue, saturation: 0.75, brightness: 1, alpha: 1).cgColor)
        paint?.move(to: a)
        paint?.addLine(to: b)
        paint?.strokePath()
    }

    func clear() {
        paint?.clear(CGRect(x: 0, y: 0, width: StreamCanvas.n, height: StreamCanvas.n))
    }

    /// Draws the picture at time `t` into `rgba` and returns it as an image for the pad.
    func render(_ t: CFTimeInterval) -> CGImage? {
        let n = StreamCanvas.n, size = CGFloat(n), center = CGPoint(x: size / 2, y: size / 2)
        let paintImage = paint?.makeImage()
        trail.removeAll { t - $0.1 > 0.6 }
        let trail = self.trail, cursor = self.cursor, stats = self.stats
        return rgba.withUnsafeMutableBytes { buffer -> CGImage? in
            guard let ctx = CGContext(data: buffer.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            let all = CGRect(x: 0, y: 0, width: size, height: size)
            ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            ctx.fill(all)
            let colors = [CGColor(red: 0.07, green: 0.10, blue: 0.22, alpha: 1), CGColor(red: 0, green: 0, blue: 0, alpha: 1)]
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1]) {
                ctx.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: 120, options: [])
            }
            if let paintImage { ctx.draw(paintImage, in: all) }   // both bottom-up: same orientation

            ctx.translateBy(x: 0, y: size)   // the rest in board coordinates (top-left origin)
            ctx.scaleBy(x: 1, y: -1)
            let a = t * 2 * .pi / 4   // one turn in 4 s
            ctx.setFillColor(CGColor(red: 0.3, green: 0.9, blue: 1, alpha: 1))
            ctx.fillEllipse(in: CGRect(x: center.x + 104 * sin(a) - 4, y: center.y - 104 * cos(a) - 4, width: 8, height: 8))
            for (p, born) in trail {
                let k = CGFloat(1 - (t - born) / 0.6)
                ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.6 * k))
                ctx.fillEllipse(in: CGRect(x: p.x - 3 * k, y: p.y - 3 * k, width: 6 * k, height: 6 * k))
            }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            let title: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                                                        .foregroundColor: NSColor(white: 0.55, alpha: 1), .paragraphStyle: style]
            ("Mac → Board" as NSString).draw(in: CGRect(x: 40, y: 34, width: 160, height: 16), withAttributes: title)
            let small: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                                                        .foregroundColor: NSColor(white: 0.85, alpha: 1), .paragraphStyle: style]
            (stats as NSString).draw(in: CGRect(x: 30, y: 186, width: 180, height: 18), withAttributes: small)
            NSGraphicsContext.restoreGraphicsState()
            if let c = cursor {
                // The classic arrow, tip at the mouse.
                let shape: [CGPoint] = [CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 17), CGPoint(x: 4, y: 13), CGPoint(x: 7, y: 20),
                                        CGPoint(x: 10, y: 19), CGPoint(x: 7, y: 12), CGPoint(x: 12, y: 12)]
                ctx.beginPath()
                ctx.addLines(between: shape.map { CGPoint(x: c.x + $0.x * 1.2, y: c.y + $0.y * 1.2) })
                ctx.closePath()
                ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
                ctx.setStrokeColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
                ctx.setLineWidth(1.2)
                ctx.drawPath(using: .fillStroke)
            }
            return ctx.makeImage()
        }
    }

    /// The last rendered picture in the board's format: RGB565, little-endian, row by row.
    func rgb565() -> Data {
        let n = StreamCanvas.n
        var out = [UInt8](repeating: 0, count: n * n * 2)
        for i in 0..<(n * n) {
            let r = UInt16(rgba[i * 4]) >> 3, g = UInt16(rgba[i * 4 + 1]) >> 2, b = UInt16(rgba[i * 4 + 2]) >> 3
            let v = (r << 11) | (g << 5) | b
            out[i * 2] = UInt8(v & 255)
            out[i * 2 + 1] = UInt8(v >> 8)
        }
        return Data(out)
    }
}

/// The round pad: shows the picture and follows the mouse (move: arrow and trail, drag: draw).
final class StreamPadView: NSView {
    let canvas: StreamCanvas
    var image: CGImage? { didSet { needsDisplay = true } }
    var drawing = true { didSet { if !drawing { canvas.cursor = nil; last = nil } } }
    private var last: CGPoint?

    init(canvas: StreamCanvas, frame: NSRect) {
        self.canvas = canvas
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
        super.updateTrackingAreas()
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        NSBezierPath(ovalIn: bounds).fill()
        guard let image else { return }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(ovalIn: bounds).addClip()   // the board's glass is round
        NSImage(cgImage: image, size: bounds.size).draw(in: bounds, from: .zero, operation: .copy, fraction: 1,
                                                       respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
    }

    private func point(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        let k = CGFloat(StreamCanvas.n) / bounds.width
        return CGPoint(x: p.x * k, y: p.y * k)
    }

    private func move(_ event: NSEvent) {
        guard drawing else { return }
        let p = point(event)
        canvas.cursor = p
        canvas.trail.append((p, CACurrentMediaTime()))
    }

    override func mouseMoved(with event: NSEvent) { move(event) }
    override func mouseEntered(with event: NSEvent) { move(event) }
    override func mouseExited(with event: NSEvent) { canvas.cursor = nil; last = nil }
    override func mouseDown(with event: NSEvent) {
        guard drawing else { return }
        move(event)
        last = point(event)
        if let p = last { canvas.stroke(from: p, to: p) }
    }
    override func mouseDragged(with event: NSEvent) {
        guard drawing else { return }
        move(event)
        let p = point(event)
        canvas.stroke(from: last ?? p, to: p)
        last = p
    }
    override func mouseUp(with event: NSEvent) { last = nil }
}

/// The window: the pad, Start/Stop and Clear. Pictures go out one at a time: the next one
/// only after the board took the last one, so the speed shown is what the board really shows.
final class StreamTestWindow: NSObject, NSWindowDelegate {
    static let shared = StreamTestWindow()
    private var window: NSWindow?
    private let canvas = StreamCanvas()
    private var pad: StreamPadView?
    private var note: NSTextField?
    private var status: NSTextField?
    private var button: NSButton?
    private var mode: NSSegmentedControl?
    private var erase: NSButton?
    private var followBox: NSButton?
    private var sizeRow: [NSView] = []
    private var sizeSlider: NSSlider?
    private var sizeValue: NSTextField?
    private let lens = ScreenLens()
    private var screenMode: Bool { mode?.selectedSegment == 1 }
    private var timer: Timer?
    private var streaming = false, waiting = false
    private var frames = 0, bytes = 0, since = CACurrentMediaTime()

    func show() {
        if window == nil { build() }
        if timer == nil {
            let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.tick() }
            RunLoop.main.add(t, forMode: .common)   // keeps running while the mouse drags
            timer = t
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func build() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 452),
                         styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        w.title = L("Streaming test")
        w.isReleasedWhenClosed = false
        w.delegate = self
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 452))
        let mode = NSSegmentedControl(labels: [L("Draw"), L("Screen")], trackingMode: .selectOne,
                                      target: self, action: #selector(modeChanged))
        mode.selectedSegment = 0
        mode.frame = NSRect(x: 60, y: 414, width: 180, height: 24)
        let pad = StreamPadView(canvas: canvas, frame: NSRect(x: 30, y: 160, width: 240, height: 240))   // from the bottom up
        let note = NSTextField(wrappingLabelWithString: StreamTestWindow.drawNote)
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.frame = NSRect(x: 20, y: 104, width: 260, height: 44)
        let status = NSTextField(labelWithString: L("Preview only: not streaming"))
        status.font = .systemFont(ofSize: 11)
        status.lineBreakMode = .byTruncatingTail
        status.frame = NSRect(x: 20, y: 80, width: 260, height: 16)
        let button = NSButton(title: L("Start streaming"), target: self, action: #selector(toggle))
        button.bezelStyle = .rounded
        button.keyEquivalent = "\r"
        button.frame = NSRect(x: 150, y: 12, width: 132, height: 32)
        let clear = NSButton(title: L("Erase"), target: self, action: #selector(clearPad))
        clear.bezelStyle = .rounded
        clear.frame = NSRect(x: 18, y: 12, width: 90, height: 32)
        let follow = NSButton(checkboxWithTitle: L("Follow the mouse"), target: self, action: #selector(followChanged))
        follow.frame = NSRect(x: 20, y: 18, width: 128, height: 20)
        follow.isHidden = true
        let sizeLabel = NSTextField(labelWithString: L("Size"))
        sizeLabel.font = .systemFont(ofSize: 11)
        sizeLabel.frame = NSRect(x: 20, y: 54, width: 44, height: 16)
        let slider = NSSlider(value: Double(lens.pixels), minValue: Double(ScreenLens.sizes.lowerBound),
                              maxValue: Double(ScreenLens.sizes.upperBound), target: self, action: #selector(sizeChanged))
        slider.isContinuous = true
        slider.frame = NSRect(x: 64, y: 50, width: 136, height: 24)
        let value = NSTextField(labelWithString: "")
        value.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        value.textColor = .secondaryLabelColor
        value.frame = NSRect(x: 204, y: 54, width: 80, height: 16)
        sizeRow = [sizeLabel, slider, value]
        sizeRow.forEach { $0.isHidden = true }
        [mode, pad, note, status, button, clear, follow, sizeLabel, slider, value].forEach(root.addSubview)
        w.contentView = root
        w.center()
        window = w
        self.pad = pad
        self.note = note
        self.status = status
        self.button = button
        self.mode = mode
        self.erase = clear
        self.followBox = follow
        self.sizeSlider = slider
        self.sizeValue = value
        lens.onError = { [weak self] message in self?.lensFailed(message) }
        lens.onResize = { [weak self] _ in self?.showSize() }
        showSize()
    }

    @objc private func sizeChanged() {
        lens.pixels = Int(sizeSlider?.doubleValue ?? 240)
        showSize()
        lens.update()
    }

    /// The slider and its text: how much bigger the board shows it (1:1 at 240 screen pixels).
    private func showSize() {
        sizeSlider?.doubleValue = Double(lens.pixels)
        let zoom = Double(ScreenLens.n) / Double(lens.pixels)
        sizeValue?.stringValue = abs(zoom - 1) < 0.04 ? "1:1" : String(format: "×%.1f", zoom)
    }

    private static var drawNote: String {
        L("Move the mouse over the circle, or drag to draw. The board shows the same picture, drawn on this Mac.")
    }

    @objc private func modeChanged() {
        if screenMode {
            guard ScreenLens.permitted() else {
                lensFailed(ScreenLens.permissionText)
                return
            }
            lens.start()
            note?.stringValue = L("Drag the pink ring anywhere on the screen; scroll on it or use Size to resize it. What is inside it goes to the board.")
        } else {
            lens.stop()
            note?.stringValue = StreamTestWindow.drawNote
        }
        pad?.drawing = !screenMode
        erase?.isHidden = screenMode
        followBox?.isHidden = !screenMode
        sizeRow.forEach { $0.isHidden = !screenMode }
        if streaming { status?.stringValue = L("Streaming to the board") }
    }

    @objc private func followChanged() { lens.follow = followBox?.state == .on }

    /// Back to drawing, with the reason (no permission, screen not found, capture stopped).
    private func lensFailed(_ message: String) {
        lens.stop()
        mode?.selectedSegment = 0
        pad?.drawing = true
        erase?.isHidden = false
        followBox?.isHidden = true
        sizeRow.forEach { $0.isHidden = true }
        if streaming { status?.stringValue = L("Streaming to the board") }
        note?.stringValue = message
    }

    private func tick() {
        let now = CACurrentMediaTime()
        if now - since >= 1 {
            let fps = Double(frames) / (now - since), kbs = Double(bytes) / 1024 / (now - since)
            canvas.stats = streaming ? String(format: "%.0f fps · %.0f KB/s", fps, kbs) : "preview"
            frames = 0
            bytes = 0
            since = now
        }
        let frame: Data?
        if screenMode {
            lens.update()
            if let image = lens.preview() { pad?.image = image }
            frame = lens.rgb565()
            if streaming, !canvas.stats.isEmpty { status?.stringValue = L("Streaming to the board") + " · " + canvas.stats }
        } else {
            pad?.image = canvas.render(now)
            frame = canvas.rgb565()
        }
        guard streaming, !waiting, let frame else { return }
        waiting = true
        API.shared.postBytes("stream/frame", frame) { [weak self] ok, reply in
            guard let self else { return }
            self.waiting = false
            guard self.streaming else { return }
            if ok && (reply["streaming"] as? Bool) != false {
                self.frames += 1
                self.bytes += reply["bytes"] as? Int ?? 0
            } else {
                self.setStreaming(false, reply["message"] as? String)
            }
        }
    }

    private func setStreaming(_ on: Bool, _ message: String? = nil) {
        streaming = on
        button?.title = on ? L("Stop streaming") : L("Start streaming")
        status?.stringValue = message.flatMap { $0.isEmpty ? nil : $0 }
            ?? (on ? L("Streaming to the board") : L("Preview only: not streaming"))
        canvas.stats = on ? "…" : "preview"
        frames = 0
        bytes = 0
        since = CACurrentMediaTime()
    }

    @objc private func toggle() {
        if streaming {
            setStreaming(false)
            API.shared.postBytes("stream/stop", Data()) { _, _ in }
            return
        }
        button?.isEnabled = false
        status?.stringValue = L("Connecting to the board…")
        API.shared.postBytes("stream/start", Data()) { [weak self] ok, reply in
            self?.button?.isEnabled = true
            self?.setStreaming(ok, ok ? nil : (reply["message"] as? String ?? L("Could not reach the AI Face server.")))
        }
    }

    @objc private func clearPad() { canvas.clear() }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
        if screenMode { lensFailed(StreamTestWindow.drawNote) }
        if streaming {
            setStreaming(false)
            API.shared.postBytes("stream/stop", Data()) { _, _ in }
        }
    }
}
