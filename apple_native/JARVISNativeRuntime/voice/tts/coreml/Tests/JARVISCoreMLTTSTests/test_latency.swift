// test_latency.swift — First-chunk latency for short/medium/long prompts
//
// Targets:
//   Short  (<20 words): ≤250 ms first-chunk
//   Medium (20-60 words): as measured (oracle baseline ~270 ms)
//   Long   (>60 words): as measured
//
// Run: swift test --filter LatencyTests

import XCTest
import CryptoKit
import Foundation
@testable import JARVISCoreMLTTS

final class LatencyTests: XCTestCase {

    static let modelDir = URL(fileURLWithPath:
        "/Users/rbhanson/research/jarvis/apple_native/JARVISNativeRuntime/voice/tts/coreml/models")
    static let oracleTimings = URL(fileURLWithPath:
        "/Users/rbhanson/research/oracle/voice/timings.csv")
    static let promptsJSON = URL(fileURLWithPath:
        "/Users/rbhanson/research/oracle/voice/prompts.json")

    static let shortLatencyBudgetMs: Double = 250.0   // hard limit for <20 words
    static let oracleBaselineMs: Double     = 266.0   // mean first-chunk from manifest

    static var pipeline: XTTSCoreMLPipeline?

    override class func setUp() {
        super.setUp()
        do {
            let vsURL = modelDir.appendingPathComponent("voice_state.bin")
            guard let data = try? Data(contentsOf: vsURL) else {
                print("voice_state.bin missing — skipping pipeline init")
                return
            }
            let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            pipeline = try XTTSCoreMLPipeline(modelDir: modelDir, expectedVoiceStateSHA256Hex: sha)
            // Pre-warm by calling once
        } catch {
            print("Pipeline init failed: \(error)")
        }
    }

    // MARK: - First-chunk latency

    func testFirstChunkLatencyShortPrompts() throws {
        guard let pipeline = Self.pipeline else {
            // TODO(removal-cond: XTTSCoreMLPipeline initializer succeeds without runtime model conversion prerequisite)
            throw XCTSkip("CoreML pipeline not available")
        }

        let shortPrompts = [
            (0, "Ready."),
            (1, "JARVIS online."),
            (2, "Understood, sir."),
            (3, "Confirmed."),
            (4, "Yes, sir."),
            (5, "Good morning. All systems are nominal."),
        ]

        var latencies: [Double] = []
        for (idx, text) in shortPrompts {
            var firstChunkMs = 0.0
            _ = try pipeline.synthesise(text: text, seed: 42) { ms in
                firstChunkMs = ms
            }
            latencies.append(firstChunkMs)
            print(String(format: "  Prompt %02d %-35s first_chunk=%.1f ms", idx, text, firstChunkMs))
        }

        let meanMs = latencies.reduce(0, +) / Double(latencies.count)
        let maxMs  = latencies.max() ?? 0

        print(String(format: "\nShort prompts: mean=%.1f ms  max=%.1f ms  budget=%d ms",
                     meanMs, maxMs, Int(Self.shortLatencyBudgetMs)))

        XCTAssertLessThanOrEqual(
            meanMs, Self.shortLatencyBudgetMs,
            "Mean first-chunk latency \(meanMs) ms exceeds \(Self.shortLatencyBudgetMs) ms budget"
        )
    }

    func testFirstChunkLatencyMediumPrompts() throws {
        guard let pipeline = Self.pipeline else {
            // TODO(removal-cond: XTTSCoreMLPipeline initializer succeeds without runtime model conversion prerequisite)
            throw XCTSkip("CoreML pipeline not available")
        }

        let mediumPrompts = [
            (15, "All systems are operating within normal parameters. Reactor output at ninety-six percent. Suit integrity is nominal."),
            (16, "Good morning. I have your morning briefing ready. Shall I proceed?"),
        ]

        for (idx, text) in mediumPrompts {
            var firstChunkMs = 0.0
            _ = try pipeline.synthesise(text: text, seed: 42) { ms in
                firstChunkMs = ms
            }
            let oracleMs = oracleFirstChunkMs(for: idx)
            let comparison = oracleMs > 0
                ? String(format: "  oracle=%.1f ms  delta=%.1f ms", oracleMs, firstChunkMs - oracleMs)
                : ""
            print(String(format: "  Medium [%02d]: first_chunk=%.1f ms%@", idx, firstChunkMs, comparison))
        }
    }

