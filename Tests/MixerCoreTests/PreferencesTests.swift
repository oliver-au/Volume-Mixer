import Foundation
import MixerCore

final class MemoryPreferences: PreferencesBacking {
    var values: [String: Any] = [:]
    var removedDomains: [String] = []
    var canSynchronize = true
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
    func removeObject(forKey key: String) { values.removeValue(forKey: key) }
    func removePersistentDomain(forName domain: String) { removedDomains.append(domain); values.removeAll() }
    func persistentDomain(forName domain: String) -> [String: Any]? { values }
    @discardableResult func synchronize() -> Bool { canSynchronize }
}

final class PreferencesTests {
    func testMuteRestoresLevelAndSliderUnmutes() {
        var level = AppLevel(volume: 0.35)
        level.muted = true
        checkEqual(level.gain, 0)
        checkEqual(level.volume, 0.35)
        level.muted = false
        checkEqual(level.gain, 0.35)
        level.muted = true; level.moveSlider(to: 0.8)
        checkFalse(level.muted)
        checkEqual(level.gain, 0.8)
    }
    func testPersistenceAndUninstallDoNotTouchOtherDomains() {
        let domain = "local.oliver.VolumeMixer.test.\(UUID().uuidString)"
        let store = MemoryPreferences(), other = MemoryPreferences()
        other.set("keep", forKey: "value")
        let identity = IdentityResolver.resolve(.init(pid: 1, bundleID: "test.player"))
        let prefs = Preferences(domain: domain, backing: store)
        prefs.save(AppLevel(volume: 0.42, muted: true), for: identity)
        prefs.hasEnabledControl = true
        let restarted = Preferences(domain: domain, backing: store)
        checkEqual(restarted.level(for: identity), AppLevel(volume: 0.42, muted: true))
        restarted.removeAll()
        restarted.save(AppLevel(volume: 0.1), for: identity)
        checkEqual(Preferences(domain: domain, backing: store).level(for: identity), AppLevel())
        checkFalse(Preferences(domain: domain, backing: store).hasEnabledControl)
        checkEqual(store.removedDomains, [domain])
        checkEqual(other.values["value"] as? String, "keep")
    }
    func testVisibilityRetainsMutedRunningAppAndRecentIdleApp() {
        let now = Date()
        checkTrue(RowVisibility.shouldShow(active: false, running: true, muted: true, lastActive: now.addingTimeInterval(-120), now: now))
        checkTrue(RowVisibility.shouldShow(active: false, running: false, muted: false, lastActive: now.addingTimeInterval(-59), now: now))
        checkFalse(RowVisibility.shouldShow(active: false, running: true, muted: false, lastActive: now.addingTimeInterval(-61), now: now))
    }
    func testRemovalFailureIsReportedAndWritesStayDisabled() {
        let store = MemoryPreferences(); store.canSynchronize = false
        let prefs = Preferences(backing: store)
        checkFalse(prefs.removeAll())
        prefs.paused = true; prefs.hasEnabledControl = true
        checkTrue(store.values.isEmpty)
    }
}
