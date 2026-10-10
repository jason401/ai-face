// The settings window: toolbar tabs (일반 · 대기 화면 · 사진 · AI 연결 · 보드), each a
// SwiftUI form, like the settings of RunCat and other menu bar apps.
import Cocoa
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

struct Choice<T: Hashable>: Hashable {
    let value: T
    let label: String
}

let SAVER_TYPES: [Choice<String>] = [
    Choice(value: "sleep", label: L("Sleepy face → asleep")),
    Choice(value: "clock", label: L("Clock")),
    Choice(value: "photo", label: L("Photos")),
    Choice(value: "slideshow", label: L("Photo slideshow")),
    Choice(value: "fire", label: L("Pixel campfire")),
    Choice(value: "off", label: L("Off")),
]
let SLIDE_CHOICES: [Choice<Int>] = [
    Choice(value: 10, label: secondsText(10)), Choice(value: 30, label: secondsText(30)), Choice(value: 60, label: minutesText(1)),
    Choice(value: 300, label: minutesText(5)), Choice(value: 900, label: minutesText(15)),
]

func minutesText(_ m: Int) -> String {
    if m >= 60 && m % 60 == 0 { return String(format: L("%d h"), m / 60) }
    if m > 60 { return String(format: L("%d h %d min"), m / 60, m % 60) }
    return String(format: L("%d min"), m)
}

func secondsText(_ s: Int) -> String {
    return String(format: L("%d s"), s)
}

struct OwnerStats: Equatable {
    var count = 0
    var top: [String] = []            // "행복 ×3"
    var groups: [String: Int] = [:]   // emotion group -> count
}

struct TimelineEvent: Identifiable, Equatable {
    let id: Int
    let t: Double                     // seconds since 1970
    let owner: String
    let name: String
}

struct WeekRow: Identifiable, Equatable {
    let id: String                    // yyyy-MM-dd
    let label: String                 // weekday
    let counts: [String: Int]         // owner -> changes
}

let OWNERS = ["claude", "gpt", "user"]
let OWNER_LABEL = ["claude": "Claude", "gpt": "GPT", "user": L("You")]
let OWNER_COLOR: [String: Color] = [
    "claude": Color(red: 0xD9 / 255.0, green: 0x77 / 255.0, blue: 0x57 / 255.0),
    "gpt": Color(red: 0x10 / 255.0, green: 0xA3 / 255.0, blue: 0x7F / 255.0),
    "user": Color.gray,
]
// Emotion groups by id (from the server), with their names and colors.
let GROUP_ORDER = ["joy", "love", "wonder", "work", "stance", "oops", "rest", "sad", "tense", "angry", "body"]
let GROUP_LABEL: [String: String] = [
    "joy": L("Joy"), "love": L("Love & bond"), "wonder": L("Surprise & interest"), "work": L("Working"),
    "stance": L("Stance"), "oops": L("Oops"), "rest": L("Calm & rest"), "sad": L("Sadness"),
    "tense": L("Anxiety & tension"), "angry": L("Anger & dislike"), "body": L("Body"), "other": L("Other"),
]
let GROUP_COLOR: [String: Color] = [
    "joy": .yellow, "love": .pink, "wonder": .orange, "work": .blue, "stance": .teal, "oops": .brown,
    "rest": .mint, "sad": .indigo, "tense": .purple, "angry": .red, "body": .green,
]

struct LibraryItem: Identifiable, Hashable {
    let name: String
    let mtime: Int
    var id: String { return "\(name)|\(mtime)" }
}

// MARK: - State shared by the tabs

final class SettingsStore: NSObject, ObservableObject {
    // Board
    @Published var connected = false
    @Published var port = ""
    @Published var ports: [String] = []
    @Published var message = ""
    @Published var flashing = false
    @Published var firmwareBusy = false
    @Published var firmwareLog = ""
    @Published var photos: [Int] = []
    @Published var currentPhoto = -1
    @Published var boardThumbs: [Int: NSImage] = [:]
    // Screen saver (loaded once per window opening, then edited here)
    @Published var saverAfter = 10
    @Published var saverType = "sleep"
    @Published var saverClock = false
    @Published var saverSlide = 60
    // Photo library
    @Published var library: [LibraryItem] = []
    @Published var thumbs: [String: NSImage] = [:]
    @Published var sending = ""
    @Published var dropping = false   // a picture is dragged over the library
    @Published var notice = ""
    // AI apps
    @Published var claude = "off"
    @Published var codex = "off"
    @Published var codexAvailable = false
    @Published var serverPath = ""
    @Published var aiNotice = ""
    // General
    @Published var loginItem = false
    @Published var mono = false
    @Published var version = ""
    // Keep awake (lid closed)
    @Published var awakeSupported = false
    @Published var awakeReady = false
    @Published var awakeOn = false
    @Published var awakeLeft = 0
    // Expression history (기록 tab)
    @Published var historyDay = Calendar.current.startOfDay(for: Date())
    @Published var dayTotal = 0
    @Published var dayStats: [String: OwnerStats] = [:]
    @Published var timeline: [TimelineEvent] = []
    @Published var week: [WeekRow] = []
    private var historyKey = ""
    private var weekKey = ""

