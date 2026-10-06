import Foundation
import AVFAudio
import AudioDSP

/// User-invoked diagnostics. This uses synthetic samples and an offline engine;
/// it never discovers, opens, captures, or changes a physical audio device.
public enum PlaybackProbe {
    public static func run() throws {
        try check(rate: 44100, channels: 2)
        try check(rate: 24000, channels: 1)
    }
    private static func check(rate: Double, channels: UInt32) throws {
        let captureFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: true)!
        let playbackFormat = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
        let input = AudioStreamInfo(id: 0, format: captureFormat.streamDescription.pointee)
        let destination = OutputDevice(id: 0, uid: "offline-probe", name: "Offline test", sampleRate: rate, inputs: [],
            outputs: [AudioStreamInfo(id: 0, format: playbackFormat.streamDescription.pointee)])
        let playback = try BufferedPlayback(input: input, output: destination, gain: 0.37, offline: true)
        defer { playback.stop() }
        guard let capture = AVAudioPCMBuffer(pcmFormat: captureFormat, frameCapacity: 512),
              let output = AVAudioPCMBuffer(pcmFormat: playbackFormat, frameCapacity: 512) else {
            throw AudioFailure("Couldn't allocate the offline audio check.")
        }
        try playback.start()
        var captured = 0, rendered = 0
        func render(_ frames: Int) throws {
            let needed = Int(Double(rendered + frames) * 48000 / rate) + 8192
            while captured < needed {
                let count = min(512, needed - captured)
                capture.frameLength = UInt32(count)
                let data = capture.floatChannelData![0]
                for i in 0..<count {
                    let value = Float(0.5 * sin(2 * Double.pi * 1000 * Double(captured + i) / 48000))
                    data[2*i] = value; data[2*i + 1] = value
                }
                VMBridgeCapture(playback.bridge, capture.audioBufferList)
                captured += count
            }
            let status = try playback.renderOffline(UInt32(frames), to: output)
            guard status == .success, output.frameLength == frames, playback.fault == 0,
                  VMBridgeUnderruns(playback.bridge) == 0 else {
                throw AudioFailure("The offline audio check couldn't maintain \(Int(rate)) Hz playback (status \(status.rawValue), fault \(playback.fault)). Keep control paused.")
            }
            rendered += frames
        }
        var samples: [Double] = []
        while rendered < Int(rate) {
            try render(min(512, Int(rate) - rendered))
            if rendered > Int(rate / 4) {
                for i in 0..<Int(output.frameLength) {
                    let value = output.floatChannelData![0][i]
                    guard value.isFinite else { throw AudioFailure("The offline audio check produced invalid samples. Keep control paused.") }
                    if channels == 2, abs(value - output.floatChannelData![1][i]) > 0.0001 {
                        throw AudioFailure("The offline audio check couldn't preserve both channels. Keep control paused.")
                    }
                    samples.append(Double(value))
                }
            }
        }
        var s = 0.0, c = 0.0, ss = 0.0, cc = 0.0, sc = 0.0
        for (i, value) in samples.enumerated() {
            let angle = 2 * Double.pi * 1000 * Double(i) / rate
            let sine = sin(angle), cosine = cos(angle)
            s += value*sine; c += value*cosine; ss += sine*sine; cc += cosine*cosine; sc += sine*cosine
        }
        let determinant = ss*cc - sc*sc
        let a = (s*cc - c*sc) / determinant, b = (c*ss - s*sc) / determinant
        var error = 0.0
        for (i, value) in samples.enumerated() {
            let angle = 2 * Double.pi * 1000 * Double(i) / rate
            let delta = value - a*sin(angle) - b*cos(angle); error += delta*delta
        }
        guard abs(hypot(a, b) - 0.185) < 0.002, sqrt(error / Double(samples.count)) < 0.002 else {
            throw AudioFailure("The offline audio check couldn't preserve pitch and volume at \(Int(rate)) Hz. Keep control paused.")
        }
        playback.setGain(0)
        for _ in 0..<8 { try render(512) }
        for c in 0..<Int(channels) {
            for i in 0..<Int(output.frameLength) where abs(output.floatChannelData![c][i]) > 0.000001 {
                throw AudioFailure("The offline audio check couldn't mute playback. Keep control paused.")
            }
        }
    }
}
