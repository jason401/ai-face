// AI Face Listener: writes down what this Mac plays and what the microphone hears, as text only.
// A helper app of its own (Contents/Helpers/AI Face Listener.app): only it opens the microphone and
// the system audio tap. macOS attributes the permission to the enclosing AI Face bundle (its usage
// strings are checked, and Privacy & Security lists AI Face), but no code in AI Face or its server
// records audio.
//
//   --start --agreed TIME [--title T] [--language auto|ko|en] [--out FOLDER]
//        live, until "stop" (AI Face's panel). TIME: when everyone's agreement was confirmed there;
//        without it the Listener does not start.
//   --file AUDIO --out FOLDER [--language L]
//        an audio file through the same path (tests; prints the transcript path)
// AI Face stops it with the distributed notification local.aiface.listener.stop; the Listener posts
// local.aiface.listener.status every 2 s (state, folder, since, lines, warning, error).
//
// Threads: the main queue owns starting and stopping (`stopping` is set once and checked by every late
// callback: a permission answer, the Whisper server coming up, a device change); `queue` owns the
// segmenters, the lines and the file; `work` runs Whisper, one utterance at a time.
import AVFoundation
import Cocoa

let STOP = Notification.Name("local.aiface.listener.stop")
let STATUS = Notification.Name("local.aiface.listener.status")

struct Options {
    var live = false
    var file: String?
    var title = ""
    var language = "auto"
    var agreed = ""
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
            case "--agreed": agreed = next() ?? ""
            case "--out": out = next().map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            default: break
            }
            i += 1
        }
        if !["auto", "ko", "en"].contains(language) { language = "auto" }
    }
}

/// A time after which Whisper is not asked any more (set when stopping); read from `work`.
final class Deadline {
    private let lock = NSLock()
    private var at = Date.distantFuture
    func set(_ date: Date) { lock.lock(); at = min(at, date); lock.unlock() }
    var passed: Bool { lock.lock(); defer { lock.unlock() }; return Date() > at }
}

final class Session {
    /// Audio waiting for Whisper beyond this is not transcribed (and marked so): memory stays bounded.
    static let backlogSeconds = 600.0
    /// After Stop, at most this long for the lines still waiting.
    static let finishSeconds = 180.0

