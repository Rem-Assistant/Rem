// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "RemKit",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(name: "RemProtocol", targets: ["RemProtocol"]),
        .library(name: "RemKit", targets: ["RemKit"]),
        .library(name: "RemChatUI", targets: ["RemChatUI"]),
    ],
    dependencies: [
        // Pin Rem's playback-only fork of 0.1.1 until a tagged upstream release contains the fix.
        // It isolates replacement PCM generations and cancels stopped MP3/PCM streams without
        // importing upstream's unrelated request, retry, speed-validation, or toolchain changes.
        .package(
            url: "https://github.com/Rem-Assistant/ElevenLabsKit",
            revision: "9a908266eb9bdb63c04d6391b19242cab07b1ce0"),
        .package(url: "https://github.com/gonzalezreal/textual", exact: "0.3.1"),
    ],
    targets: [
        .target(
            name: "RemProtocol",
            path: "Sources/RemProtocol",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
            ]),
        .target(
            name: "RemKit",
            dependencies: [
                "RemProtocol",
                .product(name: "ElevenLabsKit", package: "ElevenLabsKit"),
            ],
            path: "Sources/RemKit",
            resources: [
                .process("Resources"),
            ],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
            ]),
        .target(
            name: "RemChatUI",
            dependencies: [
                "RemKit",
                .product(
                    name: "Textual",
                    package: "textual",
                    condition: .when(platforms: [.macOS, .iOS])),
            ],
            path: "Sources/RemChatUI",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
            ]),
        .testTarget(
            name: "RemKitTests",
            dependencies: ["RemKit", "RemChatUI"],
            path: "Tests/RemKitTests",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
                .enableExperimentalFeature("SwiftTesting"),
            ]),
    ])
