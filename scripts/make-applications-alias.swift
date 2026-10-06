import Foundation

// A Finder bookmark works on the UDF installer, whose driver does not reliably
// resolve the symlinks emitted by makehybrid on this macOS version.
let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let alias = URL(fileURLWithPath: CommandLine.arguments[2])
let bookmark = try destination.bookmarkData(options: .suitableForBookmarkFile,
    includingResourceValuesForKeys: nil, relativeTo: nil)
try URL.writeBookmarkData(bookmark, to: alias)