    private var saverLoaded = false
    private var timer: Timer?
    private var boardThumbKey = ""
    private var libraryKey = ""

    var afterChoices: [Int] {
        var list = [1, 2, 3, 5, 10, 15, 20, 30, 45, 60, 90, 120, 180]
        if !list.contains(saverAfter) { list.append(saverAfter); list.sort() }
        return list
    }

    var slideChoices: [Choice<Int>] {
        if SLIDE_CHOICES.contains(where: { $0.value == saverSlide }) { return SLIDE_CHOICES }
        return SLIDE_CHOICES + [Choice(value: saverSlide, label: secondsText(saverSlide))]
    }

    func start() {
        saverLoaded = false
        loginItem = LoginItem.enabled
        refresh()
        refreshAI()
        if timer == nil {
            let t = Timer(timeInterval: 2, target: self, selector: #selector(tickTimer), userInfo: nil, repeats: true)
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    @objc private func tickTimer() {
        refresh()
    }

    func refresh() {
        loadHistory()
        API.shared.getJSON("status") { [weak self] json in
            guard let self = self, let s = json as? [String: Any] else { return }
            self.connected = (s["connected"] as? Bool) ?? false
            self.port = (s["port"] as? String) ?? ""
            self.ports = (s["ports"] as? [String]) ?? []
            self.message = (s["message"] as? String) ?? ""
            self.flashing = (s["flashing"] as? Bool) ?? false
            self.version = (s["version"] as? String) ?? ""
            self.mono = (s["mono"] as? Bool) ?? false
            if let a = s["awake"] as? [String: Any] {
                self.awakeSupported = (a["supported"] as? Bool) ?? false
                self.awakeReady = (a["ready"] as? Bool) ?? false
                self.awakeOn = (a["on"] as? Bool) ?? false
                self.awakeLeft = (a["left"] as? NSNumber)?.intValue ?? 0
            }
            let photos = ((s["photos"] as? [NSNumber]) ?? []).map { $0.intValue }
            let current = (s["current_photo"] as? NSNumber)?.intValue ?? -1
            if photos != self.photos { self.photos = photos }
            if current != self.currentPhoto { self.currentPhoto = current }
            if !self.saverLoaded, let saver = s["saver"] as? [String: Any] {
                self.saverLoaded = true
                self.saverAfter = (saver["after"] as? NSNumber)?.intValue ?? 10
                self.saverType = (saver["type"] as? String) ?? "sleep"
                self.saverClock = (saver["clock"] as? Bool) ?? false
                self.saverSlide = (saver["slide"] as? NSNumber)?.intValue ?? 60
            }
            self.loadBoardThumbs()
        }
        API.shared.getJSON("library") { [weak self] json in
            guard let self = self, let list = json as? [[String: Any]] else { return }
            let items = list.compactMap { d -> LibraryItem? in
                guard let name = d["name"] as? String else { return nil }
                return LibraryItem(name: name, mtime: (d["mtime"] as? NSNumber)?.intValue ?? 0)
            }
            let key = items.map { $0.id }.joined(separator: "\n")
            if key != self.libraryKey {
                self.libraryKey = key
                self.library = items
                self.loadThumbs()
            }
        }
    }

    // MARK: History

    static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    var historyDayText: String {
        let f = DateFormatter()
        f.locale = APP_LOCALE
        f.setLocalizedDateFormatFromTemplate("MMMdE")
        return f.string(from: historyDay)
    }

    var isToday: Bool { return Calendar.current.isDateInToday(historyDay) }

    func moveDay(_ days: Int) {
        let next = Calendar.current.date(byAdding: .day, value: days, to: historyDay) ?? historyDay
        if next > Date() { return }
        historyDay = Calendar.current.startOfDay(for: next)
        historyKey = ""
        weekKey = ""
        loadHistory()
    }

    func clearHistory() {
        let alert = NSAlert()
        alert.messageText = L("Delete all history?")
        alert.informativeText = L("Every recorded face change, from all days, is deleted from this Mac. This cannot be undone.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("Delete"))
        alert.addButton(withTitle: L("Cancel"))
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        API.shared.call("history_clear") { [weak self] _, _ in
            guard let self = self else { return }
            self.historyKey = ""
            self.weekKey = ""
            self.loadHistory()
        }
    }

    func goToday() {
        historyDay = Calendar.current.startOfDay(for: Date())
        historyKey = ""
        weekKey = ""
        loadHistory()
    }

    func loadHistory() {
        let day = SettingsStore.dayFormat.string(from: historyDay)
        API.shared.get("history?day=" + day) { [weak self] data in
            guard let self = self, let data = data else { return }
            let key = String(decoding: data, as: UTF8.self)
            if key == self.historyKey { return }
            self.historyKey = key
            guard let s = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any] else { return }
            self.dayTotal = (s["total"] as? NSNumber)?.intValue ?? 0
            var stats: [String: OwnerStats] = [:]
            let owners = (s["owners"] as? [String: Any]) ?? [:]
            for owner in OWNERS {
                let o = (owners[owner] as? [String: Any]) ?? [:]
                var st = OwnerStats()
                st.count = (o["count"] as? NSNumber)?.intValue ?? 0
                st.top = ((o["top"] as? [[String: Any]]) ?? []).map { item in
                    "\((item["name"] as? String) ?? "") ×\((item["count"] as? NSNumber)?.intValue ?? 0)"
                }
                for (g, n) in (o["groups"] as? [String: Any]) ?? [:] {
                    st.groups[g] = (n as? NSNumber)?.intValue ?? 0
                }
                stats[owner] = st
            }
            self.dayStats = stats
            let events = (s["timeline"] as? [[String: Any]]) ?? []
            self.timeline = events.enumerated().map { pair in
                let e = pair.element
                return TimelineEvent(id: pair.offset, t: (e["t"] as? NSNumber)?.doubleValue ?? 0,
                                     owner: (e["owner"] as? String) ?? "user", name: (e["name"] as? String) ?? "")
            }
        }
        API.shared.get("history/week?day=" + day) { [weak self] data in
            guard let self = self, let data = data else { return }
            let key = String(decoding: data, as: UTF8.self)
            if key == self.weekKey { return }
            self.weekKey = key
            let rows = ((try? JSONSerialization.jsonObject(with: data, options: [])) as? [[String: Any]]) ?? []
            let weekday = DateFormatter()
            weekday.locale = APP_LOCALE
            weekday.dateFormat = "E"
            self.week = rows.map { r in
                let d = (r["day"] as? String) ?? ""
                var counts: [String: Int] = [:]
                for owner in OWNERS { counts[owner] = (r[owner] as? NSNumber)?.intValue ?? 0 }
                let label = SettingsStore.dayFormat.date(from: d).map { weekday.string(from: $0) } ?? d
                return WeekRow(id: d, label: label, counts: counts)
            }
        }
    }

    // MARK: Screen saver

    func saveSaver() {
        let saver: [String: Any] = ["after": saverAfter, "type": saverType, "clock": saverClock, "slide": saverSlide]
        API.shared.call("saver", ["saver": saver]) { [weak self] ok, reply in
            if !ok { self?.notice = (reply["message"] as? String) ?? "" }
        }
    }

    var saverHint: String {
        switch saverType {
        case "sleep": return String(format: L("If the face does not change for %@, it gets sleepy; after %@ it falls asleep."),
                                    minutesText(saverAfter), minutesText(saverAfter * 2))
        case "clock": return L("If the board has never been connected to the Mac it does not know the time, so it shows the sleepy face instead.")
        case "photo": return L("Shows the selected photo. With no photos, the sleepy face is shown instead.")
        case "slideshow": return L("Shows the stored photos in turn.")
        case "fire": return L("A pixel-art campfire under the night sky, in the menu bar too.")
        default: return L("Keeps the last face.")
        }
    }

    // MARK: Photos

    private func loadThumbs() {
        for item in library where thumbs[item.id] == nil {
            API.shared.get("library/" + API.escape(item.name) + "?t=\(item.mtime)", timeout: 30) { [weak self] data in
                guard let data = data else { return }
                DispatchQueue.global(qos: .userInitiated).async {
                    let image = thumbnail(data)
                    DispatchQueue.main.async { if let image = image { self?.thumbs[item.id] = image } }
                }
            }
        }
    }

    private func loadBoardThumbs() {
        let key = photos.map { String($0) }.joined(separator: ",")
        if key == boardThumbKey { return }
        boardThumbKey = key
        for id in photos {
            API.shared.get("photo/\(id)?v=\(key.hashValue)", timeout: 10) { [weak self] data in
                guard let data = data, let text = String(data: data, encoding: .utf8),
                      let bytes = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
                      let image = imageFromBoardPhoto(bytes) else { return }
                self?.boardThumbs[id] = image
            }
        }
    }

    func forgetBoardThumbs() {
        boardThumbKey = ""
        boardThumbs = [:]
    }

    func addPictures(_ urls: [URL]) {
        let pictures = urls.filter { IMAGE_EXTENSIONS.contains($0.pathExtension.lowercased()) }
        if pictures.isEmpty {
            notice = L("Only picture files can be added.")
            return
        }
        notice = L("Adding to the library…")
        var left = pictures.count
        for url in pictures {
            guard let data = try? Data(contentsOf: url) else { left -= 1; continue }
            API.shared.addToLibrary(name: url.lastPathComponent, data: data) { [weak self] ok, message in
                guard let self = self else { return }
                left -= 1
                if !ok { self.notice = message }
                if left <= 0 {
                    if ok { self.notice = L("Added to the library. Click a photo to show it on the board.") }
                    self.refresh()
                }
            }
        }
    }

    func choosePictures() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType.image]
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK { addPictures(panel.urls) }
    }

    func sendToBoard(_ item: LibraryItem) {
        guard connected else { notice = L("No board is connected. Plug one in and it connects by itself."); return }
        guard sending.isEmpty else { return }
        sending = item.id
        notice = L("Sending to the board… (takes a few seconds)")
        API.shared.get("library/" + API.escape(item.name), timeout: 30) { [weak self] data in
            guard let self = self else { return }
            guard let data = data else { self.sending = ""; self.notice = L("Could not read the photo from the library."); return }
            DispatchQueue.global(qos: .userInitiated).async {
                let photo = boardPhoto(data)
                DispatchQueue.main.async {
                    guard let photo = photo else {
                        self.sending = ""
                        self.notice = L("This picture format cannot be opened. Convert it to JPG or PNG.")
                        return
                    }
                    API.shared.call("photo", ["data": photo.base64EncodedString()], timeout: 120) { ok, reply in
                        self.sending = ""
                        self.notice = (reply["message"] as? String) ?? (ok ? L("Shown on the board.") : L("That didn't work."))
                        self.forgetBoardThumbs()
                        self.refresh()
                    }
                }
            }
        }
    }

    func showBoardPhoto(_ id: Int) {
        API.shared.call("photo_show", ["id": id]) { [weak self] _, reply in
            self?.notice = (reply["message"] as? String) ?? ""
            self?.refresh()
        }
    }

    func deleteBoardPhoto(_ id: Int) {
        API.shared.call("photo_delete", ["id": id]) { [weak self] _, reply in
            self?.notice = (reply["message"] as? String) ?? ""
            self?.forgetBoardThumbs()
            self?.refresh()
        }
    }

    func deleteFromLibrary(_ item: LibraryItem) {
        API.shared.call("library_delete", ["name": item.name]) { [weak self] _, reply in
            self?.notice = (reply["message"] as? String) ?? ""
            self?.refresh()
        }
    }

    func openLibraryFolder() {
        API.shared.call("library_open")
    }

    // MARK: AI apps

    func refreshAI() {
        API.shared.getJSON("mcp") { [weak self] json in
            guard let self = self, let s = json as? [String: Any] else { return }
            self.claude = (s["claude"] as? String) ?? "off"
            self.codex = (s["codex"] as? String) ?? "off"
            self.codexAvailable = (s["codex_available"] as? Bool) ?? false
            self.serverPath = (s["server"] as? String) ?? ""
        }
    }

    func setAI(_ target: String, on: Bool) {
        aiNotice = L("Working…")
        API.shared.call(on ? "mcp_install" : "mcp_remove", ["target": target]) { [weak self] _, reply in
            self?.aiNotice = (reply["message"] as? String) ?? ""
            self?.refreshAI()
        }
    }

    var otherAppCommand: String {
        return "/usr/bin/python3 '\(serverPath)'"
    }

    func copyCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("claude mcp add ai-face -e AIFACE_AGENT=claude -- " + otherAppCommand, forType: .string)
        aiNotice = L("Copied the Claude Code command. Paste it into a terminal.")
    }

