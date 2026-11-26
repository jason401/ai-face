// AI Face Listener: writes down what this Mac plays and what the microphone hears, as text only.
// A helper app of its own (Contents/Helpers/AI Face Listener.app) so that only it holds the microphone
// and system audio permissions; AI Face, which AIs can drive over MCP, never does.
//
//   --start [--title T] [--language auto|ko|en] [--out FOLDER]   live, until "stop" (AI Face's panel)
//   --file AUDIO --out FOLDER [--language L]                     an audio file through the same path
//                                                                (tests; prints the transcript path)
// AI Face stops it with the distributed notification local.aiface.listener.stop; the Listener posts
// local.aiface.listener.status every 2 s (state, folder, since, lines, warning, error).
import AVFoundation
import Cocoa

let STOP = Notification.Name("local.aiface.listener.stop")
let STATUS = Notification.Name("local.aiface.listener.status")

struct Options {
    var live = false
    var file: String?
    var title = ""
    var language = "auto"
    var out: URL?

    init(_ args: [String]) {
        var i = 1
        func next() -> String? {
            i += 1
            return i < args.count ? args[i] : nil
        }
        while i < args.count {
            switch args[i] {
            case "--start": live = true
            case "--file": file = next()
            case "--title": title = next() ?? ""
            case "--language": language = next() ?? "auto"
            case "--out": out = next().map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            default: break
            }
            i += 1
        }
        if !["auto", "ko", "en"].contains(language) { language = "auto" }
    }
}

final class Session {
    let options: Options
    let started = Date()
    let whisper = Whisper()
    private let queue = DispatchQueue(label: "local.aiface.listener.session")    // segmenters, lines, file
    private let work = DispatchQueue(label: "local.aiface.listener.whisper")     // one utterance at a time
    private let me = Segmenter(track: .me)
    private let them = Segmenter(track: .them)
    private let assembler = Assembler()
    private var system: AnyObject?            // SystemCapture (macOS 14.2+)
    private let mic = MicCapture()
    private var handle: FileHandle?
    private(set) var folder: URL?
    private var lines = 0
    private var waiting = 0
    private var glossary = ""
    private var context: [Track: String] = [:]
    private var state = "starting"
    private var warning = ""
    private var startWarning = ""             // from starting the captures; stays until a live one
    private var error = ""
    private var timer: DispatchSourceTimer?
    private var activity: NSObjectProtocol?
    private var stopping = false
    private var lastRebuild = Date()
    private var ownerMissing = 0
    var finished: ((Int32) -> Void)?

    init(_ options: Options) {
        self.options = options
    }

    var elapsed: Double { Date().timeIntervalSince(started) }

    // MARK: - Start

    func begin() {
        post()
        do {
            try openTranscript()
        } catch {
            fail("Could not create the transcript: \(error.localizedDescription)")
            return
        }
        glossary = Self.loadGlossary()
        work.async {
            do {
                try self.whisper.start()
            } catch {
                DispatchQueue.main.async { self.fail("\(error)") }
                return
            }
            DispatchQueue.main.async {
                if let file = self.options.file { self.runFile(file) } else { self.startCapture() }
            }
        }
    }

