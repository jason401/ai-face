// The shared-folder panel under the menu bar face: a drop zone and the list of shared folders.
// It slides in by itself while a folder is dragged anywhere (drop it there to share it), and
// when the pointer rests on the face (Settings → AI → Shared folders can turn that off).
//
// No event monitors and no extra permission: the face's 12 fps timer calls `tick`, which looks
// at the pointer (NSEvent.mouseLocation) and at the system drag pasteboard.
import Cocoa
import SwiftUI
import UniformTypeIdentifiers

final class ShelfPanel: NSPanel {
    override var canBecomeKey: Bool { return true }   // switches and buttons work without activating the app
}

final class FolderShelf: NSObject {
    static let hoverKey = "folderShelfOnHover"
    static var showOnHover: Bool {
        if API.preview { return true }
        return UserDefaults.standard.object(forKey: hoverKey) as? Bool ?? true
    }

    enum Reason { case drag, hover }

    let store: SettingsStore
    var openSettings: (() -> Void)?
    private var panel: ShelfPanel?
    private var reason: Reason?
    private var dragCount = NSPasteboard(name: .drag).changeCount   // the drag pasteboard while no button is down
    private var dragChecked = -1
    private var dragHasFolder = false
    private var hoverSince = 0.0
    private var outsideSince = 0.0
    private var dropUntil = 0.0                                     // stay a moment after a drop

    init(store: SettingsStore) {
        self.store = store
        super.init()
    }

    var visible: Bool { return panel?.isVisible ?? false }

    /// Called about 12 times a second with the face's frame on screen.
    func tick(face: NSRect, menuOpen: Bool, now: Double) {
        let mouse = NSEvent.mouseLocation
        let down = NSEvent.pressedMouseButtons & 1 != 0
        let drag = NSPasteboard(name: .drag)
        if !down { dragCount = drag.changeCount }
        if menuOpen { hide(); return }

        // A folder is being dragged: a new drag pasteboard while the button is down.
        if down && drag.changeCount != dragCount {
            if dragChecked != drag.changeCount {
                dragChecked = drag.changeCount
                dragHasFolder = FolderShelf.folders(in: drag)
            }
            if dragHasFolder && reason != .drag { show(.drag, under: face) }
            return
        }

        let inside = face.insetBy(dx: -2, dy: -2).contains(mouse)
            || (panel.map { visible && $0.frame.insetBy(dx: -12, dy: -12).contains(mouse) } ?? false)
        if visible {
            if inside || now < dropUntil || store.folderDropping {
                outsideSince = 0
            } else if outsideSince == 0 {
                outsideSince = now
            } else if now - outsideSince > (reason == .drag ? 0.3 : 0.5) {
                hide()
            }
            if reason == .drag && !down && inside { reason = .hover }   // dropped here: stay while pointed at
            return
        }
        // Resting on the face (not pressing it) for half a second.
        if FolderShelf.showOnHover && !down && face.contains(mouse) {
            if hoverSince == 0 { hoverSince = now }
            if now - hoverSince > 0.5 { show(.hover, under: face) }
        } else {
            hoverSince = 0
        }
    }

    static func folders(in pasteboard: NSPasteboard) -> Bool {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.contains { url in
            var dir: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &dir) && dir.boolValue
                && !url.pathExtension.lowercased().hasSuffix("app")
        }
    }

    func show(_ why: Reason, under face: NSRect) {
        reason = why
        outsideSince = 0
        hoverSince = 0
        store.loadFolders()
        let p = panel ?? makePanel()
        panel = p
        p.contentView?.layoutSubtreeIfNeeded()
        let size = p.contentView?.fittingSize ?? NSSize(width: 280, height: 200)
        let screen = NSScreen.screens.first { $0.frame.contains(face.origin) }?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        var x = face.midX - size.width / 2
        x = max(screen.minX + 8, min(x, screen.maxX - size.width - 8))
        p.setFrame(NSRect(x: x, y: face.minY - 6 - size.height, width: size.width, height: size.height), display: true)
        if !p.isVisible {
            p.alphaValue = 0
            p.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.15; p.animator().alphaValue = 1 }
        }
    }

    func hide() {
        guard let p = panel, p.isVisible else { reason = nil; return }
        reason = nil
        outsideSince = 0
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.12; p.animator().alphaValue = 0 }) {
            if self.reason == nil { p.orderOut(nil) }
        }
    }

    /// After a drop the panel stays a little, to show the new folder.
    func dropped() {
        dropUntil = Date.timeIntervalSinceReferenceDate + 2
    }

    private func makePanel() -> ShelfPanel {
        let p = ShelfPanel(contentRect: NSRect(x: 0, y: 0, width: 280, height: 200),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.level = .popUpMenu
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let effect = NSVisualEffectView()
        effect.material = .menu
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 10
        effect.layer?.masksToBounds = true
        let host = NSHostingView(rootView: FolderShelfView(store: store, shelf: self))
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

    /// The list changed size: keep the top edge under the face.
    func resize() {
        guard let p = panel, p.isVisible, let size = p.contentView?.fittingSize else { return }
        let top = p.frame.maxY
        p.setFrame(NSRect(x: p.frame.minX, y: top - size.height, width: size.width, height: size.height), display: true)
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

struct FolderShelfView: View {
    @ObservedObject var store: SettingsStore
    let shelf: FolderShelf

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L("Shared folders")).font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(L("Read only")).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            VStack(spacing: 4) {
                Image(systemName: "folder.badge.plus").font(.system(size: 18))
                Text(L("Drop folders here to share them with the AIs"))
                    .font(.system(size: 11)).multilineTextAlignment(.center)
            }
            .foregroundStyle(store.folderDropping ? Color.accentColor : Color.secondary)
            .frame(maxWidth: .infinity, minHeight: 64)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(store.folderDropping ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5]))
                .foregroundStyle(store.folderDropping ? Color.accentColor : Color.secondary.opacity(0.5)))
            if !store.folders.isEmpty {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(store.folders) { folder in row(folder) }
                    }
                }
                .frame(height: min(220, CGFloat(store.folders.count) * 36))
            }
            if !store.folderNotice.isEmpty {
                Text(store.folderNotice).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(L("Add folder…")) { shelf.add() }
                Spacer()
                Button(L("Settings…")) { shelf.settings() }
            }
            .buttonStyle(.link).font(.system(size: 11))
        }
        .font(.system(size: 12))
        .controlSize(.small)
        .padding(12)
        .frame(width: 280)
        .onDrop(of: [UTType.fileURL], isTargeted: $store.folderDropping) { providers in
            shelf.dropped()
            return droppedURLs(providers) { store.addFolders($0) }
        }
        .onChange(of: store.folders) { _ in DispatchQueue.main.async { shelf.resize() } }
        .onChange(of: store.folderNotice) { _ in DispatchQueue.main.async { shelf.resize() } }
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
            }
        }
        .frame(height: 36)
        .contextMenu {
            if !folder.missing {
                Button(L("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folder.path)]) }
            } else {
                Button(L("Locate…")) { shelf.hide(); store.locateFolder(folder) }
            }
            Button(L("Stop sharing (the folder itself is not touched)")) { store.removeFolder(folder) }
        }
    }
}
