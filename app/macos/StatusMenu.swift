// The menu bar face and its menu (like RunCat: click the icon, a short menu with a
// bigger face on top, quick actions, 설정…, 종료).
import Cocoa

/// Top of the menu: a bigger animated face, the mood name and who chose it.
final class MenuHeader: NSView {
    let face = NSImageView(frame: NSRect(x: 14, y: 10, width: 64, height: 64))
    let title = NSTextField(labelWithString: "")
    let detail = NSTextField(labelWithString: "")
    let extra = NSTextField(labelWithString: "")

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: 84))
        face.imageScaling = .scaleProportionallyUpOrDown
        addSubview(face)
        title.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        detail.font = NSFont.systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        extra.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        extra.textColor = .secondaryLabelColor
        title.frame = NSRect(x: 90, y: 50, width: 180, height: 20)
        detail.frame = NSRect(x: 90, y: 31, width: 180, height: 16)
        extra.frame = NSRect(x: 90, y: 13, width: 180, height: 16)
        for label in [title, detail, extra] {
            label.lineBreakMode = .byTruncatingTail
            addSubview(label)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("not used")
    }
}

final class StatusController: NSObject, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let animator = FaceAnimator()
    let fire = Campfire()
    var view = FaceView()
    var name = L("Starting…")
    var board = false
    var moods: [String: [String: Any]] = [:]
    var moodList: [[String: Any]] = []
    var recent: [String] = []            // moods picked by hand, newest first (menu "Recent")
    var openSettings: (() -> Void)?
    private var icons: [String: NSImage] = [:]

    private let menu = NSMenu()
    private let header = MenuHeader()
    private let headerItem = NSMenuItem()
    private var menuOpen = false
    private var polling = false
    private var drawTimer: Timer?
    private var pollTimer: Timer?
    // The photo shown by a photo saver (or picked by hand): board photo id + file version.
    private var photoKey = ""
    private var photoLoading = ""
    // A little jump (or a shiver for upset moods) when the face changes.
    private var lastChange = ""
    private var bounceStart = 0.0
    private var bounceShake = false
    static let SHAKE_MOODS: Set<String> = ["angry", "furious", "annoyed", "disgusted", "jealous", "shocked",
                                          "terrified", "afraid", "cold", "cringe", "nervous", "sick", "dizzy"]

    override init() {
        super.init()
        item.button?.toolTip = "AI Face"
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        headerItem.view = header
        rebuildMenu()
        // .common: keep animating while the menu is open (event tracking run loop mode).
        let draw = Timer(timeInterval: 1.0 / 12, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        draw.tolerance = 0.02
        RunLoop.main.add(draw, forMode: .common)
        drawTimer = draw
        tick()
    }

    func start() {
        poll()
        let t = Timer(timeInterval: 1.0, target: self, selector: #selector(poll), userInfo: nil, repeats: true)
        t.tolerance = 0.2
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
    }

    // MARK: - Data from the server

    @objc func poll() {
        if polling || !API.shared.ready { return }
        polling = true
        if moods.isEmpty {
            API.shared.getJSON("emotions") { [weak self] json in
                guard let self = self, let list = json as? [[String: Any]] else { return }
                var map: [String: [String: Any]] = [:]
                for mood in list {
                    if let id = mood["id"] as? String { map[id] = mood }
                }
                self.moods = map
                self.moodList = list
                self.icons = [:]
                self.loadRecent()
                self.rebuildMenu()
                self.applyEmotion(self.pendingEmotion)
            }
        }
        API.shared.getJSON("view") { [weak self] json in
            guard let self = self else { return }
            self.polling = false
            if let v = json as? [String: Any] { self.apply(v) }
        }
    }

    private var pendingEmotion = ""

    private func loadRecent() {
        API.shared.getJSON("recent") { [weak self] json in
            guard let self = self, let list = json as? [String] else { return }
            self.recent = list
        }
    }

    /// A small still of the mood for its menu item: its most telling frame, like the preview sheet.
    private func icon(_ mood: [String: Any]) -> NSImage? {
        guard let id = mood["id"] as? String else { return nil }
        let key = id + (view.mono ? "|mono" : "")
        if let cached = icons[key] { return cached }
        let frames = framesOf(mood)
        guard !frames.isEmpty else { return nil }
        func score(_ f: Frame) -> Int {
            return (f.v[F.fx] != 0 ? 2 : 0) + (f.v[F.eyes] != 0 ? 1 : 0) + (f.v[F.left] > 30 ? 1 : 0)
        }
        var best = frames[0]
        for f in frames where score(f) > score(best) { best = f }
        var still = FaceView()
        still.mono = view.mono
        let image = renderFace(side: 18, inset: 0, view: still, pose: poseOf(best), fire: fire, now: 0)
        icons[key] = image
        return image
    }

    private func applyEmotion(_ id: String) {
        pendingEmotion = id
        guard !id.isEmpty, let mood = moods[id] else { return }
        animator.show(id, frames: framesOf(mood))
    }

    func apply(_ v: [String: Any]) {
        let kind = (v["kind"] as? String) ?? "face"
        if kind == "fire" && view.kind != "fire" { fire.warmUp() }   // flames already up
        view.kind = kind
        view.owner = (v["owner"] as? String) ?? "user"
        if let e = v["emotion"] as? String, !e.isEmpty { applyEmotion(e) }
        let now = Date.timeIntervalSinceReferenceDate
        if let t = v["timer"] as? [String: Any] {
            view.timerEnd = now + ((t["left"] as? NSNumber)?.doubleValue ?? 0)
            view.timerTotal = max(1, (t["total"] as? NSNumber)?.doubleValue ?? 1)
            view.timerColor = TIMER_COLORS.firstIndex(of: (t["color"] as? String) ?? "blue") ?? 2
        } else {
            view.timerEnd = 0
        }
        view.mono = (v["mono"] as? Bool) ?? false
        view.clockOnPhoto = (v["clock"] as? Bool) ?? false
        if kind == "photo" {
            let id = (v["photo"] as? NSNumber)?.intValue ?? -1
            let version = (v["photo_v"] as? NSNumber)?.intValue ?? 0
            loadPhoto(id, key: "\(id)-\(version)")
        }
        let emotion = (v["emotion"] as? String) ?? ""
        let change = "\(kind)|\(emotion)|\(view.owner)"
        if !lastChange.isEmpty && change != lastChange {
            bounceStart = now
            bounceShake = StatusController.SHAKE_MOODS.contains(emotion)
            if view.owner == "user" { loadRecent() }
        }
        lastChange = change
        name = (v["name"] as? String) ?? ""
        board = (v["board"] as? Bool) ?? false
        item.button?.toolTip = "AI Face · \(name) · \(ownerName(view.owner))"
    }

    private func loadPhoto(_ id: Int, key: String) {
        guard id >= 0, key != photoKey, key != photoLoading else { return }
        photoLoading = key
        API.shared.get("photo/\(id)?v=\(key)", timeout: 10) { [weak self] data in
            guard let self = self else { return }
            self.photoLoading = ""
            guard let data = data, let text = String(data: data, encoding: .utf8),
                  let bytes = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
                  let image = imageFromBoardPhoto(bytes) else { return }
            self.photoKey = key
            self.view.photo = image
        }
    }

    /// Offset for the change animation: a hop up, or a short shiver.
    private func bounce(_ now: Double) -> NSPoint {
        let t = now - bounceStart
        guard t >= 0 && t < 0.7 else { return .zero }
        let decay = 1 - t / 0.7
        if bounceShake { return NSPoint(x: 1.6 * sin(t * 55) * decay, y: 0) }
        return NSPoint(x: 0, y: -3 * abs(sin(t * Double.pi * 2.6)) * decay)
    }

    func ownerName(_ owner: String) -> String {
        switch owner {
        case "claude": return L("Chosen by Claude")
        case "gpt": return L("Chosen by GPT")
        default: return L("Chosen by you")
        }
    }

    // MARK: - Drawing

    @objc func tick() {
        let now = Date.timeIntervalSinceReferenceDate
        animator.step(now)
        if view.kind == "fire" { fire.step() }
        let side = NSStatusBar.system.thickness
        item.button?.image = renderFace(side: side, inset: 2, view: view, pose: animator.pose, fire: fire, now: now,
                                        offset: bounce(now))
        if menuOpen { updateHeader(now) }
    }

    func timerText(_ now: Double) -> String? {
        guard view.timerEnd > 0 else { return nil }
        let left = Int((view.timerEnd - now).rounded(.up))
        if left <= 0 { return L("⏰ Time's up!") }
        let h = left / 3600, m = left % 3600 / 60, s = left % 60
        return h > 0 ? String(format: L("⏱ %ld:%02ld:%02ld left"), h, m, s) : String(format: L("⏱ %ld:%02ld left"), m, s)
    }

    private func updateHeader(_ now: Double) {
        header.face.image = renderFace(side: 64, inset: 1, view: view, pose: animator.pose, fire: fire, now: now,
                                       offset: bounce(now))
        header.title.stringValue = name.isEmpty ? "AI Face" : name
        header.detail.stringValue = view.kind == "face" ? ownerName(view.owner) : (board ? L("Showing on the board") : L("Showing in the menu bar"))
        header.extra.stringValue = timerText(now) ?? (board ? L("● Board connected") : L("○ No board"))
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === self.menu { rebuildMenu() }
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        menuOpen = true
        updateHeader(Date.timeIntervalSinceReferenceDate)
    }

    func menuDidClose(_ menu: NSMenu) {
        if menu === self.menu { menuOpen = false }
    }

    private func add(_ menu: NSMenu, _ title: String, _ action: Selector?, key: String = "", object: Any? = nil) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
        it.target = self
        it.representedObject = object
        menu.addItem(it)
        return it
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        menu.addItem(headerItem)
        menu.addItem(.separator())

        if view.timerEnd > 0 {
            _ = add(menu, L("Cancel timer"), #selector(cancelTimer))
        }
        let timer = add(menu, L("Timer"), nil)
        let timerMenu = NSMenu()
        timerMenu.autoenablesItems = false
        for minutes in [5, 25, 50] {
            _ = add(timerMenu, minutesText(minutes), #selector(startTimer(_:)), object: minutes)
        }
        timerMenu.addItem(.separator())
        _ = add(timerMenu, L("Custom…"), #selector(customTimer))
        timer.submenu = timerMenu
        _ = add(menu, L("Light the campfire"), #selector(campfire))
        _ = add(menu, L("Show the clock"), #selector(clock))

        if !moodList.isEmpty {
            let faces = add(menu, L("Faces"), nil)
            let groups = NSMenu()
            groups.autoenablesItems = false
            let picks = recent.compactMap { moods[$0] }
            if !picks.isEmpty {
                let title = add(groups, L("Recent"), nil)
                title.isEnabled = false
                for mood in picks { moodItem(groups, mood) }
                groups.addItem(.separator())
            }
            var order: [String] = []
            var byGroup: [String: [[String: Any]]] = [:]
            for mood in moodList {
                guard mood["id"] is String else { continue }
                let g = (mood["group"] as? String) ?? L("Other")
                if byGroup[g] == nil { order.append(g); byGroup[g] = [] }
                byGroup[g]?.append(mood)
            }
            for g in order {
                let groupItem = add(groups, g, nil)
                let list = NSMenu()
                list.autoenablesItems = false
                for mood in byGroup[g] ?? [] { moodItem(list, mood) }
                groupItem.submenu = list
            }
            faces.submenu = groups
        }
        menu.addItem(.separator())
        _ = add(menu, L("Settings…"), #selector(settings), key: ",")
        _ = add(menu, L("Quit AI Face"), #selector(quit), key: "q")
    }

    private func moodItem(_ list: NSMenu, _ mood: [String: Any]) {
        let it = add(list, (mood["name"] as? String) ?? "", #selector(chooseMood(_:)), object: mood["id"])
        it.image = icon(mood)
        it.toolTip = mood["description"] as? String
        if view.kind == "face" && (mood["id"] as? String) == animator.emotion { it.state = .on }
    }

    private func report(_ ok: Bool, _ reply: [String: Any]) {
        if !ok {
            let alert = NSAlert()
            alert.messageText = "AI Face"
            alert.informativeText = (reply["message"] as? String) ?? L("That didn't work.")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
        poll()
    }

    @objc func startTimer(_ sender: NSMenuItem) {
        let minutes = (sender.representedObject as? Int) ?? 25
        API.shared.call("timer", ["seconds": minutes * 60]) { [weak self] ok, reply in self?.report(ok, reply) }
    }

    @objc func customTimer() {
        let alert = NSAlert()
        alert.messageText = L("Timer")
        alert.informativeText = L("How many minutes? (1–1440)")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        field.stringValue = "15"
        alert.accessoryView = field
        alert.addButton(withTitle: L("Start"))
        alert.addButton(withTitle: L("Cancel"))
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard let minutes = Double(text), minutes > 0, minutes <= 1440 else {
            report(false, ["message": L("Enter 1 to 1440 minutes.")])
            return
        }
        API.shared.call("timer", ["seconds": Int((minutes * 60).rounded())]) { [weak self] ok, reply in self?.report(ok, reply) }
    }

    @objc func cancelTimer() {
        API.shared.call("timer", ["seconds": 0]) { [weak self] ok, reply in self?.report(ok, reply) }
    }

    @objc func campfire() {
        API.shared.call("mode", ["mode": "FIRE"]) { [weak self] ok, reply in self?.report(ok, reply) }
    }

    @objc func clock() {
        API.shared.call("mode", ["mode": "CLOCK"]) { [weak self] ok, reply in self?.report(ok, reply) }
    }

    @objc func chooseMood(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        API.shared.call("emotion", ["id": id]) { [weak self] ok, reply in self?.report(ok, reply) }
    }

    @objc func settings() {
        openSettings?()
    }

    @objc func quit() {
        NSApp.terminate(nil)
    }
}
