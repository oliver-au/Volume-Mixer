import Foundation
import MixerCore

final class UninstallTests {
    func testCleanupIsScopedAndDoesNotFollowSymlinks() throws {
        let home = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("work/cleanup-test-\(UUID().uuidString)")
        let fm = FileManager.default
        defer { try? fm.removeItem(at: home) }
        let unrelated = home.appendingPathComponent("Library/Application Support/AnotherApp/keep.txt")
        try fm.createDirectory(at: unrelated.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: unrelated)
        let urls = OwnedFiles.cleanupURLs(home: home)
        for url in urls.dropLast() {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            try Data("remove".utf8).write(to: url.appendingPathComponent("state.json"))
        }
        try fm.createDirectory(at: urls.last!.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: urls.last!, withDestinationURL: unrelated.deletingLastPathComponent())
        try OwnedFiles.removeCaches(home: home)
        checkTrue(fm.fileExists(atPath: unrelated.path))
        for url in urls { checkFalse(fm.fileExists(atPath: url.path)) }
        try OwnedFiles.removeCaches(home: home) // Idempotent cleanup.
    }
}
