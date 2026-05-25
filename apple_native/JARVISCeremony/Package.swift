// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "JARVISCeremony",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "JARVISCeremonyCore", targets: ["JARVISCeremonyCore"]),
        .executable(name: "JARVISCeremony", targets: ["JARVISCeremonyApp"]),
        .executable(name: "JARVISCeremonySmoke", targets: ["JARVISCeremonySmoke"]),
    ],
    dependencies: [
        .package(path: "../JARVISMacCockpit/SecureEnclave"),
    ],
    targets: [
        .systemLibrary(
            name: "CCeremonyLibsodium",
            path: "Sources/CCeremonyLibsodium",
            pkgConfig: "libsodium",
            providers: [.brew(["libsodium"])]
        ),
        .target(
            name: "CharacterValuesBridge",
            path: "Sources/CharacterValuesBridge",
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("../../Vendor/JARVISNativeRuntime/identity/character_values"),
                .headerSearchPath("../../Vendor/JARVISNativeRuntime/integrity/audit"),
                .headerSearchPath("../../Vendor/JARVISNativeRuntime/holograph/hdc"),
                .headerSearchPath("../../Vendor/JARVISNativeRuntime/security"),
                .headerSearchPath("../../Vendor/libsodium_include"),
                .unsafeFlags(["-std=c++20"]),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-LVendor/JARVISNativeRuntime/identity/character_values/build",
                    "-LVendor/JARVISNativeRuntime/identity/character_values/build/distress_build",
                    "-Xlinker", "-force_load", "-Xlinker", "Vendor/JARVISNativeRuntime/identity/character_values/build/libjarvis_audit.a",
                ]),
                .linkedLibrary("jarvis_identity_character_values"),
                .linkedLibrary("jarvis_holograph_hdc"),
                .linkedLibrary("jarvis_audit"),
                .linkedLibrary("jarvis_identity_distress"),
                .linkedLibrary("sodium"),
            ]
        ),
        .target(
            name: "JARVISCeremonyCore",
            dependencies: [
                "CCeremonyLibsodium",
                "CharacterValuesBridge",
                .product(name: "JARVISSecureEnclave", package: "SecureEnclave"),
            ],
            path: "Sources/JARVISCeremonyCore",
            resources: [.process("../../Resources/bip39_english.txt")],
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedFramework("CryptoKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("IOKit"),
                .linkedFramework("DiskArbitration"),
                .linkedLibrary("sodium"),
            ]
        ),
        .executableTarget(
            name: "JARVISCeremonyApp",
            dependencies: ["JARVISCeremonyCore"],
            path: "Sources/JARVISCeremonyApp",
            linkerSettings: [
                .linkedFramework("SwiftUI"),
                .linkedFramework("AppKit"),
                // @rpath resolution: at runtime the executable lives in
                // <bundle>.app/Contents/MacOS/ and the embedded dylibs
                // (libJARVISSecureEnclave.dylib, libsodium.26.dylib) sit
                // next to it. @executable_path/. is the directory containing
                // the executable, which is exactly where build_app.sh puts
                // them. Without this, dyld falls back to the build-machine
                // path and the app fails to launch on a clean Mac.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/."]),
            ]
        ),
        .executableTarget(
            name: "JARVISCeremonySmoke",
            dependencies: ["JARVISCeremonyCore"],
            path: "Sources/JARVISCeremonySmoke"
        ),
        .testTarget(
            name: "JARVISCeremonyTests",
            dependencies: ["JARVISCeremonyCore"],
            path: "Tests/JARVISCeremonyTests"
        ),
    ],
    cxxLanguageStandard: .cxx20
)
