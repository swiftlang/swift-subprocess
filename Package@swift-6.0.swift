// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let availabilityMacro: SwiftSetting = .enableExperimentalFeature(
    "AvailabilityMacro=SubprocessSpan: macOS 9999"
)

let package = Package(
    name: "Subprocess",
    platforms: [.macOS(.v13)],
    products: [
        .library(
            name: "Subprocess",
            targets: ["Subprocess"]
        )
    ],
    dependencies: [
        .package(
            url: "https://github.com/apple/swift-system",
            from: "1.0.0"
        ),
        .package(
            url: "https://github.com/apple/swift-docc-plugin",
            from: "1.4.3"
        ),
    ],
    targets: [
        .target(
            name: "Subprocess",
            dependencies: [
                "_SubprocessCShims",
                .product(name: "SystemPackage", package: "swift-system"),
            ],
            path: "Sources/Subprocess",
            exclude: [
                "Span+Subprocess.swift",
                "SubprocessFoundation/Span+SubprocessFoundation.swift",
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .define("SubprocessFoundation"),
                availabilityMacro,
            ]
        ),
        .testTarget(
            name: "SubprocessTests",
            dependencies: [
                "_SubprocessCShims",
                "Subprocess",
                "TestResources",
                .product(name: "SystemPackage", package: "swift-system"),
            ],
            swiftSettings: [
                availabilityMacro
            ]
        ),

        .target(
            name: "TestResources",
            dependencies: [
                .product(name: "SystemPackage", package: "swift-system")
            ],
            path: "Tests/TestResources",
            resources: [
                .copy("Resources")
            ]
        ),

        .target(
            name: "_SubprocessCShims",
            path: "Sources/_SubprocessCShims"
        ),
    ]
)
