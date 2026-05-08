// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TerminalTiler",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "TerminalTilerCore", targets: ["TerminalTilerCore"]),
        .executable(name: "TerminalTiler", targets: ["TerminalTiler"]),
    ],
    targets: [
        .target(
            name: "TerminalTilerCore",
            path: "Sources/TerminalTilerCore"
        ),
        .executableTarget(
            name: "TerminalTiler",
            dependencies: ["TerminalTilerCore"],
            path: "Sources/TerminalTiler"
        ),
        .testTarget(
            name: "TerminalTilerCoreTests",
            dependencies: ["TerminalTilerCore"],
            path: "Tests/TerminalTilerCoreTests"
        ),
    ]
)
