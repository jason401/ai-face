// What becomes of an utterance once Whisper has read it: cleaning, the order of the lines, the
// sound of the other side heard again by the microphone ("bleed"), and the transcript file.
import Foundation

struct Line {
    let track: Track
    let start: Double
    let end: Double
    let text: String          // with "(?)" after words Whisper was unsure of
    var flagged: Bool { Transcript.hasNumber(text) }
}

/// One word from whisper-server's verbose_json.
struct Word {
    let text: String
    let probability: Double
}

enum Transcript {
    /// Words below this probability get "(?)".
    static let unsure = 0.4

    /// Whisper's well known inventions on music, noise or quiet. Dropped when they are the whole line.
    static let inventions: [String] = [
        "thank you for watching", "thanks for watching", "thank you so much for watching",
        "please subscribe", "subscribe to my channel", "like and subscribe",
        "subtitles by the amara.org community", "transcription by castingwords",
        "시청해 주셔서 감사합니다", "시청해주셔서 감사합니다", "구독과 좋아요", "구독 좋아요",
        "다음 영상에서 만나요", "mbc 뉴스", "kbs 뉴스", "자막 제공",
    ]

    /// 16-bit mono PCM WAV of 16 kHz samples, built in memory for the upload.
    static func wav(_ samples: [Float], rate: Int = Segmenter.rate) -> Data {
        var data = Data(capacity: 44 + samples.count * 2)
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1)
        u32(UInt32(rate)); u32(UInt32(rate * 2)); u16(2); u16(16)
        data.append(contentsOf: Array("data".utf8)); u32(bytes)
        for s in samples {
            let v = Int16(max(-1, min(1, s)) * 32767)
            u16(UInt16(bitPattern: v))
        }
        return data
    }

    /// The text to keep, or nil for nothing worth writing.
    static func clean(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        text = collapseLoops(text)
        let bare = text.lowercased().trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespaces))
        if bare.isEmpty { return nil }
        if bare.unicodeScalars.allSatisfy({ !CharacterSet.alphanumerics.contains($0) }) { return nil }   // "♪", "..."
        if text.hasPrefix("[") && text.hasSuffix("]") { return nil }      // [Music], [BLANK_AUDIO]
        if text.hasPrefix("(") && text.hasSuffix(")") { return nil }      // (음악), (박수)
        if inventions.contains(where: { bare == $0 || bare == $0 + "." }) { return nil }
        return text
    }

    /// "the the the the the" or a phrase repeated 4+ times in a row → once.
    static func collapseLoops(_ text: String) -> String {
        var words = text.split(separator: " ").map(String.init)
        guard words.count >= 4 else { return text }
        var size = 1
        while size <= words.count / 4 {
            var i = 0
            var changed = false
            while i + size * 4 <= words.count {
                let unit = Array(words[i..<(i + size)])
                var repeats = 1
                while i + size * (repeats + 1) <= words.count,
                      Array(words[(i + size * repeats)..<(i + size * (repeats + 1))]) == unit {
                    repeats += 1
                }
                if repeats >= 4 {
                    words.removeSubrange((i + size)..<(i + size * repeats))
                    changed = true
                }
                i += 1
            }
            if !changed { size += 1 }
        }
        return words.joined(separator: " ")
    }

    /// The segment text with "(?)" after unsure words, when the words add up to the text
    /// (Korean tokens can be pieces of a syllable; then the plain text is kept).
    static func mark(text: String, words: [Word]) -> String {
        let joined = words.map(\.text).joined()
        guard !words.isEmpty, joined.trimmingCharacters(in: .whitespaces) == text.trimmingCharacters(in: .whitespaces),
              words.contains(where: { $0.probability < unsure }) else { return text }
        var out = ""
        for w in words {
            out += w.text
            let core = w.text.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespaces))
            if w.probability < unsure && !core.isEmpty { out += "(?)" }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// Lines with numbers get ⚑: a wrong number reads just as well as a right one. A digit right after
    /// a letter is part of a name (A0 mode, LiNbO3), not a value.
    static func hasNumber(_ text: String) -> Bool {
        return text.range(of: "(?<![\\p{L}])\\p{Nd}", options: .regularExpression) != nil
    }

    /// Dice similarity of letter bigrams, for "the microphone heard the speakers".
    static func similarity(_ a: String, _ b: String) -> Double {
        func grams(_ s: String) -> [String: Int] {
            let chars = Array(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
            var g: [String: Int] = [:]
            if chars.count < 2 { return g }
            for i in 0..<(chars.count - 1) { g[String(chars[i]) + String(chars[i + 1]), default: 0] += 1 }
            return g
        }
        let x = grams(a), y = grams(b)
        let nx = x.values.reduce(0, +), ny = y.values.reduce(0, +)
        if nx == 0 || ny == 0 { return 0 }
        var both = 0
        for (k, v) in x { both += min(v, y[k] ?? 0) }
        return 2 * Double(both) / Double(nx + ny)
    }

    static func clock(_ t: Double) -> String {
        let s = max(0, Int(t))
        return String(format: "%02d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
    }

    static func format(_ line: Line) -> String {
        return "\(line.flagged ? "⚑ " : "")[\(clock(line.start))] **\(line.track.rawValue):** \(line.text)"
    }

    static func header(title: String, started: Date, language: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        let name = title.isEmpty ? "Transcript" : title
        return """
        # \(name) — \(f.string(from: started))

        - Them = what this Mac played (every app), Me = the microphone. No audio was kept.
        - Language: \(language). Written by Whisper on this Mac; it can mishear names, terms and numbers.
        - ⚑ = the line has a number: check it before relying on it. (?) = a word Whisper was unsure of.


        """
    }

    static func footer(stopped: Date, minutes: Int, lines: Int) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return "\n- Stopped \(f.string(from: stopped)) · \(minutes) min · \(lines) lines\n"
    }

    /// "2026-11-26_1500" or "2026-11-26_1500_Weekly meeting" (unsafe characters dropped).
    static func folderName(started: Date, title: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HHmm"
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
        let safe = String(title.unicodeScalars.filter { !bad.contains($0) })
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        let short = String(safe.prefix(60))
        return short.isEmpty ? f.string(from: started) : "\(f.string(from: started))_\(short)"
    }
}

