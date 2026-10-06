import Foundation
import AVFAudio
import AudioToolbox
import AudioDSP

private final class PlaybackBuffer {
    let pointer: OpaquePointer
    init(_ pointer: OpaquePointer) { self.pointer = pointer }
    deinit { VMDestroyBridge(pointer) }
}

/// Compensates small clock differences without changing a physical device's rate.
/// Updated only on the serial control queue, never in an audio callback.
public struct PlaybackClockRecovery {
    private var average: Double?
    public init() {}
    public mutating func rate(queued: UInt32, target: UInt32, sampleRate: Double, active: Bool) -> Float {
        guard active, sampleRate.isFinite, sampleRate > 0 else { average = nil; return 1 }
        let error = (Double(queued) - Double(target)) / sampleRate
        average = (average ?? error) * 0.8 + error * 0.2
        return Float(1 + min(0.002, max(-0.002, average! * 0.02)))
    }
}

/// The tap's clock writes a bounded C queue. AVAudioEngine pulls from that queue
/// on the output clock; its mixer performs sample-rate conversion. The input node
/// is never accessed. Offline mode exercises this same graph without any device.
public final class BufferedPlayback {
    private let buffer: PlaybackBuffer
    public var bridge: OpaquePointer { buffer.pointer }
    private let engine = AVAudioEngine()
    private let speed: AVAudioUnitVarispeed
    private var source: AVAudioSourceNode?
    private let inputRate: Double
    private let offline: Bool
    private var clock = PlaybackClockRecovery()
    private var timingFault: UInt32 = 0
    private var lastUnderruns: UInt64 = 0
    private var recentUnderruns: [(time: TimeInterval, count: UInt64)] = []
    private var started = false

    public static var componentsAvailable: Bool {
        for (type, subtype) in [(kAudioUnitType_FormatConverter, kAudioUnitSubType_Varispeed),
                                (kAudioUnitType_Mixer, kAudioUnitSubType_MultiChannelMixer)] {
            var description = AudioComponentDescription(componentType: type, componentSubType: subtype,
                componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
            if AudioComponentFindNext(nil, &description) == nil { return false }
        }
        return true
    }

    public init(input: AudioStreamInfo, output: OutputDevice, gain: Float, offline: Bool = false) throws {
        // Some restricted environments cannot resolve system Audio Units. Apple's
        // convenience constructors raise an Objective-C exception in that case.
        guard Self.componentsAvailable else { throw AudioFailure("The macOS playback components are unavailable. App audio control couldn't start.") }
        speed = AVAudioUnitVarispeed()
        guard input.isNativeFloat, (1...2).contains(input.channels), output.controlUnavailableReason == nil,
              input.format.mSampleRate.isFinite, (8000...384000).contains(input.format.mSampleRate),
              output.outputs[0].format.mSampleRate.isFinite, (8000...384000).contains(output.outputs[0].format.mSampleRate),
              let inputFormat = AVAudioFormat(standardFormatWithSampleRate: input.format.mSampleRate, channels: output.channels),
              let outputFormat = AVAudioFormat(standardFormatWithSampleRate: output.outputs[0].format.mSampleRate, channels: output.channels),
              let bridge = VMCreateBridge(gain, input.format.mSampleRate, input.channels, output.channels) else {
            throw AudioFailure("Couldn't prepare buffered application playback.")
        }
        buffer = PlaybackBuffer(bridge); inputRate = input.format.mSampleRate; self.offline = offline
        do {
            if offline {
                // This must precede any output-node access: tests never connect to hardware.
                try engine.enableManualRenderingMode(.offline, format: outputFormat, maximumFrameCount: 4096)
            } else {
                try engine.outputNode.withAUAudioUnit { unit in
                    try unit.setDeviceID(output.id)
                    guard unit.deviceID == output.id, !unit.isInputEnabled else {
                        throw AudioFailure("Couldn't establish playback-only access to \(output.name).")
                    }
                }
                let actual = engine.outputNode.outputFormat(forBus: 0)
                guard actual.channelCount == output.channels,
                      abs(actual.sampleRate - outputFormat.sampleRate) < 0.01 else {
                    throw AudioFailure("\(output.name) changed its playback format. Retry after it finishes connecting.")
                }
            }
            let source = AVAudioSourceNode(format: inputFormat) { _, _, frames, buffers in
                VMBridgeRender(bridge, frames, buffers)
            }
            self.source = source
            engine.attach(source); engine.attach(speed)
            try engine.connectNode(source, to: speed, format: inputFormat)
            try engine.connectNode(speed, to: engine.mainMixerNode, format: inputFormat)
            try engine.connectNode(engine.mainMixerNode, to: engine.outputNode, format: outputFormat)
            engine.prepare()
        } catch {
            engine.stop()
            throw error
        }
    }
    public func start() throws { try engine.start(); started = true }
    public func stop() { engine.stop(); started = false }
    public func setGain(_ value: Float) { VMBridgeSetGain(bridge, value) }
    public var callbacks: UInt64 { VMBridgeDeliveredFrames(bridge) }
    public var fault: UInt32 { timingFault == 0 ? VMBridgeFault(bridge) : timingFault }
    public var peak: Float { VMBridgePeak(bridge) }
    public var outputPeak: Float { VMBridgeOutputPeak(bridge) }

    public func maintain(active: Bool) {
        guard started else { return }
        if !engine.isRunning { timingFault = 4; return }
        let now = ProcessInfo.processInfo.systemUptime
        let underruns = VMBridgeUnderruns(bridge)
        if active, underruns > lastUnderruns { recentUnderruns.append((now, underruns - lastUnderruns)) }
        lastUnderruns = underruns
        recentUnderruns.removeAll { !active || now - $0.time > 5 }
        if recentUnderruns.reduce(UInt64(0), { $0 + $1.count }) >= 3 { timingFault = 2 }
        speed.rate = clock.rate(queued: VMBridgeQueuedFrames(bridge), target: VMBridgeTargetFrames(bridge),
                                sampleRate: inputRate, active: active)
    }

    /// Synthetic checks only. Calling this for a live session is an error.
    public func renderOffline(_ frames: AVAudioFrameCount, to buffer: AVAudioPCMBuffer) throws -> AVAudioEngineManualRenderingStatus {
        guard offline else { throw AudioFailure("Offline rendering requires an offline playback graph.") }
        return try engine.renderOffline(frames, to: buffer)
    }
    deinit { engine.stop() }
}
