// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Training",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
    ],
    products: [
        .library(name: "TrainingApp", targets: ["TrainingApp"]),
    ],
    targets: [
        .target(
            name: "TrainingApp",
            path: "Training/Training",
            exclude: [
                "TrainingApp.swift",
                "Training.entitlements",
                "Assets.xcassets",
            ]
        ),
        .testTarget(
            name: "TrainingAppTests",
            dependencies: ["TrainingApp"]
        ),
    ]
)
