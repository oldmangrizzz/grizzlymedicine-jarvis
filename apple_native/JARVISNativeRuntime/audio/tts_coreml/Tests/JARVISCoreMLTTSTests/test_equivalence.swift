// test_equivalence.swift — Voice equivalence test against oracle mel spectrograms
//
// Runs all 50 reference prompts through the CoreML pipeline and computes
// mel-L2 (dB) against the oracle mels in oracle/voice/mel/*.npy.
//
// Pass criteria (per prompt): mel-L2 <= 1.0 dB
//
// Run: swift test --filter EquivalenceTests

import XCTest
import Foundation
@testable import JARVISCoreMLTTS

final class EquivalenceTests: XCTestCase {

    // Paths
    static let oracleDir = URL(fileURLWithPath: "/Users/rbhanson/research/oracle/voice")
    static let modelDir  = URL(fileURLWithPath:
        "/Users/rbhanson/research/jarvis/apple_native/JARVISNativeRuntime/audio/tts_coreml/models")
    static let promptsJSON = oracleDir.appendingPathComponent("prompts.json")

    static let melL2Threshold: Float = 1.0  // dB (oracle spec)
    static let hardFailMinPassed = 48       // must pass at least 48/50

    // Shared pipeline (expensive to create)
    static var pipeline: XTTSCoreMLPipeline?
    static var prompts: [[String: Any]] = []
    static var melPipeline = MelPipelineSwift()

    override class func setUp() {
        super.setUp()
        do {
            pipeline = try XTTSCoreMLPipeline(modelDir: modelDir)
        } catch {
            XCTFail("Failed to create pipeline: \(error)")
        }
        prompts = loadPrompts()
    }

    // MARK: - Main equivalence test

    func testAllPromptsEquivalence() throws {
        guard let pipeline = Self.pipeline else {
            XCTFail("CoreML pipeline not available; full conversion did not produce all required mlpackages"); return
        }

        var results: [EquivalenceResult] = []
        var passed = 0
        var failed = 0

        for prompt in Self.prompts {
            guard let idx = prompt["idx"] as? Int,
                  let text = prompt["text"] as? String else { continue }

            let result = try evaluatePrompt(
                pipeline: pipeline,
                idx: idx,
                text: text
            )
            results.append(result)
            if result.passed { passed += 1 } else { failed += 1 }
        }

        // Report worst 5
        let worst = results.sorted { $0.melL2dB > $1.melL2dB }.prefix(5)
        print("\n=== Equivalence Test Results ===")
        print(String(format: "Passed: %d/50  Failed: %d/50", passed, failed))
        print("\nWorst 5 prompts by mel-L2:")
        for r in worst {
            let status = r.passed ? "PASS" : "FAIL"
            print(String(format: "  [%02d] %-30s  L2=%.3f dB  %@",
                         r.promptIdx, String(r.promptText.prefix(30)), r.melL2dB, status))
        }
        print("================================\n")

        XCTAssertGreaterThanOrEqual(
            passed, Self.hardFailMinPassed,
            "Only \(passed)/50 prompts passed mel-L2 ≤ 1.0 dB (need ≥ 48)"
        )
        for r in results {
            XCTAssertLessThanOrEqual(
                r.melL2dB, Self.melL2Threshold,
                "Prompt \(r.promptIdx) '\(r.promptText.prefix(40))': " +
                "mel-L2 = \(r.melL2dB) dB exceeds \(Self.melL2Threshold) dB threshold"
            )
        }
    }

    // MARK: - Individual prompt evaluation

    private func evaluatePrompt(
        pipeline: XTTSCoreMLPipeline,
        idx: Int,
        text: String
    ) throws -> EquivalenceResult {
        let startMs = Date().timeIntervalSince1970 * 1000

        // Synthesise
        let result = try pipeline.synthesise(text: text, seed: 42)

        let synthMs = Date().timeIntervalSince1970 * 1000 - startMs

        // Load oracle mel
        let oracleMelPath = Self.oracleDir
            .appendingPathComponent("mel")
            .appendingPathComponent(String(format: "%02d.npy", idx))
        let oracleMel = try NpyLoader.loadFloat32(oracleMelPath)
        let oracleFrames = oracleMel.count / 128

        // Compute mel from synthesised audio
        let synthMel = Self.melPipeline.compute(pcm: result.audio, nSamples: result.audio.count)
        let synthFrames = synthMel.count / 128

        // Compute mel-L2
        let l2db = MelPipelineSwift.melL2dB(
            melA: oracleMel, framesA: oracleFrames,
            melB: synthMel, framesB: synthFrames,
            nBins: 128
        )

        return EquivalenceResult(
            promptIdx: idx,
            promptText: text,
            melL2dB: l2db,
            passed: l2db <= Self.melL2Threshold,
            synthesisMs: synthMs
        )
    }

    // MARK: - Helpers

    static func loadPrompts() -> [[String: Any]] {
        guard let data = try? Data(contentsOf: promptsJSON),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ps = json["prompts"] as? [[String: Any]] else {
            return []
        }
        return ps
    }
}

// ---------------------------------------------------------------------------
// MARK: - NpyLoader (minimal, float32 only)
// ---------------------------------------------------------------------------

struct NpyLoader {
    /// Load a 2-D float32 .npy file. Returns flat array [rows * cols].
    static func loadFloat32(_ url: URL) throws -> [Float] {
        let data = try Data(contentsOf: url)
        // npy magic: \x93NUMPY
        guard data.count > 10 else { throw NSError(domain: "NpyLoader", code: 1) }
        // Skip header: magic(6) + major(1) + minor(1) + header_len(2 for v1 or 4 for v2)
        let major = data[6]
        let headerLenBytes = major == 1 ? 2 : 4
        var headerLen = 0
        for i in 0 ..< headerLenBytes {
            headerLen |= Int(data[8 + i]) << (8 * i)
        }
        let dataStart = 8 + headerLenBytes + headerLen
        let floatCount = (data.count - dataStart) / 4
        var floats = [Float](repeating: 0, count: floatCount)
        data.subdata(in: dataStart ..< data.count).withUnsafeBytes { ptr in
            _ = memcpy(&floats, ptr.baseAddress!, floatCount * 4)
        }
        return floats
    }
}

// ---------------------------------------------------------------------------
// MARK: - MelPipelineSwift (Swift wrapper over C++ mel_pipeline)
// ---------------------------------------------------------------------------

struct MelPipelineSwift {
    func compute(pcm: [Float], nSamples: Int) -> [Float] {
        guard nSamples >= 2048 else { return [] }
        let nFrames = 1 + (nSamples - 2048) / 256
        var mel = [Float](repeating: 0, count: nFrames * 128)
        var actualFrames: Int = 0
        pcm.withUnsafeBufferPointer { pcmPtr in
            mel.withUnsafeMutableBufferPointer { melPtr in
                let pipeline = mel_pipeline_create()
                defer { mel_pipeline_destroy(pipeline) }
                mel_pipeline_compute(
                    pipeline,
                    pcmPtr.baseAddress,
                    nSamples,
                    melPtr.baseAddress,
                    &actualFrames
                )
            }
        }
        mel.removeLast((nFrames - actualFrames) * 128)
        return mel
    }

    static func melL2dB(
        melA: [Float], framesA: Int,
        melB: [Float], framesB: Int,
        nBins: Int
    ) -> Float {
        melA.withUnsafeBufferPointer { pA in
            melB.withUnsafeBufferPointer { pB in
                mel_l2_db(pA.baseAddress, framesA, pB.baseAddress, framesB, Int32(nBins))
            }
        }
    }
}
