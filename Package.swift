// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LyrX",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "LyrX",
            path: "Sources/LyrX",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(
            name: "LyrXTests",
            dependencies: ["LyrX"]
        )
    ]
)
