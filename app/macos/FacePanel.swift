// The panel under the menu bar face: the face, timer, keep awake, shared folders, Settings and Quit
// in one place (it replaces the old click menu; right-click on the face still opens that menu).
// - Peek: resting the pointer on the face for half a second shows it without taking the keyboard
//   from the app you are typing in; it hides when the pointer leaves. Quit and Install wait for a click.
// - Pinned: clicking the face, or anywhere in a peek, pins it. It stays until the face is clicked
//   again, Esc is pressed or something outside is clicked. Tab, Esc, ⌘, and ⌘Q work.
// - Drag: while a folder is dragged anywhere, a small panel with the drop zone slides in.
//
// The face's 12 fps timer calls `tick`, which looks at the pointer (NSEvent.mouseLocation) and at the
// system drag pasteboard. Only while pinned, mouse-button monitors notice clicks outside (mouse
// buttons only, never keys, so no extra permission); they are removed as soon as the panel closes.
import Cocoa
import SwiftUI
import UniformTypeIdentifiers

final class ShelfPanel: NSPanel {
    var onMouseDown: (() -> Void)?
    var onEscape: (() -> Void)?
    var onCommand: ((String) -> Bool)?
    override var canBecomeKey: Bool { return true }   // switches and buttons work without activating the app

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown || event.type == .rightMouseDown || event.type == .otherMouseDown { onMouseDown?() }
        super.sendEvent(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 53 { onEscape?(); return true }
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           let key = event.charactersIgnoringModifiers?.lowercased(), onCommand?(key) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?() } else { super.keyDown(with: event) }
    }

    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

/// What the panel buttons do; the menu bar controller does it.
protocol FacePanelActions: AnyObject {
    func panelMode(_ mode: String)
    func panelTimer(_ seconds: Int)
    func panelAwake(_ minutes: Int)
    func panelResumeAwake()
    func panelInstall()
    func panelQuit()
    func panelFaces() -> NSViewController?
}

/// Everything the panel shows. The controller sets it only when a value changes.
final class PanelModel: ObservableObject {
    enum Page { case main, faces }
    @Published var pinned = false
    @Published var compact = false          // opened by a folder drag: only the drop zone and the folders
    @Published var page = Page.main
    @Published var title = "AI Face"
    @Published var detail = ""
    @Published var extra = ""
    @Published var kind = "face"
    @Published var timerOn = false
    @Published var customTimer = false
    @Published var customMinutes = "15"
    @Published var customError = false
    @Published var awakeSupported = false
    @Published var awakeReady = false
    @Published var awakeOn = false
    @Published var awakeLines: [String] = []
    @Published var awakePausedMinutes = 0
    @Published var updateAvailable = false
    @Published var updateSummary = ""
    /// Drawn by the 12 fps timer directly, so the face moving does not redraw the whole panel.
    let face = NSImageView()
    var picker: NSViewController?

    init() {
        face.imageScaling = .scaleProportionallyUpOrDown
    }

    func set<T: Equatable>(_ key: ReferenceWritableKeyPath<PanelModel, T>, _ value: T) {
        if self[keyPath: key] != value { self[keyPath: key] = value }
    }
}

private struct PanelSize: PreferenceKey {
    static var defaultValue = CGSize.zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

final class FacePanel: NSObject {
    static let hoverKey = "folderShelfOnHover"   // the old name, so the setting carries over
    static var showOnHover: Bool {
        if API.preview { return true }
        return UserDefaults.standard.object(forKey: hoverKey) as? Bool ?? true
    }
    static let width: CGFloat = 308

    enum Reason { case peek, pinned, drag }

    let store: SettingsStore
    let model = PanelModel()
    weak var actions: FacePanelActions?
    var openSettings: (() -> Void)?
    var willShow: (() -> Void)?                 // fill the model before the size is measured
    var statusWindow: (() -> NSWindow?)?        // clicks on the face itself are the face's own
    var highlight: ((Bool) -> Void)?
    private var panel: ShelfPanel?
    private var reason: Reason?
    private var dragCount = NSPasteboard(name: .drag).changeCount   // the drag pasteboard while no button is down
    private var dragChecked = -1
    private var dragHasFolder = false
    private var hoverSince = 0.0
    private var hoverArmed = true               // after closing, the pointer leaves the face before a new peek
    private var outsideSince = 0.0
    private var dropUntil = 0.0                 // stay a moment after a drop
    private var face = NSRect.zero
    private var monitors: [Any] = []

