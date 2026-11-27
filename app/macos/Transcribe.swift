// "Transcribe" in the panel: starts and stops AI Face Listener (Contents/Helpers/AI Face Listener.app),
// which writes what this Mac plays and what the microphone hears to transcript.md,
// as text only. Only the helper opens the audio inputs. macOS may attribute its permission requests
// to the enclosing AI Face bundle. The main app only controls and displays the session.
import Cocoa

final class Transcriber {
    static let shared = Transcriber()
    static let bundleID = "local.aiface.listener"
    static let stopName = Notification.Name("local.aiface.listener.stop")
    static let statusName = Notification.Name("local.aiface.listener.status")
    static let support = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/AI Face/Listener")

    static let outputFolderKey = "transcriptOutputFolder"
    static let defaultOutputFolder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Meetings", isDirectory: true)
    static var glossaryFile: URL { support.appendingPathComponent("glossary.txt") }

    static func outputFolder(for path: String) -> URL {
        path.isEmpty ? defaultOutputFolder : URL(fileURLWithPath: path, isDirectory: true)
    }

    private var outputFolderPath: String {
        UserDefaults.standard.string(forKey: Self.outputFolderKey) ?? ""
    }

    private(set) var state = ""        // starting, listening, stopping, stopped, error ("" = no word yet)
    private(set) var folder = ""
    private(set) var since = 0.0
    private(set) var lines = 0
    private(set) var warning = ""
    private(set) var error = ""
    private var runningCache = false
    private var launching = false
    private var stopAsked: Date?
    private var confirmedStopping = false   // the Listener itself said "stopping": its inputs are closed
    private var runningChecked = 0.0

    private init() {
        DistributedNotificationCenter.default().addObserver(forName: Self.statusName, object: nil, queue: .main) { [weak self] note in
            guard let self = self, let info = note.userInfo else { return }
            self.state = (info["state"] as? String) ?? ""
            self.confirmedStopping = self.state == "stopping" || self.state == "stopped" || self.state == "error"
            self.folder = (info["folder"] as? String) ?? self.folder
            if self.confirmedStopping { self.stopAsked = nil }
            self.since = (info["since"] as? NSNumber)?.doubleValue ?? 0
            self.lines = (info["lines"] as? NSNumber)?.intValue ?? 0
            self.warning = (info["warning"] as? String) ?? ""
            self.error = (info["error"] as? String) ?? ""
            self.runningCache = self.state != "stopped" && self.state != "error"
            self.runningChecked = Date.timeIntervalSinceReferenceDate
        }
    }

    var helper: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/AI Face Listener.app") }

