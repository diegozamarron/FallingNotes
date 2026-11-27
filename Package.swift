// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "FallingNotes",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "FallingNotes",
            path: "Sources/FallingNotes"
        )
    ]
)
