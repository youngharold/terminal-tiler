// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TerminalTiler",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "TerminalTiler",
            path: "Sources/TerminalTiler"
        )
    ]
)
