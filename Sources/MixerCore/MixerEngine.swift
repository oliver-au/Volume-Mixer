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
    public var applications: () throws -> [AudioApplication] = ProcessCatalog.scan
    public var isRunning: (AudioApplication) -> Bool = ProcessCatalog.isRunning
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
    private var outputSignature: String?
    private var graphSignatures: [String: String] = [:]
    private var enabled: Bool
    private var paused: Bool
    private var sleeping = false
    private var stopped = false
    private var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var update: (@Sendable (MixerSnapshot) -> Void)?
    private var lastSnapshot: MixerSnapshot?

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
                    if selector == kAudioHardwarePropertyServiceRestarted { self.stopSessions(); self.outputSignature = nil }
                    self.refresh()
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
            levels[id] = level; preferences.save(level, for: app.identity)
            if let session = sessions[id] { session.setGain(level.gain) }
            retryAfter.removeValue(forKey: id)
            refresh()
        }
    }
    public func resetLevels() {
        queue.async { [self] in
            guard !stopped else { return }
            preferences.resetLevels(); levels.removeAll(); errors.removeAll(); retryAfter.removeAll()
            stopSessions(); refresh()
        }
    }
    public func setOutput(id: String, uid: String?) {
        queue.async { [self] in
            guard !stopped, let app = applications[id] else { return }
            var level = levels[id] ?? preferences.level(for: app.identity)
            // Resolve the user's selection against the most recently published inventory.
            // Never write the system's default device or an application's own preferences.
            let device = lastSnapshot?.outputs.first { $0.uid == uid }
            guard uid == nil || device != nil else { return }
            level.outputUID = uid; level.outputName = device?.name
            levels[id] = level; preferences.save(level, for: app.identity)
            retryAfter.removeValue(forKey: id); errors.removeValue(forKey: id)
            refresh()
        }
    }
    public func setSleeping(_ value: Bool) {
        queue.async { [self] in
            guard !stopped else { return }
            sleeping = value; stopSessions(); outputSignature = nil; retryAfter.removeAll()
            if !value { refresh() }
        }
    }
    private func stopSessions() {
        for session in sessions.values { session.stop() }
        sessions.removeAll(); callbackProgress.removeAll(); graphSignatures.removeAll()
    }
    /// Completion is delivered on the main queue after all audio resources are released.
    public func shutdown(completion: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            stopped = true; timer?.cancel(); timer = nil
            for (var address, block) in listeners { AudioObjectRemovePropertyListenerBlock(HAL.system, &address, queue, block) }
            listeners.removeAll(); stopSessions(); update = nil
            DispatchQueue.main.async(execute: completion)
        }
    }
    public func clearSettingsAfterShutdown() -> Bool { queue.sync { preferences.removeAll() } }

    private func refresh() {
        guard !stopped && !sleeping else { return }
        let now = environment.now()
        do {
            let output = try environment.output()
            var outputs = try environment.outputs()
            if !outputs.contains(where: { $0.uid == output.uid }) { outputs.append(output) }
            if output.signature != outputSignature {
                stopSessions(); outputSignature = output.signature
                retryAfter.removeAll(); errors.removeAll()
            }
            let current = try environment.applications()
            let running = Set(current.map { $0.identity.key })
            for app in current {
                applications[app.identity.key] = app
                if app.active { lastActive[app.identity.key] = now }
                if levels[app.identity.key] == nil { levels[app.identity.key] = preferences.level(for: app.identity) }
            }
            var rows: [MixerRow] = []
            for (id, app) in applications {
                let level = levels[id] ?? AppLevel()
                let hasAudioProcess = running.contains(id)
                let isRunning = hasAudioProcess || environment.isRunning(app)
                let active = hasAudioProcess && app.active
                guard RowVisibility.shouldShow(active: active, running: isRunning, muted: level.muted, lastActive: lastActive[id], now: now) else {
                    sessions.removeValue(forKey: id)?.stop(); errors.removeValue(forKey: id)
                    callbackProgress.removeValue(forKey: id); retryAfter.removeValue(forKey: id); continue
                }
                let destination: OutputDevice?
                if let uid = level.outputUID { destination = outputs.first { $0.uid == uid } }
                else { destination = output }
                // Leave untouched 100% apps on their original path. Only an explicit
                // destination or gain adjustment authorizes creating a playback graph.
                let needsRouting = level.outputUID != nil
                let needsSession = enabled && !paused && hasAudioProcess && (level.gain < 1 || needsRouting)
                let sources = app.outputDevices.sorted().map { source in
                    outputs.first { $0.id == source }?.signature ?? "missing:\(source)"
                }.joined(separator: "|")
                let signature = "\(app.sessionSignature)|\(sources)|\(destination?.signature ?? "disconnected")|\(level.outputUID ?? "system")"
                let graphChanged = graphSignatures[id] != signature
                if graphChanged {
                    graphSignatures[id] = signature
                    errors.removeValue(forKey: id); retryAfter.removeValue(forKey: id)
                }
                if let session = sessions[id], !needsSession || graphChanged {
                    session.stop(); sessions.removeValue(forKey: id)
                    callbackProgress.removeValue(forKey: id)
                }
                if let session = sessions[id] {
                    session.maintain(active: active)
                    let count = session.callbacks
                    let progress = callbackProgress[id] ?? (count: count, time: now)
                    let stalled = active && count == progress.count && now.timeIntervalSince(progress.time) >= 3
                    let invalidLayout = session.fault != 0
                    if invalidLayout || stalled {
                        let fault = session.fault
                        session.stop(); sessions.removeValue(forKey: id); callbackProgress.removeValue(forKey: id)
                        errors[id] = fault == 2 || fault == 3
                            ? "Playback to this output lost synchronization. Retry control or choose another output."
                            : fault == 1
                            ? "The audio stream changed to an unsupported layout. Original playback has been restored."
                            : "The audio output stopped responding. Original playback has been restored. Check audio permission or reconnect your output."
                        // Repeatedly restarting a broken route interrupts ordinary playback.
                        // Retry only after a user action or a real graph/device change.
                        retryAfter[id] = .distantFuture
                    } else if count != progress.count || !active {
                        callbackProgress[id] = (count, now)
                    }
                }
                if needsSession && destination == nil {
                    errors[id] = "\(level.outputName ?? "The selected output") is disconnected. Reconnect it or choose System output below."
                } else if needsSession, let destination, sessions[id] == nil && (retryAfter[id] ?? .distantPast) <= now {
                    publishConnecting(id: id, level: level)
                    do {
                        let session = try environment.makeSession(app, destination, level.gain)
                        sessions[id] = session; callbackProgress[id] = (session.callbacks, now)
                        errors.removeValue(forKey: id); retryAfter.removeValue(forKey: id)
                    } catch {
                        errors[id] = error.localizedDescription; retryAfter[id] = .distantFuture
                    }
                } else if !needsSession { errors.removeValue(forKey: id) }
                rows.append(MixerRow(id: id, identity: app.identity, level: level, active: active, running: isRunning,
                                     controlled: sessions[id] != nil, connecting: false, error: errors[id]))
            }
            let retained = Set(rows.map(\.id)).union(running)
            applications = applications.filter { retained.contains($0.key) }
            levels = levels.filter { retained.contains($0.key) }
            lastActive = lastActive.filter { retained.contains($0.key) }
            graphSignatures = graphSignatures.filter { retained.contains($0.key) }
            rows.sort { a, b in
                let order = a.identity.name.localizedStandardCompare(b.identity.name)
                return order == .orderedSame ? a.id < b.id : order == .orderedAscending
            }
            publish(MixerSnapshot(rows: rows, outputName: output.name, outputs: outputs, enabled: enabled, paused: paused, error: nil))
        } catch {
            stopSessions()
            publish(MixerSnapshot(rows: [], outputName: "No available output", outputs: [], enabled: enabled, paused: paused, error: error.localizedDescription))
        }
    }
    private func publish(_ snapshot: MixerSnapshot) {
        lastSnapshot = snapshot
        guard let update else { return }
        DispatchQueue.main.async { update(snapshot) }
    }
    private func publishConnecting(id: String, level: AppLevel) {
        guard let lastSnapshot else { return }
        let rows = lastSnapshot.rows.map { row in
            row.id == id ? MixerRow(id: row.id, identity: row.identity, level: level, active: row.active,
                running: row.running, controlled: false, connecting: true, error: nil) : row
        }
        publish(MixerSnapshot(rows: rows, outputName: lastSnapshot.outputName, outputs: lastSnapshot.outputs, enabled: enabled, paused: paused, error: nil))
    }
}
