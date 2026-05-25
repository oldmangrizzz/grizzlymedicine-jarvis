// test_determinism.swift — Verifies same prompt + same seed → bit-identical mel
//
// Run: swift test --filter DeterminismTests

import XCTest
import Foundation
@testable import JARVISCoreMLTTS

final class DeterminismTests: XCTestCase {

    static let modelDir = URL(fileURLWithPath:
        "/Users/rbhanson/research/jarvis/apple_native/JARVISNativeRuntime/audio/tts_coreml/models")

    static var pipeline: XTTSCoreMLPipeline?

    override class func setUp() {
        super.setUp()
        do {
            pipeline = try XTTSCoreMLPipeline(modelDir: modelDir)
        } catch {
            print("Pipeline init failed: \(error)")
        }
    }

    // MARK: - Bit-identical mel test

    func testSameSeedBitIdenticalMel() throws {
        guard let pipeline = Self.pipeline else {
            XCTFail("CoreML pipeline not available; full conversion did not produce all required mlpackages"); return
        }

        let testPrompts = [
            (0, "Ready."),
            (1, "JARVIS online."),
            (5, "Good morning. All systems are nominal."),
        ]
        let mel = MelPipelineSwift()

        for (idx, text) in testPrompts {
            let r1 = try pipeline.synthesise(text: text, seed: 42)
            let r2 = try pipeline.synthesise(text: text, seed: 42)

            let m1 = mel.compute(pcm: r1.audio, nSamples: r1.audio.count)
            let m2 = mel.compute(pcm: r2.audio, nSamples: r2.audio.count)

            XCTAssertEqual(
                m1.count, m2.count,
                "Prompt \(idx): mel frame count differs (\(m1.count) vs \(m2.count))"
            )

            let maxDiff = zip(m1, m2).map { abs($0 - $1) }.max() ?? 0
            XCTAssertEqual(
                maxDiff, 0,
                "Prompt \(idx) '\(text)': mel not bit-identical; max diff = \(maxDiff)"
            )

            print(String(format: "Prompt %02d: determinism check %@  max_diff=%.2e",
                         idx, maxDiff == 0 ? "PASS" : "FAIL", maxDiff))
        }
    }

    // MARK: - Different seeds produce different output

    func testDifferentSeedsDifferentOutput() throws {
        guard let pipeline = Self.pipeline else {
            XCTFail("CoreML pipeline not available; full conversion did not produce all required mlpackages"); return
        }

        let text = "Good morning. All systems are nominal."
        let r1 = try pipeline.synthesise(text: text, seed: 42)
        let r2 = try pipeline.synthesise(text: text, seed: 123)

        // Different seeds should produce different output
        let maxDiff = zip(r1.audio, r2.audio).map { abs($0 - $1) }.max() ?? 0
        XCTAssertGreaterThan(
            maxDiff, 0,
            "Different seeds produced identical audio (RNG is broken)"
        )
        print(String(format: "Different seeds: max diff = %.4f  (expected > 0)", maxDiff))
    }

    // MARK: - Oracle seed reproducibility

    func testOracleSeed42() throws {
        // Verifies that running with seed=42 and temperature=0.75 produces
        // deterministic output across multiple pipeline instantiations.
        guard let pipeline1 = Self.pipeline,
              let pipeline2 = try? XTTSCoreMLPipeline(modelDir: Self.modelDir) else {
            XCTFail("CoreML pipeline not available; full conversion did not produce all required mlpackages"); return
        }

        let text = "Confirmed."
        let r1 = try pipeline1.synthesise(text: text, seed: 42)
        let r2 = try pipeline2.synthesise(text: text, seed: 42)

        let mel = MelPipelineSwift()
        let m1 = mel.compute(pcm: r1.audio, nSamples: r1.audio.count)
        let m2 = mel.compute(pcm: r2.audio, nSamples: r2.audio.count)

        XCTAssertEqual(m1.count, m2.count, "Oracle-seed test: mel frame count differs")
        let maxDiff = zip(m1, m2).map { abs($0 - $1) }.max() ?? 0
        XCTAssertEqual(maxDiff, 0,
            "Oracle seed 42: different pipeline instances produced non-identical mel")
        print(String(format: "Oracle seed 42 cross-instance: max_diff=%.2e", maxDiff))
    }
}
