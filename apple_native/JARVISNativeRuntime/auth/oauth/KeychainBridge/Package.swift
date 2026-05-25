// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "JARVISOAuthKeychainBridge",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "JARVISOAuthKeychainBridge", targets: ["JARVISOAuthKeychainBridge"]),
    ],
    targets: [
        .target(name: "JARVISOAuthKeychainBridge"),
        .testTarget(name: "JARVISOAuthKeychainBridgeTests", dependencies: ["JARVISOAuthKeychainBridge"]),
    ]
)
