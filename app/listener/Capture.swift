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
    private(set) var lastCallback = Date()
    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var aggregate = AudioObjectID(kAudioObjectUnknown)
    private var proc: AudioDeviceIOProcID?
    private var resampler: Resampler?
    private let queue = DispatchQueue(label: "local.aiface.listener.system", qos: .userInitiated)
    private var listening = false
    private lazy var outputChanged: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        DispatchQueue.main.async { self?.rebuild() }
    }

    func start() throws {
        try build()
        if !listening {
            var addr = Self.address(kAudioHardwarePropertyDefaultSystemOutputDevice)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main, outputChanged)
            listening = true
        }
    }

    func stop() {
        if listening {
            var addr = Self.address(kAudioHardwarePropertyDefaultSystemOutputDevice)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main, outputChanged)
            listening = false
        }
        teardown()
    }

    /// Tear everything down and build it again (device change, no callbacks, or a long run of zeros:
    /// long sessions have been seen to deliver only zero buffers until the tap is recreated).
    func rebuild() {
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
        guard err == noErr, let avFormat = AVAudioFormat(streamDescription: &format),
              let resampler = Resampler(from: avFormat) else {
            teardown()
            throw CaptureError.os("Reading the tap format", err)
        }
        self.resampler = resampler

        let output = try Self.defaultOutputUID()
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

        var procID: AudioDeviceIOProcID?
        err = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregate, queue) { [weak self] _, input, _, _, _ in
            guard let self = self,
                  let buffer = AVAudioPCMBuffer(pcmFormat: avFormat, bufferListNoCopy: input, deallocator: nil) else { return }
            self.lastCallback = Date()
            let samples = resampler.convert(buffer)
            if !samples.isEmpty { self.onSamples?(samples) }
        }
        guard err == noErr, let procID = procID else {
            teardown()
            throw CaptureError.os("Creating the audio callback", err)
        }
        proc = procID
        err = AudioDeviceStart(aggregate, procID)
        guard err == noErr else {
            teardown()
            throw CaptureError.os("Starting system audio", err)
        }
        lastCallback = Date()
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

    static func defaultOutputUID() throws -> String {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = address(kAudioHardwarePropertyDefaultSystemOutputDevice)
        var err = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device)
        guard err == noErr else { throw CaptureError.os("Finding the output device", err) }
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        addr = address(kAudioDevicePropertyDeviceUID)
        err = AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &uid)
        guard err == noErr, let value = uid?.takeRetainedValue() else { throw CaptureError.os("Reading the output device", err) }
        return value as String
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
