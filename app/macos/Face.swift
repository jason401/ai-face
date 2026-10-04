// The face, drawn small: mirrors renderFace()/drawFace() in ESP32_Display.ino, with
// features a bit bigger and lines thicker so they read at menu bar size.
import Cocoa

// Frame fields, in the order /emotions sends them.
let FIELD_NAMES = ["move", "hold", "left", "right", "x", "y", "width", "smile", "open",
                   "brow", "lift", "eyes", "tilt", "fx", "color", "shake"]
enum F {
    static let move = 0, hold = 1, left = 2, right = 3, x = 4, y = 5, width = 6, smile = 7, open = 8
    static let brow = 9, lift = 10, eyes = 11, tilt = 12, fx = 13, color = 14, shake = 15
}
// Continuously interpolated fields, in pose order.
let CONT = [F.left, F.right, F.x, F.y, F.width, F.smile, F.open, F.brow, F.lift, F.tilt, F.shake]
enum P {
    static let left = 0, right = 1, x = 2, y = 3, width = 4, smile = 5, open = 6, brow = 7, lift = 8, tilt = 9, shake = 10
}
enum Eye {
    static let normal = 0, happy = 1, calm = 2, cross = 3, heart = 4, spiral = 5, star = 6, dot = 7, big = 8, squeeze = 9
}
let FX_BLUSH = 1, FX_TEAR = 2, FX_SWEAT = 4, FX_ZZZ = 8, FX_WAVE = 1024, FX_BULB = 2048, FX_PRAY = 4096
let PALETTE: [[Double]] = [[255, 255, 255], [255, 150, 190], [120, 180, 255], [255, 225, 90],
                           [255, 70, 60], [130, 220, 110], [190, 140, 255], [255, 160, 60]]
let TIMER_COLORS = ["white", "pink", "blue", "yellow", "red", "green", "purple", "orange"]

struct Frame {
    var v = [Int](repeating: 0, count: 16)
}

struct Pose {
    var v = [Double](repeating: 0, count: 11)
    var rgb: [Double] = [255, 255, 255]
    var eyes = 0
    var fx = 0
}

func poseOf(_ f: Frame) -> Pose {
    var p = Pose()
    for i in 0..<11 { p.v[i] = Double(f.v[CONT[i]]) }
    p.rgb = PALETTE[max(0, min(7, f.v[F.color]))]
    p.eyes = f.v[F.eyes]
    p.fx = f.v[F.fx]
    return p
}

// Monochrome style (설정 → 일반): every color becomes its gray (luminance), like the LCD.
var MONO = false

func rgb(_ r: Double, _ g: Double, _ b: Double) -> NSColor {
    if MONO {
        let y = (r * 77 + g * 150 + b * 29) / 256 / 255
        return NSColor(srgbRed: CGFloat(y), green: CGFloat(y), blue: CGFloat(y), alpha: 1)
    }
    return NSColor(srgbRed: CGFloat(r / 255), green: CGFloat(g / 255), blue: CGFloat(b / 255), alpha: 1)
}

func pt(_ x: Double, _ y: Double) -> NSPoint {
    return NSPoint(x: x, y: y)
}

func roundPath(_ path: NSBezierPath, _ width: Double) -> NSBezierPath {
    path.lineWidth = CGFloat(width)
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    return path
}

// The sleeping face, shown until the moods arrive from the server.
let SLEEPING_FRAME: Frame = {
    var f = Frame()
    f.v = [600, 2000, 0, 0, 0, 2, 40, 6, 0, 0, 0, 2, 0, 0, 0, 0]
    return f
}()

func framesOf(_ mood: [String: Any]) -> [Frame] {
    guard let list = mood["frames"] as? [[String: Any]] else { return [] }
    var out: [Frame] = []
    for item in list.prefix(24) {
        var f = Frame()
        for k in 0..<FIELD_NAMES.count {
            f.v[k] = (item[FIELD_NAMES[k]] as? NSNumber)?.intValue ?? 0
        }
        if f.v[F.move] < 1 { f.v[F.move] = 1 }
        out.append(f)
    }
    return out
}

