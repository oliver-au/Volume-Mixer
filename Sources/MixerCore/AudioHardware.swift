import Foundation
import CoreAudio
import AudioDSP

public struct AudioFailure: LocalizedError, Sendable {
    public let message: String
    public let status: OSStatus?
    public init(_ message: String, status: OSStatus? = nil) { self.message = message; self.status = status }
    public var isTransientDiscovery: Bool {
        status == kAudioHardwareBadPropertySizeError || status == kAudioHardwareBadObjectError ||
            status == kAudioHardwareBadDeviceError
    }
    public var errorDescription: String? {
        guard let status else { return message }
        return "\(message) (Core Audio \(status))"
    }
}

public enum HAL {
    public static let system = AudioObjectID(kAudioObjectSystemObject)
    public static func address(_ selector: AudioObjectPropertySelector,
                               _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
    public static func check(_ result: OSStatus, _ operation: String) throws {
        if result != noErr { throw AudioFailure(operation, status: result) }
    }
    public static func read<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, into value: inout T,
                               scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws {
        var a = address(selector, scope), size = UInt32(MemoryLayout<T>.size)
        try withUnsafeMutablePointer(to: &value) { ptr in
            try check(AudioObjectGetPropertyData(id, &a, 0, nil, &size, ptr), "Couldn't read an audio property")
        }
        guard size == MemoryLayout<T>.size else { throw AudioFailure("The audio service returned an unexpected property size.") }
    }
    public static func scalar(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                              scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> UInt32 {
        var value: UInt32 = 0; try read(id, selector, into: &value, scope: scope); return value
    }
    public static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        var value: Unmanaged<CFString>?
        try read(id, selector, into: &value)
        return value?.takeRetainedValue() as String? ?? ""
    }
    public static func objects(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                               scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> [AudioObjectID] {
        var a = address(selector, scope)
        for _ in 0..<3 {
            var size: UInt32 = 0
            try check(AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size), "Couldn't list audio objects")
            if size == 0 { return [] }
            let count = try objectCount(byteCount: size)
            let capacity = size
            var result = [AudioObjectID](repeating: 0, count: count)
            let status = result.withUnsafeMutableBytes { AudioObjectGetPropertyData(id, &a, 0, nil, &size, $0.baseAddress!) }
            if status == kAudioHardwareBadPropertySizeError { continue }
            try check(status, "Couldn't list audio objects")
            return Array(result.prefix(try objectCount(byteCount: size, capacity: capacity)))
        }
        throw AudioFailure("Audio devices changed during discovery. Please retry.", status: kAudioHardwareBadPropertySizeError)
    }
    /// Validate service-reported lengths before allocating or reading an object list.
    /// One MiB permits 262,144 objects while bounding malformed-driver allocations.
    public static func objectCount(byteCount: UInt32, capacity: UInt32 = 1_048_576) throws -> Int {
        guard byteCount <= min(capacity, 1_048_576), byteCount % UInt32(MemoryLayout<AudioObjectID>.size) == 0 else {
            throw AudioFailure("The audio service returned an invalid object-list size.")
        }
        return Int(byteCount) / MemoryLayout<AudioObjectID>.size
    }
    public static func streams(_ device: AudioObjectID, scope: AudioObjectPropertyScope) throws -> [AudioStreamInfo] {
        try objects(device, kAudioDevicePropertyStreams, scope: scope).map { id in
            var format = AudioStreamBasicDescription()
            try read(id, kAudioStreamPropertyVirtualFormat, into: &format)
            return AudioStreamInfo(id: id, format: format,
                terminalType: (try? scalar(id, kAudioStreamPropertyTerminalType)) ?? 0)
        }
    }
    public static func defaultOutput() throws -> OutputDevice {
        let id = try scalar(system, kAudioHardwarePropertyDefaultOutputDevice)
        guard id != kAudioObjectUnknown else { throw AudioFailure("No audio output is connected.") }
        return try outputDevice(id)
    }
    public static func outputDevice(_ id: AudioObjectID) throws -> OutputDevice {
        var rate: Float64 = 0
        try read(id, kAudioDevicePropertyNominalSampleRate, into: &rate)
        return OutputDevice(id: id, uid: try string(id, kAudioDevicePropertyDeviceUID),
                            name: try string(id, kAudioObjectPropertyName), sampleRate: rate,
                            inputs: try streams(id, scope: kAudioObjectPropertyScopeInput),
                            outputs: try streams(id, scope: kAudioObjectPropertyScopeOutput),
                            transportType: (try? scalar(id, kAudioDevicePropertyTransportType)) ?? 0)
    }
    public static func availableOutputs() throws -> [OutputDevice] {
        try objects(system, kAudioHardwarePropertyDevices).compactMap { id in
            // A device can disappear between enumeration and reading its properties.
            guard let device = try? outputDevice(id), device.channels > 0,
                  !device.uid.hasPrefix("local.oliver.VolumeMixer.audio."),
                  (try? scalar(id, kAudioDevicePropertyDeviceIsAlive)) == 1 else { return nil }
            return device
        }.sorted { $0.name == $1.name ? $0.uid < $1.uid : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    /// Only used during a discovery failure; unknown/dead routes fail open.
    public static func sessionIsUsable(_ app: AudioApplication, _ output: OutputDevice) -> Bool {
        guard (try? scalar(output.id, kAudioDevicePropertyDeviceIsAlive)) == 1,
              (try? string(output.id, kAudioDevicePropertyDeviceUID)) == output.uid,
              !app.lifetimes.isEmpty,
              app.lifetimes.allSatisfy({ $0.matches(startTime: VMProcessStartTime($0.pid)) }) else { return false }
        return app.processObjects.allSatisfy { object in
            guard let pid = try? scalar(object, kAudioProcessPropertyPID) else { return false }
            return app.pids.contains(Int32(bitPattern: pid))
        }
    }
    public static func observePlayback(_ object: AudioObjectID, queue: DispatchQueue,
                                       changed: @escaping @Sendable () -> Void) -> (() -> Void) {
        var registered: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
        for property in [address(kAudioProcessPropertyIsRunningOutput),
                         address(kAudioProcessPropertyDevices, kAudioObjectPropertyScopeOutput)] {
            var property = property
            let block: AudioObjectPropertyListenerBlock = { _, _ in changed() }
            if AudioObjectAddPropertyListenerBlock(object, &property, queue, block) == noErr {
                registered.append((property, block))
            }
        }
        return {
            for (var property, block) in registered {
                AudioObjectRemovePropertyListenerBlock(object, &property, queue, block)
            }
        }
    }
}

public struct AudioStreamInfo: @unchecked Sendable {
    public let id: AudioObjectID
    public let format: AudioStreamBasicDescription
    public let terminalType: UInt32
    public init(id: AudioObjectID, format: AudioStreamBasicDescription, terminalType: UInt32 = 0) {
        self.id = id; self.format = format; self.terminalType = terminalType
    }
    public var channels: UInt32 { format.mChannelsPerFrame }
    public var isNativeFloat: Bool {
        guard channels > 0, channels <= UInt32.max / 4 else { return false }
        return format.mFormatID == kAudioFormatLinearPCM && format.mBitsPerChannel == 32 &&
        format.mFormatFlags & kAudioFormatFlagIsFloat != 0 &&
        format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0 &&
        format.mFormatFlags & kAudioFormatFlagIsPacked != 0 &&
        format.mFramesPerPacket == 1 &&
        format.mBytesPerFrame == (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 ? 4 : 4 * channels)
    }
    public var signature: String { "\(id):\(format.mSampleRate):\(channels):\(format.mFormatID):\(format.mFormatFlags):\(format.mBytesPerFrame)" }
}

public struct OutputDevice: Sendable {
    public let id: AudioObjectID
    public let uid: String
    public let name: String
    public let sampleRate: Double
    public let inputs: [AudioStreamInfo]
    public let outputs: [AudioStreamInfo]
    public let transportType: UInt32
    public init(id: AudioObjectID, uid: String, name: String, sampleRate: Double,
                inputs: [AudioStreamInfo], outputs: [AudioStreamInfo], transportType: UInt32 = 0) {
        self.id = id; self.uid = uid; self.name = name; self.sampleRate = sampleRate
        self.inputs = inputs; self.outputs = outputs; self.transportType = transportType
    }
    public var symbolName: String {
        if outputs.contains(where: { $0.terminalType == kAudioStreamTerminalTypeHeadphones }) { return "headphones" }
        if outputs.contains(where: { $0.terminalType == kAudioStreamTerminalTypeSpeaker }) { return "speaker.wave.2" }
        switch transportType {
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return "display"
        case kAudioDeviceTransportTypeAirPlay: return "airplay.audio"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "waveform"
        default: return "speaker.wave.2"
        }
    }
    public var channels: UInt32 {
        outputs.reduce(0) { total, stream in
            let (sum, overflow) = total.addingReportingOverflow(stream.channels)
            return overflow ? UInt32.max : sum
        }
    }
    public var controlUnavailableReason: String? {
        guard (1...2).contains(channels), outputs.count == 1 else { return "This output needs a mono or stereo playback stream." }
        guard outputs.allSatisfy(\.isNativeFloat) else { return "This output's audio format isn't supported." }
        guard sampleRate.isFinite, (8000...384000).contains(sampleRate) else { return "This output's sample rate isn't supported." }
        return nil
    }
    public var signature: String { "\(id):\(uid):\(sampleRate):\(inputs.map(\.signature)):\(outputs.map(\.signature))" }
}
