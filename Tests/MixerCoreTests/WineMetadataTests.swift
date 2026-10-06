import Foundation
import AudioDSP

final class WineMetadataTests {
    private func data(arguments: [String], environment: [String]) -> Data {
        var count = Int32(arguments.count)
        var bytes = withUnsafeBytes(of: &count) { Data($0) }
        bytes.append(Data("/Applications/CrossOver.app/bin/wine64\0\0".utf8))
        for value in arguments + environment { bytes.append(Data((value + "\0").utf8)) }
        bytes.append(0)
        return bytes
    }
    private func text<T>(_ value: inout T) -> String {
        withUnsafeBytes(of: &value) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
    func testWineMetadataAndAmbiguousExecutables() {
        var info = VMProcessInfo()
        let normal = data(arguments: ["wine64", "C:\\Games\\Game.exe"], environment: ["CX_BOTTLE=Steam", "WINEPREFIX=/Bottles/Steam", "UNRELATED=not returned"])
        checkTrue(normal.withUnsafeBytes { VMExtractWineMetadata($0.baseAddress, $0.count, &info) })
        checkEqual(text(&info.wineExecutable), "C:\\Games\\Game.exe")
        checkEqual(text(&info.wineBottle), "/Bottles/Steam")
        let ambiguous = data(arguments: ["wine64", "launcher.exe", "game.exe"], environment: ["CX_BOTTLE=Steam"])
        checkTrue(ambiguous.withUnsafeBytes { VMExtractWineMetadata($0.baseAddress, $0.count, &info) })
        checkEqual(text(&info.wineExecutable), "")
        checkEqual(text(&info.wineBottle), "Steam")
        let truncated = normal.prefix(8)
        checkFalse(truncated.withUnsafeBytes { VMExtractWineMetadata($0.baseAddress, $0.count, &info) })
        checkEqual(text(&info.wineExecutable), ""); checkEqual(text(&info.wineBottle), "")
    }

    func testMalformedMetadataNeverReturnsPartialIdentity() {
        let valid = data(arguments: ["wine64", "C:\\Games\\Game.exe"],
                         environment: ["WINEPREFIX=/Bottles/Steam", "UNRELATED=private test value"])
        var info = VMProcessInfo()
        checkFalse(VMReadProcessInfo(0, nil))
        checkFalse(VMExtractWineMetadata(nil, 0, &info))
        checkFalse(valid.withUnsafeBytes { VMExtractWineMetadata($0.baseAddress, $0.count, nil) })
        // Exercise every truncation boundary, including argument and environment terminators.
        for length in 0...valid.count {
            checkTrue(valid.withUnsafeBytes { VMExtractWineMetadata($0.baseAddress, $0.count, &info) })
            let truncated = Data(valid.prefix(length))
            let accepted = truncated.withUnsafeBytes { VMExtractWineMetadata($0.baseAddress, $0.count, &info) }
            if accepted {
                checkEqual(text(&info.wineExecutable), "C:\\Games\\Game.exe")
                checkTrue(["", "/Bottles/Steam"].contains(text(&info.wineBottle)))
            } else {
                checkEqual(text(&info.wineExecutable), "")
                checkEqual(text(&info.wineBottle), "")
            }
        }
        for count: Int32 in [-1, 0, 65_537, Int32.max] {
            var count = count
            var invalid = valid
            invalid.replaceSubrange(0..<4, with: withUnsafeBytes(of: &count) { Data($0) })
            checkFalse(invalid.withUnsafeBytes { VMExtractWineMetadata($0.baseAddress, $0.count, &info) })
            checkEqual(text(&info.wineExecutable), ""); checkEqual(text(&info.wineBottle), "")
        }
        // Long identities must not be truncated into a different app's saved key.
        for invalid in [data(arguments: ["wine64", String(repeating: "x", count: 4096) + ".exe"], environment: []),
                        data(arguments: ["wine64", "game.exe"], environment: ["WINEPREFIX=" + String(repeating: "x", count: 4096)]),
                        data(arguments: ["wine64", "game.exe"], environment: ["CX_BOTTLE=" + String(repeating: "x", count: 4096)])] {
            checkFalse(invalid.withUnsafeBytes { VMExtractWineMetadata($0.baseAddress, $0.count, &info) })
            checkEqual(text(&info.wineExecutable), ""); checkEqual(text(&info.wineBottle), "")
        }
    }
}
