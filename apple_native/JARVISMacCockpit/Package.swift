// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "JARVISMacCockpit",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "JARVISMacCockpit", targets: ["JARVISMacCockpit"]),
    ],
    targets: [
        .target(
            name: "NativeRuntimeModule",
            path: "NativeRuntimeModule",
            publicHeadersPath: "include",
            cxxSettings: [
                .unsafeFlags([
                    "-std=c++20",
                    "-I../orchestration/shadow_router",
                    "-I/opt/homebrew/opt/libsodium/include"
                ])
            ],
            linkerSettings: [
                .unsafeFlags(["-L/opt/homebrew/opt/libsodium/lib"]),
                .linkedLibrary("sodium")
            ]
        ),
        .executableTarget(
            name: "JARVISMacCockpit",
            dependencies: ["NativeRuntimeModule"],
            path: ".",
            exclude: [
                ".build", "Dialog", "Networking/Tests", "Tests", "Config", "NativeRuntimeModule",
                "SecureEnclave",
                "Info.plist", "JARVISMacCockpit.entitlements", "JARVISMacCockpit-Bridging-Header.h",
                "NativeRuntimeHTTPServiceReceipt.swift", "tools/bundle_dylibs.sh", "Speakers/README.md",
                "README.md"
            ],
            resources: [.process("Networking/pins.plist")],
            swiftSettings: [.define("SWIFTPM_BUILD")]
        ),
        .testTarget(
            name: "JARVISMacCockpitTests",
            dependencies: ["JARVISMacCockpit"],
            path: "Tests/JARVISMacCockpitTests"
        ),
    ],
    cxxLanguageStandard: .cxx20
)
