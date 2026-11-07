import Cocoa
import SwiftUI

// Render settings tabs with fixture data to PNGs. No server, board, Calendar or Mail access.
@main struct SettingsPreview {
    static func main() throws {
        precondition(API.preview, "Render only with AIFACE_PREVIEW=1")
        guard let home = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] else {
            fatalError("Preview requires an isolated home")
        }
        precondition(FileManager.default.homeDirectoryForCurrentUser.path == home)
        let key = FolderShelf.hoverKey
        let before = UserDefaults.standard.object(forKey: key) as? Bool
        let probe = SettingsStore()
        probe.folderShelfHover = false
        precondition((UserDefaults.standard.object(forKey: key) as? Bool) == before,
                     "Preview must not persist fixture values")
        API.shared.base = URL(string: "http://127.0.0.1:1")
        API.shared.token = "preview-fixture"
        precondition(!API.shared.ready && API.shared.url("api") == nil,
                     "Preview must never contact the app server")
        let now = Date(timeIntervalSince1970: 100)
        let progress = UpdateProgress(["stage": "install", "started": 90,
            "waiting": true, "prepared": true, "retry_at": 110])!
        precondition(progress.stage == 3 && progress.summary(at: now).contains("10"))
        precondition(progress.summary(at: now.addingTimeInterval(3)).contains("7"))
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let store = SettingsStore()
        store.version = "2.1.0 (3613ce9)"
        store.weatherLocation = ["name": "Example City", "timezone": "America/Los_Angeles"]
        store.weatherDetail = L("Current model estimate") + " · " + L("Rain") + " · 2026-11-04T18:00:00-08:00"
        store.loginItem = true
        store.awakeSupported = true
        store.awakeReady = true
        store.awakeCommand = true
        store.updateText = String(format: L("New version available (%@)"), "90a4d6e") + "\nBuild like AI Illuminati\n" + String(format: L("Last checked %@"), "Oct 28, 11:13")
        store.updateAvailable = true
        store.saverType = "slideshow"
        store.claude = "on"; store.claudeCode = "on"; store.claudeCodeAvailable = true; store.codexAvailable = true
        store.illuminatiAvailable = true; store.illuminati = "on"
        store.hooks = "on"
        store.calAccess = "full"; store.calWriteClaude = true
        store.calendars = [CalendarItem(id: "1", title: "Home", account: "iCloud", shown: true, canWrite: true, write: true),
                           CalendarItem(id: "2", title: "Work", account: "Google", shown: true, canWrite: true),
                           CalendarItem(id: "3", title: "Holidays", account: "Subscribed", shown: false)]
        store.calChanges = [CalendarChange(n: 1, text: "Added “Coffee with Min” Oct 29 9:00", undone: false),
                            CalendarChange(n: 2, text: "Moved “Dentist” to Nov 2 15:00", undone: true)]
        store.mailAccess = "allowed"
        store.mailAccounts = [MailAccount(name: "iCloud", shown: true), MailAccount(name: "Gmail", shown: false)]
        store.folders = [SharedFolder(id: "f1", name: "Papers", path: "/Users/example/Documents/Papers", last: "Read by Claude · 5 min ago"),
                         SharedFolder(id: "f2", name: "Lab data", path: "/Users/example/Documents/Lab data", on: false),
                         SharedFolder(id: "f3", name: "Old notes", path: "/Volumes/Backup/Old notes", missing: true)]
        store.serverPath = "/Users/me/Library/Application Support/AI Face/ai_face_mcp.py"
        store.lightNight = true; store.lightOffSleeping = true; store.lightBright = 70; store.lightFrom = 23; store.lightTo = 7
        store.connected = true; store.port = "/dev/cu.usbmodem14101"; store.ports = ["/dev/cu.usbmodem14101"]
        store.photos = [1, 2, 3]; store.currentPhoto = 2
        store.library = (1...7).map { LibraryItem(name: "photo\($0).jpg", mtime: $0) }
        let base = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        func tl(_ n: Int, _ day: Double) -> [[String: Any]] {
            (0..<n).map { ["t": day + Double(30000 + $0 * 1700), "owner": $0 % 3 == 0 ? "claude" : $0 % 3 == 1 ? "gpt" : "illuminati", "name": "Happy"] }
        }
        func counts(_ i: Int) -> [String: Any] { ["claude": (i * 7) % 11, "gpt": (i * 5) % 9, "illuminati": (i * 3) % 5, "user": i % 4 == 0 ? 2 : 0] }
        let owners: [String: Any] = [
            "claude": ["count": 14, "top": [["name": "Focused", "count": 3], ["name": "Proud", "count": 3], ["name": "Thinking", "count": 3]],
                       "groups": ["work": 8, "joy": 5, "oops": 1]],
            "gpt": ["count": 11, "top": [["name": "Happy", "count": 3], ["name": "Talking", "count": 3]], "groups": ["joy": 6, "work": 4, "wonder": 1]],
            "illuminati": ["count": 6, "top": [["name": "Curious", "count": 2]], "groups": ["wonder": 4, "joy": 2]]]
        let periods: [String: [String: Any]] = [
            "day": ["kind": "day", "total": 25, "owners": owners, "timeline": tl(18, base), "rows": []],
            "week": ["kind": "week", "total": 25, "owners": owners, "timeline": [], "rows": (0..<7).map { i -> [String: Any] in
                let day = Date(timeIntervalSince1970: base - Double((6 - i) * 86400))
                return ["day": SettingsStore.dayFormat.string(from: day), "timeline": tl(i * 3 % 8, day.timeIntervalSince1970)] }],
            "month": ["kind": "month", "total": 25, "owners": owners, "timeline": [], "rows": (1...31).map { i -> [String: Any] in
                var r = counts(i); r["day"] = String(format: "2026-10-%02d", i); return r }],
            "year": ["kind": "year", "total": 25, "owners": owners, "timeline": [], "rows": (1...12).map { i -> [String: Any] in
                var r = counts(i); r["day"] = String(format: "2026-%02d", i); return r }]]
        func history(_ kind: String) -> AnyView {
            store.historyKind = kind
            store.applyHistory(periods[kind] ?? [:])
            return AnyView(HistoryTab(store: store))
        }
        let weatherStore = SettingsStore()
        weatherStore.weatherLocation = store.weatherLocation
        weatherStore.weatherMode = "date"
        weatherStore.weatherHour = 20
        weatherStore.weatherDate = SettingsStore.weatherDateFormat.date(from: "2026-10-20")!
        weatherStore.weatherDetail = L("Historical reanalysis") + " · " + L("Rain") + " · 2026-10-20T20:00:00-07:00"
        let waitingStore = SettingsStore()
        waitingStore.updateProgress = progress
        waitingStore.updateText = L("Update prepared · waiting for active work to finish")
        let views: [(String, () -> AnyView)] = [
            ("1general-waiting", { AnyView(GeneralTab(store: waitingStore)) }),
            ("1general", { AnyView(GeneralTab(store: store)) }), ("1appearance", { AnyView(AppearanceTab(store: store)) }), ("1appearance-noboard", { AnyView(SettingsPage { BoardCard(store: SettingsStore()) }) }),
            ("1weather-date", { AnyView(SettingsPage { CampfireWeatherCard(store: weatherStore) }) }), ("2ai", { AnyView(AITab(store: store)) }),
            ("2ai-shelf", { AnyView(FolderShelfView(store: store, shelf: FolderShelf(store: store)).background(Color(nsColor: .windowBackgroundColor))) }), ("2ai-folders", { AnyView(FolderList(store: store).background(Color(nsColor: .windowBackgroundColor))) }), ("2ai-calendars", { AnyView(CalendarList(store: store).background(Color(nsColor: .windowBackgroundColor))) }), ("2ai-changes", { AnyView(CalendarChanges(store: store).background(Color(nsColor: .windowBackgroundColor))) }),
            ("2ai-mail", { AnyView(MailAccountList(store: store).background(Color(nsColor: .windowBackgroundColor))) }),
            ("3board", { AnyView(BoardDetails(store: store)) }),
            ("4history-day", { history("day") }), ("4history-week", { history("week") }),
            ("4history-month", { history("month") }), ("4history-year", { history("year") })]
        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            for (name, make) in views {
                let view = make()
                let size = NSSize(width: SettingsWindowController.size.width, height: name.hasPrefix("2ai-") ? 420 : 1000)
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
        let previewData = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AI Face")
        precondition(!FileManager.default.fileExists(atPath: previewData.path),
                     "Preview must not create application data")
    }
}
