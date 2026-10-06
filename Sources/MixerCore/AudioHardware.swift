import Foundation
import CoreAudio

public struct AudioFailure: LocalizedError, Sendable {
    public let message: String
    public let status: OSStatus?
    public init(_ message: String, status: OSStatus? = nil) { self.message = message; self.status = status }
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
            var result = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
            let status = result.withUnsafeMutableBytes { AudioObjectGetPropertyData(id, &a, 0, nil, &size, $0.baseAddress!) }
            if status == kAudioHardwareBadPropertySizeError { continue }
            try check(status, "Couldn't list audio objects")
            return Array(result.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
        }
        throw AudioFailure("Audio devices changed during discovery. Please retry.")
    }
    public static func streams(_ device: AudioObjectID, scope: AudioObjectPropertyScope) throws -> [AudioStreamInfo] {
        try objects(device, kAudioDevicePropertyStreams, scope: scope).map { id in
            var format = AudioStreamBasicDescription()
            try read(id, kAudioStreamPropertyVirtualFormat, into: &format)
            return AudioStreamInfo(id: id, format: format)
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
                            outputs: try streams(id, scope: kAudioObjectPropertyScopeOutput))
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
}

public struct AudioStreamInfo: @unchecked Sendable {
    public let id: AudioObjectID
    public let format: AudioStreamBasicDescription
    public init(id: AudioObjectID, format: AudioStreamBasicDescription) { self.id = id; self.format = format }
    public var channels: UInt32 { format.mChannelsPerFrame }
    public var isNativeFloat: Bool {
        format.mFormatID == kAudioFormatLinearPCM && format.mBitsPerChannel == 32 &&
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
    public init(id: AudioObjectID, uid: String, name: String, sampleRate: Double,
                inputs: [AudioStreamInfo], outputs: [AudioStreamInfo]) {
        self.id = id; self.uid = uid; self.name = name; self.sampleRate = sampleRate
        self.inputs = inputs; self.outputs = outputs
    }
    public var channels: UInt32 { outputs.reduce(0) { $0 + $1.channels } }
    public var controlUnavailableReason: String? {
        guard (1...2).contains(channels), outputs.count == 1 else { return "This output needs a mono or stereo playback stream." }
        guard outputs.allSatisfy(\.isNativeFloat) else { return "This output's audio format isn't supported." }
        guard sampleRate.isFinite, (8000...384000).contains(sampleRate) else { return "This output's sample rate isn't supported." }
        return nil
    }
    public var signature: String { "\(id):\(uid):\(sampleRate):\(inputs.map(\.signature)):\(outputs.map(\.signature))" }
}