    func testFirstChunkLatencyLongPrompts() throws {
        guard let pipeline = Self.pipeline else {
            // TODO(removal-cond: XTTSCoreMLPipeline initializer succeeds without runtime model conversion prerequisite)
            throw XCTSkip("CoreML pipeline not available")
        }

        let longPrompts = [
            (22, "I've run a full diagnostic sweep across all primary and secondary systems. Structural integrity is at one hundred percent. Power distribution is optimal. Communications array is fully operational, with no signal interference detected. Navigation subsystems are aligned and calibrated. Weapons systems remain in standby mode, awaiting your command, sir."),
        ]

        for (idx, text) in longPrompts {
            var firstChunkMs = 0.0
            _ = try pipeline.synthesise(text: text, seed: 42) { ms in
                firstChunkMs = ms
            }
            print(String(format: "  Long [%02d]: first_chunk=%.1f ms", idx, firstChunkMs))
            // No hard limit for long prompts; just report
        }
    }

    // MARK: - Latency comparison table

    func testLatencyComparisonTable() throws {
        guard let pipeline = Self.pipeline else {
            // TODO(removal-cond: XTTSCoreMLPipeline initializer succeeds without runtime model conversion prerequisite)
            throw XCTSkip("CoreML pipeline not available")
        }

        guard let data = try? Data(contentsOf: Self.promptsJSON),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let prompts = json["prompts"] as? [[String: Any]] else { return }

        let testPrompts = prompts.filter { p in
            guard let cat = p["cat"] as? String else { return false }
            return ["very_short", "short"].contains(cat)
        }

        print("\n=== Latency Comparison (CoreML vs Oracle) ===")
        print(String(format: "%-4s %-20s %-8s %-12s %-12s", "idx", "name", "words", "coreml_ms", "oracle_ms"))

        var coremlLatencies: [Double] = []

        for prompt in testPrompts {
            guard let idx = prompt["idx"] as? Int,
                  let text = prompt["text"] as? String,
                  let name = prompt["name"] as? String else { continue }

            var fcMs = 0.0
            _ = try pipeline.synthesise(text: text, seed: 42) { ms in
                fcMs = ms
            }
            coremlLatencies.append(fcMs)

            let words = text.split(separator: " ").count
            let oracle = oracleFirstChunkMs(for: idx)
            let oracleStr = oracle > 0 ? String(format: "%.1f", oracle) : "n/a"
            print(String(format: "%-4d %-20s %-8d %-12.1f %-12s",
                         idx, name, words, fcMs, oracleStr))
        }

        let mean = coremlLatencies.reduce(0, +) / Double(max(1, coremlLatencies.count))
        print(String(format: "\nMean CoreML first-chunk: %.1f ms  (oracle baseline: %.1f ms)",
                     mean, Self.oracleBaselineMs))
        print("==============================================\n")
    }

    // MARK: - Helpers

    private func oracleFirstChunkMs(for idx: Int) -> Double {
        guard let data = try? String(contentsOf: Self.oracleTimings),
              !data.isEmpty else { return 0 }
        let rows = data.split(separator: "\n").dropFirst()  // skip header
        for row in rows {
            let cols = row.split(separator: ",").map(String.init)
            guard cols.count > 5, let rowIdx = Int(cols[0]), rowIdx == idx else { continue }
            return Double(cols[5]) ?? 0
        }
        return 0
    }
}
