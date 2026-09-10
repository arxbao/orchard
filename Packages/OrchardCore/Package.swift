// swift-tools-version: 6.0
import PackageDescription

// OrchardCore — the shared backend for the orchard macOS app and the
// orchard-cli executable. GUI and CLI talk to container-apiserver over XPC
// through this package ONLY; the `container` CLI binary is never invoked
// (see spec §1 "通信架构").
let package = Package(
    name: "OrchardCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "OrchardCore", targets: ["OrchardCore"]),
        .executable(name: "orchard-cli", targets: ["orchard-cli"]),
    ],
    dependencies: [
        // Pinned to the exact release matching the installed container-apiserver.
        // Client and daemon ship in lockstep; do not use `from:` here (spec §5).
        // 1.3.1 is a security patch (six advisories in containerization; the one
        // reaching this process is CVE-2026-65388: RegistryClient followed an
        // unvalidated WWW-Authenticate realm and leaked the registry password).
        // Both pins move together — container 1.3.1 requires containerization 0.42.0.
        .package(url: "https://github.com/apple/container.git", exact: "1.3.1"),
        .package(url: "https://github.com/apple/containerization.git", exact: "0.42.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.0.0"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.2.1"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.80.0"),
    ],
    targets: [
        // The library. Swift 5 language mode is REQUIRED: the baseline code
        // (ported from davit) is written for Swift 5 with manual @MainActor
        // annotations; the Swift 6 default actor isolation would break it
        // (spec §5 避坑 1). Products are the exact set davit's ContainerStack
        // target linked (minus Yams/NIO — added when the compose stage lands).
        .target(
            name: "OrchardCore",
            dependencies: [
                .product(name: "ContainerAPIClient", package: "container"),
                .product(name: "ContainerResource", package: "container"),
                .product(name: "ContainerPersistence", package: "container"),
                .product(name: "ContainerPlugin", package: "container"),
                .product(name: "TerminalProgress", package: "container"),
                .product(name: "ContainerBuild", package: "container"),
                .product(name: "ContainerCommands", package: "container"),
                .product(name: "ContainerImagesService", package: "container"),
                .product(name: "MachineAPIClient", package: "container"),
                .product(name: "ContainerizationExtras", package: "containerization"),
                .product(name: "ContainerizationOCI", package: "containerization"),
                .product(name: "ContainerizationOS", package: "containerization"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "Yams", package: "Yams"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "orchard-cli",
            dependencies: [
                "OrchardCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "OrchardCoreTests",
            dependencies: ["OrchardCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