/// Plays a mood's frames with the same timing as the LCD.
final class FaceAnimator {
    private(set) var emotion = ""
    private var frames: [Frame] = [SLEEPING_FRAME]
    private var index = 0
    private var from = poseOf(SLEEPING_FRAME)
    private(set) var pose = poseOf(SLEEPING_FRAME)
    private var started = Date.timeIntervalSinceReferenceDate

    func show(_ id: String, frames list: [Frame]) {
        guard id != emotion, !list.isEmpty else { return }
        emotion = id
        frames = list
        index = 0
        from = pose
        started = Date.timeIntervalSinceReferenceDate
    }

    func step(_ now: Double) {
        let f = frames[index]
        let dt = (now - started) * 1000
        var t = min(1.0, dt / Double(f.v[F.move]))
        t = t * t * (3 - 2 * t)
        let target = poseOf(f)
        for i in 0..<11 { pose.v[i] = from.v[i] + (target.v[i] - from.v[i]) * t }
        for i in 0..<3 { pose.rgb[i] = from.rgb[i] + (target.rgb[i] - from.rgb[i]) * t }
        pose.eyes = t < 0.5 ? from.eyes : target.eyes
        pose.fx = t < 0.5 ? from.fx : target.fx
        if dt >= Double(f.v[F.move] + f.v[F.hold]) {
            from = pose
            index = (index + 1) % frames.count
            started = now
        }
    }
}

