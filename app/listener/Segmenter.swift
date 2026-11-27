// Cuts one track (16 kHz mono) into utterances for Whisper. Everything stays in memory: the
// samples of an utterance live only until it is transcribed, and no audio is ever written to disk.
//
// A plain energy detector with an adaptive noise floor: 20 ms frames, an utterance starts after
// 60 ms above the floor (with 300 ms kept from before it) and ends after `hangover` of quiet.
// Whisper's own Silero VAD (whisper-server --vad) then trims inside each utterance, so this
// only has to find roughly where speech is; it never decides what was said.
import Foundation

enum Track: String {
    case me = "Me"        // the microphone
    case them = "Them"    // everything this Mac plays
}

struct Utterance {
    let track: Track
    let start: Double     // seconds since the session began
    let samples: [Float]
    var end: Double { start + Double(samples.count) / Double(Segmenter.rate) }
}

final class Segmenter {
    static let rate = 16_000
    static let frame = 320                    // 20 ms
    static let frameSeconds = 0.02

    let track: Track
    var maxSeconds = 30.0                     // Whisper's window
    var hangover = 0.7                        // quiet that ends an utterance
    var preRoll = 0.3                         // kept from before the onset
    var minSpeech = 0.3                       // loud time an utterance needs to be kept

    /// Level of the last second (dBFS) and how long the track has been exactly zero: an
    /// all-zero system track usually means the audio capture permission is missing.
    private(set) var level: Float = -120
    private(set) var zeroSeconds = 0.0
    private(set) var heardSound = false

    private var origin: Double                // session time of sample 0
    private var index = 0                     // samples taken into frames so far
    private var pending: [Float] = []         // less than a frame
    private var history: [Float] = []         // the last `preRoll` while idle
    private var current: [Float] = []
    private var currentStart = 0              // sample index of current[0]
    private var levels: [Float] = []          // dB of each frame of `current`
    private var speechFrames = 0
    private var quietFrames = 0
    private var onset = 0
    private var noise: Float = -70
    private var levelSum: Float = 0
    private var levelFrames = 0

    init(track: Track, origin: Double = 0) {
        self.track = track
        self.origin = origin
    }

    var speaking: Bool { !current.isEmpty }

    /// Session time before which this track can produce no new utterance: the start of the one in
    /// progress, or else of the pre-roll it would keep. Lines are written only up to the earliest
    /// frontier of both tracks, so they come out in time order.
    var frontier: Double {
        let first = current.isEmpty ? index - history.count : currentStart
        return origin + Double(first) / Double(Self.rate)
    }

    /// Adds samples; returns the utterances they finished.
    func push(_ samples: [Float]) -> [Utterance] {
        pending.append(contentsOf: samples)
        var out: [Utterance] = []
        var at = 0
        while pending.count - at >= Self.frame {
            if let u = step(Array(pending[at..<(at + Self.frame)])) { out.append(contentsOf: u) }
            at += Self.frame
        }
        pending.removeFirst(at)
        return out
    }

    /// The utterance in progress, if any (at the end of a session or before a device change).
    func flush() -> [Utterance] {
        if !pending.isEmpty {
            current.append(contentsOf: pending)
            pending = []
        }
        let u = finish(upTo: current.count)
        reset()
        return u.map { [$0] } ?? []
    }

    /// After the audio device changed: the next samples start at session time `origin`.
    func restart(origin: Double) -> [Utterance] {
        let u = flush()
        self.origin = origin
        index = 0
        history = []
        return u
    }

    private func reset() {
        current = []
        levels = []
        speechFrames = 0
        quietFrames = 0
        onset = 0
    }

    private func step(_ frame: [Float]) -> [Utterance]? {
        var sum: Float = 0
        var zero = true
        for s in frame {
            sum += s * s
            if s != 0 { zero = false }
        }
        let db = 10 * log10(sum / Float(frame.count) + 1e-12)
        index += frame.count
        zeroSeconds = zero ? zeroSeconds + Self.frameSeconds : 0
        if !zero { heardSound = true }
        levelSum += db
        levelFrames += 1
        if levelFrames == 50 {
            level = levelSum / 50
            levelSum = 0
            levelFrames = 0
        }

        let threshold = max(-50, noise + 12)
        let loud = db > threshold
        if loud {
            noise += 0.002 * (db - noise)         // a steady hum slowly becomes the floor
        } else {
            noise += 0.05 * (max(db, -90) - noise)
        }

        if current.isEmpty {
            history.append(contentsOf: frame)
            let keep = Int(preRoll * Double(Self.rate)) + Self.frame * 3
            if history.count > keep { history.removeFirst(history.count - keep) }
            onset = loud ? onset + 1 : 0
            if onset >= 3 {
                current = history
                currentStart = index - history.count
                levels = Array(repeating: db, count: history.count / Self.frame)
                speechFrames = onset
                quietFrames = 0
                history = []
            }
            return nil
        }

        current.append(contentsOf: frame)
        levels.append(db)
        if loud {
            speechFrames += 1
            quietFrames = 0
        } else {
            quietFrames += 1
        }
        if Double(quietFrames) * Self.frameSeconds >= hangover {
            let tail = max(0, quietFrames - 10) * Self.frame        // keep 200 ms of the quiet
            let u = finish(upTo: current.count - tail)
            reset()
            return u.map { [$0] }
        }
        if Double(current.count) >= maxSeconds * Double(Self.rate) {
            // Too long: cut at the quietest frame of the last 3 s and go on from there.
            let frames = levels.count
            let from = max(0, frames - 150)
            var cut = frames
            var lowest = Float.greatestFiniteMagnitude
            for i in from..<frames where levels[i] < lowest {
                lowest = levels[i]
                cut = i + 1
            }
            let samples = min(cut * Self.frame, current.count)
            let u = finish(upTo: samples)
            let rest = Array(current[samples...])
            let restStart = currentStart + samples
            let restLevels = Array(levels[min(cut, levels.count)...])
            reset()
            if !rest.isEmpty {
                current = rest
                currentStart = restStart
                levels = restLevels
                speechFrames = restLevels.filter { $0 > threshold }.count
            }
            return u.map { [$0] }
        }
        return nil
    }

    private func finish(upTo count: Int) -> Utterance? {
        guard count > 0, Double(speechFrames) * Self.frameSeconds >= minSpeech else { return nil }
        let start = origin + Double(currentStart) / Double(Self.rate)
        return Utterance(track: track, start: start, samples: Array(current[0..<min(count, current.count)]))
    }
}
