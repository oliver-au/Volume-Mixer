import Foundation
import CoreAudio
import MixerCore

private final class FakeSession: AppAudioSession {
    var callbacks: UInt64 = 1
    var fault: UInt32 = 0
    var gain: Float
    let output: OutputDevice
    var stopped = false
    init(_ output: OutputDevice, _ gain: Float) {
        self.gain = gain; self.output = output
    }
    func setGain(_ value: Float) { gain = value }
    func stop() { stopped = true }
}

private final class CompletionFlag: @unchecked Sendable { var value = false }

private final class EngineHarness {
    let store = MemoryPreferences()
    var engine: MixerEngine!
    var snapshots: [MixerSnapshot] = []
    var sessions: [FakeSession] = []
    var clock = Date(timeIntervalSince1970: 100)
    var failCreation = false
    var failDiscovery = false
    var temporaryDiscovery = false
    var scans = 0
    var unusableOutputs: Set<AudioObjectID> = []
    var rate = 48000.0
    var defaultOutputID: AudioObjectID = 1
    var extraOutputs: [OutputDevice] = []
    var runningWithoutAudio: Set<String> = []
    var apps: [AudioApplication] = [
        AudioApplication(identity: IdentityResolver.resolve(.init(pid: 10, bundleID: "example.A", appName: "Audio A")),
                         processObjects: [10], pids: [10], active: true, outputDevices: [1]),
        AudioApplication(identity: IdentityResolver.resolve(.init(pid: 20, bundleID: "example.B", appName: "Audio B")),
                         processObjects: [20], pids: [20], active: true, outputDevices: [1])
    ]
    init(initialLevel: Float? = nil) {
        let preferences = Preferences(backing: store)
        preferences.hasEnabledControl = true
        if let initialLevel { preferences.save(AppLevel(volume: initialLevel), for: apps[0].identity) }
        var environment = MixerEnvironment()
        environment.observesHardware = false; environment.pollsAutomatically = false
        environment.now = { [unowned self] in clock }
        environment.output = { [unowned self] in
            if failDiscovery { throw AudioFailure("Simulated discovery failure", status: temporaryDiscovery ? kAudioHardwareBadPropertySizeError : nil) }
            return OutputDevice(id: defaultOutputID, uid: defaultOutputID == 1 ? "test" : "test-\(defaultOutputID)",
                                name: "Test output", sampleRate: rate, inputs: [], outputs: [])
        }
        environment.applications = { [unowned self] _ in scans += 1; return apps }
        environment.outputs = { [unowned self] in extraOutputs }
        environment.sessionIsUsable = { [unowned self] _, output in !unusableOutputs.contains(output.id) }
        environment.isRunning = { [unowned self] in runningWithoutAudio.contains($0.identity.key) }
        environment.makeSession = { [unowned self] _, output, gain in
            if failCreation { throw AudioFailure("Simulated permission denial") }
            let session = FakeSession(output, gain); sessions.append(session); return session
        }
        engine = MixerEngine(preferences: preferences, environment: environment)
        engine.start { [weak self] in self?.snapshots.append($0) }
    }
    func wait(_ condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(2)
        while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
        if !condition() { throw AudioFailure("Timed out waiting for engine state") }
    }
    func row(_ id: String) -> MixerRow? { snapshots.last?.rows.first { $0.id == id } }
    func settle(_ change: () -> Void) throws {
        let before = snapshots.count; change()
        try wait { snapshots.count > before && snapshots.last?.rows.contains(where: \.connecting) == false }
    }
    func stop() throws {
        // shutdown delivers on the main queue, which is pumped by wait().
        let done = CompletionFlag(); engine.shutdown { done.value = true }; try wait { done.value }
    }
}