    // MARK: Board

    func reconnect() {
        API.shared.call("connect", [:], timeout: 30) { [weak self] _, reply in
            self?.message = (reply["message"] as? String) ?? ""
            self?.refresh()
        }
    }

    func updateFirmware() {
        firmwareBusy = true
        firmwareLog = ""
        API.shared.call("firmware", [:], timeout: 1800) { [weak self] ok, reply in
            guard let self = self else { return }
            self.firmwareBusy = false
            let text = (reply["message"] as? String) ?? ""
            self.firmwareLog = ok ? "" : text
            self.message = text
            self.forgetBoardThumbs()
            self.refresh()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.refresh() }
    }

    // MARK: General

    func setMono(_ on: Bool) {
        mono = on
        API.shared.call("style", ["mono": on]) { [weak self] ok, reply in
            if !ok { self?.mono = !on; self?.notice = (reply["message"] as? String) ?? "" }
        }
    }

    func setLogin(_ on: Bool) {
        LoginItem.enabled = on
        loginItem = LoginItem.enabled
    }

    var awakeStatus: String {
        if !awakeReady { return L("Not set up") }
        if !awakeOn { return L("Turned off") }
        if awakeLeft <= 0 { return L("Turned on") }
        return String(format: L("On · %ld:%02ld left"), awakeLeft / 3600, awakeLeft % 3600 / 60)
    }

