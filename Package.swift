// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MenuMonitor",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "MenuMonitor",
            path: "Sources/MenuMonitor",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("Charts"),
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI")
            ]
        )
    ]
)