// Draws one face in a 240x240 space (y down), like the LCD.
func drawFaceFeatures(_ p: Pose, _ now: Double) {
    let col = rgb(p.rgb[0], p.rgb[1], p.rgb[2])
    let sx = p.v[P.shake] * sin(now * 71.0), sy = p.v[P.shake] * 0.6 * cos(now * 93.0)
    let ey = 90 + p.v[P.y] + sy
    let ex = [80 + p.v[P.x] + sx, 160 + p.v[P.x] + sx]
    let LINE = 9.0

    if p.fx & FX_BLUSH != 0 {
        rgb(240, 100, 140).setFill()
        for e in 0..<2 {
            NSBezierPath(roundedRect: NSRect(x: ex[e] - 15, y: ey + 16, width: 30, height: 11), xRadius: 5, yRadius: 5).fill()
        }
    }
    for e in 0..<2 {
        let open = p.v[P.left + e], x = ex[e]
        col.setFill()
        col.setStroke()
        if p.eyes != Eye.normal && open < 20 {   // closed eye
            NSBezierPath(roundedRect: NSRect(x: x - 13, y: ey - 4, width: 26, height: 8), xRadius: 4, yRadius: 4).fill()
            continue
        }
        let path = roundPath(NSBezierPath(), LINE)
        switch p.eyes {
        case Eye.happy:   // ^
            path.move(to: pt(x - 12, ey + 5))
            path.curve(to: pt(x + 12, ey + 5), controlPoint1: pt(x - 8, ey - 9), controlPoint2: pt(x + 8, ey - 9))
            path.stroke()
        case Eye.calm:    // u
            path.move(to: pt(x - 12, ey - 4))
            path.curve(to: pt(x + 12, ey - 4), controlPoint1: pt(x - 8, ey + 10), controlPoint2: pt(x + 8, ey + 10))
            path.stroke()
        case Eye.cross:
            path.move(to: pt(x - 10, ey - 10)); path.line(to: pt(x + 10, ey + 10))
            path.move(to: pt(x + 10, ey - 10)); path.line(to: pt(x - 10, ey + 10))
            path.stroke()
        case Eye.heart:
            rgb(255, 70, 120).setFill()
            let h = NSBezierPath()
            h.move(to: pt(x, ey + 13))
            h.curve(to: pt(x, ey - 6), controlPoint1: pt(x - 20, ey), controlPoint2: pt(x - 12, ey - 18))
            h.curve(to: pt(x, ey + 13), controlPoint1: pt(x + 12, ey - 18), controlPoint2: pt(x + 20, ey))
            h.fill()
        case Eye.spiral:
            let rot = now * 5.5
            path.move(to: pt(x, ey))
            var a = 0.0
            while a < 12.5 {
                path.line(to: pt(x + cos(a + rot) * a * 1.05, ey + sin(a + rot) * a * 1.05))
                a += 0.3
            }
            path.lineWidth = 4
            path.stroke()
        case Eye.star:
            for k in 0..<10 {
                let a = -Double.pi / 2 + Double(k) * Double.pi / 5, r = (k % 2 == 1) ? 6.0 : 15.0
                let q = pt(x + cos(a) * r, ey + sin(a) * r)
                if k == 0 { path.move(to: q) } else { path.line(to: q) }
            }
            path.close()
            path.fill()
        case Eye.dot:
            NSBezierPath(ovalIn: NSRect(x: x - 6, y: ey - 6, width: 12, height: 12)).fill()
        case Eye.big:
            NSBezierPath(ovalIn: NSRect(x: x - 14, y: ey - 14, width: 28, height: 28)).fill()
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: x - 1, y: ey - 10, width: 9, height: 9)).fill()
        case Eye.squeeze:   // > <
            let d = e == 0 ? 1.0 : -1.0
            path.move(to: pt(x - 8 * d, ey - 9)); path.line(to: pt(x + 8 * d, ey)); path.line(to: pt(x - 8 * d, ey + 9))
            path.stroke()
        default:   // normal
            let h = max(3, 17 * open / 100)
            NSBezierPath(roundedRect: NSRect(x: x - 12, y: ey - h, width: 24, height: h * 2),
                         xRadius: CGFloat(min(11, h)), yRadius: CGFloat(min(11, h))).fill()
        }
    }
    col.setStroke()
    if p.v[P.lift] >= 0.5 {   // eyebrows
        let bY = ey - 18 - p.v[P.lift] * 1.5, d = p.v[P.brow] * 0.6
        for e in 0..<2 {
            let outer = e == 0 ? ex[e] - 12 : ex[e] + 12, inner = e == 0 ? ex[e] + 12 : ex[e] - 12
            let b = roundPath(NSBezierPath(), 7)
            b.move(to: pt(outer, bY + d)); b.line(to: pt(inner, bY - d))
            b.stroke()
        }
    }
    // Mouth: the LCD's curve (smile, tilt, opening), stroked thick.
    let w = max(6, p.v[P.width] / 2), mx = 120 + p.v[P.x] * 0.3 + sx
    var top: [NSPoint] = [], bottom: [NSPoint] = []
    for i in 0...24 {
        let u = -1 + Double(i) / 12.0, curve = 1 - u * u
        let y = 142 + sy + p.v[P.smile] * curve - p.v[P.tilt] * (u + 1) * 0.5, o = p.v[P.open] * curve
        top.append(pt(mx + u * w, y - o / 2))
        bottom.append(pt(mx + u * w, y + o / 2))
    }
    if p.v[P.open] >= 4 {   // filled open mouth: top edge forward, bottom edge back
        let fill = NSBezierPath()
        fill.move(to: top[0])
        for q in top.dropFirst() { fill.line(to: q) }
        for q in bottom.reversed() { fill.line(to: q) }
        fill.close()
        col.setFill()
        fill.fill()
    }
    let mouth = roundPath(NSBezierPath(), LINE)
    mouth.move(to: top[0])
    for q in top.dropFirst() { mouth.line(to: q) }
    mouth.stroke()
    if p.fx & FX_TEAR != 0 {
        rgb(90, 170, 255).setFill()
        let q = fmod(now / 1.5, 1.0)
        for e in 0..<2 {
            let tx = e == 1 ? ex[1] + 8 : ex[0] - 8
            NSBezierPath(ovalIn: NSRect(x: tx - 5, y: ey + 12 + q * 30, width: 10, height: 12)).fill()
        }
    }
    if p.fx & FX_SWEAT != 0 {
        rgb(90, 170, 255).setFill()
        NSBezierPath(ovalIn: NSRect(x: 178, y: 62 + fmod(now / 2.2, 1.0) * 10, width: 12, height: 15)).fill()
    }
}

func stroke(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double, _ width: Double) {
    let p = roundPath(NSBezierPath(), width)
    p.move(to: pt(x0, y0))
    p.line(to: pt(x1, y1))
    p.stroke()
}

