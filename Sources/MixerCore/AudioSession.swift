import Foundation
import CoreAudio
import AudioDSP

public protocol AppAudioSession: AnyObject {
    var callbacks: UInt64 { get }
    var fault: UInt32 { get }
    func setGain(_ value: Float)
    func maintain(active: Bool)
    func stop()
}
public extension AppAudioSession { func maintain(active: Bool) {} }

/// All methods except atomic gain/telemetry access run on the engine's serial control queue.
public final class AudioSession: AppAudioSession {
    private var tap: AudioObjectID = kAudioObjectUnknown
    private var aggregate: AudioObjectID = kAudioObjectUnknown
    private var ioProc: AudioDeviceIOProcID?
    private var dsp: OpaquePointer?
    private var playback: BufferedPlayback?
    private var started = false
    public var callbacks: UInt64 { playback?.callbacks ?? dsp.map(VMGetCallbackCount) ?? 0 }
    public var fault: UInt32 { playback?.fault ?? dsp.map(VMGetFault) ?? 0 }
    public var peak: Float { playback?.peak ?? dsp.map(VMGetPeak) ?? 0 }
    public var outputPeak: Float { playback?.outputPeak ?? dsp.map(VMGetOutputPeak) ?? 0 }

    public init(app: AudioApplication, output: OutputDevice, gain: Float) throws {
        guard !app.processObjects.isEmpty else { throw AudioFailure("This app has no audio process.") }
        if let reason = output.controlUnavailableReason { throw AudioFailure(reason) }
        do {
            let description = Self.tapDescription(for: app)
            try HAL.check(AudioHardwareCreateProcessTap(description, &tap), "Couldn't enable app audio control. Check System Audio Recording permission")
            var tapFormat = AudioStreamBasicDescription()
            try HAL.read(tap, kAudioTapPropertyFormat, into: &tapFormat)
            let tapStream = AudioStreamInfo(id: tap, format: tapFormat)
            guard tapStream.isNativeFloat, (1...2).contains(tapStream.channels) else {
                throw AudioFailure("The application's playback format isn't supported.")
            }
            let tapUID = try HAL.string(tap, kAudioTapPropertyUID)
            if abs(tapFormat.mSampleRate - output.outputs[0].format.mSampleRate) > 0.01 {
                try startBuffered(app: app, tapUID: tapUID, tapStream: tapStream, output: output, gain: gain)
                return
            }
            let composition: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Volume Mixer · \(app.identity.name)",
                kAudioAggregateDeviceUIDKey: "local.oliver.VolumeMixer.audio.\(UUID().uuidString)",
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: true,
                kAudioAggregateDeviceMainSubDeviceKey: output.uid,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: output.uid, kAudioSubDeviceInputChannelsKey: 0]],
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: true,
                                                  kAudioSubTapDriftCompensationQualityKey: kAudioAggregateDriftCompensationMaxQuality]],
                kAudioAggregateDeviceTapAutoStartKey: false
            ]
            try HAL.check(AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregate), "Couldn't connect the application to the output")
            let inputs = try HAL.streams(aggregate, scope: kAudioObjectPropertyScopeInput)
            let outputs = try HAL.streams(aggregate, scope: kAudioObjectPropertyScopeOutput)
            let layout = try PlaybackLayout.validate(inputs: inputs, outputs: outputs, tap: tapStream, destination: output)
            if abs(layout.inputSampleRate - layout.outputSampleRate) > 0.01 {
                try HAL.check(AudioHardwareDestroyAggregateDevice(aggregate), "Couldn't release the previous playback connection")
                aggregate = kAudioObjectUnknown
                try startBuffered(app: app, tapUID: tapUID, tapStream: tapStream, output: output, gain: gain)
                return
            }
            guard let state = VMCreateDSP(gain, layout.outputSampleRate, layout.physicalChannels,
                                          tapStream.channels, output.channels) else {
                throw AudioFailure("Couldn't allocate the audio processor.")
            }
            dsp = state
            try HAL.check(VMCreateIOProc(aggregate, state, &ioProc), "Couldn't prepare playback")
            guard let ioProc else { throw AudioFailure("No playback callback was created.") }
            // Explicitly disable every physical input. In particular, never activate a headset microphone.
            if inputs.count > 1 {
                try HAL.check(VMSetInputUsage(aggregate, ioProc, UInt32(inputs.count), UInt32(inputs.count - 1)), "Couldn't isolate playback from microphone streams")
            }
            try HAL.check(AudioDeviceStart(aggregate, ioProc), "Couldn't start app audio control")
            started = true
        } catch {
            stop()
            throw error
        }
    }
    private func startBuffered(app: AudioApplication, tapUID: String, tapStream: AudioStreamInfo,
                               output: OutputDevice, gain: Float) throws {
        // No physical sub-device: capture cannot open a microphone or impose the
        // Bluetooth output clock on the tap. Output is a separate AVAudioEngine.
        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Volume Mixer · \(app.identity.name)",
            kAudioAggregateDeviceUIDKey: "local.oliver.VolumeMixer.audio.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID]],
            kAudioAggregateDeviceTapAutoStartKey: false
        ]
        try HAL.check(AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregate), "Couldn't prepare application capture")
        let inputs = try HAL.streams(aggregate, scope: kAudioObjectPropertyScopeInput)
        let outputs = try HAL.streams(aggregate, scope: kAudioObjectPropertyScopeOutput)
        let input = try PlaybackLayout.validateCapture(inputs: inputs, outputs: outputs, tap: tapStream)
        let playback = try BufferedPlayback(input: input, output: output, gain: gain)
        self.playback = playback
        try HAL.check(VMCreateCaptureIOProc(aggregate, playback.bridge, &ioProc), "Couldn't prepare application capture")
        guard let ioProc else { throw AudioFailure("No capture callback was created.") }
        // The output initially renders silence. Original playback is only muted
        // once capture starts, after the output has successfully started.
        try playback.start()
        try HAL.check(AudioDeviceStart(aggregate, ioProc), "Couldn't start app audio control")
        started = true
    }
    /// Capture the selected processes across their original outputs. The aggregate alone
    /// determines the destination, so games bound to an old device can still be controlled.
    public static func tapDescription(for app: AudioApplication) -> CATapDescription {
        let description = CATapDescription(stereoMixdownOfProcesses: app.processObjects)
        description.name = "Volume Mixer · \(app.identity.name)"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped
        return description
    }
    public func setGain(_ value: Float) {
        if let dsp { VMSetGain(dsp, value) }
        playback?.setGain(value)
    }
    public func maintain(active: Bool) { playback?.maintain(active: active) }
    public func stop() {
        playback?.stop()
        if aggregate != kAudioObjectUnknown, let ioProc {
            if started { AudioDeviceStop(aggregate, ioProc) }
            AudioDeviceDestroyIOProcID(aggregate, ioProc)
        }
        started = false; ioProc = nil
        if aggregate != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregate); aggregate = kAudioObjectUnknown }
        if tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tap); tap = kAudioObjectUnknown }
        if let dsp { VMDestroyDSP(dsp) }; dsp = nil
        // The bridge outlives BOTH capture and playback callbacks.
        playback = nil
    }
    deinit { stop() }
}

