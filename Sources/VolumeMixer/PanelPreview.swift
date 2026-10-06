import Foundation
import CoreAudio
import MixerCore
import AppKit

/// Explicit developer-only UI mode: no HAL enumeration, real audio sessions,
/// user defaults, login registration, privacy panes, or installed-app mutations.
enum PanelPreview {
    static func option(_ name: String) -> Bool {
        CommandLine.arguments.contains("--preview-\(name)") ||
            (Bundle.main.object(forInfoDictionaryKey: "VolumeMixerPreviewOptions") as? [String] ?? []).contains(name)
    }
    static func recordEvent(_ event: String) {
        guard Bundle.main.object(forInfoDictionaryKey: "VolumeMixerPreview") as? Bool == true else { return }
        let url = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("events.txt")
        let previous = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        try? (previous + event + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
    @MainActor static func recordLayout(screen: NSScreen, anchor: NSRect, frame: NSRect,
                                       requestedHeight: CGFloat, listHeight: CGFloat) {
        guard Bundle.main.object(forInfoDictionaryKey: "VolumeMixerPreview") as? Bool == true else { return }
        let report = "screen=\(screen.frame)\nvisible=\(screen.visibleFrame)\nanchor=\(anchor)\npanel=\(frame)\nrequested=\(requestedHeight)\nlist=\(listHeight)\n"
        try? report.write(to: Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("layout.txt"),
                          atomically: true, encoding: .utf8)
    }
    static func makeEngine() -> MixerEngine {
        let preferences = Preferences(backing: PreviewPreferences())
        preferences.hasEnabledControl = !option("welcome")
        preferences.paused = option("paused")
        let safari = IdentityResolver.resolve(.init(pid: 10001, bundleID: "preview.Safari", appName: "Safari", appPath: "/Applications/Safari.app"))
        let game = IdentityResolver.resolve(.init(pid: 10002, bundleID: "preview.Game", appName: "SUPER ROBOT WARS Y", appPath: "/Applications/CrossOver.app"))
        preferences.save(AppLevel(volume: 0.8), for: safari)
        preferences.save(AppLevel(volume: 0.37, outputUID: "preview.headphones", outputName: "WH-1000XM5"), for: game)
        var identities = [safari, game]
        if option("long") {
            identities += (1...10).map { IdentityResolver.resolve(.init(pid: Int32(10002 + $0),
                bundleID: "preview.Extra\($0)", appName: "Preview app \($0) with a long application name")) }
        }
        let apps = option("empty") ? [] : identities.enumerated().map { index, identity in
            AudioApplication(identity: identity, processObjects: [UInt32(10001 + index)],
                             pids: [Int32(10001 + index)], active: true, outputDevices: [1])
        }
        let format = AudioStreamBasicDescription(mSampleRate: 44100, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2,
            mBitsPerChannel: 32, mReserved: 0)
        let headphones = OutputDevice(id: 1, uid: "preview.headphones", name: "WH-1000XM5", sampleRate: 44100,
                                      inputs: [], outputs: [AudioStreamInfo(id: 10, format: format)])
        let speakers = OutputDevice(id: 2, uid: "preview.speakers", name: "MacBook Pro Speakers", sampleRate: 44100,
                                    inputs: [], outputs: [AudioStreamInfo(id: 20, format: format)])
        var environment = MixerEnvironment()
        environment.observesHardware = false
        environment.pollsAutomatically = false
        environment.output = { headphones }
        environment.outputs = { [headphones, speakers] }
        environment.applications = { apps }
        environment.isRunning = { _ in true }
        environment.makeSession = { app, _, _ in
            if option("error"), app.identity.key == game.key {
                throw AudioFailure("The selected output is disconnected. Reconnect it or choose another output.")
            }
            return PreviewSession()
        }
        return MixerEngine(preferences: preferences, environment: environment)
    }
}

private final class PreviewSession: AppAudioSession {
    private var progress: UInt64 = 0
    var callbacks: UInt64 { progress += 1; return progress }
    var fault: UInt32 { 0 }
    func setGain(_ value: Float) {}
    func stop() {}
}

private final class PreviewPreferences: PreferencesBacking {
    private var values: [String: Any] = [:]
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
    func removeObject(forKey key: String) { values.removeValue(forKey: key) }
    func removePersistentDomain(forName _: String) { values.removeAll() }
    func persistentDomain(forName _: String) -> [String: Any]? { values }
    func synchronize() -> Bool { true }
}