    func setUpAwake() {
        API.shared.call("awake_setup") { [weak self] ok, reply in
            if !ok { self?.notice = (reply["message"] as? String) ?? "" }
        }
    }

    func openDataFolder() {
        let folder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AI Face")
        NSWorkspace.shared.open(folder)
    }
}

/// Open at login: the app itself as a login item (System Settings → General → Login Items →
/// Open at Login, with its name and icon).
///
/// Older versions used a LaunchAgent instead. macOS showed that one as a bare "AIFace / exec"
/// background item: it can only link a LaunchAgent to its app through a developer Team ID,
/// which a self-built app does not have. refresh() moves such a setup to a real login item.
enum LoginItem {
    static var legacyAgent: String {
        return NSHomeDirectory() + "/Library/LaunchAgents/local.aiface.plist"
    }

    static func refresh() {
        guard FileManager.default.fileExists(atPath: legacyAgent) else { return }
        try? FileManager.default.removeItem(atPath: legacyAgent)
        enabled = true
    }

    static var enabled: Bool {
        get { return SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                NSLog("AI Face: login item: \(error.localizedDescription)")
            }
            if newValue && SMAppService.mainApp.status == .requiresApproval {
                SMAppService.openSystemSettingsLoginItems()
            }
        }
    }
}

// MARK: - Tabs

