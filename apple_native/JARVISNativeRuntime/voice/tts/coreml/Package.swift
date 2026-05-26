// swift-tools-version:5.9
// Package.swift — JARVIS CoreML TTS package
//
// Targets:
//   JARVISCoreMLTTS         — main library (Swift + bridged C++)
//   JARVISSPMBridge         — SentencePiece C++ bridge (no-op stub if libsentencepiece unavailable)
//   JARVISCoreMLTTSTests    — XCTest suite: equivalence, determinism, latency

import PackageDescription

let package = Package(
    name: "JARVISCoreMLTTS",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(
            name: "JARVISCoreMLTTS",
            targets: ["JARVISCoreMLTTS"]
        ),
        .executable(
            name: "CompileLoadPredictSmoke",
            targets: ["CompileLoadPredictSmoke"]
        ),
    ],
    targets: [
        // MARK: — SPM C++ bridge
        .target(
            name: "JARVISSPMBridge",
            path: "Sources/JARVISSPMBridge",
            publicHeadersPath: ".",
            cxxSettings: [
                // Try Homebrew sentencepiece location
                .unsafeFlags(["-I/opt/homebrew/include", "-std=c++17"]),
            ],
            linkerSettings: [
                // Link against sentencepiece if available
                .linkedLibrary("sentencepiece", .when(platforms: [.macOS])),
                .unsafeFlags(["-L/opt/homebrew/lib"], .when(platforms: [.macOS])),
            ]
        ),

        // MARK: — Mel pipeline C++ target (Accelerate)
        .target(
            name: "JARVISMelPipeline",
            path: ".",
            sources: ["mel_pipeline.cpp"],
            publicHeadersPath: "include_mel",
            cxxSettings: [
                .unsafeFlags(["-std=c++17", "-O3"]),
            ],
            linkerSettings: [
                .linkedFramework("Accelerate"),
            ]
        ),

        // MARK: — Voice state decoder C++ target
        .target(
            name: "JARVISVoiceStateDecoder",
            path: ".",
            sources: ["voice_state_decoder.cpp"],
            publicHeadersPath: "include_voice_state",
            cxxSettings: [
                .unsafeFlags(["-std=c++17", "-O2"]),
            ]
        ),

        // MARK: — Main Swift library
        .target(
            name: "JARVISCoreMLTTS",
            dependencies: [
                "JARVISSPMBridge",
                "JARVISMelPipeline",
                "JARVISVoiceStateDecoder",
            ],
            path: "Sources/JARVISCoreMLTTS",
            resources: [
                // Bundle model directory references (populated after conversion)
                .copy("../../models"),
            ],
            swiftSettings: [
                .unsafeFlags(["-Onone"]),  // release: remove this flag
            ],
            linkerSettings: [
                .linkedFramework("CoreML"),
                .linkedFramework("Accelerate"),
                .linkedFramework("Foundation"),
            ]
        ),

        // MARK: — Smoke executable
        .executableTarget(
            name: "CompileLoadPredictSmoke",
            dependencies: ["JARVISCoreMLTTS"],
            path: "smoke"
        ),

        // MARK: — Test target
        .testTarget(
            name: "JARVISCoreMLTTSTests",
            dependencies: ["JARVISCoreMLTTS"],
            path: "Tests/JARVISCoreMLTTSTests"
        ),

        // MARK: — C++ manifest hash parity harness (used by test_manifest_hash_parity.swift)
        .executableTarget(
            name: "ManifestHashHarness",
            path: "Tests/Harness",
            sources: ["manifest_hash_harness.cpp"],
            cxxSettings: [
                .unsafeFlags(["-std=c++17", "-I/opt/homebrew/include"]),
            ],
            linkerSettings: [
                .linkedLibrary("sodium"),
                .unsafeFlags(["-L/opt/homebrew/lib"]),
            ]
        ),

        // MARK: — Swift hash parity smoke tool (used by test_manifest_hash_parity.swift)
        .executableTarget(
            name: "HashParitySmoke",
            dependencies: ["JARVISCoreMLTTS"],
            path: "smoke_hash"
        ),

        // MARK: — R8 voice_state loadtime integrity smoke
        .executableTarget(
            name: "IntegritySmoke",
            dependencies: ["JARVISCoreMLTTS"],
            path: "smoke_integrity"
        ),

        // MARK: — R9 prewarm invariant + R10 boot-phase bells smoke
        .executableTarget(
            name: "PrewarmInvariantSmoke",
            dependencies: ["JARVISCoreMLTTS"],
            path: "smoke_prewarm_invariant"
        ),

        // MARK: — R10 boot lifecycle tracker smoke
        //
        // Exercises BootLifecycleTracker end-to-end without paying the 5.6-min
        // CoreML compile cost: fake-emits the R9 phase sequence, asserts
        // snapshot transitions, ETA file roundtrip via §7 atomic write,
        // gate-vs-ready behaviour. The tracker source lives in the
        // JARVISMacCockpitService directory (xcodeproj target); we include
        // the single file directly so the smoke is buildable with `swift build`
        // even outside the cockpit's xcodebuild context.
        .executableTarget(
            name: "BootLifecycleSmoke",
            path: "smoke_boot_lifecycle",
            sources: [
                "BootLifecycleSmoke.swift",
                "BootLifecycleTracker.swift",
            ]
        ),
    ],
    cxxLanguageStandard: .cxx17
)
