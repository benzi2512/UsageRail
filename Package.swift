// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "UsageRail",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "UsageRail", targets: ["UsageRail"]),
        .executable(name: "UsageBridge", targets: ["UsageBridge"])
    ],
    targets: [
        .target(
            name: "UsageCore",
            path: "Sources/UsageCore"
        ),
        .executableTarget(
            name: "UsageRail",
            dependencies: ["UsageCore"],
            path: "Sources/UsageRail"
        ),
        .executableTarget(
            name: "UsageBridge",
            dependencies: ["UsageCore"],
            path: "Sources/UsageBridge"
        ),
        .testTarget(
            name: "UsageCoreTests",
            dependencies: ["UsageCore"],
            path: "Tests/UsageCoreTests"
        )
    ]
)
