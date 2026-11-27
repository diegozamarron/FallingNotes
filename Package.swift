// swift-tools-version:5.9
// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Diego Zamarron
import Foundation
import PackageDescription

// libx264 is built by Tools/build_x264.sh into ThirdParty/x264 (a universal static library).
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

let package = Package(
    name: "FallingNotes",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "CX264",
            path: "Sources/CX264",
            linkerSettings: [.unsafeFlags(["-L\(root)/ThirdParty/x264/lib"]), .linkedLibrary("x264")]
        ),
        .executableTarget(
            name: "FallingNotes",
            dependencies: ["CX264"],
            path: "Sources/FallingNotes"
        ),
    ]
)