struct GeneralTab: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        Form {
            Section {
                Toggle(L("Open at login"), isOn: Binding(get: { store.loginItem }, set: { store.setLogin($0) }))
            } footer: {
                Text(L("The face appears in the menu bar as soon as you log in.")).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Toggle(L("Monochrome"), isOn: Binding(get: { store.mono }, set: { store.setMono($0) }))
            } footer: {
                Text(L("Draws the face in grays and shows who chose it by the ring pattern: you = solid, Claude = short dashes, GPT = six long arcs. Applies to the menu bar and the board."))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if store.awakeSupported {
                Section(L("Keep awake")) {
                    LabeledContent(L("Status"), value: store.awakeStatus)
                    LabeledContent(L("Permission")) {
                        Button(store.awakeReady ? L("Remove…") : L("Set up…")) { store.setUpAwake() }
                    }
                } footer: {
                    Text(L("Keeps the MacBook awake even with the lid closed, for 1, 2 or 4 hours (menu → Keep awake). It turns off at the end, at 20% battery, when the Mac gets hot, in Low Power Mode and when AI Face quits. Setting it up asks for your Mac password once, in Terminal, and allows only this one setting."))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Section(L("About")) {
                LabeledContent(L("Version"), value: "AI Face " + store.version)
                LabeledContent(L("Settings and photo library")) {
                    Button(L("Show in Finder")) { store.openDataFolder() }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct SaverTab: View {
    @ObservedObject var store: SettingsStore

    func bind<T>(_ path: ReferenceWritableKeyPath<SettingsStore, T>) -> Binding<T> {
        return Binding(get: { store[keyPath: path] }, set: { store[keyPath: path] = $0; store.saveSaver() })
    }

    var body: some View {
        Form {
            Section {
                Picker(L("Screen saver"), selection: bind(\.saverType)) {
                    ForEach(SAVER_TYPES, id: \.self) { c in Text(c.label).tag(c.value) }
                }
                Picker(L("Wait"), selection: bind(\.saverAfter)) {
                    ForEach(store.afterChoices, id: \.self) { m in Text(minutesText(m)).tag(m) }
                }
                .disabled(store.saverType == "off")
                if store.saverType == "photo" || store.saverType == "slideshow" {
                    Toggle(L("Clock hands over photos"), isOn: bind(\.saverClock))
                }
                if store.saverType == "slideshow" {
                    Picker(L("Change every"), selection: bind(\.saverSlide)) {
                        ForEach(store.slideChoices, id: \.self) { c in Text(c.label).tag(c.value) }
                    }
                }
            } footer: {
                Text(store.saverHint).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Text(L("When the face has not changed for a while, the screen saver starts. A new face from an AI or the end of a timer brings the face back. The board keeps this setting, so it works with the Mac off too."))
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct PhotosTab: View {
    // No @State: the Command Line Tools have no SwiftUI macro plugin, and the newest SDK
    // resolves @State to a macro. View state lives in the store instead.
    @ObservedObject var store: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L("Photos on the board")).font(.headline)
                Text("\(store.photos.count)/10").foregroundStyle(.secondary)
                Spacer()
            }
            if !store.connected {
                Text(L("They show up here when a board is connected.")).foregroundStyle(.secondary).frame(height: 64)
            } else if store.photos.isEmpty {
                Text(L("None yet. Click a photo in the library below to send it to the board.")).foregroundStyle(.secondary).frame(height: 64)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(store.photos, id: \.self) { id in boardThumb(id) }
                    }
                    .padding(4)
                }
                .frame(height: 72)
            }
            Divider()
            HStack {
                Text(L("Photo library")).font(.headline)
                Text(String(format: L("%d photos"), store.library.count)).foregroundStyle(.secondary)
                Spacer()
                Button(L("Add photos…")) { store.choosePictures() }
                Button { store.openLibraryFolder() } label: { Image(systemName: "folder") }
                    .help(L("Show in Finder"))
            }
            ZStack {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 88, maximum: 110), spacing: 10)], spacing: 10) {
                        ForEach(store.library) { item in libraryThumb(item) }
                    }
                    .padding(2)
                }
                if store.library.isEmpty || store.dropping {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6]))
                        .foregroundStyle(store.dropping ? Color.accentColor : Color.secondary.opacity(0.5))
                        .overlay(Text(L("Drop pictures here")).foregroundStyle(.secondary))
                        .background(store.dropping ? Color.accentColor.opacity(0.08) : Color.clear)
                }
            }
            .frame(maxHeight: .infinity)
            .onDrop(of: [UTType.fileURL], isTargeted: $store.dropping) { providers in
                var urls: [URL] = []
                let group = DispatchGroup()
                for provider in providers {
                    group.enter()
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        if let url = url { DispatchQueue.main.async { urls.append(url) } }
                        group.leave()
                    }
                }
                group.notify(queue: .main) { store.addPictures(urls) }
                return true
            }
            Text(store.notice.isEmpty ? L("Click a photo to show it on the board. Right-click to delete.") : store.notice)
                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
        .padding(20)
    }

    func boardThumb(_ id: Int) -> some View {
        Button { store.showBoardPhoto(id) } label: {
            ZStack {
                Color.black
                if let image = store.boardThumbs[id] {
                    Image(nsImage: image).resizable().scaledToFill()
                }
            }
            .frame(width: 60, height: 60)
            .clipShape(Circle())
            .overlay(Circle().stroke(id == store.currentPhoto ? Color.accentColor : Color.clear, lineWidth: 3))
        }
        .buttonStyle(.plain)
        .help(L("Show this photo"))
        .contextMenu {
            Button(L("Show on the board")) { store.showBoardPhoto(id) }
            Button(L("Delete from the board")) { store.deleteBoardPhoto(id) }
        }
    }

    func libraryThumb(_ item: LibraryItem) -> some View {
        Button { store.sendToBoard(item) } label: {
            ZStack {
                Color.black
                if let image = store.thumbs[item.id] {
                    Image(nsImage: image).resizable().scaledToFill()
                }
                if store.sending == item.id {
                    Color.black.opacity(0.5)
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: 88, height: 88)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(item.name)
        .contextMenu {
            Button(L("Show on the board")) { store.sendToBoard(item) }
            Button(L("Remove from the library")) { store.deleteFromLibrary(item) }
        }
    }
}

struct AITab: View {
    @ObservedObject var store: SettingsStore

    func statusText(_ s: String) -> String {
        switch s {
        case "on": return L("Connected")
        case "other": return L("Connected to another location")
        case "error": return L("Cannot read its settings file")
        default: return L("Not connected")
        }
    }

    func row(_ title: String, _ status: String, _ target: String, available: Bool = true) -> some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                Text(available ? statusText(status) : L("Not installed"))
                    .foregroundStyle(status == "on" ? Color.green : Color.secondary)
                if available {
                    if status == "on" {
                        Button(L("Disconnect")) { store.setAI(target, on: false) }
                    } else {
                        Button(L("Connect")) { store.setAI(target, on: true) }
                    }
                }
            }
        }
    }

    var body: some View {
        Form {
            Section {
                row(L("Claude desktop"), store.claude, "claude")
                row("Codex (GPT)", store.codex, "codex", available: store.codexAvailable)
            } header: {
                Text(L("AI apps"))
            } footer: {
                Text(store.aiNotice.isEmpty
                     ? L("Once connected, the AI picks a face for every reply. After connecting or disconnecting, quit that app (⌘Q) and open it again. Ring colors: Claude orange, GPT green, your own picks white.")
                     : store.aiNotice)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section(L("Other apps")) {
                LabeledContent("Claude Code") {
                    Button(L("Copy command")) { store.copyCommand() }
                }
                LabeledContent(L("Server command")) {
                    Text(store.otherAppCommand)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct BoardTab: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        Form {
            Section(L("ESP32 display")) {
                LabeledContent(L("Status")) {
                    Text(store.connected ? L("Connected") : (store.ports.isEmpty ? L("Not connected") : L("Connecting or error")))
                        .foregroundStyle(store.connected ? Color.green : Color.secondary)
                }
                if store.connected {
                    LabeledContent(L("Port"), value: store.port)
                }
                if !store.message.isEmpty {
                    Text(store.message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if !store.connected && !store.ports.isEmpty {
                    Button(L("Reconnect")) { store.reconnect() }
                }
            }
            Section {
                HStack {
                    Button(L("Update firmware")) { store.updateFirmware() }
                        .disabled(store.ports.isEmpty || store.firmwareBusy || store.flashing)
                    if store.firmwareBusy || store.flashing {
                        ProgressView().controlSize(.small)
                    }
                }
                if !store.firmwareLog.isEmpty {
                    ScrollView {
                        Text(store.firmwareLog)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 140)
                }
            } header: {
                Text(L("Firmware"))
            } footer: {
                Text(L("Compiles firmware/ESP32_Display from the project and uploads it to the board. Needs Arduino IDE 2 in Applications; the first time takes 1–2 minutes."))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Window

final class SettingsWindowController: NSObject, NSWindowDelegate {
    let store = SettingsStore()
    private var window: NSWindow?

    static let size = NSSize(width: 520, height: 470)

    private func tab<V: View>(_ content: V, _ title: String, _ symbol: String) -> NSTabViewItem {
        let size = SettingsWindowController.size
        let host = NSHostingController(rootView: content.frame(width: size.width, height: size.height))
        // A fixed size: otherwise the hosting view sizes itself from the forms' ideal width
        // (long footers on one line) and the window shows it clipped edge to edge.
        host.sizingOptions = []
        host.view.frame = NSRect(origin: .zero, size: size)
        host.preferredContentSize = size
        host.title = title
        let item = NSTabViewItem(viewController: host)
        item.label = title
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        return item
    }

    func show() {
        if window == nil {
            let tabs = NSTabViewController()
            tabs.tabStyle = .toolbar
            tabs.addTabViewItem(tab(GeneralTab(store: store), L("General"), "gearshape"))
            tabs.addTabViewItem(tab(SaverTab(store: store), L("Screen saver"), "moon.zzz"))
            tabs.addTabViewItem(tab(PhotosTab(store: store), L("Photos"), "photo.on.rectangle"))
            tabs.addTabViewItem(tab(HistoryTab(store: store), L("History"), "chart.bar"))
            tabs.addTabViewItem(tab(AITab(store: store), L("AI apps"), "sparkles"))
            tabs.addTabViewItem(tab(BoardTab(store: store), L("Board"), "cpu"))
            let w = NSWindow(contentViewController: tabs)
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.setContentSize(SettingsWindowController.size)
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            window = w
        }
        store.start()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        store.stop()
    }
}


// MARK: - 기록 tab

struct HistoryTab: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Button { store.moveDay(-1) } label: { Image(systemName: "chevron.left") }
                    Text(store.historyDayText).font(.headline).frame(minWidth: 110)
                    Button { store.moveDay(1) } label: { Image(systemName: "chevron.right") }
                        .disabled(store.isToday)
                    Spacer()
                    if !store.isToday { Button(L("Today")) { store.goToday() } }
                    Text(String(format: L("%d changes"), store.dayTotal)).foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    ForEach(OWNERS, id: \.self) { owner in ownerCard(owner) }
                }
                section(L("Emotion groups")) { distribution }
                section(L("Timeline")) { TimelineStrip(events: store.timeline, day: store.historyDay) }
                section(L("Last 7 days")) { WeekChart(rows: store.week) }
                HStack(alignment: .top) {
                    Text(L("Each face change is saved on this Mac: only the time, who chose it and the mood. No conversation text is saved."))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button(L("Delete all history…")) { store.clearHistory() }
                }
            }
            .padding(20)
        }
    }

    func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold))
            content()
        }
    }

    func ownerCard(_ owner: String) -> some View {
        let s = store.dayStats[owner] ?? OwnerStats()
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(OWNER_COLOR[owner] ?? .gray).frame(width: 8, height: 8)
                Text(OWNER_LABEL[owner] ?? owner).font(.caption).foregroundStyle(.secondary)
            }
            Text("\(s.count)").font(.system(size: 24, weight: .semibold)).monospacedDigit()
            ForEach(s.top, id: \.self) { line in
                Text(line).font(.caption).lineLimit(1)
            }
            if s.top.isEmpty { Text("-").font(.caption).foregroundStyle(.secondary) }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
    }

    var distribution: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(OWNERS, id: \.self) { owner in
                let s = store.dayStats[owner] ?? OwnerStats()
                if s.count > 0 {
                    HStack(spacing: 8) {
                        Text(OWNER_LABEL[owner] ?? owner).font(.caption).frame(width: 44, alignment: .leading)
                        GroupBar(groups: s.groups, total: s.count)
                    }
                }
            }
            if store.dayTotal == 0 {
                Text(L("Nothing recorded on this day.")).font(.caption).foregroundStyle(.secondary)
            } else {
                Legend()
            }
        }
    }
}

