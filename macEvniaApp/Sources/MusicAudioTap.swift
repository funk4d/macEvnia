import CoreAudio
import Foundation

final class MusicAudioTap {
    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var aggregate = AudioObjectID(kAudioObjectUnknown)
    private var proc: AudioDeviceIOProcID?
    private var running = false
    private let levels = LatestMusicLevels()

    func start() throws {
        guard #available(macOS 14.2, *) else { throw TapError.unsupportedSystem }
        do {
            let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
            description.name = "macEvnia Follow Music"
            description.isPrivate = true
            description.muteBehavior = .unmuted
            try check(AudioHardwareCreateProcessTap(description, &tap), "Create system audio tap")

            var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                                     mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            var format = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try check(AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &format), "Read system audio format")
            let planar = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
            let channelsPerBuffer = planar ? 1 : format.mChannelsPerFrame
            guard format.mFormatID == kAudioFormatLinearPCM,
                  format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                  format.mBitsPerChannel == 32, (1...2).contains(format.mChannelsPerFrame),
                  format.mBytesPerFrame == channelsPerBuffer * UInt32(MemoryLayout<Float>.stride),
                  format.mSampleRate.isFinite, format.mSampleRate > 0 else {
                throw TapError.unsupportedFormat
            }

            let descriptionDictionary: [String: Any] = [
                kAudioAggregateDeviceNameKey: "macEvnia Follow Music",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true
                ]]
            ]
            try check(AudioHardwareCreateAggregateDevice(descriptionDictionary as CFDictionary, &aggregate), "Create private audio input")

            let mailbox = levels
            var spectrum = StereoMusicSpectrum(sampleRate: format.mSampleRate)
            try check(AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, nil) { _, input, _, _, _ in
                if let value = spectrum.consumeAudio(input) { mailbox.publish(value) }
            }, "Register audio callback")
            guard let proc else { throw TapError.callbackUnavailable }
            try check(AudioDeviceStart(aggregate, proc), "Start system audio capture")
            running = true
            DebugLog.write("Follow Music audio tap started at \(format.mSampleRate) Hz, \(format.mChannelsPerFrame) channels (\(planar ? "planar" : "interleaved"))")
        } catch {
            stop()
            throw error
        }
    }

    func latestLevels() -> StereoMusicLevels { levels.read() }

    func stop() {
        if aggregate != kAudioObjectUnknown {
            if let proc {
                if running { AudioDeviceStop(aggregate, proc) }
                AudioDeviceDestroyIOProcID(aggregate, proc)
                self.proc = nil
            }
            AudioHardwareDestroyAggregateDevice(aggregate)
            aggregate = kAudioObjectUnknown
        }
        running = false
        if #available(macOS 14.2, *), tap != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tap)
            tap = kAudioObjectUnknown
        }
    }

    deinit { stop() }

    private func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else { throw TapError.coreAudio(operation, status) }
    }

    private enum TapError: LocalizedError {
        case unsupportedSystem, unsupportedFormat, callbackUnavailable, coreAudio(String, OSStatus)

        var errorDescription: String? {
            switch self {
            case .unsupportedSystem: return "Follow Music requires macOS 14.2 or later."
            case .unsupportedFormat: return "Follow Music could not read the system audio format."
            case .callbackUnavailable: return "Follow Music could not start its audio input."
            case .coreAudio(let operation, let status):
                if operation == "Start system audio capture" {
                    return "Could not start system audio (\(status)). Check System Audio Recording permission."
                }
                return "\(operation) failed (\(status))."
            }
        }
    }
}

extension StereoMusicSpectrum {
    mutating func consumeAudio(_ input: UnsafePointer<AudioBufferList>) -> StereoMusicLevels? {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let first = buffers.first, let samples = Self.samples(in: first) else { return nil }
        if first.mNumberChannels == 2 { return consumeInterleaved(samples) }
        guard first.mNumberChannels == 1 else { return nil }
        if buffers.count == 1 { return consume(left: samples, right: samples) }
        guard buffers[1].mNumberChannels == 1, let right = Self.samples(in: buffers[1]) else { return nil }
        return consume(left: samples, right: right)
    }

    private static func samples(in buffer: AudioBuffer) -> UnsafeBufferPointer<Float>? {
        guard let data = buffer.mData else { return nil }
        return UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self),
                                   count: Int(buffer.mDataByteSize) / MemoryLayout<Float>.stride)
    }
}

private final class LatestMusicLevels {
    private let lock = NSLock()
    private var peak = StereoMusicLevels.zero
    private var receivedAt: UInt64 = 0

    func publish(_ levels: StereoMusicLevels) {
        // A HAL callback must not wait for the LED queue.
        guard lock.try() else { return }
        peak.left = maximum(peak.left, levels.left)
        peak.right = maximum(peak.right, levels.right)
        receivedAt = DispatchTime.now().uptimeNanoseconds
        lock.unlock()
    }

    func read() -> StereoMusicLevels {
        lock.lock()
        defer { lock.unlock() }
        let levels = peak
        peak = .zero
        return DispatchTime.now().uptimeNanoseconds - receivedAt < 150_000_000 ? levels : .zero
    }

    private func maximum(_ a: MusicBands, _ b: MusicBands) -> MusicBands {
        MusicBands(max(a.x, b.x), max(a.y, b.y), max(a.z, b.z))
    }
}