/// Holds lines for a few seconds so both tracks come out in time order and a microphone line
/// that only repeats what the speakers played (speakers instead of headphones) can be dropped.
final class Assembler {
    var delay = 8.0
    var bleedSimilarity = 0.5
    private var pending: [Line] = []
    private var recentThem: [Line] = []

    func add(_ line: Line) {
        pending.append(line)
    }

    /// Lines that ended before `now - delay`, in order.
    func ready(now: Double) -> [Line] {
        return take { $0.end <= now - self.delay }
    }

    func drain() -> [Line] {
        return take { _ in true }
    }

    private func take(_ due: (Line) -> Bool) -> [Line] {
        let out = pending.filter(due).sorted { $0.start < $1.start }
        if out.isEmpty { return [] }
        pending.removeAll(where: due)
        let them = recentThem + pending.filter { $0.track == .them } + out.filter { $0.track == .them }
        var kept: [Line] = []
        for line in out {
            if line.track == .me, them.contains(where: { isBleed(line, of: $0) }) { continue }
            kept.append(line)
        }
        recentThem.append(contentsOf: out.filter { $0.track == .them })
        if let last = out.last?.end { recentThem.removeAll { $0.end < last - 60 } }
        return kept
    }

    private func isBleed(_ me: Line, of them: Line) -> Bool {
        let overlap = me.start < them.end + 1.5 && them.start < me.end + 1.5
        return overlap && Transcript.similarity(me.text, them.text) >= bleedSimilarity
    }
}
