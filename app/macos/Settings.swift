// The settings window: toolbar tabs (일반 · AI · 보드 · 기록), compact cards like AI Illuminati's.
// This file holds the shared state; the tabs are in SettingsTabs.swift.
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

/// One row of a week, month or year chart: a day (week, month) or a month (year).
struct PeriodRow: Identifiable, Equatable {
    let id: String                    // yyyy-MM-dd or yyyy-MM
    let label: String                 // weekday, day of the month or month
    var counts: [String: Int]         // owner -> changes
    var events: [TimelineEvent] = []  // week only: that day's changes
    var start = Date()                // week only: that day's midnight
}

let OWNERS = ["claude", "gpt", "user"]
let OWNER_LABEL = ["claude": "Claude", "gpt": "GPT", "user": L("You")]
let OWNER_COLOR: [String: Color] = [
    "claude": Color(nsColor: ownerColor("claude")),
    "gpt": Color(nsColor: ownerColor("gpt")),
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

struct CalendarItem: Identifiable, Hashable {
    let id: String
    let title: String
    let account: String
    var shown: Bool
    var canWrite = false   // the calendar itself accepts changes (not subscribed / read-only)
    var write = false      // the AIs may write to it
}

struct CalendarChange: Identifiable, Hashable {
    let n: Int
    let text: String
    let undone: Bool
    var id: Int { return n }
}

struct MailAccount: Identifiable, Hashable {
    let name: String
    var shown: Bool
    var id: String { return name }
}

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
    @Published var claudeCode = "off"
    @Published var claudeCodeAvailable = false
    @Published var serverPath = ""
    @Published var helperPath = ""
    // Calendar (read only): macOS permission, which AIs may read it, which calendars, details
    @Published var calAccess = ""
    @Published var calendars: [CalendarItem] = []
    @Published var calClaude = true
    @Published var calGPT = false
    @Published var calDetails = false
    @Published var calWriteClaude = false
    @Published var calWriteGPT = false
    @Published var calConfirm = true
    @Published var calChanges: [CalendarChange] = []
    // Mail (read only): macOS permission, which AIs may read it, which accounts, links hidden
    @Published var mailAccess = ""
    @Published var mailAccounts: [MailAccount] = []
    @Published var mailClaude = true
    @Published var mailGPT = false
    @Published var mailHideLinks = true
    @Published var mailAsking = false
    @Published var hooks = "off"
    @Published var aiNotice = ""
    // Popovers in the AI tab (no @State in views: see BoardTab)
    @Published var showCalendars = false
    @Published var showCalChanges = false
    @Published var showMailAccounts = false
    // General
    @Published var loginItem = false
    @Published var mono = false
    @Published var version = ""
    @Published var autoUpdate = true
    @Published var updateRunning = false
    @Published var updateText = ""
    // Keep awake (lid closed)
    @Published var awakeSupported = false
    @Published var awakeReady = false
    @Published var awakeOn = false
    @Published var awakeLeft = 0
    @Published var awakeNotice = ""
    @Published var awakeCommand = false
    // Expression history (기록 tab)
    @Published var historyKind = "day"   // day, week, month, year
    @Published var historyDay = Calendar.current.startOfDay(for: Date())   // any day in the period
    @Published var dayTotal = 0
    @Published var dayStats: [String: OwnerStats] = [:]
    @Published var timeline: [TimelineEvent] = []
    @Published var periodRows: [PeriodRow] = []
    private var historyKey = ""

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
            if let revision = s["revision"] as? String, !revision.isEmpty {
                self.version += " (" + revision.prefix(7) + ")"
            }
            self.mono = (s["mono"] as? Bool) ?? false
            if let a = s["awake"] as? [String: Any] {
                self.awakeSupported = (a["supported"] as? Bool) ?? false
                self.awakeReady = (a["ready"] as? Bool) ?? false
                self.awakeOn = (a["on"] as? Bool) ?? false
                self.awakeLeft = (a["left"] as? NSNumber)?.intValue ?? 0
                self.awakeCommand = (a["command"] as? Bool) ?? false
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
        API.shared.getJSON("update") { [weak self] json in
            guard let self = self, let u = json as? [String: Any] else { return }
            self.autoUpdate = (u["enabled"] as? Bool) ?? true
            self.updateRunning = (u["running"] as? Bool) ?? false
            self.updateText = SettingsStore.updateText(u)
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

    var periodUnit: Calendar.Component {
        switch historyKind {
        case "week": return .weekOfYear
        case "month": return .month
        case "year": return .year
        default: return .day
        }
    }

    /// First and last day of the shown period (weeks run Monday to Sunday, as on the server).
    var periodBounds: (Date, Date) {
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 2
        cal.minimumDaysInFirstWeek = 4
        let interval = cal.dateInterval(of: periodUnit == .day ? .day : periodUnit, for: historyDay)
        let start = interval?.start ?? historyDay
        let end = cal.date(byAdding: .day, value: -1, to: interval?.end ?? historyDay) ?? historyDay
        return (start, end)
    }

    var historyDayText: String {
        let f = DateFormatter()
        f.locale = APP_LOCALE
        let (start, end) = periodBounds
        switch historyKind {
        case "week":
            f.setLocalizedDateFormatFromTemplate("MMMd")
            return f.string(from: start) + " – " + f.string(from: end)
        case "month": f.setLocalizedDateFormatFromTemplate("yMMMM")
        case "year": f.setLocalizedDateFormatFromTemplate("y")
        default: f.setLocalizedDateFormatFromTemplate("MMMdE")
        }
        return f.string(from: start)
    }

    /// The shown period holds today (no "next" and no "Today" button).
    var isToday: Bool {
        let (start, end) = periodBounds
        let today = Calendar.current.startOfDay(for: Date())
        return start <= today && today <= end
    }

    func setHistoryKind(_ kind: String) {
        historyKind = kind
        historyKey = ""
        loadHistory()
    }

    func moveDay(_ steps: Int) {
        let next = Calendar.current.date(byAdding: periodUnit, value: steps, to: historyDay) ?? historyDay
        let (start, _) = periodBounds
        if steps > 0 && (Calendar.current.date(byAdding: periodUnit, value: steps, to: start) ?? next) > Date() { return }
        historyDay = Calendar.current.startOfDay(for: min(next, Date()))
        historyKey = ""
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
            self.loadHistory()
        }
    }

    func goToday() {
        historyDay = Calendar.current.startOfDay(for: Date())
        historyKey = ""
        loadHistory()
    }

    func loadHistory() {
        let day = SettingsStore.dayFormat.string(from: historyDay)
        API.shared.get("history/period?kind=" + historyKind + "&day=" + day) { [weak self] data in
            guard let self = self, let data = data else { return }
            let key = String(decoding: data, as: UTF8.self)
            if key == self.historyKey { return }
            self.historyKey = key
            guard let s = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any] else { return }
            self.applyHistory(s)
        }
    }

    /// Show a /history/period reply (also used by the settings preview renderer).
    func applyHistory(_ s: [String: Any]) {
        dayTotal = (s["total"] as? NSNumber)?.intValue ?? 0
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
        dayStats = stats
        func events(_ list: [[String: Any]]) -> [TimelineEvent] {
            return list.enumerated().map { pair in
                let e = pair.element
                return TimelineEvent(id: pair.offset, t: (e["t"] as? NSNumber)?.doubleValue ?? 0,
                                     owner: (e["owner"] as? String) ?? "user", name: (e["name"] as? String) ?? "")
            }
        }
        timeline = events((s["timeline"] as? [[String: Any]]) ?? [])
        let label = DateFormatter()
        label.locale = APP_LOCALE
        let month = DateFormatter()
        month.dateFormat = "yyyy-MM"
        let kind = (s["kind"] as? String) ?? "day"
        label.setLocalizedDateFormatFromTemplate(kind == "week" ? "E" : kind == "year" ? "MMM" : "d")
        periodRows = ((s["rows"] as? [[String: Any]]) ?? []).map { r in
            let d = (r["day"] as? String) ?? ""
            var counts: [String: Int] = [:]
            for owner in OWNERS { counts[owner] = (r[owner] as? NSNumber)?.intValue ?? 0 }
            let date = SettingsStore.dayFormat.date(from: d) ?? month.date(from: d)
            var row = PeriodRow(id: d, label: date.map { label.string(from: $0) } ?? d, counts: counts)
            if let list = r["timeline"] as? [[String: Any]] {
                row.events = events(list)
                row.counts = OWNERS.reduce(into: [:]) { c, o in c[o] = row.events.filter { $0.owner == o }.count }
                row.start = date ?? Date()
            }
            return row
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

    func loadCalendar() {
        API.shared.getJSON("calendar/status") { [weak self] json in
            guard let self = self, let s = json as? [String: Any] else { return }
            self.calAccess = (s["access"] as? String) ?? ""
            let apps = (s["apps"] as? [String: Any]) ?? [:]
            self.calClaude = (apps["claude"] as? Bool) ?? true
            self.calGPT = (apps["gpt"] as? Bool) ?? false
            self.calDetails = (s["details"] as? Bool) ?? false
            let writers = (s["write_apps"] as? [String: Any]) ?? [:]
            self.calWriteClaude = (writers["claude"] as? Bool) ?? false
            self.calWriteGPT = (writers["gpt"] as? Bool) ?? false
            self.calConfirm = (s["confirm"] as? Bool) ?? true
            self.calendars = ((s["calendars"] as? [[String: Any]]) ?? []).compactMap { c in
                guard let id = c["id"] as? String else { return nil }
                return CalendarItem(id: id, title: (c["title"] as? String) ?? id,
                                    account: (c["account"] as? String) ?? "", shown: (c["shown"] as? Bool) ?? true,
                                    canWrite: (c["writable"] as? Bool) ?? false, write: (c["write"] as? Bool) ?? false)
            }
            self.calChanges = ((s["changes"] as? [[String: Any]]) ?? []).compactMap { c in
                guard let n = (c["n"] as? NSNumber)?.intValue else { return nil }
                return CalendarChange(n: n, text: (c["text"] as? String) ?? "", undone: (c["undone"] as? Bool) ?? false)
            }
        }
    }

    func setCalendar(_ changes: [String: Any]) {
        API.shared.call("calendar_settings", ["changes": changes]) { [weak self] ok, reply in
            if !ok { self?.aiNotice = (reply["message"] as? String) ?? "" }
            else { self?.aiNotice = L("Saved. Quit that AI app (⌘Q) and open it again for the change to apply.") }
            self?.loadCalendar()
        }
    }

    func setCalendarShown(_ id: String, _ on: Bool) {
        let hidden = calendars.filter { $0.id == id ? !on : !$0.shown }.map { $0.id }
        setCalendar(["hidden": hidden])
    }

    func setCalendarWritable(_ id: String, _ on: Bool) {
        let list = calendars.filter { $0.canWrite && ($0.id == id ? on : $0.write) }.map { $0.id }
        setCalendar(["writable": list])
    }

    func undoCalendarChange(_ n: Int) {
        API.shared.call("calendar_undo", ["n": n]) { [weak self] ok, reply in
            self?.aiNotice = ok ? L("Undone.") : ((reply["message"] as? String) ?? "")
            self?.loadCalendar()
        }
    }

    func requestCalendarAccess() {
        if calAccess == "denied" || calAccess == "restricted" {
            if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                NSWorkspace.shared.open(u)
            }
            return
        }
        CalendarAccess.request { [weak self] _ in self?.loadCalendar() }
    }

    var calAccessText: String {
        switch calAccess {
        case "full": return L("Allowed")
        case "notDetermined": return L("Not allowed yet")
        case "denied", "restricted": return L("Denied in System Settings")
        case "writeOnly": return L("Add-only access (needs full access)")
        default: return L("Unavailable")
        }
    }

    func loadMail() {
        API.shared.getJSON("mail/status") { [weak self] json in
            guard let self = self, let s = json as? [String: Any] else { return }
            self.mailAccess = (s["access"] as? String) ?? ""
            let apps = (s["apps"] as? [String: Any]) ?? [:]
            self.mailClaude = (apps["claude"] as? Bool) ?? true
            self.mailGPT = (apps["gpt"] as? Bool) ?? false
            self.mailHideLinks = (s["hide_links"] as? Bool) ?? true
            self.mailAccounts = ((s["accounts"] as? [[String: Any]]) ?? []).compactMap { a in
                guard let name = a["name"] as? String else { return nil }
                return MailAccount(name: name, shown: (a["shown"] as? Bool) ?? true)
            }
        }
    }

    func setMail(_ changes: [String: Any]) {
        API.shared.call("mail_settings", ["changes": changes]) { [weak self] ok, reply in
            if !ok { self?.aiNotice = (reply["message"] as? String) ?? "" }
            else { self?.aiNotice = L("Saved. Quit that AI app (⌘Q) and open it again for the change to apply.") }
            self?.loadMail()
        }
    }

    func setMailShown(_ name: String, _ on: Bool) {
        let hidden = mailAccounts.filter { $0.name == name ? !on : !$0.shown }.map { $0.name }
        setMail(["hidden": hidden])
    }

    func requestMailAccess() {
        if mailAccess == "denied" {
            if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                NSWorkspace.shared.open(u)
            }
            return
        }
        mailAsking = true
        MailAccess.request { [weak self] _ in
            self?.mailAsking = false
            self?.loadMail()
        }
    }

    var mailAccessText: String {
        switch mailAccess {
        case "allowed": return L("Allowed")
        case "notDetermined": return L("Not allowed yet")
        case "denied": return L("Denied in System Settings")
        case "notRunning": return L("Open Mail to check")
        default: return L("Unavailable")
        }
    }

    func refreshAI() {
        loadCalendar()
        API.shared.getJSON("mcp") { [weak self] json in
            guard let self = self, let s = json as? [String: Any] else { return }
            self.claude = (s["claude"] as? String) ?? "off"
            self.codex = (s["codex"] as? String) ?? "off"
            self.codexAvailable = (s["codex_available"] as? Bool) ?? false
            self.claudeCode = (s["claude_code"] as? String) ?? "off"
            self.claudeCodeAvailable = (s["claude_code_available"] as? Bool) ?? false
            self.serverPath = (s["server"] as? String) ?? ""
            self.helperPath = (s["helper"] as? String) ?? ""
            self.hooks = (s["claude_code_awake"] as? String) ?? "off"
        }
    }

    func setAI(_ target: String, on: Bool) {
        aiNotice = L("Working…")
        API.shared.call(on ? "mcp_install" : "mcp_remove", ["target": target], timeout: 90) { [weak self] _, reply in
            self?.aiNotice = (reply["message"] as? String) ?? ""
            self?.refreshAI()
        }
    }

    var otherAppCommand: String {
        return "/usr/bin/python3 '\(serverPath)'"
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

    // MARK: Automatic updates (core/aiface/updater.py)

    static func updateText(_ u: [String: Any]) -> String {
        if (u["running"] as? Bool) ?? false { return L("Checking for a new version…") }
        let detail = (u["detail"] as? String) ?? ""
        let current = (u["current"] as? String) ?? ""
        var text: String
        switch (u["result"] as? String) ?? "" {
        case "latest": text = String(format: L("Up to date (%@)"), current)
        case "updated":
            let previous = (u["previous"] as? String) ?? ""
            text = previous.isEmpty || previous == "legacy"
                ? String(format: L("Installed version (%@)"), current)
                : String(format: L("Updated: %@ → %@"), previous, current)
            if let first = (u["changes"] as? [String])?.first { text += "\n" + first }
        case "installing": text = L("Installing the new version…")
        case "waiting": text = String(format: L("New version found, waiting: %@"), detail)
        case "skipped": text = String(format: L("Not updating: %@"), detail)
        case "failed": text = String(format: L("Update failed: %@"), detail)
        case "error": text = String(format: L("Could not check: %@"), detail)
        case "unavailable": text = L("Not available (the project folder is not a git copy)")
        default: return L("Not checked yet")
        }
        if let checked = (u["checked"] as? NSNumber)?.doubleValue, checked > 0 {
            let f = DateFormatter()
            f.locale = APP_LOCALE
            f.setLocalizedDateFormatFromTemplate("MMMdjmm")
            text += "\n" + String(format: L("Last checked %@"), f.string(from: Date(timeIntervalSince1970: checked)))
        }
        return text
    }

    func setAutoUpdate(_ on: Bool) {
        autoUpdate = on
        API.shared.call("update_settings", ["enabled": on]) { [weak self] ok, reply in
            if !ok { self?.autoUpdate = !on; self?.notice = (reply["message"] as? String) ?? "" }
        }
    }

    func checkUpdate() {
        updateRunning = true
        updateText = L("Checking for a new version…")
        API.shared.call("update_check")
    }

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

    func revealApp() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
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

// The tabs themselves are in SettingsTabs.swift.

// MARK: - Window

final class SettingsWindowController: NSObject, NSWindowDelegate {
    let store = SettingsStore()
    private var window: NSWindow?

    static let size = NSSize(width: 334, height: 460)

    private func tab<V: View>(_ content: V, _ title: String, _ symbol: String) -> NSTabViewItem {
        let size = SettingsWindowController.size
        let host = NSHostingController(rootView: content.frame(width: size.width, height: size.height))
        // A fixed size: otherwise the hosting view sizes itself from its content's ideal width.
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
            tabs.addTabViewItem(tab(AITab(store: store), L("AI"), "sparkles"))
            tabs.addTabViewItem(tab(BoardTab(store: store), L("Board"), "cpu"))
            tabs.addTabViewItem(tab(HistoryTab(store: store), L("History"), "chart.bar"))
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
    var shown: Set<String>? = nil   // only these groups (nil: all)

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 78), spacing: 6)], alignment: .leading, spacing: 4) {
            ForEach(GROUP_ORDER.filter { shown?.contains($0) ?? true }, id: \.self) { g in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2).fill(GROUP_COLOR[g] ?? .gray).frame(width: 9, height: 9)
                    Text(GROUP_LABEL[g] ?? g).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
    }
}

