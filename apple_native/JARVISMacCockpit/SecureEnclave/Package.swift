// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "JARVISSecureEnclave",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "JARVISSecureEnclave", type: .dynamic, targets: ["JARVISSecureEnclave"]),
        .executable(name: "JARVISSecureEnclaveSmoke", targets: ["JARVISSecureEnclaveSmoke"]),
    ],
    targets: [
        .systemLibrary(
            name: "CLibsodium",
            path: "CLibsodium",
            pkgConfig: "libsodium",
            providers: [.brew(["libsodium"])]
        ),
        .target(
            name: "JARVISSecureEnclave",
            dependencies: ["CLibsodium"],
            path: "Sources/JARVISSecureEnclave",
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedFramework("CryptoKit"),
                .linkedFramework("IOKit"),
                .linkedLibrary("sodium"),
            ]
        ),
        .executableTarget(
            name: "JARVISSecureEnclaveSmoke",
            dependencies: ["JARVISSecureEnclave"],
            path: "Sources/JARVISSecureEnclaveSmoke"
        ),
        .testTarget(
            name: "JARVISSecureEnclaveTests",
            dependencies: ["JARVISSecureEnclave"],
            path: "Tests/JARVISSecureEnclaveTests"
        ),
    ]
)
