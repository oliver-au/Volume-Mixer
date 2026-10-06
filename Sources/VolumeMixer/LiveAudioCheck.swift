import Foundation
import CoreAudio
import AppKit
import MixerCore

/// Explicit developer-only invocation. Controls only the two named disposable fixtures.
/// Stores measurements/status, never captured samples. It is not run at normal launch.
enum LiveAudioCheck {
    static func run(reportURL: URL) {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        DispatchQueue(label: "local.oliver.VolumeMixer.live-check").async {
            var report: [String: Any] = ["started": ISO8601DateFormatter().string(from: Date()), "passed": false]
            var first: AudioSession?, second: AudioSession?
            do {
                let output = try HAL.defaultOutput()
                let initialTaps = try HAL.objects(HAL.system, kAudioHardwarePropertyTapList).count
                let apps = try ProcessCatalog.scan()
                guard let a = apps.first(where: { $0.identity.persistentKey == "app:local.oliver.VolumeMixer.Fixture.A" }),
                      let b = apps.first(where: { $0.identity.persistentKey == "app:local.oliver.VolumeMixer.Fixture.B" }) else {
                    throw AudioFailure("Launch both live-test fixtures first.")
                }
                report["output"] = output.name
                first = try AudioSession(app: a, output: output, gain: 0.5)
                second = try AudioSession(app: b, output: output, gain: 0.75)
                Thread.sleep(forTimeInterval: 1)
                let inputA = first!.peak, inputB = second!.peak
                let outputA = first!.outputPeak, outputB = second!.outputPeak
                report["capturePeakA"] = inputA; report["capturePeakB"] = inputB
                report["renderPeakA50"] = outputA; report["renderPeakB75"] = outputB
                report["callbacksA"] = first!.callbacks; report["callbacksB"] = second!.callbacks
                guard inputA > 0.001, inputB > 0.001,
                      abs(outputA / inputA - 0.5) < 0.03, abs(outputB / inputB - 0.75) < 0.03 else {
                    throw AudioFailure("Live samples did not match independent gains. Check audio permission.")
                }
                first!.setGain(0)
                Thread.sleep(forTimeInterval: 0.5)
                let muted = first!.outputPeak, unchangedB = second!.outputPeak
                report["renderPeakAMuted"] = muted; report["renderPeakBUnaffected"] = unchangedB
                guard muted == 0, abs(unchangedB - outputB) < 0.001 else { throw AudioFailure("Mute or independent playback failed.") }
                first!.setGain(0.5)
                Thread.sleep(forTimeInterval: 0.5)
                report["renderPeakARestored"] = first!.outputPeak
                guard first!.fault == 0, second!.fault == 0 else { throw AudioFailure("Unexpected audio layout while playing.") }
                first!.stop(); first = nil; second!.stop(); second = nil
                let remainingTaps = try HAL.objects(HAL.system, kAudioHardwarePropertyTapList).count
                report["tapCountBefore"] = initialTaps; report["tapCountAfter"] = remainingTaps
                guard remainingTaps == initialTaps, try HAL.defaultOutput().id == output.id else { throw AudioFailure("Audio resources or default output changed after teardown.") }
                report["passed"] = true
                report["limit"] = "Validates live tap input and rendered buffers, not calibrated acoustic output or Bluetooth hardware."
            } catch { report["error"] = error.localizedDescription }
            first?.stop(); second?.stop()
            report["finished"] = ISO8601DateFormatter().string(from: Date())
            do { try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: reportURL, options: .atomic) }
            catch { fputs("Couldn't write live-test report: \(error)\n", stderr) }
            DispatchQueue.main.async { application.terminate(nil) }
        }
        application.run()
    }
}
