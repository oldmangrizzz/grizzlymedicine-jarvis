// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "JARVISMacCockpit",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "JARVISMacCockpit", targets: ["JARVISMacCockpit"]),
        .executable(name: "jarvis-audit-verify-swift", targets: ["JARVISAuditVerifySwift"]),
    ],
    dependencies: [
        .package(path: "../JARVISNativeRuntime/voice/tts/coreml"),
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
                ]),
                // R11j F-F24 — strip build-host absolute paths from
                // C++ object files in release. Without these, __FILE__
                // macro expansions and debug-info source paths embed
                // /Users/<operator>/research/... into the binary,
                // exposing the host machine's directory layout in
                // strings(binary) output. Mirrors the Swift-side
                // -file-compilation-dir=/JARVIS flag below for the
                // C/C++ toolchain.
                .unsafeFlags([
                    "-ffile-prefix-map=/Users/rbhanson/research/jarvis/apple_native=/JARVIS",
                    "-fmacro-prefix-map=/Users/rbhanson/research/jarvis/apple_native=/JARVIS",
                ], .when(configuration: .release))
            ],
            linkerSettings: [
                .unsafeFlags(["-L/opt/homebrew/opt/libsodium/lib"]),
                .linkedLibrary("sodium")
            ]
        ),
        .executableTarget(
            name: "JARVISMacCockpit",
            dependencies: [
                "NativeRuntimeModule",
                .product(name: "JARVISCoreMLTTS", package: "coreml"),
            ],
            path: ".",
            exclude: [
                ".build", "Dialog", "Networking/Tests", "Tests", "Config", "NativeRuntimeModule",
                "SecureEnclave",
                "Info.plist", "JARVISMacCockpit.entitlements", "JARVISMacCockpit-Bridging-Header.h",
                "NativeRuntimeHTTPServiceReceipt.swift", "tools/bundle_dylibs.sh",
                "tools/JARVISAuditVerifySwift",
                "Speakers/README.md",
                "README.md",
                "scripts"
            ],
            resources: [.process("Networking/pins.plist")],
            swiftSettings: [
                .define("SWIFTPM_BUILD"),
                // R11d F-C02: identity/security env-override consumption sites
                // are gated behind DEBUG && JARVIS_INSECURE_PATHS. Defined only
                // for debug configuration — release ships without it and so
                // never consults JARVIS_AUDIT_ROOT, JARVIS_BIRTH_CERT_PATH,
                // JARVIS_HOME, JARVIS_COLD_ROOT_PIN_FILE, or any other
                // override. Debug builds (developer + `swift test`) honor
                // the overrides so test harnesses can run hermetically.
                .define("JARVIS_INSECURE_PATHS", .when(configuration: .debug)),
                // R11h F-E12: reproducible release builds. Stamps the
                // compilation directory to a deterministic value so the
                // operator can recompute the binary SHA from source and
                // place it on the court-exhibit paper attestation. Coupled
                // with the linker -no_uuid flag below to strip the Mach-O
                // LC_UUID load command (which is otherwise randomized per
                // link and would defeat reproducibility on its own).
                .unsafeFlags([
                    "-file-compilation-dir", "/JARVIS",
                    "-no-clang-module-breadcrumbs",
                    // R11j F-F24 — remap remaining absolute path
                    // references in #file/#filePath/#fileID macro
                    // expansions and DWARF source paths. Without this
                    // flag the cockpit binary still leaks
                    // /Users/<operator>/research/... in strings(binary)
                    // for any Swift source that uses #file (or has
                    // an autodiagnostics path embedded). Pairs with
                    // the cxxSettings -ffile-prefix-map above.
                    "-Xfrontend", "-file-prefix-map",
                    "-Xfrontend", "/Users/rbhanson/research/jarvis/apple_native=/JARVIS",
                ], .when(configuration: .release))
            ],
            linkerSettings: [
                // R11h F-E12: strip the LC_UUID load command from the linked
                // Mach-O so two clean builds from the same source produce
                // byte-identical binaries. Required for the court-exhibit
                // SHA-256 fingerprint to be reproducible by a third party.
                .unsafeFlags([
                    "-Xlinker", "-no_uuid",
                    // F-E12: ld64 symbol-table ordering determinism. Without
                    // this, mangled symbol names land in a hash-based container
                    // and are emitted in iteration order, producing scattered
                    // byte drift inside the LC_SYMTAB region of __LINKEDIT.
                    "-Xlinker", "-reproducible",
                ], .when(configuration: .release))
            ]
        ),
        .testTarget(
            name: "JARVISMacCockpitTests",
            dependencies: ["JARVISMacCockpit"],
            path: "Tests/JARVISMacCockpitTests",
            swiftSettings: [
                .define("JARVIS_INSECURE_PATHS")
            ]
        ),
        .executableTarget(
            name: "JARVISAuditVerifySwift",
            path: "tools/JARVISAuditVerifySwift"
        ),
    ],
    cxxLanguageStandard: .cxx20
)