/// One day's changes as ticks along 24 hours, in the color of who chose the face.
struct TimelineTicks: View {
    let events: [TimelineEvent]
    let day: Date
    var height: CGFloat = 30

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.08))
                ForEach(events) { e in
                    let x = geo.size.width * CGFloat(max(0, min(86400, e.t - day.timeIntervalSince1970)) / 86400)
                    Rectangle().fill(OWNER_COLOR[e.owner] ?? .gray)
                        .frame(width: 2, height: max(2, geo.size.height - 6))
                        .offset(x: min(geo.size.width - 2, x))
                        .help(e.name)
                }
            }
        }
        .frame(height: height)
    }
}

struct HourLabels: View {
    var body: some View {
        HStack {
            ForEach(["0", "6", "12", "18", "24"], id: \.self) { label in
                Text(label + ":00").font(.system(size: 9)).foregroundStyle(.secondary)
                if label != "24" { Spacer() }
            }
        }
    }
}

/// The day view: 24 hours left to right.
struct TimelineStrip: View {
    let events: [TimelineEvent]
    let day: Date

    var body: some View {
        VStack(spacing: 3) {
            TimelineTicks(events: events, day: day)
            HourLabels()
        }
    }
}

/// The week view: one 24-hour strip per day, so habits by time of day line up.
struct WeekTimeline: View {
    let rows: [PeriodRow]

