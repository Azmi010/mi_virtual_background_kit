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
        .package(name: "flutter_webrtc", path: "../flutter_webrtc"),
        .package(name: "FlutterFramework", path: "../FlutterFramework"),
        .package(url: "https://github.com/google-ai-edge/mediapipe", branch: "master")
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
