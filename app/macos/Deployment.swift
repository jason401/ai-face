import Cocoa
import ServiceManagement

// The installer runs out of process. Acknowledgement means the bundled server is serving
// the expected revision, not merely that launch services opened an app.
enum Deployment {
    static let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/AI Face")
    static var journal: URL { support.appendingPathComponent("updates/transaction.json") }
    static func record() -> [String: Any]? {
        guard let data = try? Data(contentsOf: journal) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
    static func acknowledge(_ done: @escaping () -> Void = {}) {
        guard let r = record() else { done(); return }
        if r["phase"] as? String == "failed", r["restoreLogin"] as? Bool == true {
            try? SMAppService.mainApp.register()
            done()
            return
        }
        guard r["phase"] as? String == "starting",
              r["target"] as? String == Bundle.main.bundlePath,
              let revision = Bundle.main.object(forInfoDictionaryKey: "AISourceRevision") as? String,
              r["revision"] as? String == revision,
              let token = r["token"] as? String, UUID(uuidString: token) != nil else { done(); return }
        API.shared.getJSON("status") { json in
            defer { done() }
            guard let status = json as? [String: Any], status["revision"] as? String == revision else { return }
            if r["restoreLogin"] as? Bool == true {
                do { try SMAppService.mainApp.register() }
                catch { NSLog("AI Face: login registration failed: \(error)"); return }
            }
            let ack: [String: Any] = ["revision": revision, "pid": ProcessInfo.processInfo.processIdentifier]
            if let data = try? JSONSerialization.data(withJSONObject: ack) {
                try? data.write(to: support.appendingPathComponent("updates/\(token).ack"), options: .atomic)
            }
        }
    }
    static func shouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard var r = record(), r["phase"] as? String == "prepared",
              (r["parentPID"] as? NSNumber)?.int32Value == ProcessInfo.processInfo.processIdentifier else { return .terminateNow }
        API.shared.call("install_prepare", timeout: 60) { ok, _ in
            guard ok else { sender.reply(toApplicationShouldTerminate: false); return }
            do {
                if SMAppService.mainApp.status == .enabled {
                    r["restoreLogin"] = true
                    try JSONSerialization.data(withJSONObject: r).write(to: journal, options: .atomic)
                    try SMAppService.mainApp.unregister()
                }
                sender.reply(toApplicationShouldTerminate: true)
            } catch {
                API.shared.call("install_cancel")
                sender.reply(toApplicationShouldTerminate: false)
            }
        }
        return .terminateLater
    }
}
