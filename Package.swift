// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CIStatus",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "CIStatus", targets: ["CIStatus"])
    ],
    targets: [
        .executableTarget(
            name: "CIStatus",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI")
            ]
        )
    ]
)
