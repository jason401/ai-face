// Checks for AI Face Listener's audio-free parts (segmenter, transcript, the tap buffer layout).
// Built and run by tests/test_listener.py: swiftc app/listener/{Segmenter,Transcript,Capture}.swift this main.swift
import CoreAudio
import Foundation

var failures = 0
func check(_ ok: Bool, _ what: String, line: Int = #line) {
    if !ok {
        failures += 1
        print("FAIL line \(line): \(what)")
    }
}

let rate = Segmenter.rate
func silence(_ s: Double) -> [Float] { [Float](repeating: 0, count: Int(s * Double(rate))) }
func noise(_ s: Double, _ amp: Float) -> [Float] {
    var x: UInt32 = 12345
    return (0..<Int(s * Double(rate))).map { _ in
        x = x &* 1_664_525 &+ 1_013_904_223
        return (Float(x % 2000) / 1000 - 1) * amp
    }
}
func tone(_ s: Double, _ amp: Float = 0.3) -> [Float] {
    (0..<Int(s * Double(rate))).map { amp * sinf(2 * .pi * 220 * Float($0) / Float(rate)) }
}

// Two utterances separated by quiet, in uneven chunks, with a little background noise.
do {
    let seg = Segmenter(track: .them)
    let audio = noise(1, 0.001) + tone(1.5) + noise(1.2, 0.001) + tone(2) + noise(2, 0.001)
    var out: [Utterance] = []
    var i = 0
    while i < audio.count {
        let n = min([999, 4096, 160, 7777][i % 4], audio.count - i)
        out += seg.push(Array(audio[i..<(i + n)]))
        i += n
    }
    out += seg.flush()
    check(out.count == 2, "two utterances, got \(out.count)")
    if out.count == 2 {
        check(abs(out[0].start - 0.7) < 0.15, "first starts ~0.7 s (0.3 s pre-roll), got \(out[0].start)")
        check(out[0].end > 2.45 && out[0].end < 3.3, "first ends after its speech, got \(out[0].end)")
        check(abs(out[1].start - 3.4) < 0.15, "second starts ~3.4 s, got \(out[1].start)")
        check(out.allSatisfy { $0.track == .them }, "track kept")
    }
}

// Quiet and short clicks make nothing; a long monologue is cut at ≤ 30 s and nothing is lost.
do {
    let seg = Segmenter(track: .me)
    var out = seg.push(silence(3) + tone(0.1) + silence(2))
    out += seg.flush()
    check(out.isEmpty, "a 100 ms click is not an utterance")
    check(seg.zeroSeconds > 1.5, "exact zeros are counted: \(seg.zeroSeconds)")
    check(seg.heardSound, "the click was heard")

    let long = Segmenter(track: .me)
    var speech = [Float]()
    for k in 0..<45 { speech += tone(1.6, k % 2 == 0 ? 0.3 : 0.15) + noise(0.15, 0.01) }   // ~79 s, no 0.7 s pause
    var parts = long.push(speech)
    parts += long.flush()
    check(parts.count >= 3, "cut into ≥ 3 pieces, got \(parts.count)")
    check(parts.allSatisfy { Double($0.samples.count) / Double(rate) <= 30.01 }, "every piece ≤ 30 s")
    let total = parts.reduce(0) { $0 + $1.samples.count }
    check(abs(total - speech.count) < rate, "pieces add up to the speech (\(total) vs \(speech.count))")
    for k in 1..<max(1, parts.count) {
        check(abs(parts[k].start - parts[k - 1].end) < 0.001, "pieces follow each other")
    }
}

// restart: a new timeline after a device change.
do {
    let seg = Segmenter(track: .them)
    _ = seg.push(tone(1))
    let flushed = seg.restart(origin: 100)
    check(flushed.count == 1, "the utterance in progress is flushed on restart")
    let after = seg.push(silence(0.5) + tone(1) + silence(1))
    check(after.count == 1 && abs(after[0].start - 100.2) < 0.15, "after restart times start at the origin: \(after.map(\.start))")
}

