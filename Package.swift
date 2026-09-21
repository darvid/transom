// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Transom",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Transom", targets: ["Transom"]),
    ],
    targets: [
        .executableTarget(
            name: "Transom",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("CoreGraphics"),
            ]
        ),
        .testTarget(name: "TransomTests", dependencies: ["Transom"]),
    ],
    swiftLanguageModes: [.v5]
)
