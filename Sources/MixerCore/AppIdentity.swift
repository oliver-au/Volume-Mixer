import Foundation
import AppKit
import CoreAudio
import AudioDSP

public struct AppIdentity: Equatable, Sendable {
    public let key: String
    public let persistentKey: String?
    public let name: String
    public let detail: String?
    public let iconPath: String?
    public let isWine: Bool
}

public struct ProcessIdentityInput: Sendable {
    public var pid: Int32
    public var startTime: UInt64
    public var executable: String
    public var processName: String
    public var bundleID: String
    public var appName: String?
    public var appPath: String?
    public var wineExecutable: String
    public var wineBottle: String
    public init(pid: Int32, startTime: UInt64 = 0, executable: String = "", processName: String = "",
                bundleID: String = "", appName: String? = nil, appPath: String? = nil,
                wineExecutable: String = "", wineBottle: String = "") {
        self.pid = pid; self.startTime = startTime; self.executable = executable; self.processName = processName
        self.bundleID = bundleID; self.appName = appName; self.appPath = appPath
        self.wineExecutable = wineExecutable; self.wineBottle = wineBottle
    }
}

public enum IdentityResolver {
    public static func isSharedHelperBundle(_ bundleID: String) -> Bool {
        bundleID == "com.apple.WebKit" || bundleID.hasPrefix("com.apple.WebKit.")
    }
    public static func resolve(_ input: ProcessIdentityInput) -> AppIdentity {
        let lower = input.executable.lowercased()
        let wine = lower.contains("crossover") || lower.contains("/wine") || lower.hasSuffix(".exe") ||
            !input.wineExecutable.isEmpty || input.bundleID.lowercased().hasPrefix("com.codeweavers.crossover")
        if wine {
            let executable = input.wineExecutable.isEmpty && lower.hasSuffix(".exe") ? input.executable : input.wineExecutable
            let normal = executable.replacingOccurrences(of: "\\", with: "/")
            let game = URL(fileURLWithPath: normal).deletingPathExtension().lastPathComponent
            let hasStableGame = !executable.isEmpty && !input.wineBottle.isEmpty
            let persistent = hasStableGame ? "wine:\(input.wineBottle):\(normal.lowercased())" : nil
            return AppIdentity(key: persistent ?? "process:\(input.pid):\(input.startTime)", persistentKey: persistent,
                name: !executable.isEmpty && !game.isEmpty ? game : "CrossOver audio process \(input.pid)",
                detail: input.wineBottle.isEmpty ? "CrossOver · process \(input.pid)" : "CrossOver · \(URL(fileURLWithPath: input.wineBottle).lastPathComponent)",
                iconPath: input.appPath ?? "/Applications/CrossOver.app", isWine: true)
        }
        // A shared WebKit bundle is not evidence of which browser owns a process.
        let stable = input.bundleID.isEmpty || isSharedHelperBundle(input.bundleID) ? nil : "app:\(input.bundleID)"
        return AppIdentity(key: stable ?? "process:\(input.pid):\(input.startTime)", persistentKey: stable,
            name: input.appName ?? (input.processName.isEmpty ? "Audio process \(input.pid)" : input.processName),
            detail: stable == nil ? "Process \(input.pid) · session only" : nil, iconPath: input.appPath, isWine: false)
    }
    public static func outerAppPath(_ executable: String) -> String? {
        let parts = (executable as NSString).pathComponents
        guard let end = parts.firstIndex(where: { $0.hasSuffix(".app") }) else { return nil }
        return NSString.path(withComponents: Array(parts[...end]))
    }
}

public struct ProcessLifetime: Sendable, Equatable {
    public let pid: Int32
    public let startTime: UInt64
    public init(pid: Int32, startTime: UInt64) { self.pid = pid; self.startTime = startTime }
    public func matches(startTime current: UInt64) -> Bool { startTime != 0 && current == startTime }
}

public struct AudioApplication: Sendable {
    public let identity: AppIdentity
    public var processObjects: [AudioObjectID]
    public var pids: [Int32]
    public var active: Bool
    public var outputDevices: Set<AudioObjectID>
    public var lifetimes: [ProcessLifetime]
    public init(identity: AppIdentity, processObjects: [AudioObjectID], pids: [Int32], active: Bool,
                outputDevices: Set<AudioObjectID>, lifetimes: [ProcessLifetime] = []) {
        self.identity = identity; self.processObjects = processObjects; self.pids = pids
        self.active = active; self.outputDevices = outputDevices
        self.lifetimes = lifetimes
    }
    public var sessionSignature: String {
        processObjects.sorted().map(String.init).joined(separator: ",") + ":" +
            lifetimes.map { "\($0.pid):\($0.startTime)" }.sorted().joined(separator: ",")
    }
}

