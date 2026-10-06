import Foundation
import AVFAudio
import AudioDSP
import MixerCore

/// Every engine in these checks is in manual offline mode. No tap, audio device,
/// microphone, preference domain, or system permission is opened or changed.
private final class OfflinePlayback {
    let playback: BufferedPlayback
    let output: AVAudioPCMBuffer
    let inputRate: Double, outputRate: Double
    var captured = 0, rendered = 0, chunks = 0
    var frequency = 1000.0
    var constant: Float?
    init(inputRate: Double = 48000, outputRate: Double = 44100, mono: Bool = false, gain: Float = 0.4) throws {
        guard BufferedPlayback.componentsAvailable else {
            throw TestSkipped(reason: "The test environment cannot resolve Apple's playback Audio Units; real converter validation remains pending.")
        }
        self.inputRate = inputRate; self.outputRate = outputRate
        playback = try BufferedPlayback(input: routingStream(rate: inputRate),
            output: routingOutput(id: 0, uid: "offline-only", rate: outputRate, channels: mono ? 1 : 2), gain: gain, offline: true)
        let format = try require(AVAudioFormat(standardFormatWithSampleRate: outputRate, channels: mono ? 1 : 2))
        output = try require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096))
        try playback.start()
    }
    func capture(until target: Int) {
        let sizes = [512, 73, 256, 1024, 127]
        while captured < target {
            let count = min(sizes[chunks % sizes.count], target - captured)
            let input = Buffers(channels: [2], frames: count)
            for i in 0..<count {
                let angle = 2 * Double.pi * frequency * Double(captured + i) / inputRate
                input.samples()[2*i] = constant ?? Float(0.5 * sin(angle))
                input.samples()[2*i + 1] = constant ?? Float(0.25 * cos(angle))
            }
            VMBridgeCapture(playback.bridge, input.list.unsafePointer)
            captured += count; chunks += 1
        }
    }
    func render(_ frames: Int, clockRatio: Double = 1, lead: Int = 8192) throws {
        // The capture clock advances independently, in differently sized packets.
        capture(until: Int(Double(rendered + frames) * inputRate / outputRate * clockRatio) + lead)
        let status = try playback.renderOffline(UInt32(frames), to: output)
        guard status == .success, output.frameLength == frames, playback.fault == 0 else {
            throw AudioFailure("Offline render failed: status=\(status.rawValue), frames=\(output.frameLength), fault=\(playback.fault)")
        }
        rendered += frames
    }
    func samples(channel: Int = 0) -> [Float] {
        Array(UnsafeBufferPointer(start: output.floatChannelData![channel], count: Int(output.frameLength)))
    }
    deinit { playback.stop() }
}

