import Foundation

/// An explicit allowlist. Never searches the user's Library or follows a cleanup glob.
public enum OwnedFiles {
    public static func cleanupURLs(home: URL) -> [URL] {
        let library = home.appendingPathComponent("Library", isDirectory: true)
        return [
            library.appendingPathComponent("Caches/\(Preferences.bundleID)", isDirectory: true),
            library.appendingPathComponent("Application Support/\(Preferences.bundleID)", isDirectory: true),
            library.appendingPathComponent("Saved Application State/\(Preferences.bundleID).savedState", isDirectory: true)
        ]
    }
    public static func removeCaches(home: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        let manager = FileManager.default
        for url in cleanupURLs(home: home) {
            // removeItem removes a symlink itself, never its destination.
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey])) != nil || manager.fileExists(atPath: url.path) {
                try manager.removeItem(at: url)
            }
        }
    }
}
