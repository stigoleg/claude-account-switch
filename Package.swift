// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClaudeProfileSwitcher",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ClaudeProfileSwitcher", targets: ["ClaudeProfileSwitcher"])
    ],
    targets: [
        .executableTarget(
            name: "ClaudeProfileSwitcher",
            dependencies: ["ClaudeProfileSwitcherCore"],
            path: "Sources/ClaudeProfileSwitcher",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .target(
            name: "ClaudeProfileSwitcherCore",
            path: "Sources/ClaudeProfileSwitcherCore",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "ClaudeProfileSwitcherCoreTests",
            dependencies: ["ClaudeProfileSwitcherCore"],
            path: "Tests/ClaudeProfileSwitcherCoreTests",
            resources: [
                .copy("Fixtures")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
    ]
)
