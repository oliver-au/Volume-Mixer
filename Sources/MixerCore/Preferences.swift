import Foundation

public protocol PreferencesBacking: AnyObject {
    func data(forKey: String) -> Data?
    func bool(forKey: String) -> Bool
    func set(_ value: Any?, forKey: String)
    func removeObject(forKey: String)
    func removePersistentDomain(forName: String)
    func persistentDomain(forName: String) -> [String: Any]?
    @discardableResult func synchronize() -> Bool
}
extension UserDefaults: PreferencesBacking {}

public struct AppLevel: Codable, Equatable, Sendable {
    public var volume: Float
    public var muted: Bool
    /// nil follows the system output. Device UIDs survive reconnects; object IDs do not.
    public var outputUID: String?
    public var outputName: String?
    public init(volume: Float = 1, muted: Bool = false, outputUID: String? = nil, outputName: String? = nil) {
        self.volume = volume.isFinite ? min(1, max(0, volume)) : 1
        self.muted = muted
        self.outputUID = outputUID?.isEmpty == false ? outputUID : nil
        self.outputName = self.outputUID == nil ? nil : outputName
    }
    public var gain: Float { muted ? 0 : volume }
    public mutating func moveSlider(to value: Float) {
        volume = value.isFinite ? min(1, max(0, value)) : 1
        if volume > 0 { muted = false }
    }
}

public final class Preferences {
    public static let bundleID = "local.oliver.VolumeMixer"
    private let defaults: any PreferencesBacking
    private let domain: String
    private var writable = true
    private var saved: [String: AppLevel]
    public init(domain: String = Preferences.bundleID, backing: (any PreferencesBacking)? = nil) {
        self.domain = domain
        // Foundation reserves the running app's own domain for `standard`.
        // A separate suite is used only by isolated tests and diagnostic hosts.
        defaults = backing ?? (domain == Bundle.main.bundleIdentifier ? UserDefaults.standard : (UserDefaults(suiteName: domain) ?? UserDefaults.standard))
        if let data = defaults.data(forKey: "levels.v1"), let levels = try? JSONDecoder().decode([String: AppLevel].self, from: data) {
            saved = levels.mapValues { AppLevel(volume: $0.volume, muted: $0.muted, outputUID: $0.outputUID, outputName: $0.outputName) }
        } else { saved = [:] }
    }
    public var hasEnabledControl: Bool {
        get { defaults.bool(forKey: "hasEnabledControl") }
        set { if writable { defaults.set(newValue, forKey: "hasEnabledControl") } }
    }
    public var paused: Bool {
        get { defaults.bool(forKey: "paused") }
        set { if writable { defaults.set(newValue, forKey: "paused") } }
    }
    public func level(for identity: AppIdentity) -> AppLevel { identity.persistentKey.flatMap { saved[$0] } ?? AppLevel() }
    public func save(_ value: AppLevel, for identity: AppIdentity) {
        guard writable, let key = identity.persistentKey else { return }
        saved[key] = value
        if let data = try? JSONEncoder().encode(saved) { defaults.set(data, forKey: "levels.v1") }
    }
    public func resetLevels() { guard writable else { return }; saved.removeAll(); defaults.removeObject(forKey: "levels.v1") }
    @discardableResult public func removeAll() -> Bool {
        writable = false; saved.removeAll()
        defaults.removePersistentDomain(forName: domain)
        return defaults.synchronize() && (defaults.persistentDomain(forName: domain)?.isEmpty ?? true)
    }
}

public enum RowVisibility {
    public static func shouldShow(active: Bool, running: Bool, muted: Bool, lastActive: Date?, now: Date) -> Bool {
        active || (running && muted) || lastActive.map { now.timeIntervalSince($0) < 60 } == true
    }
}