public struct PlaybackLayout {
    public let physicalChannels: UInt32
    public let inputSampleRate: Double
    public let outputSampleRate: Double
    public static func validate(inputs: [AudioStreamInfo], outputs: [AudioStreamInfo], tap: AudioStreamInfo,
                                destination: OutputDevice) throws -> PlaybackLayout {
        // Core Audio appends sub-taps after physical sub-device input streams.
        // Drift compensation does not guarantee identical virtual sample rates.
        // A rate mismatch selects separate buffered capture/playback instead.
        // Only the tap input is subsequently enabled for the IOProc.
        guard tap.isNativeFloat, (1...2).contains(tap.channels),
              (inputs.count == 1 || inputs.count == destination.inputs.count + 1), let last = inputs.last,
              last.isNativeFloat, last.channels == tap.channels,
              outputs.count == 1, outputs[0].isNativeFloat,
              outputs[0].channels == destination.channels else {
            throw AudioFailure("\(destination.name) changed its playback layout. Retry after the device finishes connecting.")
        }
        let rate = outputs[0].format.mSampleRate
        guard rate.isFinite, (8000...384000).contains(rate), last.format.mSampleRate.isFinite,
              (8000...384000).contains(last.format.mSampleRate) else {
            throw AudioFailure("\(destination.name) reported an unsupported audio sample rate (\(last.format.mSampleRate) → \(rate) Hz).")
        }
        return PlaybackLayout(physicalChannels: inputs.dropLast().reduce(0) { $0 + $1.channels },
                              inputSampleRate: last.format.mSampleRate, outputSampleRate: rate)
    }
    public static func validateCapture(inputs: [AudioStreamInfo], outputs: [AudioStreamInfo], tap: AudioStreamInfo) throws -> AudioStreamInfo {
        guard inputs.count == 1, outputs.isEmpty, let input = inputs.first,
              input.isNativeFloat, input.channels == tap.channels,
              (1...2).contains(input.channels), input.format.mSampleRate.isFinite,
              (8000...384000).contains(input.format.mSampleRate) else {
            throw AudioFailure("The application capture stream changed to an unsupported layout.")
        }
        return input
    }
}
