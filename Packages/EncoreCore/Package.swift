// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "EncoreCore",
    platforms: [.macOS(.v15)],
    products: [
        // Everything except in-process model code: catalog, service layer, hub, audio, stores, Python bridge.
        .library(name: "EncoreCore", targets: ["EncoreCore"]),
        // The MLX Swift engine backend. Kept separate so EncoreCore builds and tests fast.
        .library(name: "EncoreMLX", targets: ["EncoreMLX"]),
        // App updates through Sparkle. Only the app links it; the CLI never updates itself.
        .library(name: "EncoreUpdates", targets: ["EncoreUpdates"]),
        // Developer harness: drives the same service layer as the app from a terminal.
        .executable(name: "encore-cli", targets: ["encore-cli"]),
    ],
    dependencies: [
        .package(url: "https://github.com/Neywa-Labs/mlx-audio-swift.git", from: "0.2.1"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.12.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.1"),
    ],
    targets: [
        .target(
            name: "EncoreCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            resources: [.copy("Resources/Manifests"), .copy("Resources/Licenses")]
        ),
        .target(
            name: "EncoreMLX",
            dependencies: [
                "EncoreCore",
                .product(name: "MLXAudioCore", package: "mlx-audio-swift"),
                .product(name: "MLXAudioTTS", package: "mlx-audio-swift"),
                .product(name: "MLXAudioSTT", package: "mlx-audio-swift"),
            ]
        ),
        .target(
            name: "EncoreUpdates",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
            ]
        ),
        .executableTarget(
            name: "encore-cli",
            dependencies: [
                "EncoreCore", "EncoreMLX",
                .product(name: "MLXAudioCore", package: "mlx-audio-swift"),
            ]
        ),
        .testTarget(name: "EncoreCoreTests", dependencies: ["EncoreCore"]),
    ],
    swiftLanguageModes: [.v5]
)