public enum ProcessCatalog {
    private static func text<T>(_ field: inout T) -> String {
        withUnsafePointer(to: &field) { $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) { String(cString: $0) } }
    }
    private static func identity(pid: pid_t, bundleID: String, lifetime: inout ProcessLifetime?) -> AppIdentity {
        var raw = VMProcessInfo()
        if VMReadProcessInfo(pid, &raw), raw.startTime != 0 {
            lifetime = ProcessLifetime(pid: pid, startTime: raw.startTime)
        }
        let executable = text(&raw.executable)
        var appPath = IdentityResolver.outerAppPath(executable)
        var app = appPath.flatMap { Bundle(path: $0) }
        var bundle = app?.bundleIdentifier ?? bundleID
        // WebKit helper processes are sometimes outside their owner's application bundle.
        if IdentityResolver.isSharedHelperBundle(bundle) || (app == nil && bundleID.isEmpty) {
            var parent = raw.parent, visited: Set<pid_t> = [pid]
            for _ in 0..<8 {
                guard parent > 1, visited.insert(parent).inserted else { break }
                if let running = NSRunningApplication(processIdentifier: parent), let url = running.bundleURL,
                   running.bundleIdentifier != Bundle.main.bundleIdentifier,
                   !IdentityResolver.isSharedHelperBundle(running.bundleIdentifier ?? "") {
                    appPath = IdentityResolver.outerAppPath(url.path) ?? url.path
                    app = appPath.flatMap { Bundle(path: $0) }
                    bundle = app?.bundleIdentifier ?? running.bundleIdentifier ?? bundle
                    break
                }
                var ancestor = VMProcessInfo()
                guard VMReadProcessInfo(parent, &ancestor) else { break }
                parent = ancestor.parent
            }
        }
        let displayName = app?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? app?.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? NSRunningApplication(processIdentifier: pid)?.localizedName
        return IdentityResolver.resolve(ProcessIdentityInput(pid: pid, startTime: raw.startTime,
            executable: executable, processName: text(&raw.name), bundleID: bundle, appName: displayName,
            appPath: appPath, wineExecutable: text(&raw.wineExecutable), wineBottle: text(&raw.wineBottle)))
    }
    public static func isRunning(_ app: AudioApplication) -> Bool {
        if !app.identity.isWine, let key = app.identity.persistentKey, key.hasPrefix("app:") {
            let bundleID = String(key.dropFirst(4))
            if NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains(where: { !$0.isTerminated }) { return true }
        }
        return app.lifetimes.contains { $0.matches(startTime: VMProcessStartTime($0.pid)) }
    }
    public static func scan() throws -> [AudioApplication] {
        let objects = try HAL.objects(HAL.system, kAudioHardwarePropertyProcessObjectList)
        var apps: [String: AudioApplication] = [:]
        for object in objects {
            guard let rawPID = try? HAL.scalar(object, kAudioProcessPropertyPID) else { continue }
            let pid = pid_t(bitPattern: rawPID)
            guard pid > 0 && pid != ProcessInfo.processInfo.processIdentifier else { continue }
            let active = (try? HAL.scalar(object, kAudioProcessPropertyIsRunningOutput)) == 1
            let devices = (try? HAL.objects(object, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeOutput)) ?? []
            // Input-only processes never belong in a playback mixer.
            guard active || !devices.isEmpty else { continue }
            let bundle = (try? HAL.string(object, kAudioProcessPropertyBundleID)) ?? ""
            guard bundle != Preferences.bundleID else { continue }
            var lifetime: ProcessLifetime?
            let identity = identity(pid: pid, bundleID: bundle, lifetime: &lifetime)
            if var existing = apps[identity.key] {
                existing.processObjects.append(object); existing.pids.append(pid)
                if let lifetime { existing.lifetimes.append(lifetime) }
                existing.active = existing.active || active; existing.outputDevices.formUnion(devices)
                apps[identity.key] = existing
            } else {
                apps[identity.key] = AudioApplication(identity: identity, processObjects: [object], pids: [pid],
                                                      active: active, outputDevices: Set(devices), lifetimes: lifetime.map { [$0] } ?? [])
            }
        }
        return apps.values.sorted { $0.identity.name.localizedStandardCompare($1.identity.name) == .orderedAscending }
    }
}
