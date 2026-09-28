// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Barc",
    platforms: [.macOS("15.4")],
    targets: [
        .executableTarget(
            name: "Barc",
            path: "Sources/Barc"
        ),
        .testTarget(
            name: "BarcTests",
            dependencies: ["Barc"],
            path: "Tests/BarcTests"
        )
    ]
)
