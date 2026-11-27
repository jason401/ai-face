// The two ears: everything this Mac plays (a Core Audio process tap on all processes, macOS 14.2+)
// and the default microphone (AVAudioEngine). Both hand over 16 kHz mono floats; nothing is stored.
//
// The tap follows AudioCap (github.com/insidegui/AudioCap): tap → private aggregate device with the
// tap in its tap list and the default output as clock → IOProc. When the default output changes
// (AirPods in or out) the aggregate is rebuilt, since its clock device may be gone.
import AVFoundation
import CoreAudio
import Foundation

enum CaptureError: Error, CustomStringConvertible {
    case os(String, OSStatus)
    case noMicrophone
    var description: String {
        switch self {
        case .os(let what, let status): return "\(what) failed (OSStatus \(status))"
        case .noMicrophone: return "No microphone"
        }
    }
}

/// Any input format → 16 kHz mono float, keeping the converter's state between buffers.
final class Resampler {
    static let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(Segmenter.rate),
                                      channels: 1, interleaved: false)!
    private let converter: AVAudioConverter

    init?(from format: AVAudioFormat) {
        guard let c = AVAudioConverter(from: format, to: Self.target) else { return nil }
        c.downmix = true
        converter = c
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
        let ratio = Self.target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard buffer.frameLength > 0, let out = AVAudioPCMBuffer(pcmFormat: Self.target, frameCapacity: capacity) else { return [] }
        var given = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if given {
                status.pointee = .noDataNow
                return nil
            }
            given = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let data = out.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(out.frameLength)))
    }
}

@available(macOS 14.2, *)
final class SystemCapture {
    var onSamples: (([Float]) -> Void)?
    var onRestart: (() -> Void)?             // after a rebuild: the next samples start a new timeline
    /// Callbacks whose buffers did not look like the tap's (wrong stream layout): reported as a warning.
    var mismatched: Int {
        lock.lock()
        defer { lock.unlock() }
        return misses
    }
    private var misses = 0
    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var aggregate = AudioObjectID(kAudioObjectUnknown)
    private var proc: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "local.aiface.listener.system", qos: .userInitiated)
    private var active = false               // between start and stop; a late rebuild after stop does nothing
    private let lock = NSLock()
    private var callbackTime = Date.timeIntervalSinceReferenceDate
    private lazy var outputChanged: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        DispatchQueue.main.async { self?.rebuild() }
    }

    /// Seconds since the tap last delivered audio (the Listener rebuilds after a few).
    var silentFor: Double {
        lock.lock()
        defer { lock.unlock() }
        return Date.timeIntervalSinceReferenceDate - callbackTime
    }

    func start() throws {
        active = true
        try build()
        // Where apps play (not the alert device): the aggregate's clock is that device.
        var addr = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main, outputChanged)
    }

    func stop() {
        guard active else { return }
        active = false
        var addr = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main, outputChanged)
        teardown()
    }

    /// Tear everything down and build it again (device change, no callbacks, or a long run of zeros:
    /// long sessions have been seen to deliver only zero buffers until the tap is recreated).
    func rebuild() {
        guard active else { return }
        teardown()
        onRestart?()
        do { try build() } catch { NSLog("AI Face Listener: system audio rebuild failed: \(error)") }
    }

    private func build() throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .unmuted
        var tapID = AudioObjectID(kAudioObjectUnknown)
        var err = AudioHardwareCreateProcessTap(description, &tapID)
        guard err == noErr else { throw CaptureError.os("Creating the system audio tap", err) }
        tap = tapID

        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var addr = Self.address(kAudioTapPropertyFormat)
        err = AudioObjectGetPropertyData(tap, &addr, 0, nil, &size, &format)
        guard err == noErr, format.mBytesPerFrame > 0, let avFormat = AVAudioFormat(streamDescription: &format),
              let resampler = Resampler(from: avFormat) else {
            teardown()
            throw CaptureError.os("Reading the tap format", err)
        }

        let (device, output) = try Self.defaultOutput()
        let settings: [String: Any] = [
            kAudioAggregateDeviceNameKey: "AI Face Listener",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: output,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: output]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        err = AudioHardwareCreateAggregateDevice(settings as CFDictionary, &aggregateID)
        guard err == noErr else {
            teardown()
            throw CaptureError.os("Creating the aggregate device", err)
        }
        aggregate = aggregateID

        // The aggregate's input buffers are the output device's own input streams (a headset's or
        // AirPods' microphone) and then the tap's. Read only the tap's; check their shape every time.
        let layout = TapLayout(format: format, deviceInputs: Self.inputStreams(device))
        var procID: AudioDeviceIOProcID?
        err = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregate, queue) { [weak self] _, input, _, _, _ in
            guard let self = self else { return }
            self.lock.lock()
            self.callbackTime = Date.timeIntervalSinceReferenceDate
            self.lock.unlock()
            guard let buffer = layout.copy(UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)),
                                           format: avFormat) else {
                self.lock.lock()
                self.misses += 1
                self.lock.unlock()
                return
            }
            let samples = resampler.convert(buffer)
            if !samples.isEmpty { self.onSamples?(samples) }
        }
        guard err == noErr, let procID = procID else {
            teardown()
            throw CaptureError.os("Creating the audio callback", err)
        }
        proc = procID
        disableDeviceInputs(layout.deviceInputs, proc: procID)
        err = AudioDeviceStart(aggregate, procID)
        guard err == noErr else {
            teardown()
            throw CaptureError.os("Starting system audio", err)
        }
        lock.lock()
        callbackTime = Date.timeIntervalSinceReferenceDate
        lock.unlock()
    }

    /// Asks Core Audio not to run the output device's own input streams for our callback, so a
    /// headset's microphone is not opened by us (it may also keep Bluetooth out of call mode; not
    /// measured). If it fails nothing changes: TapLayout still skips those buffers.
    private func disableDeviceInputs(_ count: Int, proc: AudioDeviceIOProcID) {
        guard count > 0 else { return }
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyIOProcStreamUsage,
                                              mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(aggregate, &addr, 0, nil, &size) == noErr,
              Int(size) >= MemoryLayout<AudioHardwareIOProcStreamUsage>.size else { return }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 8)
        defer { raw.deallocate() }
        let usage = raw.bindMemory(to: AudioHardwareIOProcStreamUsage.self, capacity: 1)
        usage.pointee.mIOProc = unsafeBitCast(proc, to: UnsafeMutableRawPointer.self)
        guard AudioObjectGetPropertyData(aggregate, &addr, 0, nil, &size, raw) == noErr,
              let offset = MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mStreamIsOn) else { return }
        let streams = Int(usage.pointee.mNumberStreams)
        let on = raw.advanced(by: offset).bindMemory(to: UInt32.self, capacity: streams)
        for i in 0..<min(count, streams) { on[i] = 0 }
        AudioObjectSetPropertyData(aggregate, &addr, 0, nil, size, raw)
    }

    private func teardown() {
        if aggregate != kAudioObjectUnknown {
            if let proc = proc {
                AudioDeviceStop(aggregate, proc)
                AudioDeviceDestroyIOProcID(aggregate, proc)
            }
            AudioHardwareDestroyAggregateDevice(aggregate)
        }
        if tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tap) }
        proc = nil
        aggregate = AudioObjectID(kAudioObjectUnknown)
        tap = AudioObjectID(kAudioObjectUnknown)
    }

    static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        return AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    }

    /// The device apps play to, and its UID.
    static func defaultOutput() throws -> (AudioObjectID, String) {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        var err = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device)
        guard err == noErr else { throw CaptureError.os("Finding the output device", err) }
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        addr = address(kAudioDevicePropertyDeviceUID)
        err = AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &uid)
        guard err == noErr, let value = uid?.takeRetainedValue() else { throw CaptureError.os("Reading the output device", err) }
        return (device, value as String)
    }

    /// How many input streams a device has (a headset's microphone, for example).
    static func inputStreams(_ device: AudioObjectID) -> Int {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeInput,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr else { return 0 }
        return Int(size) / MemoryLayout<AudioStreamID>.size
    }
}

