// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TopLayer",
    platforms: [.macOS("26.0")],
    targets: [
        // The overlay app.
        .executableTarget(
            name: "TopLayer",
            path: "Sources/TopLayer"
        ),
        // Stateless tool agents use to reach a TopLayer group chat (MCP server + command).
        .executableTarget(
            name: "TopLayerLink",
            path: "Sources/TopLayerLink"
        ),
        // Run with Scripts/test.sh: the tests need the full Xcode toolchain.
        .testTarget(
            name: "TopLayerTests",
            dependencies: ["TopLayer"],
            path: "Tests/TopLayerTests"
        ),
    ]
)