/// Effects added with FACE8, in LCD coordinates: waving hand, light bulb, praying hands.
func drawExtraEffects(_ p: Pose, _ now: Double) {
    let col = rgb(p.rgb[0], p.rgb[1], p.rgb[2])
    if p.fx & FX_WAVE != 0 {
        col.setStroke(); col.setFill()
        let hx = 188.0, hy = 150.0, rock = 0.45 * sin(now * 1000 / 150)
        let spread = [-0.42, -0.14, 0.14, 0.42], len = [13.0, 15.0, 15.0, 13.0]
        for k in 0..<4 {
            let a = rock + spread[k]
            stroke(hx + sin(a) * 7, hy - cos(a) * 7, hx + sin(a) * (7 + len[k]), hy - cos(a) * (7 + len[k]), 6)
        }
        let ta = rock - 1.25
        stroke(hx + sin(ta) * 6, hy - cos(ta) * 6, hx + sin(ta) * 16, hy - cos(ta) * 16, 6)
        NSBezierPath(ovalIn: NSRect(x: hx - 10, y: hy - 10, width: 20, height: 20)).fill()
    }
    if p.fx & FX_BULB != 0 {
        let bx = 182.0, by = 52.0, glass = rgb(255, 225, 90)
        let pulse = 0.5 + 0.5 * sin(now * 1000 / 180)
        glass.setStroke(); glass.setFill()
        for k in 0..<5 {
            let a = Double(-60 + k * 30) * Double.pi / 180, r1 = 18 + 4 * pulse
            stroke(bx + sin(a) * 14, by - cos(a) * 14, bx + sin(a) * r1, by - cos(a) * r1, 4)
        }
        NSBezierPath(ovalIn: NSRect(x: bx - 11, y: by - 11, width: 22, height: 22)).fill()
        rgb(170, 170, 170).setFill()
        NSBezierPath.fill(NSRect(x: bx - 6, y: by + 8, width: 12, height: 8))
    }
    if p.fx & FX_PRAY != 0 {
        col.setStroke()
        let y = 2 * sin(now * 1000 / 260)
        stroke(110, 203 + y, 118, 180 + y, 12)
        stroke(130, 203 + y, 122, 180 + y, 12)
        NSColor.black.setStroke()
        stroke(120, 176 + y, 120, 210 + y, 2)
    }
}

func drawClockHands() {
    let c = Calendar.current.dateComponents([.hour, .minute], from: Date())
    let hour = Double((c.hour ?? 0) % 12), minute = Double(c.minute ?? 0)
    let ha = (hour + minute / 60) * Double.pi / 6, ma = minute * Double.pi / 30
    NSColor.white.setStroke()
    for k in 0..<12 {   // hour marks
        let a = Double(k) * Double.pi / 6
        let t = NSBezierPath()
        t.lineWidth = k % 3 == 0 ? 9 : 5
        t.move(to: pt(120 + sin(a) * 82, 120 - cos(a) * 82))
        t.line(to: pt(120 + sin(a) * 96, 120 - cos(a) * 96))
        t.stroke()
    }
    let h = roundPath(NSBezierPath(), 16)
    h.move(to: pt(120, 120)); h.line(to: pt(120 + sin(ha) * 50, 120 - cos(ha) * 50)); h.stroke()
    let m = roundPath(NSBezierPath(), 11)
    m.move(to: pt(120, 120)); m.line(to: pt(120 + sin(ma) * 76, 120 - cos(ma) * 76)); m.stroke()
    rgb(255, 70, 60).setFill()
    NSBezierPath(ovalIn: NSRect(x: 110, y: 110, width: 20, height: 20)).fill()
}

// Mini campfire: the board's pixel-art fire on a 20x20 grid (12x12 cells in 240 space).
final class Campfire {
    static let G = 20, H = 15, MAXH = 36
    static let PAL: [[Double]] = [[110, 16, 16], [160, 28, 12], [206, 52, 12], [238, 90, 16], [250, 130, 24],
                                  [255, 168, 40], [255, 206, 70], [255, 236, 140], [255, 250, 214]]
    private var heat = [Int](repeating: 0, count: Campfire.H * Campfire.G)
    private var log = [Int](repeating: 0, count: Campfire.G * Campfire.G)   // 0 none, 2 bark, 3 cut end
    private var rng: UInt32 = 0x9E37_79B9