    private func openTranscript() throws {
        let parent = options.out ?? Self.defaultFolder()
        var folder = parent.appendingPathComponent(Transcript.folderName(started: started, title: options.title))
        var n = 2
        while FileManager.default.fileExists(atPath: folder.path) {
            folder = parent.appendingPathComponent(Transcript.folderName(started: started, title: options.title) + "-\(n)")
            n += 1
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("transcript.md")
        let header = Transcript.header(title: options.title, started: started, language: Self.languageName(options.language))
        try Data(header.utf8).write(to: file)
        handle = try FileHandle(forWritingTo: file)
        handle?.seekToEndOfFile()
        self.folder = folder
    }

    private func startCapture() {
        activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated],
                                                         reason: "Transcribing")
        mic.onSamples = { [weak self] s in self?.take(s, .me) }
        mic.onRestart = { [weak self] in self?.restart(.me) }
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                if !granted { self.startWarning = "Microphone access is off: System Settings → Privacy & Security → Microphone." }
                do { try self.mic.start() } catch { self.startWarning = "Microphone: \(error)" }
            }
        }
        if #available(macOS 14.2, *) {
            let capture = SystemCapture()
            capture.onSamples = { [weak self] s in self?.take(s, .them) }
            capture.onRestart = { [weak self] in self?.restart(.them) }
            do {
                try capture.start()
                system = capture
            } catch {
                self.startWarning = "System audio: \(error)"
            }
        }
        state = "listening"
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in self?.second() }
        t.resume()
        timer = t
        post()
    }

    /// An audio file through the same segmenter → Whisper → transcript path (as "Them").
    private func runFile(_ path: String) {
        state = "listening"
        queue.async {
            do {
                let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
                guard let resampler = Resampler(from: file.processingFormat),
                      let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16_384) else {
                    throw CaptureError.os("Reading the file", -1)
                }
                while file.framePosition < file.length {
                    try file.read(into: buffer)
                    if buffer.frameLength == 0 { break }
                    for u in self.them.push(resampler.convert(buffer)) { self.enqueue(u) }
                }
                for u in self.them.push([Float](repeating: 0, count: Segmenter.rate)) { self.enqueue(u) }   // the end
            } catch {
                DispatchQueue.main.async { self.fail("\(error)") }
                return
            }
            DispatchQueue.main.async { self.stop() }
        }
    }

    // MARK: - Audio → lines

    private func take(_ samples: [Float], _ track: Track) {
        queue.async {
            let seg = track == .me ? self.me : self.them
            for u in seg.push(samples) { self.enqueue(u) }
        }
    }

    private func restart(_ track: Track) {
        let origin = elapsed
        queue.async {
            let seg = track == .me ? self.me : self.them
            for u in seg.restart(origin: origin) { self.enqueue(u) }
        }
    }

    /// On `queue`.
    private func enqueue(_ u: Utterance) {
        waiting += 1
        let prompt = Self.prompt(glossary: glossary, context: context[u.track] ?? "")
        let language = options.language
        work.async {
            let spoken: Spoken?
            do {
                spoken = try self.whisper.transcribe(u.samples, language: language, prompt: prompt)
            } catch {
                NSLog("AI Face Listener: \(error)")
                spoken = nil
            }
            self.queue.async {
                self.waiting -= 1
                guard let spoken = spoken, let text = Transcript.clean(Transcript.mark(text: spoken.text, words: spoken.words)) else { return }
                self.assembler.add(Line(track: u.track, start: u.start, end: u.end, text: text))
                self.context[u.track] = String(((self.context[u.track] ?? "") + " " + text).suffix(150))
            }
        }
    }

    /// On `queue`.
    private func write(_ out: [Line]) {
        guard !out.isEmpty, let handle = handle else { return }
        let text = out.map(Transcript.format).joined(separator: "\n") + "\n"
        handle.write(Data(text.utf8))
        lines += out.count
    }

    private func second() {
        let now = elapsed
        queue.async {
            self.write(self.assembler.ready(now: now))
            var live = ""
            if self.me.zeroSeconds > 10 {
                live = "The microphone gives only silence: check System Settings → Privacy & Security → Microphone, or its mute."
            } else if now > 30 && !self.them.heardSound {
                live = "Nothing heard from this Mac yet. If something was playing, allow AI Face Listener in System Settings → Privacy & Security → Screen & System Audio Recording."
            }
            if self.waiting > 6 { live = "Whisper is \(self.waiting) lines behind; they will still be written." }
            let rebuild = self.them.heardSound && self.them.zeroSeconds > 120
            DispatchQueue.main.async {
                self.warning = live.isEmpty ? self.startWarning : live
                if rebuild, Date().timeIntervalSince(self.lastRebuild) > 120, #available(macOS 14.2, *),
                   let capture = self.system as? SystemCapture {
                    self.lastRebuild = Date()
                    capture.rebuild()
                }
                if Int(now) % 2 == 0 { self.post() }
                self.watchOwner()
            }
        }
    }

    /// Stop when AI Face has been gone for a minute (nobody could stop it otherwise).
    private func watchOwner() {
        if options.file != nil { return }
        let running = !NSRunningApplication.runningApplications(withBundleIdentifier: "local.aiface").isEmpty
        ownerMissing = running ? 0 : ownerMissing + 1
        if ownerMissing >= 60 { stop() }
    }

    // MARK: - Stop

    func stop() {
        if stopping { return }
        stopping = true
        state = "stopping"
        post()
        mic.stop()
        if #available(macOS 14.2, *), let capture = system as? SystemCapture { capture.stop() }
        system = nil
        queue.async {
            for u in self.me.flush() + self.them.flush() { self.enqueue(u) }
            // After every utterance queued above (both queues are serial).
            self.work.async {
                self.queue.async {
                    self.write(self.assembler.drain())
                    let minutes = Int((self.elapsed / 60).rounded())
                    self.handle?.write(Data(Transcript.footer(stopped: Date(), minutes: minutes, lines: self.lines).utf8))
                    try? self.handle?.close()
                    self.handle = nil
                    self.work.async {
                        self.whisper.stop()
                        DispatchQueue.main.async { self.end(0) }
                    }
                }
            }
        }
    }

    private func end(_ code: Int32) {
        timer?.cancel()
        if let a = activity { ProcessInfo.processInfo.endActivity(a) }
        state = code == 0 ? "stopped" : "error"
        post()
        finished?(code)
    }

    private func fail(_ message: String) {
        error = message
        NSLog("AI Face Listener: \(message)")
        mic.stop()
        if #available(macOS 14.2, *), let capture = system as? SystemCapture { capture.stop() }
        if let handle = handle {
            handle.write(Data("\n- Stopped: \(message)\n".utf8))
            try? handle.close()
        }
        handle = nil
        work.async {
            self.whisper.stop()
            DispatchQueue.main.async { self.end(1) }
        }
    }

    private func post() {
        var info: [String: Any] = ["state": state, "since": started.timeIntervalSince1970, "lines": lines,
                                   "warning": warning, "error": error, "language": options.language]
        if let folder = folder { info["folder"] = folder.path }
        DistributedNotificationCenter.default().postNotificationName(STATUS, object: nil, userInfo: info,
                                                                    deliverImmediately: true)
    }

    // MARK: - Settings

    static func defaultFolder() -> URL {
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Meetings")
    }

    /// Names and terms Whisper should spell right: Listener/glossary.txt, one per line (# comments).
    static func loadGlossary() -> String {
        let url = Whisper.support.appendingPathComponent("glossary.txt")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        let terms = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        return String(terms.joined(separator: ", ").prefix(400))
    }

    /// Whisper's prompt: the glossary and the end of what this track said last (≤ 224 tokens).
    static func prompt(glossary: String, context: String) -> String {
        return [glossary, context.trimmingCharacters(in: .whitespaces)].filter { !$0.isEmpty }.joined(separator: ". ")
    }

    static func languageName(_ code: String) -> String {
        return ["ko": "Korean", "en": "English"][code] ?? "auto (per line)"
    }
}

// MARK: - Main

let options = Options(CommandLine.arguments)
guard options.live || options.file != nil else {
    FileHandle.standardError.write(Data("Usage: AIFaceListener --start [--title T] [--language auto|ko|en] [--out DIR]\n       AIFaceListener --file AUDIO --out DIR [--language L]\n".utf8))
    exit(2)
}
let session = Session(options)
session.finished = { code in
    if options.file != nil, code == 0, let folder = session.folder {
        print(folder.appendingPathComponent("transcript.md").path)
    }
    exit(code)
}
signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)
var signals: [DispatchSourceSignal] = []
for s in [SIGTERM, SIGINT] {
    let source = DispatchSource.makeSignalSource(signal: s, queue: .main)
    source.setEventHandler { session.stop() }
    source.resume()
    signals.append(source)
}
DistributedNotificationCenter.default().addObserver(forName: STOP, object: nil, queue: .main) { _ in session.stop() }
session.begin()
if options.file != nil {
    dispatchMain()
} else {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.run()
}