final class PlaybackTests {
    func testUnavailableComponentsFailWithoutStartingAudio() throws {
        guard !BufferedPlayback.componentsAvailable else { return }
        do {
            _ = try BufferedPlayback(input: routingStream(), output: routingOutput(id: 0, uid: "offline", rate: 44100), gain: 1, offline: true)
            checkTrue(false)
        } catch { checkTrue(error.localizedDescription.contains("components are unavailable")) }
        do { try PlaybackProbe.run(); checkTrue(false) }
        catch { checkTrue(error.localizedDescription.contains("components are unavailable")) }
    }
    private func tone(inputRate: Double = 48000, outputRate: Double, mono: Bool = false,
                      frequency: Double = 1000) throws -> [[Float]] {
        let fixture = try OfflinePlayback(inputRate: inputRate, outputRate: outputRate, mono: mono)
        fixture.frequency = frequency
        let sizes = [64, 127, 441, 256, 1024, 89]
        var channels = [[Float]](repeating: [], count: mono ? 1 : 2), block = 0
        while fixture.rendered < Int(outputRate * 3) {
            try fixture.render(sizes[block % sizes.count])
            for c in channels.indices { channels[c].append(contentsOf: fixture.samples(channel: c)) }
            block += 1
        }
        checkEqual(VMBridgeUnderruns(fixture.playback.bridge), 0)
        return channels.map { Array($0.dropFirst(Int(outputRate))) }
    }
    private func measure(_ samples: [Float], rate: Double, frequency: Double = 1000) -> (amplitude: Double, residual: Double) {
        // Fit both phases, so converter latency is allowed but pitch errors and
        // discontinuities cannot hide behind an RMS-only amplitude check.
        var sine = 0.0, cosine = 0.0, ss = 0.0, cc = 0.0, sc = 0.0
        for (i, value) in samples.enumerated() {
            let angle = 2 * Double.pi * frequency * Double(i) / rate
            let s = sin(angle), c = cos(angle)
            sine += Double(value) * s; cosine += Double(value) * c
            ss += s*s; cc += c*c; sc += s*c
        }
        let determinant = ss*cc - sc*sc
        let a = (sine*cc - cosine*sc) / determinant, b = (cosine*ss - sine*sc) / determinant
        var error = 0.0
        for (i, value) in samples.enumerated() {
            let angle = 2 * Double.pi * frequency * Double(i) / rate
            let delta = Double(value) - a*sin(angle) - b*cos(angle); error += delta*delta
        }
        return (hypot(a, b), sqrt(error / Double(samples.count)))
    }
    func testAppleSampleRateConversion() throws {
        for (input, output) in [(48000.0, 44100.0), (44100.0, 48000.0)] {
            let channels = try tone(inputRate: input, outputRate: output)
            let left = measure(channels[0], rate: output), right = measure(channels[1], rate: output)
            checkEqual(left.amplitude, 0.2, accuracy: 0.001)
            checkEqual(right.amplitude, 0.1, accuracy: 0.001)
            checkLess(left.residual, 0.001); checkLess(right.residual, 0.001)
        }
        try PlaybackProbe.run()
    }
    func testMonoAndAntiAliasing() throws {
        let mono = try tone(outputRate: 24000, mono: true)
        let result = measure(mono[0], rate: 24000)
        checkEqual(result.amplitude, hypot(0.1, 0.05), accuracy: 0.001)
        checkLess(result.residual, 0.001)
        let rejected = try tone(outputRate: 24000, mono: true, frequency: 18000)[0]
        let rms = sqrt(rejected.reduce(0.0) { $0 + Double($1)*Double($1) } / Double(rejected.count))
        checkLess(rms, 0.001)
    }
    func testMuteAndIndependentSessions() throws {
        let first = try OfflinePlayback(gain: 0.19), second = try OfflinePlayback(gain: 0.7)
        first.constant = 1; second.constant = 1
        for _ in 0..<8 { try first.render(1024); try second.render(1024) }
        checkEqual(first.samples().last!, 0.19, accuracy: 0.0001)
        checkEqual(second.samples().last!, 0.7, accuracy: 0.0001)
        first.playback.setGain(0)
        for _ in 0..<4 { try first.render(1024); try second.render(1024) }
        checkTrue(first.samples().allSatisfy { abs($0) < 0.000001 })
        checkEqual(second.samples().last!, 0.7, accuracy: 0.0001)
        first.playback.setGain(0.19)
        for _ in 0..<4 { try first.render(1024) }
        checkEqual(first.samples().last!, 0.19, accuracy: 0.0001)
        checkEqual(VMBridgeUnderruns(first.playback.bridge), 0)
    }
    func testClockRecovery() {
        var clock = PlaybackClockRecovery()
        checkGreater(clock.rate(queued: 3000, target: 2048, sampleRate: 48000, active: true), 1)
        _ = clock.rate(queued: 0, target: 2048, sampleRate: 48000, active: false)
        checkLess(clock.rate(queued: 1000, target: 2048, sampleRate: 48000, active: true), 1)
        for queued: UInt32 in [0, 65536] {
            for _ in 0..<30 {
                let rate = clock.rate(queued: queued, target: 2048, sampleRate: 48000, active: true)
                checkTrue((0.998...1.002).contains(rate))
            }
        }
        checkEqual(clock.rate(queued: 0, target: 2048, sampleRate: .nan, active: true), 1)
    }
    func testSustainedPlayback() throws {
        // Ten minutes of synthetic audio, faster than real time. Exercise opposite
        // clock errors, variable capture packets, ring wraps and drift recovery.
        for ratio in [0.99985, 1.00015] {
            let fixture = try OfflinePlayback(gain: 0.37); fixture.constant = 0.5
            var nextMaintenance = 44100, minQueued = UInt32.max, maxQueued: UInt32 = 0
            while fixture.rendered < 44100 * 300 {
                try fixture.render(512, clockRatio: ratio, lead: 4096)
                if fixture.rendered >= nextMaintenance {
                    fixture.playback.maintain(active: true); nextMaintenance += 44100
                    let queued = VMBridgeQueuedFrames(fixture.playback.bridge)
                    minQueued = min(minQueued, queued); maxQueued = max(maxQueued, queued)
                }
            }
            checkEqual(VMBridgeUnderruns(fixture.playback.bridge), 0)
            checkGreater(minQueued, 512); checkLess(maxQueued, 12000)
            checkEqual(fixture.samples().last!, 0.185, accuracy: 0.001)
        }
    }
}