// WAV: 44-byte header, 16-bit mono.
do {
    let wav = Transcript.wav([0, 0.5, -1, 1])
    check(wav.count == 44 + 8, "wav size")
    check(String(data: wav[0..<4], encoding: .ascii) == "RIFF" && String(data: wav[8..<12], encoding: .ascii) == "WAVE", "wav magic")
    let rateField = wav[24..<28].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
    check(UInt32(littleEndian: rateField) == 16_000, "wav rate")
    let last = wav[50..<52].withUnsafeBytes { $0.loadUnaligned(as: Int16.self) }
    check(Int16(littleEndian: last) == 32767, "wav clamps to 32767")
}

// Cleaning.
check(Transcript.clean("  Thank you for watching. ") == nil, "a known invention is dropped")
check(Transcript.clean("시청해주셔서 감사합니다.") == nil, "Korean invention dropped")
check(Transcript.clean("[BLANK_AUDIO]") == nil && Transcript.clean("(음악)") == nil && Transcript.clean("♪ ♪") == nil, "tags dropped")
check(Transcript.clean("감사합니다.") == "감사합니다.", "a real 감사합니다 is kept")
check(Transcript.clean("Thank you for watching the demo, it helps") != nil, "an invention inside a real sentence is kept")
check(Transcript.clean("yes yes yes yes yes yes we can") == "yes we can", "loops collapse: \(Transcript.clean("yes yes yes yes yes yes we can") ?? "nil")")
check(Transcript.collapseLoops("a b a b a b a b c") == "a b c", "phrase loops collapse: \(Transcript.collapseLoops("a b a b a b a b c"))")
check(Transcript.collapseLoops("one two one two three") == "one two one two three", "a double is not a loop")

// Unsure words.
do {
    let words = [Word(text: " The", probability: 0.9), Word(text: " A0", probability: 0.2), Word(text: " mode.", probability: 0.95)]
    check(Transcript.mark(text: " The A0 mode.", words: words) == "The A0(?) mode.", "mark: \(Transcript.mark(text: " The A0 mode.", words: words))")
    check(Transcript.mark(text: "다른 글", words: words) == "다른 글", "words that do not add up leave the text alone")
    check(Transcript.mark(text: "The A0 mode.", words: []) == "The A0 mode.", "no words, no marks")
}

// Numbers flag lines; digits inside names do not.
check(Transcript.hasNumber("공진 주파수가 512kHz로"), "512kHz is a number")
check(Transcript.hasNumber("at 3.5 MPa"), "3.5 is a number")
check(!Transcript.hasNumber("The A0 mode in LiNbO3"), "A0 and LiNbO3 are names")
check(Transcript.format(Line(track: .them, start: 3725, end: 3730, text: "512 kHz")) == "⚑ [01:02:05] **Them:** 512 kHz", "format")
check(Transcript.format(Line(track: .me, start: 5, end: 6, text: "좋아요")) == "[00:00:05] **Me:** 좋아요", "format without flag")

// Folder names.
do {
    var c = DateComponents()
    c.year = 2026; c.month = 11; c.day = 26; c.hour = 15; c.minute = 4
    let d = Calendar(identifier: .gregorian).date(from: c)!
    check(Transcript.folderName(started: d, title: "") == "2026-11-26_1504", "folder without title")
    check(Transcript.folderName(started: d, title: " Butts Pauly / PRF: 1 kHz? ") == "2026-11-26_1504_Butts Pauly  PRF 1 kHz",
          "unsafe characters dropped: \(Transcript.folderName(started: d, title: " Butts Pauly / PRF: 1 kHz? "))")
    check(Transcript.folderName(started: d, title: "..") == "2026-11-26_1504", "dots only is no title")
}

