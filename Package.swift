// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VolumeMixer",
    platforms: [.macOS("27.0")],
    products: [.executable(name: "VolumeMixer", targets: ["VolumeMixer"])],
    targets: [
        .target(name: "AudioDSP", publicHeadersPath: "include",
                linkerSettings: [.linkedFramework("CoreAudio")]),
        .target(name: "MixerCore", dependencies: ["AudioDSP"],
                linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("CoreAudio"), .linkedFramework("AVFAudio")]),
        .executableTarget(name: "VolumeMixer", dependencies: ["MixerCore"],
                          linkerSettings: [.linkedFramework("SwiftUI"), .linkedFramework("ServiceManagement")]),
        .executableTarget(name: "MixerChecks", dependencies: ["MixerCore", "AudioDSP"], path: "Tests/MixerCoreTests"),
        .executableTarget(name: "AudioFixture", path: "Tests/AudioFixture",
                            linkerSettings: [.linkedFramework("AVFAudio"), .linkedFramework("AppKit")])
    ],
    swiftLanguageModes: [.v5]
)