    init(store: SettingsStore) {
        self.store = store
        super.init()
    }

    var visible: Bool { return panel?.isVisible ?? false }
    var pinned: Bool { return reason == .pinned }

    /// Called about 12 times a second with the face's frame on screen.
    func tick(face: NSRect, menuOpen: Bool, now: Double) {
        self.face = face
        let mouse = NSEvent.mouseLocation
        let down = NSEvent.pressedMouseButtons & 1 != 0
        let drag = NSPasteboard(name: .drag)
        if !down { dragCount = drag.changeCount }
        if menuOpen { if reason != nil || visible { hide() }; return }

        // A folder is being dragged: a new drag pasteboard while the button is down.
        if down && drag.changeCount != dragCount {
            if dragChecked != drag.changeCount {
                dragChecked = drag.changeCount
                dragHasFolder = FacePanel.folders(in: drag)
            }
            if dragHasFolder && reason != .drag && reason != .pinned { show(.drag) }
            return
        }

        let onFace = face.insetBy(dx: -2, dy: -2).contains(mouse)
        if !onFace { hoverArmed = true }
        guard let p = panel, visible else {
            // Resting on the face (not pressing it) for half a second.
            if FacePanel.showOnHover && hoverArmed && !down && face.contains(mouse) {
                if hoverSince == 0 { hoverSince = now }
                if now - hoverSince > 0.5 { show(.peek) }
            } else {
                hoverSince = 0
            }
            return
        }
        if reason == .pinned { outsideSince = 0; return }
        let inside = onFace || p.frame.insetBy(dx: -12, dy: -12).contains(mouse)
        if inside || now < dropUntil || store.folderDropping || NSApp.modalWindow != nil {
            outsideSince = 0
        } else if outsideSince == 0 {
            outsideSince = now
        } else if now - outsideSince > (reason == .drag ? 0.3 : 0.5) {
            hide()
        }
        if reason == .drag && !down && inside { reason = .peek }   // dropped here: stay while pointed at
    }

    static func folders(in pasteboard: NSPasteboard) -> Bool {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.contains { url in
            var dir: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &dir) && dir.boolValue
                && !url.pathExtension.lowercased().hasSuffix("app")
        }
    }

    /// A click on the menu bar face: open it pinned, pin a peek, or close it.
    func toggle() {
        if reason == .pinned { hide() } else { show(.pinned) }
    }

    func show(_ why: Reason) {
        let wasVisible = visible
        reason = why
        outsideSince = 0
        hoverSince = 0
        model.set(\.pinned, why == .pinned)
        model.set(\.compact, why == .drag)
        if !wasVisible {
            store.loadFolders()
            willShow?()
        }
        let p = panel ?? makePanel()
        panel = p
        place(p)
        if !p.isVisible || p.alphaValue < 1 {
            if !p.isVisible { p.alphaValue = 0 }
            p.orderFrontRegardless()   // a peek does not take the keyboard
            NSAnimationContext.runAnimationGroup { $0.duration = 0.15; p.animator().alphaValue = 1 }
        }
        if why == .pinned {
            p.makeKey()
            watchClicks()
        }
        if why == .pinned || wasVisible { highlight?(why == .pinned) }
    }

    /// A click inside a peek (or the drag panel) pins it; the click itself still reaches its button.
    private func pinFromInside() {
        guard visible, reason != .pinned else { return }
        reason = .pinned
        outsideSince = 0
        model.set(\.pinned, true)
        watchClicks()
        highlight?(true)
    }

