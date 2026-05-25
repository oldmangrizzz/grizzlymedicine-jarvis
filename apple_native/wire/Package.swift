// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "JARVISWire",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
        .watchOS(.v10),
    ],
    products: [
        .library(name: "JARVISWire", targets: ["JARVISWire"]),
    ],
    targets: [
        .systemLibrary(
            name: "CsodiumShim",
            pkgConfig: "libsodium",
            providers: [
                .brew(["libsodium"]),
                .apt(["libsodium-dev"]),
            ]
        ),
        .target(
            name: "JARVISWire",
            dependencies: [
                .target(name: "CsodiumShim", condition: .when(platforms: [.macOS]))
            ],
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")],
            linkerSettings: [.unsafeFlags(["-L/opt/homebrew/opt/libsodium/lib"], .when(platforms: [.macOS]))]
        ),
        .testTarget(
            name: "JARVISWireTests",
            dependencies: ["JARVISWire"]
        ),
        .testTarget(
            name: "AdversarialTests",
            dependencies: ["JARVISWire"]
        ),
    ]
)
