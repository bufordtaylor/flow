// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Flow",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Flow", targets: ["Flow"]),
        .library(name: "FlowCore", targets: ["FlowCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio", branch: "main"),
    ],
    targets: [
        .target(
            name: "FlowCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Flow",
            dependencies: ["FlowCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "FlowCoreTests",
            dependencies: ["FlowCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "FlowTests",
            dependencies: ["Flow"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
