import Foundation
import MixerCore

final class IdentityTests {
    func testRetainedIdleProcessRequiresOriginalObjectAndLifetime() {
        let identity = IdentityResolver.resolve(.init(pid: 10, bundleID: "example.player"))
        let app = AudioApplication(identity: identity, processObjects: [7], pids: [10], active: false,
            outputDevices: [1], lifetimes: [.init(pid: 10, startTime: 123)])
        checkTrue(app.owns(object: 7, pid: 10, startTime: 123))
        checkFalse(app.owns(object: 7, pid: 10, startTime: 124))
        checkFalse(app.owns(object: 8, pid: 10, startTime: 123))
        checkFalse(app.owns(object: 7, pid: 11, startTime: 123))
        checkFalse(app.owns(object: 7, pid: 10, startTime: 0))
    }
    func testBrowserHelperUsesOuterApplication() {
        checkEqual(IdentityResolver.outerAppPath("/Applications/Google Chrome.app/Contents/Frameworks/Helpers/Helper.app/Contents/MacOS/Helper"), "/Applications/Google Chrome.app")
    }
    func testUnknownWineProcessesDoNotCollideOrPersist() {
        let first = IdentityResolver.resolve(.init(pid: 100, startTime: 1, executable: "/Applications/CrossOver.app/bin/wine"))
        let reused = IdentityResolver.resolve(.init(pid: 100, startTime: 2, executable: "/Applications/CrossOver.app/bin/wine"))
        checkNotEqual(first.key, reused.key)
        checkNil(first.persistentKey)
        checkTrue(first.name.contains("100"))
        let hiddenMetadata = IdentityResolver.resolve(.init(pid: 200, bundleID: "com.codeweavers.CrossOverHelper"))
        checkTrue(hiddenMetadata.isWine); checkNil(hiddenMetadata.persistentKey)
        checkEqual(hiddenMetadata.name, "CrossOver audio process 200")
    }
    func testSameGameDifferentBottlesStaysSeparate() {
        let first = IdentityResolver.resolve(.init(pid: 1, wineExecutable: "C:\\Games\\Game.exe", wineBottle: "/Bottles/One"))
        let second = IdentityResolver.resolve(.init(pid: 2, wineExecutable: "C:\\Games\\Game.exe", wineBottle: "/Bottles/Two"))
        checkNotEqual(first.persistentKey, second.persistentKey)
        checkEqual(first.name, "Game")
    }
    func testGameIdentitySurvivesRelaunch() {
        let first = IdentityResolver.resolve(.init(pid: 1, wineExecutable: "C:\\Games\\Game.exe", wineBottle: "Steam"))
        let second = IdentityResolver.resolve(.init(pid: 9, wineExecutable: "C:\\Games\\Game.exe", wineBottle: "Steam"))
        checkEqual(first.persistentKey, second.persistentKey)
    }
    func testSharedWebKitHelpersStaySeparateWithoutOwner() {
        let a = IdentityResolver.resolve(.init(pid: 1, startTime: 10, bundleID: "com.apple.WebKit.GPU"))
        let b = IdentityResolver.resolve(.init(pid: 2, startTime: 20, bundleID: "com.apple.WebKit.GPU"))
        checkNotEqual(a.key, b.key); checkNil(a.persistentKey)
        let owned = IdentityResolver.resolve(.init(pid: 2, startTime: 20, bundleID: "com.apple.Safari"))
        checkEqual(owned.persistentKey, "app:com.apple.Safari")
    }
    func testProcessLifetimeRejectsRecycledAndUnknownPIDs() {
        let lifetime = ProcessLifetime(pid: 10, startTime: 123)
        checkTrue(lifetime.matches(startTime: 123)); checkFalse(lifetime.matches(startTime: 124))
        checkFalse(lifetime.matches(startTime: 0))
        checkFalse(ProcessLifetime(pid: 10, startTime: 0).matches(startTime: 0))
    }
}
