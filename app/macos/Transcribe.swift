// "Transcribe" in the panel: starts and stops AI Face Listener (Contents/Helpers/AI Face Listener.app),
// which writes what this Mac plays and what the microphone hears to ~/Meetings/…/transcript.md,
// as text only. AI Face itself never gets the microphone or system audio permission: it only launches
// the helper, asks it to stop, and shows the status it posts (app/listener/main.swift).
import Cocoa

final class Transcriber {
    static let shared = Transcriber()
    static let bundleID = "local.aiface.listener"
    static let stopName = Notification.Name("local.aiface.listener.stop")
    static let statusName = Notification.Name("local.aiface.listener.status")
    static let support = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/AI Face/Listener")

    private(set) var state = ""        // starting, listening, stopping, stopped, error ("" = no word yet)
    private(set) var folder = ""
    private(set) var since = 0.0
    private(set) var lines = 0
    private(set) var warning = ""
    private(set) var error = ""
    private var runningCache = false
    private var stopAsked: Date?
    private var confirmedStopping = false   // the Listener itself said "stopping": its inputs are closed
    private var runningChecked = 0.0

    private init() {
        DistributedNotificationCenter.default().addObserver(forName: Self.statusName, object: nil, queue: .main) { [weak self] note in
            guard let self = self, let info = note.userInfo else { return }
            self.state = (info["state"] as? String) ?? ""
            self.confirmedStopping = self.state == "stopping" || self.state == "stopped" || self.state == "error"
            self.folder = (info["folder"] as? String) ?? self.folder
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
        let now = Date.timeIntervalSinceReferenceDate
        if now - runningChecked > 1 {
            runningCache = !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty
            runningChecked = now
        }
        return runningCache
    }

    /// The panel's line: what it is doing now.
    func statusLine(_ now: Date = Date()) -> String {
        switch state {
        case "starting": return L("Starting Whisper…")
        case "stopping": return L("Finishing the last lines…")
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
        if state != "stopping" { stopAsked = Date() }
        state = "stopping"
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self = self, let asked = self.stopAsked, self.on, !self.confirmedStopping,
                  Date().timeIntervalSince(asked) < 120 else { return }
            self.stop()
        }
    }

    func openTranscript() {
        let file = URL(fileURLWithPath: folder).appendingPathComponent("transcript.md")
        if FileManager.default.fileExists(atPath: file.path) {
            NSWorkspace.shared.open(file)
        } else if !folder.isEmpty {
            NSWorkspace.shared.open(URL(fileURLWithPath: folder))
        }
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
            if alert.runModal() == .alertFirstButtonReturn,
               let tool = Bundle.main.resourceURL?.appendingPathComponent("tools/Set up Transcription.command") {
                NSWorkspace.shared.open(tool)
            }
            return
        }
        let form = ConsentForm()
        let alert = NSAlert()
        alert.messageText = L("Start transcribing?")
        alert.informativeText = L("AI Face Listener writes down what this Mac plays (every app, also videos and notifications) and what your microphone hears (also people near you), as text only: no audio is kept. Transcripts go to Meetings in your home folder, on this Mac only; share that folder with the AIs only if you want them to read them.\n\nIn California everyone in a conversation must agree before it is recorded or listened to. Ask first, and if someone joins later, stop until they agree too.")
        alert.accessoryView = form.view
        let start = alert.addButton(withTitle: L("Start"))
        alert.addButton(withTitle: L("Cancel"))
        start.isEnabled = false
        form.agreed = { start.isEnabled = $0 }
        alert.window.initialFirstResponder = form.title
        guard alert.runModal() == .alertFirstButtonReturn, form.agree.state == .on else { return }
        let agreed = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        launch(title: form.title.stringValue, language: ["auto", "ko", "en"][max(0, form.language.indexOfSelectedItem)],
               agreed: agreed)
    }

    private func launch(title: String, language: String, agreed: String) {
        let config = NSWorkspace.OpenConfiguration()
        config.arguments = ["--start", "--agreed", agreed, "--title", title, "--language", language]
        config.activates = false
        config.addsToRecentItems = false
        state = "starting"
        stopAsked = nil
        confirmedStopping = false
        warning = ""
        error = ""
        lines = 0
        NSWorkspace.shared.openApplication(at: helper, configuration: config) { [weak self] _, err in
            guard let err = err else { return }
            DispatchQueue.main.async {
                self?.state = "error"
                self?.error = err.localizedDescription
            }
        }
    }
}

/// Title, language, and the "everyone agreed" box that enables Start.
private final class ConsentForm: NSObject {
    let view = NSStackView()
    let title = NSTextField()
    let language = NSPopUpButton()
    let agree = NSButton(checkboxWithTitle: L("Everyone in the conversation agreed"), target: nil, action: nil)
    var agreed: ((Bool) -> Void)?

    override init() {
        super.init()
        title.placeholderString = L("Title (optional)")
        title.translatesAutoresizingMaskIntoConstraints = false
        title.widthAnchor.constraint(equalToConstant: 260).isActive = true
        language.addItems(withTitles: [L("Automatic (each line)"), L("Korean"), L("English")])
        let languageRow = NSStackView(views: [NSTextField(labelWithString: L("Language")), language])
        agree.target = self
        agree.action = #selector(toggled)
        view.orientation = .vertical
        view.alignment = .leading
        view.spacing = 8
        view.addArrangedSubview(title)
        view.addArrangedSubview(languageRow)
        view.addArrangedSubview(agree)
        view.frame = NSRect(x: 0, y: 0, width: 260, height: 86)
    }

    @objc private func toggled() {
        agreed?(agree.state == .on)
    }
}
