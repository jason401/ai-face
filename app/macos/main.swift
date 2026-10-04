// AI Face.app: starts the Python server (core/run_server.py), shows the face in the menu
// bar (even with no ESP32 plugged in) and owns the settings window.
//
// The Python server is the source of truth: /emotions (every mood's frames), /view (what
// the face shows now), /status, and POST /api for changes. Build: 앱 빌드.command.
import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {
    var server: Process?
    var status: StatusController?
    let settings = SettingsWindowController()
    var background = false
    var logPath = ""
    private var received = Data()

    func applicationDidFinishLaunching(_ notification: Notification) {
        background = CommandLine.arguments.contains("--background")
        let root = (Bundle.main.bundlePath as NSString).deletingLastPathComponent
        let script = (root as NSString).appendingPathComponent("core/run_server.py")
        guard FileManager.default.fileExists(atPath: script) else {
            fail(L("Keep AI Face.app in the AI Face project folder (next to the core folder)."))
            return
        }
        let face = StatusController()
        face.openSettings = { [weak self] in self?.settings.show() }
        status = face

        logPath = (root as NSString).appendingPathComponent("app-launch.log")
        FileManager.default.createFile(atPath: logPath, contents: nil, attributes: nil)
        let output = Pipe()
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        task.arguments = [script]
        task.currentDirectoryURL = URL(fileURLWithPath: root)
        // The server and the MCP server speak the language the app picked (en / ko).
        var env = ProcessInfo.processInfo.environment
        env["AIFACE_LANG"] = APP_LANGUAGE
        task.environment = env
        task.standardOutput = output
        task.standardError = FileHandle(forWritingAtPath: logPath) ?? FileHandle.nullDevice
        // First line: the server's address; second line: the token for POST requests.
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            DispatchQueue.main.async { self?.serverOutput(data, handle: handle) }
        }
        task.terminationHandler = { [weak self] finished in
            let code = finished.terminationStatus
            DispatchQueue.main.async { self?.serverEnded(code) }
        }
        do {
            try task.run()
        } catch {
            fail(L("Could not start Python: ") + error.localizedDescription)
            return
        }
        server = task
    }

    private func serverOutput(_ data: Data, handle: FileHandle) {
        if API.shared.ready { return }
        received.append(data)
        guard let text = String(data: received, encoding: .utf8) else { return }
        let lines = text.components(separatedBy: "\n")
        guard lines.count >= 3 else { return }   // two complete lines
        let address = lines[0].trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: address + "/"), url.host == "127.0.0.1", url.scheme == "http" else { return }
        API.shared.base = url
        API.shared.token = lines[1].trimmingCharacters(in: .whitespaces)
        handle.readabilityHandler = nil
        status?.start()
        if !background { settings.show() }
    }

    private func serverEnded(_ code: Int32) {
        if code != 0 {
            let details = (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? ""
            fail(details.isEmpty ? L("The AI Face server stopped.") : details)
            return
        }
        NSApp.terminate(nil)
    }

    private func fail(_ message: String) {
        let alert = NSAlert()
        alert.messageText = L("AI Face could not start")
        alert.informativeText = String(message.suffix(3000))
        alert.addButton(withTitle: L("OK"))
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
        NSApp.terminate(nil)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settings.show()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let task = server, task.isRunning {
            task.terminationHandler = nil
            task.terminate()
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
