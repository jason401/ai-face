// The settings window: toolbar tabs (일반 · 대기 화면 · 사진 · AI 연결 · 보드), each a
// SwiftUI form, like the settings of RunCat and other menu bar apps.
import Cocoa
import SwiftUI
import UniformTypeIdentifiers

struct Choice<T: Hashable>: Hashable {
    let value: T
    let label: String
}

let SAVER_TYPES: [Choice<String>] = [
    Choice(value: "sleep", label: "졸린 얼굴 → 잠든 얼굴"),
    Choice(value: "clock", label: "시계"),
    Choice(value: "photo", label: "사진"),
    Choice(value: "slideshow", label: "사진 슬라이드쇼"),
    Choice(value: "fire", label: "픽셀 모닥불"),
    Choice(value: "off", label: "사용 안 함"),
]
let SLIDE_CHOICES: [Choice<Int>] = [
    Choice(value: 10, label: "10초"), Choice(value: 30, label: "30초"), Choice(value: 60, label: "1분"),
    Choice(value: 300, label: "5분"), Choice(value: 900, label: "15분"),
]

func minutesText(_ m: Int) -> String {
    if m >= 60 && m % 60 == 0 { return "\(m / 60)시간" }
    if m > 60 { return "\(m / 60)시간 \(m % 60)분" }
    return "\(m)분"
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
let OWNER_LABEL = ["claude": "Claude", "gpt": "GPT", "user": "직접"]
let OWNER_COLOR: [String: Color] = [
    "claude": Color(red: 0xD9 / 255.0, green: 0x77 / 255.0, blue: 0x57 / 255.0),
    "gpt": Color(red: 0x10 / 255.0, green: 0xA3 / 255.0, blue: 0x7F / 255.0),
    "user": Color.gray,
]
let GROUP_ORDER = ["기쁨", "사랑·유대", "놀람·관심", "생각·대화", "평온·휴식", "슬픔", "불안·긴장", "분노·불쾌", "몸 상태"]
let GROUP_COLOR: [String: Color] = [
    "기쁨": .yellow, "사랑·유대": .pink, "놀람·관심": .orange, "생각·대화": .blue, "평온·휴식": .mint,
    "슬픔": .indigo, "불안·긴장": .purple, "분노·불쾌": .red, "몸 상태": .green,
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
        return SLIDE_CHOICES + [Choice(value: saverSlide, label: "\(saverSlide)초")]
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
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "M월 d일 (E)"
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
            weekday.locale = Locale(identifier: "ko_KR")
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
        case "sleep": return "표정이 \(minutesText(saverAfter)) 동안 안 바뀌면 졸린 얼굴, \(minutesText(saverAfter * 2)) 뒤 잠든 얼굴이 돼요."
        case "clock": return "보드가 맥과 한 번도 연결되지 않아 시간을 모르면 졸린 얼굴로 대신해요."
        case "photo": return "보드에 지금 선택된 사진을 띄워요. 사진이 없으면 졸린 얼굴로 대신해요. 메뉴바에는 잠든 얼굴로 보여요."
        case "slideshow": return "보드에 저장된 사진을 돌아가며 띄워요. 메뉴바에는 잠든 얼굴로 보여요."
        case "fire": return "밤하늘 아래 픽셀 모닥불이 타올라요. 메뉴바에도 작게 보여요."
        default: return "마지막 표정을 그대로 둬요."
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
            notice = "사진 파일만 넣을 수 있어요."
            return
        }
        notice = "보관함에 넣는 중…"
        var left = pictures.count
        for url in pictures {
            guard let data = try? Data(contentsOf: url) else { left -= 1; continue }
            API.shared.addToLibrary(name: url.lastPathComponent, data: data) { [weak self] ok, message in
                guard let self = self else { return }
                left -= 1
                if !ok { self.notice = message }
                if left <= 0 {
                    if ok { self.notice = "보관함에 넣었어요. 사진을 누르면 보드에 띄워요." }
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
        guard connected else { notice = "보드가 연결되어 있지 않아요. 보드를 꽂으면 자동으로 연결돼요."; return }
        guard sending.isEmpty else { return }
        sending = item.id
        notice = "보드로 보내는 중… (몇 초 걸려요)"
        API.shared.get("library/" + API.escape(item.name), timeout: 30) { [weak self] data in
            guard let self = self else { return }
            guard let data = data else { self.sending = ""; self.notice = "보관함 사진을 읽지 못했어요."; return }
            DispatchQueue.global(qos: .userInitiated).async {
                let photo = boardPhoto(data)
                DispatchQueue.main.async {
                    guard let photo = photo else {
                        self.sending = ""
                        self.notice = "이 사진 형식은 열 수 없어요. JPG나 PNG로 바꿔서 넣어 주세요."
                        return
                    }
                    API.shared.call("photo", ["data": photo.base64EncodedString()], timeout: 120) { ok, reply in
                        self.sending = ""
                        self.notice = (reply["message"] as? String) ?? (ok ? "보드에 띄웠어요." : "실패했어요.")
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
        aiNotice = "처리 중…"
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
        NSPasteboard.general.setString("claude mcp add esp32-face -e ESP32_AGENT=claude -- " + otherAppCommand, forType: .string)
        aiNotice = "Claude Code 등록 명령을 복사했어요. 터미널에 붙여 넣으세요."
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

    func openDataFolder() {
        let folder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ESP32Face")
        NSWorkspace.shared.open(folder)
    }
}

/// Launch at login: a per-user LaunchAgent that starts the app in the background.
enum LoginItem {
    static var path: String {
        return NSHomeDirectory() + "/Library/LaunchAgents/local.aiface.plist"
    }

    static var enabled: Bool {
        get { return FileManager.default.fileExists(atPath: path) }
        set {
            if !newValue {
                try? FileManager.default.removeItem(atPath: path)
                return
            }
            guard let exe = Bundle.main.executablePath else { return }
            let plist: NSDictionary = ["Label": "local.aiface",
                                       "ProgramArguments": [exe, "--background"],
                                       "RunAtLoad": true,
                                       "ProcessType": "Interactive"]
            try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                     withIntermediateDirectories: true, attributes: nil)
            plist.write(toFile: path, atomically: true)
        }
    }
}

// MARK: - Tabs

struct GeneralTab: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        Form {
            Section {
                Toggle("로그인할 때 자동 실행", isOn: Binding(get: { store.loginItem }, set: { store.setLogin($0) }))
            } footer: {
                Text("켜 두면 맥을 켤 때 메뉴바에 얼굴이 바로 나타나요.").font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Toggle("흑백 모드", isOn: Binding(get: { store.mono }, set: { store.setMono($0) }))
            } footer: {
                Text("얼굴을 흑백으로 그리고, 누가 고른 표정인지 테두리 무늬로 보여줘요. 직접 = 실선, Claude = 짧은 점선, GPT = 긴 조각 6개. 메뉴바와 보드 둘 다 바뀌어요.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("정보") {
                LabeledContent("버전", value: "AI Face " + store.version)
                LabeledContent("설정 · 사진 보관함") {
                    Button("Finder에서 열기") { store.openDataFolder() }
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
                Picker("대기 화면", selection: bind(\.saverType)) {
                    ForEach(SAVER_TYPES, id: \.self) { c in Text(c.label).tag(c.value) }
                }
                Picker("기다리는 시간", selection: bind(\.saverAfter)) {
                    ForEach(store.afterChoices, id: \.self) { m in Text(minutesText(m)).tag(m) }
                }
                .disabled(store.saverType == "off")
                if store.saverType == "photo" || store.saverType == "slideshow" {
                    Toggle("사진 위에 시계 바늘 표시", isOn: bind(\.saverClock))
                }
                if store.saverType == "slideshow" {
                    Picker("넘김 간격", selection: bind(\.saverSlide)) {
                        ForEach(store.slideChoices, id: \.self) { c in Text(c.label).tag(c.value) }
                    }
                }
            } footer: {
                Text(store.saverHint).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Text("표정이 한동안 안 바뀌면 대기 화면으로 바뀌어요. AI가 새 표정을 보내거나 타이머가 끝나면 다시 얼굴로 돌아와요. 설정은 보드에도 저장돼서 맥이 꺼져 있어도 동작해요.")
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
                Text("보드에 저장된 사진").font(.headline)
                Text("\(store.photos.count)/10").foregroundStyle(.secondary)
                Spacer()
            }
            if !store.connected {
                Text("보드를 연결하면 여기에 보여요.").foregroundStyle(.secondary).frame(height: 64)
            } else if store.photos.isEmpty {
                Text("아직 없어요. 아래 보관함에서 사진을 누르면 보드로 보내요.").foregroundStyle(.secondary).frame(height: 64)
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
                Text("사진 보관함").font(.headline)
                Text("\(store.library.count)장").foregroundStyle(.secondary)
                Spacer()
                Button("사진 추가…") { store.choosePictures() }
                Button { store.openLibraryFolder() } label: { Image(systemName: "folder") }
                    .help("Finder에서 열기")
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
                        .overlay(Text("사진을 여기로 끌어다 놓으세요").foregroundStyle(.secondary))
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
            Text(store.notice.isEmpty ? "사진을 누르면 보드에 띄워요. 오른쪽 클릭으로 지울 수 있어요." : store.notice)
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
        .help("이 사진 띄우기")
        .contextMenu {
            Button("보드에 띄우기") { store.showBoardPhoto(id) }
            Button("보드에서 지우기") { store.deleteBoardPhoto(id) }
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
            Button("보드에 띄우기") { store.sendToBoard(item) }
            Button("보관함에서 지우기") { store.deleteFromLibrary(item) }
        }
    }
}

struct AITab: View {
    @ObservedObject var store: SettingsStore

    func statusText(_ s: String) -> String {
        switch s {
        case "on": return "연결됨"
        case "other": return "다른 위치로 연결됨"
        case "error": return "설정 파일을 읽을 수 없음"
        default: return "연결 안 됨"
        }
    }

    func row(_ title: String, _ status: String, _ target: String, available: Bool = true) -> some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                Text(available ? statusText(status) : "설치되어 있지 않음")
                    .foregroundStyle(status == "on" ? Color.green : Color.secondary)
                if available {
                    if status == "on" {
                        Button("해제") { store.setAI(target, on: false) }
                    } else {
                        Button("연결") { store.setAI(target, on: true) }
                    }
                }
            }
        }
    }

    var body: some View {
        Form {
            Section {
                row("Claude 데스크톱", store.claude, "claude")
                row("Codex (GPT)", store.codex, "codex", available: store.codexAvailable)
            } header: {
                Text("AI 앱 연결")
            } footer: {
                Text(store.aiNotice.isEmpty
                     ? "연결하면 AI가 대답할 때마다 표정을 골라요. 연결하거나 해제한 뒤에는 그 앱을 완전히 종료(⌘Q)하고 다시 실행하세요. 테두리 색: Claude 주황, GPT 초록, 직접 고르면 흰색."
                     : store.aiNotice)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("다른 앱") {
                LabeledContent("Claude Code") {
                    Button("등록 명령 복사") { store.copyCommand() }
                }
                LabeledContent("서버 명령") {
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
            Section("ESP32 화면") {
                LabeledContent("상태") {
                    Text(store.connected ? "연결됨" : (store.ports.isEmpty ? "연결 안 됨" : "연결 중이거나 오류"))
                        .foregroundStyle(store.connected ? Color.green : Color.secondary)
                }
                if store.connected {
                    LabeledContent("포트", value: store.port)
                }
                if !store.message.isEmpty {
                    Text(store.message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if !store.connected && !store.ports.isEmpty {
                    Button("다시 연결") { store.reconnect() }
                }
            }
            Section {
                HStack {
                    Button("펌웨어 업데이트") { store.updateFirmware() }
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
                Text("펌웨어")
            } footer: {
                Text("프로젝트의 firmware/ESP32_Display를 컴파일해서 보드에 올려요. Arduino IDE 2가 응용 프로그램 폴더에 있어야 하고, 처음에는 1~2분 걸려요.")
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
            tabs.addTabViewItem(tab(GeneralTab(store: store), "일반", "gearshape"))
            tabs.addTabViewItem(tab(SaverTab(store: store), "대기 화면", "moon.zzz"))
            tabs.addTabViewItem(tab(PhotosTab(store: store), "사진", "photo.on.rectangle"))
            tabs.addTabViewItem(tab(HistoryTab(store: store), "기록", "chart.bar"))
            tabs.addTabViewItem(tab(AITab(store: store), "AI 연결", "sparkles"))
            tabs.addTabViewItem(tab(BoardTab(store: store), "보드", "cpu"))
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
                    if !store.isToday { Button("오늘") { store.goToday() } }
                    Text("총 \(store.dayTotal)번").foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    ForEach(OWNERS, id: \.self) { owner in ownerCard(owner) }
                }
                section("감정 분포") { distribution }
                section("하루 타임라인") { TimelineStrip(events: store.timeline, day: store.historyDay) }
                section("최근 7일") { WeekChart(rows: store.week) }
                Text("표정이 바뀔 때마다 시각, 누가 골랐는지, 무슨 표정인지만 맥에 저장해요. 대화 내용은 저장하지 않아요.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
                Text("이 날은 기록이 없어요.").font(.caption).foregroundStyle(.secondary)
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
                ForEach(GROUP_ORDER + ["기타"], id: \.self) { g in
                    let n = groups[g] ?? 0
                    if n > 0 {
                        Rectangle().fill(GROUP_COLOR[g] ?? .gray)
                            .frame(width: max(2, geo.size.width * CGFloat(n) / CGFloat(max(1, total)) - 1))
                            .help("\(g) \(n)번")
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
                    Text(g).font(.caption2).foregroundStyle(.secondary)
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
                ForEach(["0시", "6시", "12시", "18시", "24시"], id: \.self) { label in
                    Text(label).font(.caption2).foregroundStyle(.secondary)
                    if label != "24시" { Spacer() }
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