    let options: Options
    let started = Date()
    let whisper = Whisper()
    private let queue = DispatchQueue(label: "local.aiface.listener.session")    // segmenters, lines, file
    private let work = DispatchQueue(label: "local.aiface.listener.whisper")     // one utterance at a time
    private let deadline = Deadline()
    // main queue
    private var system: AnyObject?            // SystemCapture (macOS 14.2+)
    private let mic = MicCapture()
    private var state = "starting"
    private var warning = ""
    private var startWarning = ""             // from starting the captures; stays until a live one
    private var error = ""
    private var timer: DispatchSourceTimer?
    private var activity: NSObjectProtocol?
    private var stopping = false
    private var ended = false
    private var lastRebuild = Date()
    private var ownerMissing = 0
    private(set) var folder: URL?
    var finished: ((Int32) -> Void)?
    // queue
    private let me = Segmenter(track: .me)
    private let them = Segmenter(track: .them)
    private let assembler = Assembler()
    private var handle: FileHandle?
    private var live: Set<Track> = []         // tracks delivering audio (their frontier holds lines back)
    private var inflight: [Double] = []       // starts of utterances queued for or inside Whisper
    private var waitingSeconds = 0.0
    private var lines = 0
    private var missed = 0                    // utterances marked "not transcribed"
    private var glossary = ""

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
                guard !self.stopping else { return }      // stopped while Whisper was loading
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
        let header = Transcript.header(title: options.title, started: started,
                                       language: Self.languageName(options.language), agreed: options.agreed)
        try Data(header.utf8).write(to: file)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        queue.sync { self.handle = handle }
        self.folder = folder
    }

    private func startCapture() {
        activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated],
                                                         reason: "Transcribing")
        mic.onSamples = { [weak self] s in self?.take(s, .me) }
        mic.onRestart = { [weak self] in self?.restart(.me) }
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                guard !self.stopping else { return }      // the answer came after Stop: open nothing
                guard granted else {
                    self.startWarning = "Microphone access is off, so only this Mac's sound is written: System Settings → Privacy & Security → Microphone."
                    return
                }
                do {
                    try self.mic.start()
                    self.queue.async { self.live.insert(.me) }
                } catch {
                    self.startWarning = "Microphone: \(error)"
                }
            }
        }
        if #available(macOS 14.2, *) {
            let capture = SystemCapture()
            capture.onSamples = { [weak self] s in self?.take(s, .them) }
            capture.onRestart = { [weak self] in self?.restart(.them) }
            do {
                try capture.start()
                system = capture
                queue.async { self.live.insert(.them) }
            } catch {
                capture.stop()
                startWarning = "System audio: \(error)"
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

    private enum Heard {
        case spoken(Spoken)
        case missing(String)
    }

    /// On `queue`.
    private func enqueue(_ u: Utterance) {
        let seconds = u.end - u.start
        if waitingSeconds + seconds > Self.backlogSeconds {
            missed += 1
            assembler.add(.missing(u.track, start: u.start, end: u.end, "Whisper was too far behind"))
            return
        }
        waitingSeconds += seconds
        inflight.append(u.start)
        let prompt = glossary
        let language = options.language
        work.async {
            let heard = self.transcribe(u, language: language, prompt: prompt)
            self.queue.async {
                self.waitingSeconds -= seconds
                if let i = self.inflight.firstIndex(of: u.start) { self.inflight.remove(at: i) }
                switch heard {
                case .spoken(let spoken):
                    if let text = Transcript.clean(Transcript.mark(text: spoken.text, words: spoken.words)) {
                        self.assembler.add(Line(track: u.track, start: u.start, end: u.end, text: text))
                    }
                case .missing(let reason):
                    self.missed += 1
                    self.assembler.add(.missing(u.track, start: u.start, end: u.end, reason))
                }
            }
        }
    }

    /// On `work`: one try, and one more after restarting a crashed server.
    private func transcribe(_ u: Utterance, language: String, prompt: String) -> Heard {
        if deadline.passed { return .missing("stopped before Whisper got to it") }
        for attempt in 0..<2 {
            do {
                return .spoken(try whisper.transcribe(u.samples, language: language, prompt: prompt))
            } catch {
                NSLog("AI Face Listener: \(error)")
                if attempt == 0 && !whisper.alive && !deadline.passed { try? whisper.restart() }
            }
        }
        return .missing("Whisper failed")
    }

    /// On `queue`.
    private func write(_ out: [Line]) {
        guard !out.isEmpty, let handle = handle else { return }
        let text = out.map(Transcript.format).joined(separator: "\n") + "\n"
        do {
            try handle.write(contentsOf: Data(text.utf8))
            lines += out.filter { !$0.note }.count
        } catch {
            self.handle = nil
            DispatchQueue.main.async { self.fail("Could not write the transcript: \(error.localizedDescription)") }
        }
    }

    /// On `queue`: nothing can still come before this time.
    private func frontier(_ now: Double) -> Double {
        var fronts = inflight
        if live.contains(.me) { fronts.append(me.frontier) }
        if live.contains(.them) { fronts.append(them.frontier) }
        return fronts.min() ?? now
    }

    private func second() {
        let now = elapsed
        let capture: AnyObject? = system
        queue.async {
            self.write(self.assembler.ready(frontier: self.frontier(now), now: now))
            var live = ""
            if self.live.contains(.me) && self.me.zeroSeconds > 10 {
                live = "The microphone gives only silence: check System Settings → Privacy & Security → Microphone, or its mute."
            } else if self.live.contains(.them) && now > 30 && !self.them.heardSound {
                live = "Nothing heard from this Mac yet. If something was playing, allow AI Face Listener in System Settings → Privacy & Security → Screen & System Audio Recording."
            }
            if self.waitingSeconds > 60 {
                live = "Whisper is \(Int(self.waitingSeconds)) s of speech behind; it catches up when people pause."
            }
            if self.missed > 0 { live += (live.isEmpty ? "" : " ") + "\(self.missed) lines could not be transcribed (marked in the transcript)." }
            let zeros = self.them.heardSound && self.them.zeroSeconds > 120
            DispatchQueue.main.async {
                guard !self.stopping else { return }
                var warning = live
                if #available(macOS 14.2, *), let capture = capture as? SystemCapture {
                    // No callbacks for 5 s (the device went away) or 2 min of exact zeros: rebuild the tap.
                    let quiet = capture.silentFor > 5
                    if (quiet || zeros), Date().timeIntervalSince(self.lastRebuild) > (quiet ? 10 : 120) {
                        self.lastRebuild = Date()
                        capture.rebuild()
                    }
                    if quiet { warning = "This Mac's sound stopped arriving; trying again." }
                    if capture.mismatched > 50 && warning.isEmpty {
                        warning = "This Mac's sound arrives in a layout the Listener does not know; it is skipped."
                    }
                }
                self.warning = warning.isEmpty ? self.startWarning : warning
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

    /// Closes both inputs at once, then writes what is still waiting (at most `finishSeconds`).
    func stop() {
        if stopping { return }
        stopping = true
        closeInputs()
        deadline.set(Date().addingTimeInterval(Self.finishSeconds))
        state = "stopping"                        // posted only after the inputs are closed
        post()
        queue.async {
            self.live = []
            for u in self.me.flush() + self.them.flush() { self.enqueue(u) }
            // After every utterance queued above (both queues are serial).
            self.work.async {
                self.queue.async {
                    self.write(self.assembler.drain())
                    let minutes = Int((self.elapsed / 60).rounded())
                    if let handle = self.handle {
                        try? handle.write(contentsOf: Data(Transcript.footer(stopped: Date(), minutes: minutes, lines: self.lines).utf8))
                        try? handle.close()
                    }
                    self.handle = nil
                    self.work.async {
                        self.whisper.stop()
                        DispatchQueue.main.async { self.end(0) }
                    }
                }
            }
        }
    }

    private func closeInputs() {
        mic.stop()
        if #available(macOS 14.2, *), let capture = system as? SystemCapture { capture.stop() }
        system = nil
    }

    private func end(_ code: Int32) {
        if ended { return }
        ended = true
        timer?.cancel()
        if let a = activity { ProcessInfo.processInfo.endActivity(a) }
        state = code == 0 ? "stopped" : "error"
        post()
        finished?(code)
    }

    private func fail(_ message: String) {
        if ended { return }
        stopping = true
        error = message
        NSLog("AI Face Listener: \(message)")
        closeInputs()
        deadline.set(Date())
        queue.async {
            if let handle = self.handle {
                try? handle.write(contentsOf: Data("\n- Stopped: \(message)\n".utf8))
                try? handle.close()
            }
            self.handle = nil
            self.work.async {
                self.whisper.stop()
                DispatchQueue.main.async { self.end(1) }
            }
        }
    }

    private func post() {
        var info: [String: Any] = ["state": state, "since": started.timeIntervalSince1970, "lines": queue.sync { lines },
                                   "warning": warning, "error": error, "language": options.language]
        if let folder = folder { info["folder"] = folder.path }
        DistributedNotificationCenter.default().postNotificationName(STATUS, object: nil, userInfo: info,
                                                                    deliverImmediately: true)
    }

    // MARK: - Settings

    /// ~/Meetings: outside Documents (which iCloud may sync) and outside ~/Library (which AI Face's
    /// shared folders refuse), so transcripts stay on this Mac and can still be shared with the AIs.
    static func defaultFolder() -> URL {
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Meetings")
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

    static func languageName(_ code: String) -> String {
        return ["ko": "Korean", "en": "English"][code] ?? "auto (per line)"
    }
}

// MARK: - Main

let options = Options(CommandLine.arguments)
guard options.live || options.file != nil else {
    FileHandle.standardError.write(Data("Usage: AIFaceListener --start --agreed TIME [--title T] [--language auto|ko|en] [--out DIR]\n       AIFaceListener --file AUDIO --out DIR [--language L]\n".utf8))
    exit(2)
}
if options.live && options.file == nil && options.agreed.isEmpty {
    // Start from AI Face's panel, which asks everyone's agreement first.
    FileHandle.standardError.write(Data("Not started: confirm in AI Face that everyone agreed (--agreed).\n".utf8))
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