    var body: some View {
        VStack(spacing: 4) {
            ForEach(rows) { r in
                HStack(spacing: 6) {
                    Text(r.label).font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 24, alignment: .leading)
                    TimelineTicks(events: r.events, day: r.start, height: 14)
                    Text(r.events.isEmpty ? "" : "\(r.events.count)").font(.system(size: 9)).foregroundStyle(.secondary)
                        .monospacedDigit().frame(width: 20, alignment: .trailing)
                }
            }
            HStack(spacing: 6) {
                Spacer().frame(width: 24)
                HourLabels()
                Spacer().frame(width: 20)
            }
        }
    }
}

/// Changes per day (month view) or per month (year view), stacked by who chose the face.
struct BarChart: View {
    let rows: [PeriodRow]
    var labelEvery = 1     // label every n-th bar (and the last); a month has too many for all

    var body: some View {
        let totals = rows.map { r in OWNERS.reduce(0) { $0 + (r.counts[$1] ?? 0) } }
        let most = max(1, totals.max() ?? 1)
        let spacing: CGFloat = rows.count > 12 ? 2 : 5
        return HStack(alignment: .bottom, spacing: spacing) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, r in
                VStack(spacing: 3) {
                    if rows.count <= 12 {
                        Text(totals[index] > 0 ? "\(totals[index])" : "").font(.system(size: 9)).foregroundStyle(.secondary)
                            .lineLimit(1).minimumScaleFactor(0.7)
                    }
                    VStack(spacing: 1) {
                        ForEach(OWNERS.reversed(), id: \.self) { owner in
                            let n = r.counts[owner] ?? 0
                            if n > 0 {
                                Rectangle().fill(OWNER_COLOR[owner] ?? .gray)
                                    .frame(height: max(2, 70 * CGFloat(n) / CGFloat(most)))
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 70, alignment: .bottom)
                    .background(Rectangle().fill(Color.secondary.opacity(0.06)))
                    .help("\(r.label): \(totals[index])")
                    Text(index % labelEvery == 0 || index == rows.count - 1 ? r.label : " ")
                        .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                        .frame(width: rows.count > 12 ? 4 : nil)
                }
            }
        }
    }
}
