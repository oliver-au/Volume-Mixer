import Foundation
import CoreAudio

public struct MixerRow: Identifiable, Sendable {
    public let id: String
    public let identity: AppIdentity
    public let level: AppLevel
    public let active: Bool
    public let running: Bool
    public let controlled: Bool
    public let connecting: Bool
    public let error: String?
}

public struct MixerSnapshot: Sendable {
    public var outputSymbol: String = "speaker.wave.2"
    public let rows: [MixerRow]
    public let outputName: String
    public let outputs: [OutputDevice]
    public let enabled: Bool
    public let paused: Bool
    public let error: String?
}

/// Production uses HAL; tests supply an isolated clock, catalog, and graph factory.
public struct MixerEnvironment {
    public var output: () throws -> OutputDevice = HAL.defaultOutput
    public var outputs: () throws -> [OutputDevice] = HAL.availableOutputs
    public var applications: ([AudioApplication]) throws -> [AudioApplication] = { try ProcessCatalog.scan(keeping: $0) }
    public var isRunning: (AudioApplication) -> Bool = ProcessCatalog.isRunning
    public var sessionIsUsable: (AudioApplication, OutputDevice) -> Bool = HAL.sessionIsUsable
    public var makeSession: (AudioApplication, OutputDevice, Float) throws -> any AppAudioSession = {
        try AudioSession(app: $0, output: $1, gain: $2)
    }
    public var now: () -> Date = Date.init
    public var observesHardware = true
    public var pollsAutomatically = true
    public init() {}
}

public final class MixerEngine: @unchecked Sendable {
    private let queue = DispatchQueue(label: "local.oliver.VolumeMixer.audio-control", qos: .userInitiated)
    private let preferences: Preferences
    private let environment: MixerEnvironment
    private var timer: DispatchSourceTimer?
    private var sessions: [String: any AppAudioSession] = [:]
    private var callbackProgress: [String: (count: UInt64, time: Date)] = [:]
    private var applications: [String: AudioApplication] = [:]
    private var levels: [String: AppLevel] = [:]
    private var lastActive: [String: Date] = [:]
    private var errors: [String: String] = [:]
    private var retryAfter: [String: Date] = [:]
    private var graphSignatures: [String: String] = [:]
    private var sessionOutputs: [String: OutputDevice] = [:]
    private var catalogIDs: Set<String> = []
    private var runningIDs: Set<String> = []
    private var editingIDs: Set<String> = []
    private var unityRelease: [String: Date] = [:]
    private var output: OutputDevice?
    private var outputs: [OutputDevice] = []
    private var discoveryError: String?
    private var discoveryFailures = 0
    private var failureBegan: Date?
    private var saveRequest: DispatchWorkItem?
    private var refreshRequest: DispatchWorkItem?
    private var processListeners: [AudioObjectID: () -> Void] = [:]
    private var enabled: Bool
    private var paused: Bool
    private var sleeping = false
    private var stopped = false
    private var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var update: (@Sendable (MixerSnapshot) -> Void)?

