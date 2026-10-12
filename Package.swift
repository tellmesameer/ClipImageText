// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ClipText",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "ClipText", targets: ["ClipText"]),
        .library(name: "ClipTextCore", targets: ["ClipTextCore"])
    ],
    targets: [
        .target(
            name: "ClipTextCore",
            path: "Sources/ClipTextCore",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("Vision"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("UniformTypeIdentifiers"),
                .linkedFramework("CryptoKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreImage")
            ]
        ),
        .executableTarget(
            name: "ClipText",
            dependencies: ["ClipTextCore"],
            path: "Sources/ClipText"
        ),
        .testTarget(
            name: "ClipTextTests",
            dependencies: ["ClipTextCore"],
            path: "Tests/ClipTextTests"
        )
    ]
)