struct GroupBar: View {
    let groups: [String: Int]
    let total: Int

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 1) {
                ForEach(GROUP_ORDER + ["other"], id: \.self) { g in
                    let n = groups[g] ?? 0
                    if n > 0 {
                        Rectangle().fill(GROUP_COLOR[g] ?? .gray)
                            .frame(width: max(2, geo.size.width * CGFloat(n) / CGFloat(max(1, total)) - 1))
                            .help("\(GROUP_LABEL[g] ?? g) \(n)")
                    }
                }
            }
        }
        .frame(height: 14)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

struct Legend: View {
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 6)], alignment: .leading, spacing: 4) {
            ForEach(GROUP_ORDER, id: \.self) { g in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2).fill(GROUP_COLOR[g] ?? .gray).frame(width: 10, height: 10)
                    Text(GROUP_LABEL[g] ?? g).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// 24 hours left to right; every face change is a tick in the color of who chose it.
struct TimelineStrip: View {
    let events: [TimelineEvent]
    let day: Date

    var body: some View {
        VStack(spacing: 2) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.08))
                    ForEach(events) { e in
                        let start = day.timeIntervalSince1970
                        let x = geo.size.width * CGFloat(max(0, min(86400, e.t - start)) / 86400)
                        Rectangle().fill(OWNER_COLOR[e.owner] ?? .gray)
                            .frame(width: 2, height: geo.size.height - 6)
                            .offset(x: min(geo.size.width - 2, x))
                            .help(e.name)
                    }
                }
            }
            .frame(height: 30)
            HStack {
                ForEach(["0:00", "6:00", "12:00", "18:00", "24:00"], id: \.self) { label in
                    Text(label).font(.caption2).foregroundStyle(.secondary)
                    if label != "24:00" { Spacer() }
                }
            }
        }
    }
}

/// Changes per day for the last 7 days, stacked by who chose the face.
struct WeekChart: View {
    let rows: [WeekRow]

    var body: some View {
        let most = max(1, rows.map { r in OWNERS.reduce(0) { $0 + (r.counts[$1] ?? 0) } }.max() ?? 1)
        return HStack(alignment: .bottom, spacing: 10) {
            ForEach(rows) { r in
                VStack(spacing: 4) {
                    let total = OWNERS.reduce(0) { $0 + (r.counts[$1] ?? 0) }
                    Text(total > 0 ? "\(total)" : "").font(.caption2).foregroundStyle(.secondary)
                    VStack(spacing: 1) {
                        ForEach(OWNERS.reversed(), id: \.self) { owner in
                            let n = r.counts[owner] ?? 0
                            if n > 0 {
                                Rectangle().fill(OWNER_COLOR[owner] ?? .gray)
                                    .frame(height: max(2, 90 * CGFloat(n) / CGFloat(most)))
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 90, alignment: .bottom)
                    Text(r.label).font(.caption2)
                }
            }
        }
    }
}