    init() {
        logLine(5, 17, 14, 14)
        logLine(6, 14, 15, 17)
    }

    private func rand() -> UInt32 {
        rng ^= rng << 13
        rng ^= rng >> 17
        rng ^= rng << 5
        return rng
    }

    private func logLine(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) {
        let G = Campfire.G
        for cy in 0..<G {
            for cx in 0..<G {
                let dx = x1 - x0, dy = y1 - y0, l = dx * dx + dy * dy
                let t = max(0.0, min(1.0, ((Double(cx) - x0) * dx + (Double(cy) - y0) * dy) / l))
                let ex = x0 + t * dx - Double(cx), ey = y0 + t * dy - Double(cy)
                if (ex * ex + ey * ey).squareRoot() <= 0.7 { log[cy * G + cx] = (t <= 0 || t >= 1) ? 3 : 2 }
            }
        }
    }

    func step() {
        let G = Campfire.G, H = Campfire.H, M = Campfire.MAXH
        for x in 0..<G {   // fuel row: hottest in the middle, flickering
            let d = abs(Double(x) - 9.5) / 4.2
            var h = 0
            if d < 1 {
                h = Int(Double(M) * (1 - 0.35 * d * d)) - Int(rand() % 9) + ((rand() & 15) == 0 ? 6 : 0)
            }
            heat[(H - 1) * G + x] = max(0, min(M, h))
        }
        // Heat rises with a random sideways drift, cools, and is squeezed toward the middle.
        for y in 1..<H {
            for x in 0..<G {
                let p = heat[y * G + x]
                let r = rand()
                let nx = max(0, min(G - 1, x + Int(r % 3) - 1))
                let half = 1 + (y * 4) / H, off = abs(nx * 2 - 19) / 2
                var cool = 1 + Int((r >> 3) & 1)
                if off > half { cool += 1 + Int((r >> 5) & 1) }
                if y < 5 && (r >> 7) % 3 == 0 { cool += 1 }
                let h = max(0, p - cool)
                let i = (y - 1) * G + nx
                heat[i] = (h * 3 + heat[i]) / 4
            }
        }
    }

    func warmUp() {
        for _ in 0..<20 { step() }
    }

    func draw() {
        let G = Campfire.G, H = Campfire.H, M = Campfire.MAXH
        for cy in 0..<G {
            for cx in 0..<G {
                let c: NSColor
                let h = cy < H ? heat[cy * G + cx] : 0
                if log[cy * G + cx] == 2 {
                    c = rgb(104, 58, 30)
                } else if log[cy * G + cx] == 3 {
                    c = rgb(214, 160, 98)
                } else if h >= 5 {
                    let f = Campfire.PAL[min(8, (h - 5) * 9 / (M - 4))]
                    c = rgb(f[0], f[1], f[2])
                } else if cy < 15 {   // night sky
                    c = rgb(Double(10 + cy), Double(12 + cy / 2), Double(30 + cy))
                } else {   // ground lit by the fire
                    let a = (Double(cx) - 9.5) / 8, b = (Double(cy) - 15.5) / 3
                    let g = max(0.0, 1 - a * a - b * b) * 0.6
                    c = rgb(34 + (150 - 34) * g, 22 + (70 - 22) * g, 18 + (24 - 18) * g)
                }
                c.setFill()
                NSBezierPath.fill(NSRect(x: Double(cx * 12), y: Double(cy * 12), width: 12.4, height: 12.4))
            }
        }
    }
}

/// What the face shows right now, from the server's /view.
struct FaceView {
    var kind = "face"            // face / clock / fire / photo
    var photo: NSImage? = nil    // the picture for "photo" (a board photo, 240x240)
    var clockOnPhoto = false     // clock hands drawn over the photo
    var mono = false             // monochrome style: grays, owner shown by the ring pattern
    var owner = "user"           // user / claude / gpt: ring color
    var timerEnd = 0.0           // seconds since the reference date; 0 = no timer
    var timerTotal = 1.0
    var timerColor = 2
}

/// Monochrome ring patterns (same as the LCD): app solid, Claude short dashes, GPT six arcs.
/// Lengths are along the ring (radius 110 in 240 space: about 1.92 per degree).
func ownerDash(_ owner: String) -> [CGFloat]? {
    switch owner {
    case "claude": return [19.2, 11.5]
    case "gpt": return [96, 19.2]
    default: return nil
    }
}