final class LifecycleTests {
    func testKeyboardStyleChangesDebouncePersistence() throws {
        let h = EngineHarness(initialLevel: 0.8); defer { try? h.stop() }
        try h.wait { h.row("app:example.A")?.controlled == true }
        let writes = h.store.levelWrites, scans = h.scans
        let session = try require(h.sessions.first)
        // Discrete key actions use the debounce, without mouse-drag brackets.
        for i in 0..<20 {
            try h.settle { h.engine.setLevel(id: "app:example.A", volume: 0.79 - Float(i) * 0.01) }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            checkEqual(h.store.levelWrites, writes)
        }
        try h.wait { h.store.levelWrites == writes + 1 }
        checkEqual(h.scans, scans); checkEqual(h.sessions.count, 1)
        checkFalse(session.stopped)
        checkEqual(Preferences(backing: h.store).level(for: h.apps[0].identity).volume, 0.6, accuracy: 0.00001)
    }
    func testDraggingDefersSaveAndKeepsUnityUntilFinished() throws {
        let h = EngineHarness(); defer { try? h.stop() }
        try h.wait { !h.snapshots.isEmpty }
        h.engine.setEditing(id: "app:example.A", editing: true)
        try h.settle { h.engine.setLevel(id: "app:example.A", volume: 0.5) }
        try h.settle { h.engine.setLevel(id: "app:example.A", volume: 1) }
        h.clock.addTimeInterval(10); h.sessions[0].callbacks += 1
        try h.settle { h.engine.refreshNow() }
        checkFalse(h.sessions[0].stopped); checkEqual(h.store.levelWrites, 0)
        h.engine.setEditing(id: "app:example.A", editing: false)
        try h.settle { h.engine.refreshNow() }
        checkEqual(h.store.levelWrites, 1); checkFalse(h.sessions[0].stopped)
        h.clock.addTimeInterval(2)
        try h.settle { h.engine.refreshNow() }
        checkTrue(h.sessions[0].stopped); checkFalse(h.row("app:example.A")!.controlled)
    }
    func testPendingSaveIsFlushedOnPauseAndCannotReturnAfterResetOrUninstall() throws {
        let h = EngineHarness(); defer { try? h.stop() }
        try h.wait { !h.snapshots.isEmpty }
        h.engine.setEditing(id: "app:example.A", editing: true)
        try h.settle { h.engine.setLevel(id: "app:example.A", volume: 0.3) }
        checkEqual(h.store.levelWrites, 0)
        try h.settle { h.engine.setPaused(true) }
        checkEqual(Preferences(backing: h.store).level(for: h.apps[0].identity).volume, 0.3)
        try h.settle { h.engine.setLevel(id: "app:example.A", volume: 0.2) }
        try h.settle { h.engine.resetLevels() }
        try h.stop()
        checkEqual(Preferences(backing: h.store).level(for: h.apps[0].identity).volume, 1)
        checkTrue(h.engine.clearSettingsAfterShutdown())
        h.engine.setLevel(id: "app:example.A", volume: 0.9)
        try h.stop(); checkTrue(h.store.values.isEmpty)
    }
    func testRepeatedDiscoveryFailuresStopControlButRetainRouteChoices() throws {
        let h = EngineHarness(); defer { try? h.stop() }
        try h.wait { !h.snapshots.isEmpty }
        h.extraOutputs = [routingOutput(id: 2, uid: "headphones")]
        try h.settle { h.engine.setLevel(id: "app:example.A", volume: 0.5) }
        h.failDiscovery = true; h.temporaryDiscovery = true
        for _ in 0..<3 { try h.settle { h.engine.refreshNow() } }
        checkTrue(h.sessions[0].stopped); checkFalse(h.row("app:example.A")!.controlled)
        checkTrue(h.row("app:example.A")?.error != nil)
        checkTrue(h.snapshots.last!.outputs.contains { $0.uid == "headphones" })
        try h.settle { h.engine.setOutput(id: "app:example.A", uid: "headphones") }
        checkEqual(h.row("app:example.A")?.level.outputUID, "headphones")
        checkEqual(h.sessions.count, 1) // Stale inventory cannot create a new graph.
        h.failDiscovery = false
        try h.settle { h.engine.refreshNow() }
        checkEqual(h.sessions.last!.output.uid, "headphones"); checkEqual(h.sessions.count, 2)
    }
    func testDiscoveryGraceStillStopsFaultyOrDisconnectedRoutes() throws {
        for disconnect in [false, true] {
            let h = EngineHarness(); defer { try? h.stop() }
            try h.wait { !h.snapshots.isEmpty }
            h.extraOutputs = [routingOutput(id: 2, uid: "headphones")]
            try h.settle { h.engine.setLevel(id: "app:example.B", volume: 0.7) }
            let healthy = try require(h.sessions.last)
            try h.settle { h.engine.setOutput(id: "app:example.A", uid: "headphones") }
            let faulty = try require(h.sessions.last)
            if disconnect { h.unusableOutputs = [2] } else { faulty.fault = 1 }
            h.failDiscovery = true; h.temporaryDiscovery = true
            try h.settle { h.engine.refreshNow() }
            checkTrue(faulty.stopped); checkFalse(healthy.stopped)
            checkFalse(h.row("app:example.A")!.controlled); checkTrue(h.row("app:example.B")!.controlled)
            h.failDiscovery = false; h.unusableOutputs.removeAll()
            try h.settle { h.engine.refreshNow() }
            checkFalse(h.row("app:example.A")!.controlled); checkFalse(healthy.stopped)
            try h.settle { h.engine.retry(id: "app:example.A") }
            checkTrue(h.row("app:example.A")!.controlled)
        }
    }
    func testDiscoveryGraceHasTimeLimit() throws {
        let h = EngineHarness(); defer { try? h.stop() }
        try h.wait { !h.snapshots.isEmpty }
        try h.settle { h.engine.setLevel(id: "app:example.A", volume: 0.5) }
        h.failDiscovery = true; h.temporaryDiscovery = true
        try h.settle { h.engine.refreshNow() }
        h.clock.addTimeInterval(2.1); h.sessions[0].callbacks += 1
        try h.settle { h.engine.refreshNow() }
        checkTrue(h.sessions[0].stopped)
    }
    func testHiddenIdleAppKeepsAttenuation() throws {
        let h = EngineHarness(); defer { try? h.stop() }
        try h.wait { !h.snapshots.isEmpty }
        try h.settle { h.engine.setLevel(id: "app:example.A", volume: 0.5) }
        let session = try require(h.sessions.first)
        h.apps[0].active = false
        try h.settle { h.engine.refreshNow() }
        h.clock.addTimeInterval(61)
        try h.settle { h.engine.refreshNow() }
        checkNil(h.row("app:example.A")); checkFalse(session.stopped)
        h.apps[0].active = true; session.callbacks += 1
        try h.settle { h.engine.refreshNow() }
        checkEqual(h.sessions.count, 1); checkEqual(session.gain, 0.5)
        checkTrue(h.row("app:example.A")!.controlled)
    }
    func testSliderUpdatesDoNotScanOrWriteForEveryEvent() throws {
        let h = EngineHarness(); defer { try? h.stop() }
        try h.wait { !h.snapshots.isEmpty }
        try h.settle { h.engine.setLevel(id: "app:example.A", volume: 0.5) }
        let scans = h.scans, writes = h.store.levelWrites
        for n in 1...40 { h.engine.setLevel(id: "app:example.A", volume: Float(n) / 100) }
        try h.wait { h.row("app:example.A")?.level.volume == 0.4 }
        checkEqual(h.scans, scans)
        checkLessEqual(h.store.levelWrites - writes, 1)
        checkEqual(h.sessions.count, 1); checkEqual(h.sessions[0].gain, 0.4)
        try h.stop()
        checkEqual(Preferences(backing: h.store).level(for: h.apps[0].identity).volume, 0.4)
    }
    func testUnityBoundaryDoesNotChurnSessions() throws {
        let h = EngineHarness(); defer { try? h.stop() }
        try h.wait { !h.snapshots.isEmpty }
        try h.settle { h.engine.setLevel(id: "app:example.A", volume: 0.99) }
        for _ in 0..<5 {
            try h.settle { h.engine.setLevel(id: "app:example.A", volume: 1) }
            try h.settle { h.engine.setLevel(id: "app:example.A", volume: 0.99) }
        }
        checkEqual(h.sessions.count, 1); checkFalse(h.sessions[0].stopped)
    }
    func testTemporaryDiscoveryFailurePreservesHealthyControl() throws {
        let h = EngineHarness(); defer { try? h.stop() }
        try h.wait { !h.snapshots.isEmpty }
        try h.settle { h.engine.setLevel(id: "app:example.A", volume: 0.5) }
        h.failDiscovery = true; h.temporaryDiscovery = true
        try h.settle { h.engine.refreshNow() }
        checkFalse(h.sessions[0].stopped)
        checkEqual(h.snapshots.last?.rows.count, 2)
        checkTrue(h.row("app:example.A")?.controlled == true)
        h.failDiscovery = false
        try h.settle { h.engine.refreshNow() }
        checkEqual(h.sessions.count, 1); checkNil(h.snapshots.last?.error)
    }
    func testNewAppPublishesConnecting() throws {
        let h = EngineHarness(initialLevel: 0.5); defer { try? h.stop() }
        try h.wait { h.row("app:example.A")?.controlled == true }
        checkTrue(h.snapshots.contains { $0.rows.contains { $0.id == "app:example.A" && $0.connecting } })
    }
    func testDefaultOutputSwitchPreservesUnchangedExplicitRoute() throws {
        let h = EngineHarness(); defer { try? h.stop() }
        try h.wait { !h.snapshots.isEmpty }
        h.extraOutputs = [routingOutput(id: 2, uid: "headphones")]
        try h.settle { h.engine.refreshNow() }
        h.engine.setOutput(id: "app:example.A", uid: "headphones")
        try h.wait { h.row("app:example.A")?.controlled == true }
        let headphones = try require(h.sessions.last)
        h.engine.setLevel(id: "app:example.B", volume: 0.5)
        try h.wait { h.row("app:example.B")?.controlled == true }
        let originalDefault = try require(h.sessions.last)
        // Both apps still produce audio on device 1; it remains connected.
        // Only the system-following playback destination changes to device 3.
        h.extraOutputs.append(originalDefault.output)
        h.defaultOutputID = 3
        try h.settle { h.engine.refreshNow() }
        try h.wait { h.snapshots.last?.outputs.contains { $0.id == 3 } == true }
        checkFalse(headphones.stopped)
        checkTrue(originalDefault.stopped)
        checkEqual(h.sessions.count, 3)
        checkEqual(h.sessions.first { $0.output.id == 3 }?.gain, 0.5)
        checkTrue(h.row("app:example.A")!.controlled)
        checkTrue(h.row("app:example.B")!.controlled)
    }
    func testUnrelatedDefaultSwitchDoesNotRetryFailedExplicitRoute() throws {
        let h = EngineHarness(); defer { try? h.stop() }
        try h.wait { !h.snapshots.isEmpty }
        h.extraOutputs = [routingOutput(id: 2, uid: "headphones")]
        // Keep the original source in the inventory after changing the default.
        h.extraOutputs.append(try require(h.snapshots.last?.outputs.first { $0.id == 1 }))
        try h.settle { h.engine.refreshNow() }
        h.failCreation = true
        h.engine.setOutput(id: "app:example.A", uid: "headphones")
        try h.wait { h.row("app:example.A")?.error != nil }
        let error = h.row("app:example.A")?.error
        h.failCreation = false; h.defaultOutputID = 3
        try h.settle { h.engine.refreshNow() }
        try h.wait { h.snapshots.last?.outputs.contains { $0.id == 3 } == true }
        checkEqual(h.row("app:example.A")?.error, error)
        checkFalse(h.row("app:example.A")!.controlled)
        checkTrue(h.sessions.isEmpty)
        h.engine.retry(id: "app:example.A")
        try h.wait { h.row("app:example.A")?.controlled == true }
        checkNil(h.row("app:example.A")!.error)
        checkEqual(h.sessions.count, 1)
    }
    func testExplicitOutputAtUnityIsIndependentAndPauseRestoresOriginal() throws {
        let h = EngineHarness(); defer { try? h.stop() }
        try h.wait { !h.snapshots.isEmpty }
        h.extraOutputs = [routingOutput(id: 2, uid: "headphones")]
        try h.settle { h.engine.refreshNow() }
        h.engine.setOutput(id: "app:example.A", uid: "headphones")
        try h.wait { h.row("app:example.A")?.controlled == true }
        checkEqual(h.sessions.count, 1); checkEqual(h.sessions[0].gain, 1)
        checkEqual(h.sessions[0].output.uid, "headphones")
        checkFalse(h.row("app:example.B")!.controlled)
        h.engine.setLevel(id: "app:example.B", volume: 0.7)
        try h.wait { h.row("app:example.B")?.controlled == true }
        checkEqual(h.sessions[1].output.uid, "test")
        try h.settle { h.engine.setPaused(true) }
        checkTrue(h.sessions.allSatisfy(\.stopped))
        h.engine.setPaused(false)
        try h.wait { h.snapshots.last?.rows.allSatisfy(\.controlled) == true }
        checkEqual(h.sessions.count, 4)
        try h.settle { h.engine.setOutput(id: "app:example.A", uid: nil) }
        checkFalse(h.row("app:example.A")!.controlled)
        checkTrue(h.row("app:example.B")!.controlled)
        checkTrue(h.sessions.filter { $0.output.uid == "headphones" }.allSatisfy(\.stopped))
    }
    func testDisconnectedRouteRestoresOriginalAndReconnectsByUID() throws {
        let h = EngineHarness(); defer { try? h.stop() }
        try h.wait { !h.snapshots.isEmpty }
        h.extraOutputs = [routingOutput(id: 2, uid: "headphones")]
        try h.settle { h.engine.refreshNow() }
        h.engine.setLevel(id: "app:example.B", volume: 0.7)
        try h.wait { h.row("app:example.B")?.controlled == true }
        let other = h.sessions.last!
        h.engine.setOutput(id: "app:example.A", uid: "headphones")
        try h.wait { h.row("app:example.A")?.controlled == true }
        let first = h.sessions.last!
        try h.settle { h.engine.setLevel(id: "app:example.A", volume: 0.19) }
        try h.settle { h.engine.setLevel(id: "app:example.A", toggleMute: true) }
        h.extraOutputs = []; h.engine.refreshNow()
        try h.wait { h.row("app:example.A")?.error?.contains("disconnected") == true }
        checkTrue(first.stopped); checkFalse(h.row("app:example.A")!.controlled)
        checkFalse(other.stopped); checkEqual(other.gain, 0.7)
        checkEqual(h.row("app:example.A")!.level.outputUID, "headphones")
        h.extraOutputs = [routingOutput(id: 99, uid: "headphones")]
        h.engine.refreshNow()
        try h.wait { h.row("app:example.A")?.controlled == true }
        checkEqual(h.sessions.last!.output.id, 99); checkEqual(h.sessions.last!.gain, 0)
        checkEqual(h.row("app:example.A")!.level.volume, 0.19)
        checkFalse(other.stopped)
    }
    func testBluetoothProfileAndSourceChangesRebuildOnlyAffectedRoute() throws {
        let h = EngineHarness(); defer { try? h.stop() }
        try h.wait { !h.snapshots.isEmpty }
        h.extraOutputs = [routingOutput(id: 2, uid: "headphones")]
        try h.settle { h.engine.refreshNow() }
        h.engine.setOutput(id: "app:example.A", uid: "headphones")
        try h.wait { h.row("app:example.A")?.controlled == true }
        let stereo = h.sessions.last!
        h.engine.setLevel(id: "app:example.B", volume: 0.7)
        try h.wait { h.row("app:example.B")?.controlled == true }
        let other = h.sessions.last!
        h.extraOutputs = [routingOutput(id: 2, uid: "headphones", rate: 24000, channels: 1)]
        h.engine.refreshNow()
        try h.wait { h.sessions.count == 3 }
        checkTrue(stereo.stopped); checkFalse(other.stopped)
        checkEqual(h.sessions.last!.output.channels, 1)
        checkEqual(h.sessions.last!.output.sampleRate, 24000)
        let mono = h.sessions.last!
        h.apps[0].outputDevices = [2]; h.engine.refreshNow()
        try h.wait { h.sessions.count == 4 }
        checkTrue(mono.stopped); checkFalse(other.stopped)
    }
    func testSystemOutputHandlesGameStillBoundToAnotherDevice() throws {
        let h = EngineHarness(); defer { try? h.stop() }
        try h.wait { !h.snapshots.isEmpty }
        h.apps[0].outputDevices = [42, 43]
        try h.settle { h.engine.refreshNow() }
        checkFalse(h.row("app:example.A")!.controlled); checkTrue(h.sessions.isEmpty)
        try h.settle { h.engine.setLevel(id: "app:example.A", volume: 0.19) }
        checkTrue(h.row("app:example.A")!.controlled)
        checkEqual(h.sessions.last!.output.id, 1)
        checkEqual(h.sessions.last!.gain, 0.19)
        checkFalse(h.row("app:example.B")!.controlled)
        let original = h.sessions.last!
        try h.settle { h.engine.setLevel(id: "app:example.A", volume: 1) }
        checkFalse(original.stopped)
        h.clock.addTimeInterval(2)
        try h.settle { h.engine.refreshNow() }
        checkFalse(h.row("app:example.A")!.controlled)
        checkTrue(original.stopped)
    }
    func testIndependentSessionsPauseAndShutdown() throws {
        let h = EngineHarness(); defer { try? h.stop() }
        try h.wait { h.snapshots.last?.rows.count == 2 }
        h.engine.setLevel(id: "app:example.A", volume: 0.4)
        try h.wait { h.row("app:example.A")?.controlled == true }
        h.engine.setLevel(id: "app:example.B", volume: 0.7)
        try h.wait { h.row("app:example.B")?.controlled == true }
        checkEqual(h.sessions[0].gain, 0.4); checkEqual(h.sessions[1].gain, 0.7)
        try h.settle { h.engine.setLevel(id: "app:example.A", toggleMute: true) }
        checkEqual(h.sessions[0].gain, 0); checkEqual(h.sessions[1].gain, 0.7)
        try h.settle { h.engine.setPaused(true) }
        checkTrue(h.sessions.allSatisfy(\.stopped)); checkTrue(h.snapshots.last!.paused)
        h.engine.setPaused(false)
        try h.wait { h.snapshots.last?.rows.allSatisfy(\.controlled) == true }
        checkEqual(h.sessions.count, 4)
        try h.stop(); checkTrue(h.sessions.allSatisfy(\.stopped))
        let count = h.sessions.count
        h.engine.setPaused(false); h.engine.refreshNow()
        try h.stop(); checkEqual(h.sessions.count, count)
    }
    func testPermissionFailureAndExplicitRetry() throws {
        let h = EngineHarness(); defer { try? h.stop() }
        try h.wait { !h.snapshots.isEmpty }; h.failCreation = true
        h.engine.setLevel(id: "app:example.A", volume: 0.25)
        try h.wait { h.row("app:example.A")?.error != nil }
        checkFalse(h.row("app:example.A")!.controlled); checkTrue(h.sessions.isEmpty)
        checkEqual(h.row("app:example.A")!.level.volume, 0.25)
        h.failCreation = false; h.engine.retry(id: "app:example.A")
        try h.wait { h.row("app:example.A")?.controlled == true }
        checkNil(h.row("app:example.A")!.error)
        checkEqual(h.sessions.last!.gain, 0.25)
    }
    func testOutputChangeSleepAndDeviceLoss() throws {
        let h = EngineHarness(); defer { try? h.stop() }
        try h.wait { !h.snapshots.isEmpty }
        h.engine.setLevel(id: "app:example.A", volume: 0.5)
        try h.wait { h.row("app:example.A")?.controlled == true }
        h.rate = 24000; h.engine.refreshNow()
        try h.wait { h.sessions.count == 2 }
        checkTrue(h.sessions[0].stopped)
        h.engine.setSleeping(true); h.engine.setSleeping(false)
        try h.wait { h.sessions.count == 3 }
        checkTrue(h.sessions[1].stopped)
        h.failDiscovery = true; h.engine.refreshNow()
        try h.wait { h.snapshots.last?.error != nil }
        checkTrue(h.sessions.allSatisfy(\.stopped)); checkFalse(h.row("app:example.A")!.controlled)
        h.failDiscovery = false; h.engine.refreshNow()
        try h.wait { h.row("app:example.A")?.controlled == true }
        checkEqual(h.sessions.count, 4)
    }
    func testStalledCallbackAndLayoutFaultRestorePlayback() throws {
        let h = EngineHarness(); defer { try? h.stop() }
        try h.wait { !h.snapshots.isEmpty }
        h.engine.setLevel(id: "app:example.A", volume: 0.5)
        try h.wait { h.row("app:example.A")?.controlled == true }
        h.clock.addTimeInterval(4); h.engine.refreshNow()
        try h.wait { h.row("app:example.A")?.error != nil }
        checkTrue(h.sessions[0].stopped); checkFalse(h.row("app:example.A")!.controlled)
        h.engine.retry(id: "app:example.A")
        try h.wait { h.row("app:example.A")?.controlled == true }
        h.sessions.last!.fault = 1; h.engine.refreshNow()
        try h.wait { h.row("app:example.A")?.error?.contains("unsupported layout") == true }
        checkTrue(h.sessions.last!.stopped)
        h.engine.retry(id: "app:example.A")
        try h.wait { h.row("app:example.A")?.controlled == true }
        h.sessions.last!.fault = 2; h.engine.refreshNow()
        try h.wait { h.row("app:example.A")?.error?.contains("synchronization") == true }
        checkTrue(h.sessions.last!.stopped); checkFalse(h.row("app:example.A")!.controlled)
        let count = h.sessions.count
        for _ in 0..<12 {
            h.clock.addTimeInterval(60)
            try h.settle { h.engine.refreshNow() }
        }
        checkEqual(h.sessions.count, count) // No automatic interruption every ten seconds.
        h.engine.retry(id: "app:example.A")
        try h.wait { h.row("app:example.A")?.controlled == true }
        checkEqual(h.sessions.count, count + 1)
    }
    func testMutedRunningAppSurvivesAudioObjectRemoval() throws {
        let h = EngineHarness(); defer { try? h.stop() }
        try h.wait { !h.snapshots.isEmpty }
        h.engine.setLevel(id: "app:example.A", toggleMute: true)
        try h.wait { h.row("app:example.A")?.controlled == true }
        h.runningWithoutAudio.insert("app:example.A")
        h.apps.removeAll { $0.identity.key == "app:example.A" }
        h.clock.addTimeInterval(61); h.engine.refreshNow()
        try h.wait { h.row("app:example.A")?.controlled == false }
        checkTrue(h.row("app:example.A")!.running); checkTrue(h.row("app:example.A")!.level.muted)
        checkFalse(h.row("app:example.A")!.active); checkTrue(h.sessions[0].stopped)
        checkEqual(h.sessions.count, 1) // Never tap the removed/recycled audio object.
        h.runningWithoutAudio.removeAll(); h.engine.refreshNow()
        try h.wait { h.row("app:example.A") == nil }
    }
}
