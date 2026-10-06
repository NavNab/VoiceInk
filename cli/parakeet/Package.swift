// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "voiceink-cli",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", revision: "a53aff438bed437bc23490bf0f8d1b57fa3845c7"),
    ],
    targets: [
        .executableTarget(
            name: "voiceink-cli",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")]
        ),
    ]
)