// Similarity and the assembler: order, delay, bleed.
check(Transcript.similarity("The pressure drops quickly.", "the pressure drops quickly") > 0.95, "same words are similar")
check(Transcript.similarity("The pressure drops quickly.", "점심 뭐 먹을까요") < 0.1, "different words are not")
do {
    let a = Assembler()
    a.add(Line(track: .me, start: 10, end: 12, text: "so the pressure drops quickly"))      // the speakers, heard again
    a.add(Line(track: .them, start: 9.8, end: 12.2, text: "So the pressure drops quickly."))
    a.add(Line(track: .me, start: 4, end: 6, text: "그럼 다음 주에 다시 측정할게요"))
    check(a.ready(frontier: 3, now: 13).isEmpty, "nothing before the frontier")
    let early = a.ready(frontier: 8, now: 13)
    check(early.map(\.start) == [4], "only lines well before the frontier: \(early.map(\.start))")
    let out = a.ready(frontier: 30, now: 31)
    check(out.map(\.track) == [.them, .me], "time order: \(out.map { $0.track.rawValue + ":" + $0.text })")
    check(out.count == 2 && out[1].echo && !out[0].echo, "the bleed is kept and marked, not deleted")
    if out.count == 2 { check(Transcript.format(out[1]).hasPrefix("[00:00:10] **Me (echo?):**"), Transcript.format(out[1])) }
    a.add(Line(track: .me, start: 30, end: 32, text: "So the pressure drops quickly."))   // same words, much later: real
    let later = a.drain()
    check(later.count == 1 && !later[0].echo, "the same words later are not an echo")
}
do {
    // The microphone line is done first; the speaker line it repeats is still in Whisper (frontier 10.1).
    let a = Assembler()
    a.add(Line(track: .me, start: 10, end: 12, text: "evanescent field near the plate"))
    check(a.ready(frontier: 10.1, now: 20).isEmpty, "held while an earlier-starting line may still come")
    a.add(Line(track: .them, start: 10.1, end: 12.1, text: "Evanescent field near the plate."))
    let out = a.ready(frontier: 40, now: 40)
    check(out.count == 2 && out[0].echo && out[0].track == .me, "a late speaker line still marks the echo")
    // A track that stopped delivering does not hold lines forever.
    a.add(Line(track: .them, start: 50, end: 52, text: "still there?"))
    check(a.ready(frontier: 0, now: 100).isEmpty && a.ready(frontier: 0, now: 113).count == 1, "released after the 60 s cap")
}
do {
    // Notes: not transcribed, no ⚑, never an echo.
    let note = Line.missing(.them, start: 61, end: 64.4, "Whisper failed")
    check(Transcript.format(note) == "[00:01:01] **Them:** _(not transcribed, 3 s: Whisper failed)_", Transcript.format(note))
    check(!note.flagged, "a note has no ⚑")
}

// Segmenter frontier: the pre-roll start while idle, the utterance start while speaking.
do {
    let seg = Segmenter(track: .me, origin: 5)
    _ = seg.push(silence(2))
    check(abs(seg.frontier - (5 + 2 - 0.36)) < 0.03, "idle frontier = now − pre-roll: \(seg.frontier)")
    _ = seg.push(tone(1))
    check(seg.speaking && abs(seg.frontier - (5 + 2 - 0.3)) < 0.1, "speaking frontier = utterance start: \(seg.frontier)")
}

// Where the tap's buffers are in the aggregate's input list.
do {
    var f = AudioStreamBasicDescription()
    f.mFormatFlags = kAudioFormatFlagIsFloat     // interleaved stereo float32
    f.mChannelsPerFrame = 2
    f.mBytesPerFrame = 8
    let tap = TapLayout(format: f, deviceInputs: 1)
    check(tap.index(in: [(channels: 1, bytes: 2048), (channels: 2, bytes: 4096)]) == 1, "after the headset microphone")
    check(tap.index(in: [(channels: 2, bytes: 4096)]) == 0, "no device inputs reported: the last buffer if it fits")
    check(tap.index(in: [(channels: 1, bytes: 2048)]) == nil, "nothing that fits: nil, no guessing")
    check(tap.index(in: [(channels: 2, bytes: 4096), (channels: 2, bytes: 0)]) == nil, "an empty tap buffer is skipped, not replaced by a guess")
    var n = AudioStreamBasicDescription()
    n.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved
    n.mChannelsPerFrame = 2
    n.mBytesPerFrame = 4
    let split = TapLayout(format: n, deviceInputs: 2)
    check(split.index(in: [(channels: 1, bytes: 512), (channels: 1, bytes: 512), (channels: 1, bytes: 1024), (channels: 1, bytes: 1024)]) == 2,
          "non-interleaved: two buffers after two device inputs")
}

if failures == 0 { print("listener checks: OK") }
exit(failures == 0 ? 0 : 1)