    public init(preferences: Preferences = Preferences(), environment: MixerEnvironment = MixerEnvironment()) {
        self.preferences = preferences
        self.environment = environment
        enabled = preferences.hasEnabledControl; paused = preferences.paused
    }
    public func start(update: @escaping @Sendable (MixerSnapshot) -> Void) {
        queue.async { [self] in
            guard self.update == nil && !stopped else { return }
            self.update = update
            let selectors = environment.observesHardware ? [kAudioHardwarePropertyProcessObjectList, kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDevices, kAudioHardwarePropertyServiceRestarted] : []
            for selector in selectors {
                var address = HAL.address(selector)
                let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                    guard let self, !self.stopped else { return }
                    if selector == kAudioHardwarePropertyServiceRestarted {
                        self.stopSessions(); self.removeProcessListeners()
                    }
                    self.scheduleRefresh()
                }
                if AudioObjectAddPropertyListenerBlock(HAL.system, &address, queue, block) == noErr { listeners.append((address, block)) }
            }
            if environment.pollsAutomatically {
                let source = DispatchSource.makeTimerSource(queue: queue)
                source.schedule(deadline: .now(), repeating: 1)
                source.setEventHandler { [weak self] in self?.refresh() }
                timer = source; source.resume()
            } else { refresh() }
        }
    }
    public func refreshNow() { queue.async { [self] in refresh() } }
    public func retry(id: String) {
        queue.async { [self] in
            guard !stopped else { return }
            retryAfter.removeValue(forKey: id); errors.removeValue(forKey: id); refresh()
        }
    }
    public func enableControl() {
        queue.async { [self] in
            guard !stopped else { return }
            enabled = true; paused = false
            preferences.hasEnabledControl = true; preferences.paused = false
            retryAfter.removeAll(); errors.removeAll()
            refresh()
        }
    }
    public func setPaused(_ value: Bool) {
        queue.async { [self] in
            guard !stopped else { return }
            paused = value; preferences.paused = value
            flushPreferences(); editingIDs.removeAll()
            if value { stopSessions() } else { retryAfter.removeAll(); errors.removeAll() }
            refresh()
        }
    }
    public func setLevel(id: String, volume: Float? = nil, toggleMute: Bool = false) {
        queue.async { [self] in
            guard !stopped, let app = applications[id] else { return }
            var level = levels[id] ?? preferences.level(for: app.identity)
            if let volume { level.moveSlider(to: volume) }
            if toggleMute { level.muted.toggle() }
            levels[id] = level; preferences.save(level, for: app.identity, persist: false)
            if toggleMute { flushPreferences() } else { scheduleSave() }
            if let session = sessions[id] {
                session.setGain(level.gain)
                if level.gain == 1 && level.outputUID == nil { unityRelease[id] = environment.now().addingTimeInterval(1) }
                else { unityRelease.removeValue(forKey: id) }
                publishState()
            } else if enabled && !paused && (level.gain < 1 || level.outputUID != nil) {
                retryAfter.removeValue(forKey: id)
                refresh() // A new graph needs a fresh process/device identity.
            } else {
                errors.removeValue(forKey: id); publishState()
            }
        }
    }
    public func setEditing(id: String, editing: Bool) {
        queue.async { [self] in
            guard !stopped else { return }
            if editing { editingIDs.insert(id); saveRequest?.cancel(); saveRequest = nil }
            else {
                editingIDs.remove(id); flushPreferences()
                if unityRelease[id] != nil { unityRelease[id] = environment.now().addingTimeInterval(1) }
            }
        }
    }
    private func scheduleSave() {
        saveRequest?.cancel(); saveRequest = nil
        guard editingIDs.isEmpty else { return }
        let request = DispatchWorkItem { [weak self] in self?.flushPreferences() }
        saveRequest = request; queue.asyncAfter(deadline: .now() + 0.35, execute: request)
    }
    private func flushPreferences() {
        saveRequest?.cancel(); saveRequest = nil; preferences.flush()
    }
    public func resetLevels() {
        queue.async { [self] in
            guard !stopped else { return }
            preferences.resetLevels(); levels.removeAll(); errors.removeAll(); retryAfter.removeAll()
            saveRequest?.cancel(); saveRequest = nil; editingIDs.removeAll()
            stopSessions(); refresh()
        }
    }
    public func setOutput(id: String, uid: String?) {
        queue.async { [self] in
            guard !stopped, let app = applications[id] else { return }
            var level = levels[id] ?? preferences.level(for: app.identity)
            // Resolve the user's selection against the most recently published inventory.
            // Never write the system's default device or an application's own preferences.
            let device = outputs.first { $0.uid == uid }
            guard uid == nil || device != nil else {
                errors[id] = "That output is no longer available. Choose a connected output or System output."
                stopSession(id); retryAfter[id] = .distantFuture; publishState(); return
            }
            if uid != level.outputUID { stopSession(id) }
            level.outputUID = uid; level.outputName = device?.name
            levels[id] = level; preferences.save(level, for: app.identity)
            retryAfter.removeValue(forKey: id); errors.removeValue(forKey: id)
            refresh()
        }
    }
    public func setSleeping(_ value: Bool) {
        queue.async { [self] in
            guard !stopped else { return }
            flushPreferences(); editingIDs.removeAll()
            sleeping = value; stopSessions(); retryAfter.removeAll()
            if !value { refresh() }
        }
    }
    private func stopSessions() {
        for session in sessions.values { session.stop() }
        sessions.removeAll(); callbackProgress.removeAll(); graphSignatures.removeAll()
        sessionOutputs.removeAll(); unityRelease.removeAll()
    }
    private func stopSession(_ id: String) {
        sessions.removeValue(forKey: id)?.stop()
        callbackProgress.removeValue(forKey: id); sessionOutputs.removeValue(forKey: id)
        unityRelease.removeValue(forKey: id)
    }
    private func scheduleRefresh() {
        guard !stopped, refreshRequest == nil else { return }
        let request = DispatchWorkItem { [weak self] in
            self?.refreshRequest = nil; self?.refresh()
        }
        refreshRequest = request; queue.asyncAfter(deadline: .now() + 0.02, execute: request)
    }
    private func removeProcessListeners() {
        for cancel in processListeners.values { cancel() }
        processListeners.removeAll()
    }
    private func observeProcesses(_ current: [AudioApplication]) {
        guard environment.observesHardware else { return }
        let objects = Set(current.flatMap(\.processObjects))
        for object in Array(processListeners.keys) where !objects.contains(object) {
            processListeners.removeValue(forKey: object)?()
        }
        for object in objects where processListeners[object] == nil {
            processListeners[object] = HAL.observePlayback(object, queue: queue) { [weak self] in self?.scheduleRefresh() }
        }
    }
    /// Completion is delivered on the main queue after all audio resources are released.
    public func shutdown(completion: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            flushPreferences()
            stopped = true; timer?.cancel(); timer = nil
            for (var address, block) in listeners { AudioObjectRemovePropertyListenerBlock(HAL.system, &address, queue, block) }
            listeners.removeAll(); removeProcessListeners(); stopSessions(); update = nil
            refreshRequest?.cancel(); refreshRequest = nil
            DispatchQueue.main.async(execute: completion)
        }
    }
    public func clearSettingsAfterShutdown() -> Bool { queue.sync { preferences.removeAll() } }

    private func refresh() {
        guard !stopped && !sleeping else { return }
        let now = environment.now()
        do {
            let discoveredOutput = try environment.output()
            var discoveredOutputs = try environment.outputs()
            if !discoveredOutputs.contains(where: { $0.uid == discoveredOutput.uid }) { discoveredOutputs.append(discoveredOutput) }
            let current = try environment.applications(Array(applications.values))
            // Commit the inventory only after discovery succeeds as a whole.
            output = discoveredOutput; outputs = discoveredOutputs
            discoveryError = nil; discoveryFailures = 0; failureBegan = nil
            catalogIDs = Set(current.map { $0.identity.key })
            for app in current {
                applications[app.identity.key] = app
                if app.active { lastActive[app.identity.key] = now }
                if levels[app.identity.key] == nil { levels[app.identity.key] = preferences.level(for: app.identity) }
            }
            runningIDs = Set(applications.compactMap { id, app in
                catalogIDs.contains(id) || environment.isRunning(app) ? id : nil
            })
            observeProcesses(current)
            for (id, app) in applications {
                let level = levels[id] ?? AppLevel()
                let hasAudioProcess = catalogIDs.contains(id)
                let active = hasAudioProcess && app.active
                let destination = level.outputUID.flatMap { uid in outputs.first { $0.uid == uid } }
                    ?? (level.outputUID == nil ? output : nil)
                // Visibility is independent of control. An idle but valid process
                // keeps its attenuation and route when its row disappears.
                let holdUnity = sessions[id] != nil &&
                    (editingIDs.contains(id) || (unityRelease[id] ?? .distantPast) > now)
                let needsSession = enabled && !paused && hasAudioProcess &&
                    (level.gain < 1 || level.outputUID != nil || holdUnity)
                let sources = app.outputDevices.sorted().map { source in
                    outputs.first { $0.id == source }?.signature ?? "missing:\(source)"
                }.joined(separator: "|")
                let signature = "\(app.sessionSignature)|\(sources)|\(destination?.signature ?? "disconnected")|\(level.outputUID ?? "system")"
                let graphChanged = graphSignatures[id] != signature
                if graphChanged {
                    graphSignatures[id] = signature
                    errors.removeValue(forKey: id); retryAfter.removeValue(forKey: id)
                }
                if !needsSession || graphChanged { stopSession(id) }
                checkHealth(id: id, active: active, now: now)
                if needsSession && destination == nil {
                    errors[id] = "\(level.outputName ?? "The selected output") is disconnected. Reconnect it or choose System output below."
                } else if needsSession, let destination, sessions[id] == nil && (retryAfter[id] ?? .distantPast) <= now {
                    // Include new rows before potentially slow graph creation.
                    publishState(connectingID: id)
                    do {
                        let session = try environment.makeSession(app, destination, level.gain)
                        sessions[id] = session; sessionOutputs[id] = destination
                        callbackProgress[id] = (session.callbacks, now)
                        errors.removeValue(forKey: id); retryAfter.removeValue(forKey: id)
                    } catch {
                        errors[id] = error.localizedDescription; retryAfter[id] = .distantFuture
                    }
                } else if !needsSession {
                    errors.removeValue(forKey: id); retryAfter.removeValue(forKey: id)
                }
            }
            let retained = Set(applications.keys.filter { shouldShow($0, now: now) }).union(catalogIDs)
            applications = applications.filter { retained.contains($0.key) }
            levels = levels.filter { retained.contains($0.key) }
            lastActive = lastActive.filter { retained.contains($0.key) }
            graphSignatures = graphSignatures.filter { retained.contains($0.key) }
            errors = errors.filter { retained.contains($0.key) }
            retryAfter = retryAfter.filter { retained.contains($0.key) }
            editingIDs.formIntersection(retained)
            publishState()
        } catch {
            handleDiscoveryFailure(error, now: now)
        }
    }
    private func checkHealth(id: String, active: Bool, now: Date) {
        guard let session = sessions[id] else { return }
        session.maintain(active: active)
        let count = session.callbacks
        let progress = callbackProgress[id] ?? (count: count, time: now)
        let stalled = active && count == progress.count && now.timeIntervalSince(progress.time) >= 3
        let fault = session.fault
        if fault != 0 || stalled {
            stopSession(id)
            errors[id] = fault == 2 || fault == 3
                ? "Playback to this output lost synchronization. Retry control or choose another output."
                : fault == 1
                ? "The audio stream changed to an unsupported layout. Original playback has been restored."
                : "The audio output stopped responding. Original playback has been restored. Check audio permission or reconnect your output."
            retryAfter[id] = .distantFuture
        } else if count != progress.count || !active { callbackProgress[id] = (count, now) }
    }
    private func handleDiscoveryFailure(_ error: Error, now: Date) {
        discoveryFailures += 1
        if failureBegan == nil { failureBegan = now }
        let brief = (error as? AudioFailure)?.isTransientDiscovery == true && output != nil &&
            discoveryFailures < 3 && now.timeIntervalSince(failureBegan!) < 2
        if brief {
            // A bounded grace period is only for healthy, still-identifiable graphs.
            // No new graph is ever made from this stale inventory.
            for id in Array(sessions.keys) {
                guard let app = applications[id], let destination = sessionOutputs[id],
                      environment.sessionIsUsable(app, destination) else {
                    stopSession(id); errors[id] = "The audio route became unavailable. Original playback is restored."
                    retryAfter[id] = .distantFuture
                    continue
                }
                checkHealth(id: id, active: app.active, now: now)
            }
            discoveryError = "Refreshing audio devices. \(error.localizedDescription)"
        } else {
            stopSessions()
            for (id, level) in levels where level.gain < 1 || level.outputUID != nil {
                errors[id] = "Audio discovery failed. Original playback is restored. \(error.localizedDescription)"
            }
            discoveryError = error.localizedDescription
        }
        for (id, level) in levels where sessions[id] == nil && errors[id] == nil &&
            (level.gain < 1 || level.outputUID != nil) {
            errors[id] = "Audio discovery is unavailable. Original playback is restored. Retry control when the output is ready."
        }
        publishState()
    }
    private func shouldShow(_ id: String, now: Date) -> Bool {
        guard let app = applications[id] else { return false }
        return RowVisibility.shouldShow(active: catalogIDs.contains(id) && app.active,
            running: runningIDs.contains(id), muted: levels[id]?.muted == true, lastActive: lastActive[id], now: now)
    }
    private func publishState(connectingID: String? = nil) {
        let now = environment.now()
        var rows: [MixerRow] = applications.compactMap { id, app in
            guard shouldShow(id, now: now) || id == connectingID else { return nil }
            return MixerRow(id: id, identity: app.identity, level: levels[id] ?? AppLevel(),
                active: catalogIDs.contains(id) && app.active, running: runningIDs.contains(id),
                controlled: sessions[id] != nil, connecting: id == connectingID,
                error: id == connectingID ? nil : errors[id])
        }
        rows.sort { a, b in
            let order = a.identity.name.localizedStandardCompare(b.identity.name)
            return order == .orderedSame ? a.id < b.id : order == .orderedAscending
        }
        var snapshot = MixerSnapshot(rows: rows, outputName: output?.name ?? "No available output",
            outputs: outputs, enabled: enabled, paused: paused, error: discoveryError)
        snapshot.outputSymbol = output?.symbolName ?? "speaker.wave.2"
        guard let update else { return }
        let published = snapshot
        DispatchQueue.main.async { update(published) }
    }
}