/// Where the tap's buffers are in the aggregate's input buffer list, and a checked copy of them.
struct TapLayout {
    let deviceInputs: Int        // buffers before the tap's (the output device's own inputs)
    let buffers: Int             // the tap's buffers: 1 interleaved, or one per channel
    let channelsPerBuffer: Int
    let bytesPerFrame: Int

    init(format: AudioStreamBasicDescription, deviceInputs: Int) {
        let interleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        self.deviceInputs = deviceInputs
        buffers = interleaved ? 1 : Int(format.mChannelsPerFrame)
        channelsPerBuffer = interleaved ? Int(format.mChannelsPerFrame) : 1
        bytesPerFrame = Int(format.mBytesPerFrame)
    }

    /// The tap's first buffer: right after the device's inputs; if the list does not look like
    /// that, the last buffers when their shape fits; else nil (nothing is guessed).
    func index(in list: [(channels: Int, bytes: Int)]) -> Int? {
        func fits(_ at: Int) -> Bool {
            guard at >= 0, at + buffers <= list.count else { return false }
            let bytes = list[at].bytes
            return bytes > 0 && bytes % bytesPerFrame == 0
                && (at..<(at + buffers)).allSatisfy { list[$0].channels == channelsPerBuffer && list[$0].bytes == bytes }
        }
        if fits(deviceInputs) { return deviceInputs }
        if fits(list.count - buffers) { return list.count - buffers }
        return nil
    }

    func copy(_ list: UnsafeMutableAudioBufferListPointer, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let shape = list.map { (channels: Int($0.mNumberChannels), bytes: $0.mData == nil ? 0 : Int($0.mDataByteSize)) }
        guard let at = index(in: shape) else { return nil }
        let frames = shape[at].bytes / bytesPerFrame
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return nil }
        out.frameLength = AVAudioFrameCount(frames)
        let target = UnsafeMutableAudioBufferListPointer(out.mutableAudioBufferList)
        guard target.count == buffers else { return nil }
        for k in 0..<buffers {
            guard let from = list[at + k].mData, let to = target[k].mData else { return nil }
            memcpy(to, from, min(Int(list[at + k].mDataByteSize), Int(target[k].mDataByteSize)))
        }
        return out
    }
}

final class MicCapture {
    var onSamples: (([Float]) -> Void)?
    var onRestart: (() -> Void)?
    private var engine = AVAudioEngine()
    private var observer: NSObjectProtocol?
    private var started = false

    func start() throws {
        engine = AVAudioEngine()
        started = true
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0, let resampler = Resampler(from: format) else {
            throw CaptureError.noMicrophone
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            let samples = resampler.convert(buffer)
            if !samples.isEmpty { self?.onSamples?(samples) }
        }
        try engine.start()
        if observer == nil {
            // Another microphone became the default (or this one went away): start again on the new one.
            observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil,
                                                              queue: .main) { [weak self] note in
                guard let self = self, (note.object as? AVAudioEngine) === self.engine else { return }
                self.engine.inputNode.removeTap(onBus: 0)
                self.engine.stop()
                self.onRestart?()
                do { try self.start() } catch { NSLog("AI Face Listener: microphone restart failed: \(error)") }
            }
        }
    }

    func stop() {
        if let o = observer { NotificationCenter.default.removeObserver(o) }
        observer = nil
        guard started else { return }    // never touch the input (and its permission) if not started
        started = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}
