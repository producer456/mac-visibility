// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MacVisibilityHost",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "MacVisibilityHost",
            path: "Sources",
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("AppKit"),
            ]
        )
    ]
)
