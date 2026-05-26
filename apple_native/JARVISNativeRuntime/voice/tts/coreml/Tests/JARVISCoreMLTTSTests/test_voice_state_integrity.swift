// test_voice_state_integrity.swift — V4R R8 loadtime SHA verification
//
// Verifies that XTTSCoreMLPipeline.loadVoiceState refuses to project bytes
// when the on-disk voice_state.bin diverges from the operator-attested SHA-256.
// Closes the tamper window surfaced by V4R R5 ATP between the C++ mount
// tripwire and the Swift Float projection.
//
// The real voice_state.bin is NEVER written by this test — only read for SHA
// seeding. The tampered copy lives in /tmp and is unlinked in tearDown.

import XCTest
import CryptoKit
import Foundation
@_spi(Testing) @testable import JARVISCoreMLTTS

final class VoiceStateIntegrityTests: XCTestCase {

    static let modelDir = URL(fileURLWithPath:
        "/Users/rbhanson/research/jarvis/apple_native/JARVISNativeRuntime/voice/tts/coreml/models")

    var tamperedBinURL: URL?

    override func tearDown() {
        if let url = tamperedBinURL {
            try? FileManager.default.removeItem(at: url)
            tamperedBinURL = nil
        }
        super.tearDown()
    }

    /// Helper: read real voice_state.bin, compute true SHA, copy to /tmp, flip one byte.
    /// Returns (tamperedBinURL, jsonURL, trueSHA). Bails via XCTSkip if fixture missing.
    private func makeTamperedFixture() throws -> (binURL: URL, jsonURL: URL, expectedSHA: String) {
        let realBin = Self.modelDir.appendingPathComponent("voice_state.bin")
        let realJSON = Self.modelDir.appendingPathComponent("voice_state.json")
        guard FileManager.default.fileExists(atPath: realBin.path),
              FileManager.default.fileExists(atPath: realJSON.path) else {
            throw XCTSkip("voice_state fixture not present at \(Self.modelDir.path)")
        }
        let realData = try Data(contentsOf: realBin)
        let trueSHA = SHA256.hash(data: realData).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(trueSHA.count, 64, "SHA-256 hex must be 64 chars")

        var tampered = realData
        // Flip a byte well past any header alignment to maximize cache-line distance from any reasonable mmap boundary.
        let flipIndex = tampered.count / 2
        tampered[flipIndex] ^= 0xFF
        XCTAssertNotEqual(tampered, realData)

        let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("v4r_r8_tampered_voice_state_\(getpid())_\(UUID().uuidString).bin")
        try tampered.write(to: tmpURL)
        tamperedBinURL = tmpURL
        return (tmpURL, realJSON, trueSHA)
    }

    // MARK: - Integrity rejection

    func testLoadVoiceStateRejectsTamperedFile() throws {
        let fixture = try makeTamperedFixture()

        var capturedEvents: [(String, [String: String])] = []
        let auditor: (String, [String: String]) -> Void = { event, fields in
            capturedEvents.append((event, fields))
        }

        XCTAssertThrowsError(
            try XTTSCoreMLPipeline.loadVoiceState(
                binURL: fixture.binURL,
                jsonURL: fixture.jsonURL,
                expectedSHA256Hex: fixture.expectedSHA,
                audit: auditor
            ),
            "loadVoiceState must throw on SHA mismatch"
        ) { error in
            guard case CoreMLLoaderError.voiceStateIntegrityMismatch(let exp, let act, _) = error else {
                XCTFail("Expected voiceStateIntegrityMismatch, got \(error)")
                return
            }
            XCTAssertEqual(exp.count, 12, "expected prefix must be 12 hex chars")
            XCTAssertEqual(act.count, 12, "actual prefix must be 12 hex chars")
            XCTAssertNotEqual(exp, act, "prefixes must differ for a real mismatch")
        }

        XCTAssertEqual(capturedEvents.count, 1, "exactly one audit record must be emitted on mismatch")
        guard let (event, fields) = capturedEvents.first else {
            XCTFail("audit record absent")
            return
        }
        XCTAssertEqual(event, "voice_state_loadtime_integrity_mismatch")
        XCTAssertEqual(fields["severity"], "BLOCKER")
        XCTAssertEqual(fields["expected_prefix12"]?.count, 12)
        XCTAssertEqual(fields["actual_prefix12"]?.count, 12)
        XCTAssertNotNil(fields["path"])
        XCTAssertNotNil(fields["size_bytes"])
    }

    // MARK: - Anchor input validation

    func testLoadVoiceStateRejectsEmptyAnchor() throws {
        let realBin = Self.modelDir.appendingPathComponent("voice_state.bin")
        let realJSON = Self.modelDir.appendingPathComponent("voice_state.json")
        guard FileManager.default.fileExists(atPath: realBin.path) else {
            throw XCTSkip("voice_state fixture not present")
        }
        XCTAssertThrowsError(
            try XTTSCoreMLPipeline.loadVoiceState(
                binURL: realBin,
                jsonURL: realJSON,
                expectedSHA256Hex: "",
                audit: nil
            )
        ) { error in
            guard case CoreMLLoaderError.voiceStateAnchorMissing = error else {
                XCTFail("Expected voiceStateAnchorMissing, got \(error)")
                return
            }
        }
    }

    func testLoadVoiceStateRejectsMalformedAnchor() throws {
        let realBin = Self.modelDir.appendingPathComponent("voice_state.bin")
        let realJSON = Self.modelDir.appendingPathComponent("voice_state.json")
        guard FileManager.default.fileExists(atPath: realBin.path) else {
            throw XCTSkip("voice_state fixture not present")
        }
        XCTAssertThrowsError(
            try XTTSCoreMLPipeline.loadVoiceState(
                binURL: realBin,
                jsonURL: realJSON,
                expectedSHA256Hex: "not-a-sha-256",
                audit: nil
            )
        ) { error in
            guard case CoreMLLoaderError.voiceStateAnchorMalformed = error else {
                XCTFail("Expected voiceStateAnchorMalformed, got \(error)")
                return
            }
        }
    }

    // MARK: - Honest match (sanity)

    func testLoadVoiceStateAcceptsMatchingAnchor() throws {
        let realBin = Self.modelDir.appendingPathComponent("voice_state.bin")
        let realJSON = Self.modelDir.appendingPathComponent("voice_state.json")
        guard FileManager.default.fileExists(atPath: realBin.path) else {
            throw XCTSkip("voice_state fixture not present")
        }
        let data = try Data(contentsOf: realBin)
        let trueSHA = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()

        var captured: [(String, [String: String])] = []
        let auditor: (String, [String: String]) -> Void = { e, f in captured.append((e, f)) }

        let result = try XTTSCoreMLPipeline.loadVoiceState(
            binURL: realBin,
            jsonURL: realJSON,
            expectedSHA256Hex: trueSHA,
            audit: auditor
        )
        XCTAssertGreaterThan(result.0.count, 0, "voice cache must be non-empty on honest load")
        XCTAssertGreaterThan(result.1, 0, "voice seqLen must be positive")
        XCTAssertEqual(captured.count, 0, "no audit record should fire on successful match")
    }
}
