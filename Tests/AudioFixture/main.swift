import AppKit
import AVFAudio

// Disposable live-test source. It only plays a quiet sine tone; it never captures audio.
let frequency = Double(CommandLine.arguments.dropFirst().first ?? "440") ?? 440
let seconds = Double(CommandLine.arguments.dropFirst(2).first ?? "120") ?? 120
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let engine = AVAudioEngine()
let player = AVAudioPlayerNode()
let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000)!
buffer.frameLength = buffer.frameCapacity
for channel in 0..<2 {
    for frame in 0..<48000 { buffer.floatChannelData![channel][frame] = Float(sin(2 * .pi * frequency * Double(frame) / 48000)) * 0.015 }
}
engine.attach(player)
engine.connect(player, to: engine.mainMixerNode, format: format)
do {
    try engine.start()
    player.scheduleBuffer(buffer, at: nil, options: .loops)
    player.play()
    DispatchQueue.main.asyncAfter(deadline: .now() + min(300, max(1, seconds))) {
        player.stop(); engine.stop(); app.terminate(nil)
    }
    app.run()
} catch { fputs("Audio fixture failed: \(error)\n", stderr); exit(1) }
