// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

var dep: [Package.Dependency] = [
    .package(
        url: "https://github.com/apple/swift-system",
        from: "1.5.0"
    )
]
#if !os(Windows)
dep.append(
    .package(
        url: "https://github.com/apple/swift-docc-plugin",
        from: "1.4.5"
    ),
)
#endif

// Enable SubprocessFoundation by default
var defaultTraits: Set<String> = ["SubprocessFoundation"]
#if compiler(>=6.2)
// Enable SubprocessSpan when Span is available
defaultTraits.insert("SubprocessSpan")
#endif

let package = Package(
    name: "Subprocess",
    platforms: [.macOS(.v13), .iOS("99.0")],
    products: [
        .library(
            name: "Subprocess",
            targets: ["Subprocess"]
        )
    ],
    traits: [
        "SubprocessFoundation",
        "SubprocessSpan",
        .default(
            enabledTraits: defaultTraits
        ),
    ],
    dependencies: dep,
    targets: [
        .target(
            name: "Subprocess",
            dependencies: [
                "_SubprocessCShims",
                .product(name: "SystemPackage", package: "swift-system"),
            ],
            path: "Sources/Subprocess",
            exclude: [ "CMakeLists.txt" ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .enableExperimentalFeature("NonescapableTypes"),
                .enableExperimentalFeature("LifetimeDependence"),
                .enableExperimentalFeature("Span"),
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
                .enableExperimentalFeature("Span"),
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
            path: "Sources/_SubprocessCShims",
            exclude: [ "CMakeLists.txt" ]
        ),
    ]
)
