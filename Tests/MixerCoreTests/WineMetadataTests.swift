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
}
