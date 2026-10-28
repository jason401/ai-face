import Cocoa
import SwiftUI

// Render settings tabs with fixture data to PNGs. No server, board, Calendar or Mail access.
@main struct SettingsPreview {
    static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let store = SettingsStore()
        store.version = "2.1.0 (3613ce9)"
        store.loginItem = true
        store.awakeSupported = true
        store.awakeReady = true
        store.awakeCommand = true
        store.updateText = String(format: L("Up to date (%@)"), "3613ce9") + "\n" + String(format: L("Last checked %@"), "Oct 28, 11:13")
        store.saverType = "slideshow"
        store.claude = "on"; store.claudeCode = "on"; store.claudeCodeAvailable = true; store.codexAvailable = true
        store.hooks = "on"
        store.calAccess = "full"; store.calWriteClaude = true
        store.calendars = [CalendarItem(id: "1", title: "Home", account: "iCloud", shown: true, canWrite: true, write: true),
                           CalendarItem(id: "2", title: "Work", account: "Google", shown: true, canWrite: true),
                           CalendarItem(id: "3", title: "Holidays", account: "Subscribed", shown: false)]
        store.calChanges = [CalendarChange(n: 1, text: "Added “Coffee with Min” Oct 29 9:00", undone: false),
                            CalendarChange(n: 2, text: "Moved “Dentist” to Nov 2 15:00", undone: true)]
        store.mailAccess = "allowed"
        store.mailAccounts = [MailAccount(name: "iCloud", shown: true), MailAccount(name: "Gmail", shown: false)]
        store.serverPath = "/Users/me/Library/Application Support/AI Face/ai_face_mcp.py"
        store.connected = true; store.port = "/dev/cu.usbmodem14101"; store.ports = ["/dev/cu.usbmodem14101"]
        store.photos = [1, 2, 3]; store.currentPhoto = 2
        store.library = (1...7).map { LibraryItem(name: "photo\($0).jpg", mtime: $0) }
        store.dayTotal = 18
        store.dayStats = ["claude": OwnerStats(count: 7, top: ["Focused ×3", "Thinking ×3"], groups: ["work": 6, "joy": 1]),
                          "gpt": OwnerStats(count: 11, top: ["Happy ×3", "Talking ×3"], groups: ["joy": 6, "work": 5])]
        store.timeline = (0..<18).map { TimelineEvent(id: $0, t: store.historyDay.timeIntervalSince1970 + Double(32000 + $0 * 1500), owner: $0 % 3 == 0 ? "claude" : "gpt", name: "happy") }
        store.week = ["Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed"].enumerated().map {
            WeekRow(id: "\($0.offset)", label: $0.element, counts: ["claude": 3 + $0.offset, "gpt": 10 - $0.offset, "user": 1])
        }
        let views: [(String, AnyView)] = [("1general", AnyView(GeneralTab(store: store))), ("2ai", AnyView(AITab(store: store))),
                                          ("3board", AnyView(BoardTab(store: store))), ("4history", AnyView(HistoryTab(store: store)))]
        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            for (name, view) in views {
                let size = NSSize(width: SettingsWindowController.size.width, height: 1300)
                let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
                let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: appearance)
                window.contentView = host
                host.frame = NSRect(origin: .zero, size: size)
                for _ in 0..<5 {
                    host.layoutSubtreeIfNeeded()
                    window.displayIfNeeded()
                    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                }
                let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let theme = appearance == .darkAqua ? "dark" : "light"
                try bitmap.representation(using: .png, properties: [:])!
                    .write(to: output.appendingPathComponent("\(APP_LANGUAGE)-\(theme)-\(name).png"))
                window.contentView = nil
            }
        }
    }
}