    func hide() {
        stopWatching()
        if reason == .pinned { highlight?(false) }
        if face.insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation) { hoverArmed = false }
        reason = nil
        outsideSince = 0
        model.set(\.pinned, false)
        guard let p = panel, p.isVisible else { reset(); return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.12; p.animator().alphaValue = 0 }) {
            if self.reason == nil {
                p.orderOut(nil)
                self.reset()
            }
        }
    }

    private func reset() {
        model.set(\.page, .main)
        model.picker = nil
        model.set(\.customTimer, false)
        model.set(\.customError, false)
    }

    private func watchClicks() {
        guard monitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in self?.clickedOutside() }) {
            monitors.append(m)
        }
        if let m = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            if let self = self, event.window !== self.panel, event.window !== self.statusWindow?() { self.clickedOutside() }
            return event
        }) {
            monitors.append(m)
        }
    }

    private func stopWatching() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
    }

    private func clickedOutside() {
        // An alert or a folder chooser of this app is open, or a drop is still arriving: stay.
        if NSApp.modalWindow != nil || store.folderDropping { return }
        hide()
    }

    /// After a drop the panel stays a little, to show the new folder.
    func dropped() {
        dropUntil = Date.timeIntervalSinceReferenceDate + 2
    }

    private func place(_ p: ShelfPanel) {
        p.contentView?.layoutSubtreeIfNeeded()
        let size = p.contentView?.fittingSize ?? NSSize(width: FacePanel.width, height: 200)
        let screen = NSScreen.screens.first { $0.frame.contains(face.origin) }?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        var x = face.midX - size.width / 2
        x = max(screen.minX + 8, min(x, screen.maxX - size.width - 8))
        p.setFrame(NSRect(x: x, y: face.minY - 6 - size.height, width: size.width, height: size.height), display: true)
    }

    private func makePanel() -> ShelfPanel {
        let p = ShelfPanel(contentRect: NSRect(x: 0, y: 0, width: FacePanel.width, height: 200),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.level = .popUpMenu
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.onMouseDown = { [weak self] in self?.pinFromInside() }
        p.onEscape = { [weak self] in self?.hide() }
        p.onCommand = { [weak self] key in
            guard let self = self else { return false }
            switch key {
            case ",": self.settings(); return true
            case "q": self.actions?.panelQuit(); return true
            case "w": self.hide(); return true
            default: return false
            }
        }
        p.setAccessibilityLabel("AI Face")
        let effect = NSVisualEffectView()
        effect.material = .menu
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 10
        effect.layer?.masksToBounds = true
        let host = NSHostingView(rootView: FacePanelView(model: model, store: store, panel: self))
        host.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            host.topAnchor.constraint(equalTo: effect.topAnchor),
            host.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        p.contentView = effect
        return p
    }

    /// The content changed size: keep the top edge under the face.
    func resize() {
        guard let p = panel, p.isVisible, let size = p.contentView?.fittingSize, size != p.frame.size else { return }
        let top = p.frame.maxY
        p.setFrame(NSRect(x: p.frame.minX, y: top - size.height, width: size.width, height: size.height), display: true)
    }

    func pickFaces() {
        guard let picker = actions?.panelFaces() else { return }
        _ = picker.view   // builds the grid and its size
        pinFromInside()
        model.picker = picker
        model.set(\.page, .faces)
    }

    func backToMain() {
        model.set(\.page, .main)
        model.picker = nil
    }

    func add() {
        hide()
        store.chooseFolders()
    }

    func settings() {
        hide()
        openSettings?()
    }
}

// MARK: - Views

private struct FaceImage: NSViewRepresentable {
    let view: NSImageView
    func makeNSView(context: Context) -> NSImageView { return view }
    func updateNSView(_ nsView: NSImageView, context: Context) {}
}

private struct PickerHost: NSViewControllerRepresentable {
    let controller: NSViewController
    func makeNSViewController(context: Context) -> NSViewController { return controller }
    func updateNSViewController(_ controller: NSViewController, context: Context) {}
}