func ownerColor(_ owner: String) -> NSColor {
    switch owner {
    case "claude": return rgb(0xD9, 0x77, 0x57)
    case "gpt": return rgb(0x10, 0xA3, 0x7F)
    default: return rgb(255, 255, 255)
    }
}

/// The round face as an image of `side` points (the circle fills it but `inset` on each side).
/// `offset` moves everything (in points): the little bounce or shake when the face changes.
func renderFace(side: CGFloat, inset: CGFloat, view v: FaceView, pose p: Pose, fire: Campfire, now: Double,
                offset: NSPoint = .zero) -> NSImage {
    let d = side - inset * 2
    let img = NSImage(size: NSSize(width: side, height: side), flipped: true) { _ in
        MONO = v.mono
        defer { MONO = false }
        let tf = NSAffineTransform()
        tf.translateX(by: inset + offset.x, yBy: inset + offset.y)
        tf.scale(by: d / 240.0)
        tf.concat()
        NSColor.black.setFill()
        NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: 240, height: 240)).fill()
        let isClock = v.kind == "clock", isFire = v.kind == "fire", isPhoto = v.kind == "photo" && v.photo != nil
        if isPhoto, let photo = v.photo {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: 240, height: 240)).addClip()
            // Flipped context: draw the picture upright.
            photo.draw(in: NSRect(x: 0, y: 0, width: 240, height: 240), from: .zero, operation: .sourceOver,
                       fraction: 1, respectFlipped: true, hints: nil)
            if v.mono {   // saturation from white = grays only
                NSColor.white.setFill()
                NSRect(x: 0, y: 0, width: 240, height: 240).fill(using: .saturation)
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        if isFire {   // clipped to the circle, under the ring
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: 240, height: 240)).addClip()
            fire.draw()
            NSGraphicsContext.restoreGraphicsState()
        }
        NSGraphicsContext.saveGraphicsState()
        if isClock || (isPhoto && v.clockOnPhoto) {
            drawClockHands()
        } else if !isFire && !isPhoto {
            // Features larger than on the LCD (about the face center) so they read small.
            let zoom = NSAffineTransform()
            zoom.translateX(by: 120, yBy: 118)
            zoom.scale(by: 1.3)
            zoom.translateX(by: -120, yBy: -118)
            zoom.concat()
            drawFaceFeatures(p, now)
        }
        NSGraphicsContext.restoreGraphicsState()
        if !isClock && !isFire && !isPhoto { drawExtraEffects(p, now) }
        // Border ring: who chose the face, or the timer.
        let RW = 20.0
        let circle = NSBezierPath(ovalIn: NSRect(x: RW / 2, y: RW / 2, width: 240 - RW, height: 240 - RW))
        circle.lineWidth = CGFloat(RW)
        if v.timerEnd > 0 {
            let left = max(0, v.timerEnd - now), frac = left / max(1, v.timerTotal)
            let c = v.mono ? PALETTE[0] : PALETTE[max(0, min(7, v.timerColor))]
            rgb(c[0] / 4, c[1] / 4, c[2] / 4).setStroke()
            circle.stroke()
            if left > 0 || fmod(now, 0.8) < 0.4 {   // blink when time is up
                let arc = NSBezierPath()
                // Remaining part, ending at 12 o'clock (y is down: angles run clockwise).
                arc.appendArc(withCenter: pt(120, 120), radius: CGFloat(120 - RW / 2),
                              startAngle: CGFloat(-90 - 360 * (left > 0 ? frac : 1)), endAngle: -90, clockwise: false)
                arc.lineWidth = CGFloat(RW)
                rgb(c[0], c[1], c[2]).setStroke()
                arc.stroke()
            }
        } else if v.mono {
            NSColor.white.setStroke()
            if let dash = ownerDash(v.owner) { circle.setLineDash(dash, count: dash.count, phase: 0) }
            circle.stroke()
        } else {
            ownerColor(v.owner).setStroke()
            circle.stroke()
        }
        return true
    }
    img.isTemplate = false   // keep the colors
    return img
}
