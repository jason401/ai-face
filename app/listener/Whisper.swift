// whisper.cpp's whisper-server, run by the Listener while it transcribes: the model stays loaded, and
// each utterance goes over 127.0.0.1 as an in-memory WAV. Without --convert the server reads the
// upload from memory and writes nothing; it still runs in an empty folder of its own, which the
// Listener removes when it stops.
import Foundation

struct Spoken {
    let text: String
    let words: [Word]
    let language: String
}

enum WhisperError: Error, CustomStringConvertible {
    case notInstalled, noModel, notStarting(String), failed(String)
    var description: String {
        switch self {
        case .notInstalled: return "whisper.cpp is not installed (brew install whisper-cpp)."
        case .noModel: return "No Whisper model in \(Whisper.modelFolder.path)."
        case .notStarting(let s): return "whisper-server did not start: \(s)"
        case .failed(let s): return "Whisper failed: \(s)"
        }
    }
}

final class Whisper {
    /// Models and glossary.txt (AIFACE_LISTENER_SUPPORT: another folder, for tests).
    static let support = ProcessInfo.processInfo.environment["AIFACE_LISTENER_SUPPORT"].map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/AI Face/Listener")
    static let modelFolder = support.appendingPathComponent("models")
    /// Best first (turbo: large-v3 with a 4-layer decoder, multilingual, much faster).
    static let models = ["ggml-large-v3-turbo-q5_0.bin", "ggml-large-v3-turbo-q8_0.bin", "ggml-large-v3-turbo.bin",
                         "ggml-large-v3.bin", "ggml-medium.bin", "ggml-small.bin"]
    static let vadModel = "ggml-silero-v5.1.2.bin"

    static func server() -> URL? {
        let env = ProcessInfo.processInfo.environment["AIFACE_WHISPER_SERVER"].map { [$0] } ?? []
        for p in env + ["/opt/homebrew/bin/whisper-server", "/usr/local/bin/whisper-server"]
            where FileManager.default.isExecutableFile(atPath: p) {
            return URL(fileURLWithPath: p)
        }
        return nil
    }

    static func model() -> URL? {
        for name in models {
            let u = modelFolder.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        return nil
    }

    private var process: Process?
    private var work: URL?
    private var port = 0

    func start() throws {
        guard let exe = Self.server() else { throw WhisperError.notInstalled }
        guard let model = Self.model() else { throw WhisperError.noModel }
        port = Self.freePort()
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("aiface-whisper-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        self.work = work
        let p = Process()
        p.executableURL = exe
        var args = ["-m", model.path, "--host", "127.0.0.1", "--port", String(port), "-t", "4"]
        let vad = Self.modelFolder.appendingPathComponent(Self.vadModel)
        if FileManager.default.fileExists(atPath: vad.path) { args += ["--vad", "-vm", vad.path] }
        p.arguments = args
        p.currentDirectoryURL = work
        p.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        p.standardError = errors
        try p.run()
        process = p
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline {
            if !p.isRunning {
                let tail = String(data: errors.fileHandleForReading.availableData, encoding: .utf8) ?? ""
                throw WhisperError.notStarting(String(tail.suffix(300)))
            }
            if ping() {
                // Keep reading its log so the pipe never fills and blocks it.
                errors.fileHandleForReading.readabilityHandler = { h in _ = h.availableData }
                return
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        stop()
        throw WhisperError.notStarting("no answer in 90 s")
    }

    func stop() {
        if let p = process, p.isRunning {
            p.terminate()
            p.waitUntilExit()
        }
        process = nil
        if let w = work { try? FileManager.default.removeItem(at: w) }
        work = nil
    }

    /// The server is still running (it can crash, e.g. out of memory).
    var alive: Bool { process?.isRunning ?? false }

    /// After a crash: start it again on a new port.
    func restart() throws {
        stop()
        try start()
    }

    /// The folder the server runs in (empty unless something wrote audio there; the tests check).
    var workFolder: URL? { work }

    /// Transcribes one utterance (blocking; call it off the main thread).
    func transcribe(_ samples: [Float], language: String, prompt: String) throws -> Spoken {
        let boundary = "aiface-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"u.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(Transcript.wav(samples))
        body.append(Data("\r\n".utf8))
        field("language", language)
        field("response_format", "verbose_json")
        field("temperature", "0.0")
        field("temperature_inc", "0.2")
        if !prompt.isEmpty { field("prompt", prompt) }
        body.append(Data("--\(boundary)--\r\n".utf8))

        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/inference")!, timeoutInterval: 120)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        let (data, status) = Self.send(req)
        guard status == 200, let data = data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WhisperError.failed("HTTP \(status)")
        }
        if let e = json["error"] as? String { throw WhisperError.failed(e) }
        var text = ""
        var words: [Word] = []
        for seg in (json["segments"] as? [[String: Any]]) ?? [] {
            // A segment Whisper itself thinks is not speech, and is not sure of, is left out.
            let noSpeech = (seg["no_speech_prob"] as? Double) ?? 0
            let logprob = (seg["avg_logprob"] as? Double) ?? 0
            if noSpeech > 0.6 && logprob < -0.7 { continue }
            text += (seg["text"] as? String) ?? ""
            for w in (seg["words"] as? [[String: Any]]) ?? [] {
                words.append(Word(text: (w["word"] as? String) ?? "", probability: (w["probability"] as? Double) ?? 1))
            }
        }
        if (json["segments"] as? [[String: Any]]) == nil { text = (json["text"] as? String) ?? "" }
        return Spoken(text: text, words: words, language: (json["language"] as? String) ?? language)
    }

    private func ping() -> Bool {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/")!, timeoutInterval: 1)
        req.httpMethod = "GET"
        return Self.send(req).1 != 0
    }

    private static func send(_ req: URLRequest) -> (Data?, Int) {
        let done = DispatchSemaphore(value: 0)
        var result: (Data?, Int) = (nil, 0)
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            result = (data, (resp as? HTTPURLResponse)?.statusCode ?? 0)
            done.signal()
        }.resume()
        done.wait()
        return result
    }

    private static func freePort() -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) }
        }
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        return Int(UInt16(bigEndian: addr.sin_port))
    }
}