struct FacePanelView: View {
    @ObservedObject var model: PanelModel
    @ObservedObject var store: SettingsStore
    let panel: FacePanel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.compact {
                FolderShelfView(store: store, panel: panel, compact: true)
            } else if model.page == .faces, let picker = model.picker {
                faces(picker)
            } else {
                main
            }
        }
        .font(.system(size: 12))
        .controlSize(.small)
        .padding(12)
        .frame(width: FacePanel.width)
        .fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { g in Color.clear.preference(key: PanelSize.self, value: g.size) })
        .onPreferenceChange(PanelSize.self) { _ in DispatchQueue.main.async { panel.resize() } }
        .onDrop(of: [UTType.fileURL], isTargeted: $store.folderDropping) { providers in
            panel.dropped()
            return droppedURLs(providers) { store.addFolders($0) }
        }
    }

    private var main: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()
            timer
            if model.awakeSupported && model.awakeReady {   // not set up: Settings → AI → Keep awake
                Divider()
                awake
            }
            Divider()
            FolderShelfView(store: store, panel: panel, compact: false)
            Divider()
            footer
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button { panel.pickFaces() } label: {
                FaceImage(view: model.face).frame(width: 56, height: 56)
            }
            .buttonStyle(.plain)
            .help(L("Choose a face"))
            .accessibilityLabel(L("Choose a face"))
            VStack(alignment: .leading, spacing: 2) {
                Text(model.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Text(model.detail).foregroundStyle(.secondary).lineLimit(1)
                Text(model.extra).font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            VStack(spacing: 4) {
                modeButton("flame", L("Light the campfire"), on: model.kind == "fire") { panel.actions?.panelMode("FIRE") }
                modeButton("clock", L("Show the clock"), on: model.kind == "clock") { panel.actions?.panelMode("CLOCK") }
            }
        }
    }

    private func modeButton(_ symbol: String, _ tip: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 26, height: 26)
                .background(Circle().fill(on ? Color.accentColor.opacity(0.3) : Color.primary.opacity(0.07)))
        }
        .buttonStyle(.plain)
        .help(tip)
        .accessibilityLabel(tip)
    }

    private func chip(_ title: String, on: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).frame(maxWidth: .infinity).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(on ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.07)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.system(size: 12, weight: .semibold))
    }

    private var timer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                sectionTitle(L("Timer"))
                Spacer()
                if model.timerOn {
                    Button(L("Cancel timer")) { panel.actions?.panelTimer(0) }.buttonStyle(.link)
                }
            }
            HStack(spacing: 6) {
                ForEach([5, 25, 50], id: \.self) { minutes in
                    chip(minutesText(minutes)) { panel.actions?.panelTimer(minutes * 60) }
                }
                chip(L("Custom…"), on: model.customTimer) {
                    model.customError = false
                    model.customTimer.toggle()
                }
            }
            if model.customTimer {
                CustomTimerRow(model: model) { panel.actions?.panelTimer($0) }
            }
        }
    }

    private var awake: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                sectionTitle(L("Keep awake"))
                Spacer()
                if model.awakeOn {
                    Button(L("Turn off all")) { panel.actions?.panelAwake(0) }.buttonStyle(.link)
                }
            }
            HStack(spacing: 6) {
                ForEach([60, 120, 240], id: \.self) { minutes in
                    chip(minutesText(minutes)) { panel.actions?.panelAwake(minutes) }
                }
            }
            ForEach(model.awakeLines, id: \.self) { line in
                Text(line).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            if model.awakePausedMinutes > 0 {
                Text(String(format: L("Automatic keep awake paused · %ld min"), model.awakePausedMinutes))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Button(L("Resume automatic keep awake")) { panel.actions?.panelResumeAwake() }.buttonStyle(.link)
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !model.updateSummary.isEmpty {
                Text(model.updateSummary).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(L("Settings…")) { panel.settings() }
                Spacer()
                if model.updateAvailable {
                    Button(L("Install new version")) { panel.actions?.panelInstall() }
                        .disabled(!model.pinned)
                        .help(model.pinned ? "" : L("Click the panel once to pin it, then press this."))
                    Spacer()
                }
                Button(L("Quit AI Face")) { panel.actions?.panelQuit() }
                    .disabled(!model.pinned)
                    .help(model.pinned ? "" : L("Click the panel once to pin it, then press this."))
            }
            .buttonStyle(.link)
        }
    }

    private func faces(_ picker: NSViewController) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { panel.backToMain() } label: {
                Label(L("Back"), systemImage: "chevron.left")
            }
            .buttonStyle(.link)
            PickerHost(controller: picker)
                .frame(width: picker.preferredContentSize.width, height: picker.preferredContentSize.height)
                .frame(maxWidth: .infinity)
        }
    }
}

