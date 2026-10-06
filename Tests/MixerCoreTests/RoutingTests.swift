import Foundation
import CoreAudio
import MixerCore

func routingStream(id: AudioObjectID = 10, rate: Double = 48000, channels: UInt32 = 2) -> AudioStreamInfo {
    AudioStreamInfo(id: id, format: AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: channels * 4,
        mFramesPerPacket: 1, mBytesPerFrame: channels * 4, mChannelsPerFrame: channels, mBitsPerChannel: 32, mReserved: 0))
}

func routingOutput(id: AudioObjectID, uid: String, rate: Double = 48000, channels: UInt32 = 2) -> OutputDevice {
    OutputDevice(id: id, uid: uid, name: "Test headphones", sampleRate: rate, inputs: [],
                 outputs: [routingStream(rate: rate, channels: channels)])
}

final class RoutingTests {
    func testOutputIconsUseHardwareMetadata() {
        let format = routingStream().format
        func device(_ transport: UInt32, _ terminal: UInt32 = 0) -> OutputDevice {
            OutputDevice(id: 1, uid: "icon-test", name: "WH-airpods-headphone misleading name", sampleRate: 48000,
                inputs: [], outputs: [AudioStreamInfo(id: 10, format: format, terminalType: terminal)], transportType: transport)
        }
        checkEqual(device(kAudioDeviceTransportTypeBluetooth, kAudioStreamTerminalTypeHeadphones).symbolName, "headphones")
        checkEqual(device(kAudioDeviceTransportTypeBluetooth, kAudioStreamTerminalTypeSpeaker).symbolName, "speaker.wave.2")
        checkEqual(device(kAudioDeviceTransportTypeBluetooth).symbolName, "waveform")
        checkEqual(device(kAudioDeviceTransportTypeHDMI).symbolName, "display")
        checkEqual(device(kAudioDeviceTransportTypeAirPlay).symbolName, "airplay.audio")
        checkEqual(device(0).symbolName, "speaker.wave.2")
    }
    func testMalformedHardwareMetadataIsRejected() throws {
        for size: UInt32 in [0, 4, 8, 4096, 1_048_576] {
            checkEqual(try HAL.objectCount(byteCount: size), Int(size) / 4)
        }
        for (size, capacity): (UInt32, UInt32) in [(1, 4), (3, 4), (5, 8), (7, 8), (12, 8),
                                                   (1_048_580, UInt32.max), (UInt32.max, UInt32.max)] {
            do {
                _ = try HAL.objectCount(byteCount: size, capacity: capacity)
                checkTrue(false)
            } catch { checkTrue(error.localizedDescription.contains("object-list size")) }
        }
        func malformedStream(_ channels: UInt32) -> AudioStreamInfo {
            var format = routingStream().format
            format.mChannelsPerFrame = channels
            return AudioStreamInfo(id: 20, format: format)
        }
        checkFalse(malformedStream(0).isNativeFloat)
        checkFalse(malformedStream(UInt32.max).isNativeFloat)
        checkFalse(malformedStream(UInt32.max / 4 + 1).isNativeFloat)
        let overflowOutput = OutputDevice(id: 1, uid: "invalid", name: "Invalid", sampleRate: 48000,
                                         inputs: [], outputs: [malformedStream(UInt32.max), routingStream()])
        checkEqual(overflowOutput.channels, UInt32.max)
        checkTrue(overflowOutput.controlUnavailableReason != nil)
        for physical in [[malformedStream(UInt32.max)],
                         [malformedStream(UInt32.max - 2), routingStream()]] {
            let destination = OutputDevice(id: 1, uid: "invalid", name: "Invalid", sampleRate: 48000,
                                           inputs: physical, outputs: [routingStream()])
            do {
                _ = try PlaybackLayout.validate(inputs: physical + [routingStream()], outputs: destination.outputs,
                                                tap: routingStream(), destination: destination)
                checkTrue(false)
            } catch { checkTrue(error.localizedDescription.contains("invalid channel layout")) }
        }
    }
    func testCaptureOnlyLayout() throws {
        let tap = routingStream()
        let capture = try PlaybackLayout.validateCapture(inputs: [tap], outputs: [], tap: tap)
        checkEqual(capture.channels, 2); checkEqual(capture.format.mSampleRate, 48000)
        for (inputs, outputs) in [([tap, tap], []), ([tap], [tap]), ([routingStream(channels: 1)], []),
                                  ([routingStream(rate: .nan)], [])] {
            do {
                _ = try PlaybackLayout.validateCapture(inputs: inputs, outputs: outputs, tap: tap)
                checkTrue(false)
            } catch { checkTrue(error.localizedDescription.contains("layout")) }
        }
    }
    func testTapIncludesOnlySelectedProcessesAcrossOutputs() {
        let app = AudioApplication(identity: IdentityResolver.resolve(.init(pid: 123, bundleID: "test.game")),
                                   processObjects: [123, 456], pids: [123, 456], active: true, outputDevices: [7, 8])
        // Constructing the description does not create a tap or request any permissions.
        let description = AudioSession.tapDescription(for: app)
        checkEqual(description.processes, [123, 456])
        checkTrue(description.isMixdown); checkFalse(description.isMono)
        checkFalse(description.isExclusive); checkTrue(description.isPrivate)
        checkNil(description.deviceUID)
        checkEqual(description.muteBehavior, .mutedWhenTapped)
    }
    func testOldPreferencesAndSavedOutputSurviveRelaunch() throws {
        let store = MemoryPreferences()
        store.values["levels.v1"] = Data(#"{"app:test.game":{"volume":0.19,"muted":true}}"#.utf8)
        let identity = IdentityResolver.resolve(.init(pid: 1, bundleID: "test.game"))
        let prefs = Preferences(backing: store)
        var level = prefs.level(for: identity)
        checkEqual(level.volume, 0.19); checkTrue(level.muted); checkNil(level.outputUID)
        level.outputUID = "headphone-uid"; level.outputName = "My headphones"
        prefs.save(level, for: identity)
        let restarted = Preferences(backing: store)
        let newPID = IdentityResolver.resolve(.init(pid: 999, bundleID: "test.game"))
        checkEqual(restarted.level(for: newPID), level)
        restarted.resetLevels()
        checkEqual(Preferences(backing: store).level(for: newPID), AppLevel())
        restarted.save(level, for: identity); checkTrue(restarted.removeAll())
        checkTrue(store.values.isEmpty)
    }
    func testMonoBluetoothLayoutExcludesMicrophoneAndUsesAggregateRate() throws {
        let microphone = routingStream(id: 20, rate: 24000, channels: 1)
        let headphone = OutputDevice(id: 2, uid: "headphone", name: "Headphones", sampleRate: 24000,
                                     inputs: [microphone], outputs: [routingStream(rate: 24000, channels: 1)])
        checkNil(headphone.controlUnavailableReason)
        // A 48 kHz stereo mixdown may be converted by the aggregate to its 24 kHz clock.
        let tap = routingStream(id: 30)
        let aggregateTap = routingStream(id: 40, rate: 24000)
        let layout = try PlaybackLayout.validate(inputs: [microphone, aggregateTap], outputs: headphone.outputs,
                                                tap: tap, destination: headphone)
        checkEqual(layout.physicalChannels, 1); checkEqual(layout.outputSampleRate, 24000)
        let noPhysicalInput = try PlaybackLayout.validate(inputs: [aggregateTap], outputs: headphone.outputs,
                                                         tap: tap, destination: headphone)
        checkEqual(noPhysicalInput.physicalChannels, 0)
        // Mixed rates are preserved for the converter rather than rejected or truncated.
        let mixed = try PlaybackLayout.validate(inputs: [microphone, tap], outputs: headphone.outputs,
                                                tap: tap, destination: headphone)
        checkEqual(mixed.inputSampleRate, 48000); checkEqual(mixed.outputSampleRate, 24000)
        let sony = routingOutput(id: 2, uid: "WH-1000XM5", rate: 44100)
        let sonyLayout = try PlaybackLayout.validate(inputs: [tap], outputs: sony.outputs, tap: tap, destination: sony)
        checkEqual(sonyLayout.inputSampleRate, 48000); checkEqual(sonyLayout.outputSampleRate, 44100)
        do {
            _ = try PlaybackLayout.validate(inputs: [microphone, routingStream(rate: .nan)], outputs: headphone.outputs,
                                            tap: tap, destination: headphone)
            checkTrue(false)
        } catch { checkTrue(error.localizedDescription.contains("sample rate")) }
        do {
            _ = try PlaybackLayout.validate(inputs: [microphone], outputs: headphone.outputs,
                                            tap: tap, destination: headphone)
            checkTrue(false)
        } catch { checkTrue(error.localizedDescription.contains("layout")) }
        checkTrue(routingOutput(id: 3, uid: "surround", channels: 6).controlUnavailableReason != nil)
    }
}
