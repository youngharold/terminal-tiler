// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TermUsher",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "TermUsherCore", targets: ["TermUsherCore"]),
        .executable(name: "TermUsher", targets: ["TermUsher"]),
    ],
    targets: [
        .target(
            name: "TermUsherCore",
            path: "Sources/TermUsherCore"
        ),
        .executableTarget(
            name: "TermUsher",
            dependencies: ["TermUsherCore"],
            path: "Sources/TermUsher"
        ),
        .testTarget(
            name: "TermUsherCoreTests",
            dependencies: ["TermUsherCore"],
            path: "Tests/TermUsherCoreTests"
        ),
    ]
)