/// "Custom…" timer: minutes typed right in the panel (no separate window that would close it).
private struct CustomTimerRow: View {
    @ObservedObject var model: PanelModel
    let start: (Int) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L("How many minutes? (1–1440)")).font(.system(size: 11)).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                TextField("", text: $model.customMinutes)
                    .frame(width: 70)
                    .focused($focused)
                    .onSubmit(go)
                Button(L("Start"), action: go)
            }
            if model.customError {
                Text(L("Enter 1 to 1440 minutes.")).font(.system(size: 11)).foregroundStyle(.red)
            }
        }
        .onAppear { DispatchQueue.main.async { focused = true } }
    }

    private func go() {
        let text = model.customMinutes.trimmingCharacters(in: .whitespaces)
        guard let minutes = Double(text), minutes > 0, minutes <= 1440 else {
            model.customError = true
            return
        }
        model.customError = false
        model.customTimer = false
        start(Int((minutes * 60).rounded()))
    }
}

/// The shared folders: a drop zone and the list. Alone (small) while a folder is dragged.
struct FolderShelfView: View {
    @ObservedObject var store: SettingsStore
    let panel: FacePanel
    var compact = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L("Shared folders")).font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(L("Read only")).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            drop
            if !store.folders.isEmpty {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(store.folders) { folder in row(folder) }
                    }
                }
                .frame(height: min(compact ? 220 : 144, CGFloat(store.folders.count) * 36))
            }
            if !store.folderNotice.isEmpty {
                Text(store.folderNotice).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(L("Add folder…")) { panel.add() }
                Spacer()
                if compact { Button(L("Settings…")) { panel.settings() } }
            }
            .buttonStyle(.link).font(.system(size: 11))
        }
    }

    /// A big box while dragging (or when opened by a drag), one line otherwise.
    private var drop: some View {
        let big = compact || store.folderDropping
        let layout = big ? AnyLayout(VStackLayout(spacing: 4)) : AnyLayout(HStackLayout(spacing: 6))
        return layout {
            Image(systemName: "folder.badge.plus").font(.system(size: big ? 18 : 13))
            Text(L("Drop folders here to share them with the AIs"))
                .font(.system(size: 11)).multilineTextAlignment(.center)
        }
        .foregroundStyle(store.folderDropping ? Color.accentColor : Color.secondary)
        .frame(maxWidth: .infinity, minHeight: big ? 64 : 30)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(store.folderDropping ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5]))
            .foregroundStyle(store.folderDropping ? Color.accentColor : Color.secondary.opacity(0.5)))
    }

    func row(_ folder: SharedFolder) -> some View {
        HStack(spacing: 8) {
            if folder.missing {
                Image(systemName: "questionmark.folder").foregroundStyle(.secondary).frame(width: 16)
            } else {
                Image(nsImage: NSWorkspace.shared.icon(for: .folder)).resizable().frame(width: 16, height: 16)
            }
            nameLabel(folder.name, folder.missing ? L("Not found: moved or deleted?")
                      : (folder.last.isEmpty ? folder.shortPath : folder.last))
                .opacity(folder.on || folder.missing ? 1 : 0.5)
                .contentShape(Rectangle())
                .onTapGesture { if !folder.missing { NSWorkspace.shared.open(URL(fileURLWithPath: folder.path)) } }
                .help(L("Click to open in Finder"))
            if !folder.missing {
                Toggle(L("Share"), isOn: Binding(get: { folder.on }, set: { store.setFolderOn(folder, $0) }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                    .help(L("Off: paused, the AIs cannot read it until you turn it on again"))
                    .accessibilityLabel(String(format: "%@ · %@", L("Share"), folder.name))
            }
        }
        .frame(height: 36)
        .contextMenu {
            if !folder.missing {
                Button(L("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folder.path)]) }
            } else {
                Button(L("Locate…")) { panel.hide(); store.locateFolder(folder) }
            }
            Button(L("Stop sharing (the folder itself is not touched)")) { store.removeFolder(folder) }
        }
    }
}
