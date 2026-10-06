// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

var dep: [Package.Dependency] = [
    .package(
        url: "https://github.com/apple/swift-system",
        from: "1.5.0"
    )
]

// SystemPackage is only used on non-Apple platforms; Apple platforms use the
// System framework from the SDK (see `#if canImport(System)` in the sources).
let systemPackageDependency: Target.Dependency = .product(
    name: "SystemPackage",
    package: "swift-system",
    condition: .when(platforms: [.linux, .windows, .android, .wasi, .openbsd, .custom("freebsd")])
)

// Enable SubprocessFoundation by default
let defaultTraits: Set<String> = ["SubprocessFoundation"]

let packageSwiftSettings: [SwiftSetting] = [
    .define("SUBPROCESS_ASYNCIO_KQUEUE", .when(platforms: [.macOS, .custom("freebsd"), .openbsd])),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("InternalImportsByDefault"),
    .swiftLanguageMode(.v6),
]

let package = Package(
    name: "swift-subprocess",
    platforms: [.macOS(.v13), .iOS("99.0")],
    products: [
        .library(
            name: "Subprocess",
            targets: ["Subprocess"]
        )
    ],
    traits: [
        "SubprocessFoundation",
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
                systemPackageDependency,
            ],
            path: "Sources/Subprocess",
            exclude: ["CMakeLists.txt"],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .enableExperimentalFeature("Lifetimes"),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
            ] + packageSwiftSettings
        ),
        .testTarget(
            name: "SubprocessTests",
            dependencies: [
                "_SubprocessCShims",
                "Subprocess",
                "TestResources",
                systemPackageDependency,
            ],
            swiftSettings: packageSwiftSettings,
            linkerSettings: [
                .linkedLibrary("util", .when(platforms: [.openbsd])) // for openpty
            ]
        ),

        .target(
            name: "TestResources",
            dependencies: [
                systemPackageDependency
            ],
            path: "Tests/TestResources",
            resources: [
                .copy("Resources")
            ],
            swiftSettings: packageSwiftSettings
        ),

        .target(
            name: "_SubprocessCShims",
            path: "Sources/_SubprocessCShims",
            exclude: ["CMakeLists.txt"]
        ),
    ]
)
