// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Offload",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "OffloadApp", targets: ["OffloadApp"]),
        .library(name: "OffloadCore", targets: ["OffloadCore"]),
        .library(name: "OffloadEngine", targets: ["OffloadEngine"]),
    ],
    targets: [
        .target(name: "OffloadCore"),
        .target(name: "OffloadEngine", dependencies: ["OffloadCore"]),
        .executableTarget(
            name: "OffloadApp",
            dependencies: ["OffloadCore", "OffloadEngine"],
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "OffloadTests",
            dependencies: ["OffloadCore", "OffloadEngine"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