    /// The process tap needs macOS 14.2; older builds have no helper.
    var supported: Bool {
        ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 14, minorVersion: 2, patchVersion: 0))
            && FileManager.default.fileExists(atPath: helper.path)
    }

    /// whisper.cpp and a model are on this Mac ("Set up Transcription.command" puts them there).
    var setUp: Bool {
        let server = ["/opt/homebrew/bin/whisper-server", "/usr/local/bin/whisper-server"]
            .contains { FileManager.default.isExecutableFile(atPath: $0) }
        let models = (try? FileManager.default.contentsOfDirectory(atPath: Self.support.appendingPathComponent("models").path)) ?? []
        return server && models.contains { $0.hasPrefix("ggml-") && $0.hasSuffix(".bin") && !$0.contains("silero") }
    }

    /// Is the Listener running (checked at most once a second; the 12 fps panel asks often).
    var on: Bool {
        if launching { return true }
        let now = Date.timeIntervalSinceReferenceDate
        if now - runningChecked > 1 {
            let running = !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty
            if runningCache && !running && ["starting", "listening", "stopping"].contains(state) {
                state = "error"
                stopAsked = nil
                error = L("AI Face Listener quit unexpectedly.")
            }
            runningCache = running
            runningChecked = now
        }
        return runningCache
    }

    var capturing: Bool { on && state == "listening" }
    var stopping: Bool { stopAsked != nil || state == "stopping" }

    /// The panel's line: what it is doing now.
    func statusLine(_ now: Date = Date()) -> String {
        if stopAsked != nil { return L("Stopping transcription…") }
        switch state {
        case "starting": return L("Starting Whisper…")
        case "stopping": return L("Finishing the last lines…")
        case "stopped": return L("Transcript saved")
        case "error": return String(format: L("Transcription stopped: %@"), error)
        default:
            if !on { return "" }
            let minutes = since > 0 ? Int(now.timeIntervalSince1970 - since) / 60 : 0
            return String(format: L("● Transcribing · %ld min · %ld lines"), minutes, lines)
        }
    }

    func toggle() {
        if on { stop() } else { ask() }
    }

    /// Asks the Listener to stop, and asks again every 5 s until it says it is stopping (a distributed
    /// notification can be missed, e.g. while it was still loading).
    func stop() {
        DistributedNotificationCenter.default().postNotificationName(Self.stopName, object: nil, userInfo: nil,
                                                                    deliverImmediately: true)
        if stopAsked == nil { stopAsked = Date() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self = self, let asked = self.stopAsked, self.on, !self.confirmedStopping,
                  Date().timeIntervalSince(asked) < 120 else { return }
            self.stop()
        }
    }

    func openTranscript() {
        guard !folder.isEmpty else { return }
        let directory = URL(fileURLWithPath: folder, isDirectory: true)
        let file = directory.appendingPathComponent("transcript.md")
        NSWorkspace.shared.open(FileManager.default.fileExists(atPath: file.path) ? file : directory)
    }

    func openTranscriptFolder() {
        let path = outputFolderPath
        let folder = Self.outputFolder(for: path)
        do {
            if path.isEmpty {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            }
            if folderExists(folder), NSWorkspace.shared.open(folder) { return }
            showFolderError(folder)
        } catch {
            showFolderError(folder, reason: error.localizedDescription)
        }
    }

    func openGlossary() {
        let file = Self.glossaryFile
        try? FileManager.default.createDirectory(at: Self.support, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: file.path) {
            let starter = "# Names and terms Whisper should spell right, one per line (lines starting with # are ignored).\n# Example:\n# LiNbO3\n# hydrophone\n"
            try? starter.write(to: file, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(file)
    }

    func openSetup() {
        if let tool = Bundle.main.resourceURL?.appendingPathComponent("tools/Set up Transcription.command") {
            NSWorkspace.shared.open(tool)
        }
    }

    private func folderExists(_ folder: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private func showFolderError(_ folder: URL, reason: String? = nil) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("Transcript folder unavailable")
        alert.informativeText = [folder.path, reason, L("Check the folder or choose another in Settings → AI → Transcribe.")]
            .compactMap { $0 }.joined(separator: "\n\n")
        alert.runModal()
    }

    private func ask() {
        NSApp.activate(ignoringOtherApps: true)
        if !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty {
            // The last session is still writing its last lines: one Listener at a time.
            let alert = NSAlert()
            alert.messageText = L("The last transcript is still being finished")
            alert.informativeText = L("Try again in a moment.")
            alert.runModal()
            return
        }
        if !setUp {
            let alert = NSAlert()
            alert.messageText = L("Transcription needs whisper.cpp and a Whisper model")
            alert.informativeText = L("Set Up opens a Terminal window that installs whisper.cpp with Homebrew and downloads the Whisper model (about 600 MB) to this Mac. Transcribing then runs only on this Mac.")
            alert.addButton(withTitle: L("Set Up…"))
            alert.addButton(withTitle: L("Cancel"))
            if alert.runModal() == .alertFirstButtonReturn {
                openSetup()
            }
            return
        }
        let path = outputFolderPath
        let outputFolder = Self.outputFolder(for: path)
        guard path.isEmpty || folderExists(outputFolder) else {
            showFolderError(outputFolder)
            return
        }
        let alert = NSAlert()
        alert.messageText = L("Start transcribing?")
        alert.informativeText = String(format: L("AI Face Listener writes down what this Mac plays (every app, also videos and notifications) and what your microphone hears (also people near you), as text only: no audio is kept.\n\nSave to: %@\n\nIn California everyone in a conversation must agree before it is recorded or listened to. Ask first, and if someone joins later, stop until they agree too."), outputFolder.path)
        let form = ConsentForm(alert: alert)
        let start = alert.addButton(withTitle: L("Start"))
        alert.addButton(withTitle: L("Cancel"))
        start.isEnabled = false
        form.agreed = { start.isEnabled = $0 }
        alert.window.initialFirstResponder = form.title
        guard alert.runModal() == .alertFirstButtonReturn, form.agree.state == .on else { return }
        let agreed = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        launch(title: form.title.stringValue, language: ["auto", "ko", "en"][max(0, form.language.indexOfSelectedItem)],
               agreed: agreed, outputFolder: outputFolder)
    }

    private func launch(title: String, language: String, agreed: String, outputFolder: URL) {
        let config = NSWorkspace.OpenConfiguration()
        config.arguments = ["--start", "--agreed", agreed, "--title", title, "--language", language,
                            "--out", outputFolder.path]
        config.activates = false
        config.addsToRecentItems = false
        state = "starting"
        launching = true
        stopAsked = nil
        confirmedStopping = false
        warning = ""
        error = ""
        folder = ""
        lines = 0
        NSWorkspace.shared.openApplication(at: helper, configuration: config) { [weak self] app, err in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.launching = false
                if let err = err {
                    self.state = "error"
                    self.stopAsked = nil
                    self.error = err.localizedDescription
                } else if !self.confirmedStopping {
                    self.runningCache = app != nil
                    self.runningChecked = 0
                }
            }
        }
    }
}

/// Title, language, and the "everyone agreed" box that enables Start.
final class ConsentForm: NSObject {
    let view = NSView()
    let title = NSTextField()
    let language = NSPopUpButton()
    /// The "everyone agreed" box is NSAlert's own checkbox (its suppression button), which the alert
    /// lays out and draws itself. A checkbox of ours in the accessory view had the right frame but
    /// was not drawn on macOS 27, so Start could not be enabled.
    private(set) var agree = NSButton()
    var agreed: ((Bool) -> Void)?

    /// Title and language go in the alert's accessory view; the agreement box is the alert's.
    init(alert: NSAlert) {
        super.init()
        title.placeholderString = L("Title (optional)")
        title.translatesAutoresizingMaskIntoConstraints = false
        title.widthAnchor.constraint(equalToConstant: 260).isActive = true
        language.addItems(withTitles: [L("Automatic (each line)"), L("Korean"), L("English")])
        let languageRow = NSStackView(views: [NSTextField(labelWithString: L("Language")), language])
        let controls = NSStackView(views: [title, languageRow])
        controls.orientation = .vertical
        controls.alignment = .leading
        controls.spacing = 8
        controls.translatesAutoresizingMaskIntoConstraints = false
        view.setFrameSize(controls.fittingSize)
        view.addSubview(controls)
        NSLayoutConstraint.activate([
            controls.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controls.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            controls.topAnchor.constraint(equalTo: view.topAnchor),
            controls.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        alert.accessoryView = view
        alert.showsSuppressionButton = true
        if let box = alert.suppressionButton {
            box.title = L("Everyone in the conversation agreed")
            box.state = .off
            box.target = self
            box.action = #selector(toggled)
            agree = box
        }
    }

    @objc private func toggled() {
        agreed?(agree.state == .on)
    }
}
