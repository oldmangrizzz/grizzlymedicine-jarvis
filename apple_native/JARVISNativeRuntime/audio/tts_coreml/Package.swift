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
    ],
    targets: [
        // MARK: — SPM C++ bridge
        .target(
            name: "JARVISSPMBridge",
            path: "Sources/JARVISSPMBridge",
            publicHeadersPath: ".",
            cxxSettings: [
                .unsafeFlags(["-std=c++17", "-I/opt/homebrew/include"]),
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
            path: "Sources/JARVISMelPipeline",
            sources: ["mel_pipeline.cpp"],
            publicHeadersPath: ".",
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
            path: "Sources/JARVISVoiceStateDecoder",
            sources: ["voice_state_decoder.cpp"],
            publicHeadersPath: ".",
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

        // MARK: — Test target
        .testTarget(
            name: "JARVISCoreMLTTSTests",
            dependencies: ["JARVISCoreMLTTS"],
            path: "Tests/JARVISCoreMLTTSTests"
        ),
    ],
    cxxLanguageStandard: .cxx17
)
