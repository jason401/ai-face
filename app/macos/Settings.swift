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
    @Published var notice = ""
    // AI apps
    @Published var claude = "off"
    @Published var codex = "off"
    @Published var codexAvailable = false
    @Published var serverPath = ""
    @Published var aiNotice = ""
    // General
    @Published var loginItem = false
    @Published var version = ""

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
        API.shared.getJSON("status") { [weak self] json in
            guard let self = self, let s = json as? [String: Any] else { return }
            self.connected = (s["connected"] as? Bool) ?? false
            self.port = (s["port"] as? String) ?? ""
            self.ports = (s["ports"] as? [String]) ?? []
            self.message = (s["message"] as? String) ?? ""
            self.flashing = (s["flashing"] as? Bool) ?? false
            self.version = (s["version"] as? String) ?? ""
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
    @ObservedObject var store: SettingsStore
    @State private var dropping = false

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
                if store.library.isEmpty || dropping {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6]))
                        .foregroundStyle(dropping ? Color.accentColor : Color.secondary.opacity(0.5))
                        .overlay(Text("사진을 여기로 끌어다 놓으세요").foregroundStyle(.secondary))
                        .background(dropping ? Color.accentColor.opacity(0.08) : Color.clear)
                }
            }
            .frame(maxHeight: .infinity)
            .onDrop(of: [UTType.fileURL], isTargeted: $dropping) { providers in
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
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Window

final class SettingsWindowController: NSObject, NSWindowDelegate {
    let store = SettingsStore()
    private var window: NSWindow?

    private func tab<V: View>(_ content: V, _ title: String, _ symbol: String) -> NSTabViewItem {
        let host = NSHostingController(rootView: content.frame(width: 560, height: 480))
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
            tabs.addTabViewItem(tab(AITab(store: store), "AI 연결", "sparkles"))
            tabs.addTabViewItem(tab(BoardTab(store: store), "보드", "cpu"))
            let w = NSWindow(contentViewController: tabs)
            w.styleMask = [.titled, .closable, .miniaturizable]
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
