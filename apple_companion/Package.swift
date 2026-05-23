// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "JARVISCompanion",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v17),
        .watchOS(.v10),
        .macOS(.v14),
    ],
    products: [
        .library(name: "JARVISCompanionCore", targets: ["JARVISCompanionCore"]),
        .library(name: "JARVISCompanionUI", targets: ["JARVISCompanionUI"]),
        .executable(name: "JARVISCompanionSelfTest", targets: ["JARVISCompanionSelfTest"]),
    ],
    targets: [
        .target(name: "JARVISCompanionCore"),
        .target(
            name: "JARVISCompanionUI",
            dependencies: ["JARVISCompanionCore"]
        ),
        .executableTarget(
            name: "JARVISCompanionSelfTest",
            dependencies: ["JARVISCompanionCore"]
        ),
    ]
)
