// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "mi_virtual_background_kit",
    platforms: [
        .iOS("15.0")
    ],
    products: [
        .library(name: "mi-virtual-background-kit", targets: ["mi_virtual_background_kit"])
    ],
    dependencies: [
        // Versionless on purpose: the Flutter tool rewrites this to the
        // resolved "flutter_webrtc-<version>" symlink (Flutter >= 3.47.2).
        // A hardcoded version breaks consumers that resolve another version.
        .package(name: "flutter_webrtc", path: "../flutter_webrtc"),
        .package(name: "FlutterFramework", path: "../FlutterFramework"),
        // Version tag forbidden: MediaPipe uses unsafeFlags (-all_load); SPM requires branch/revision.
        .package(url: "https://github.com/google-ai-edge/mediapipe", revision: "1b9800ed7baddd397b888eaaaf0c841fe0358241")
    ],
    targets: [
        .target(
            name: "mi_virtual_background_kit",
            dependencies: [
                .product(name: "flutter-webrtc", package: "flutter_webrtc"),
                .product(name: "WebRTC", package: "flutter_webrtc"),
                .product(name: "FlutterFramework", package: "FlutterFramework"),
                .product(name: "MediaPipeTasksVision", package: "mediapipe")
            ],
            resources: [
                .process("Resources")
            ]
        )
    ]
)
