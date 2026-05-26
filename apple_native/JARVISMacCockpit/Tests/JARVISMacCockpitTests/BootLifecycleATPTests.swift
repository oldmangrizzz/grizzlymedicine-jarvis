// BootLifecycleATPTests — V4R R11 (Adversarial Test Protocol)
//
// Pre-ceremony red-team coverage for the boot lifecycle. These tests find
// fracture points the operator should not have to discover during first
// awakening. New file — does not pollute the R10-sealed BootLifecycleSmoke.
//
// Coverage matrix in BootLifecycleATPTests.coverageNote().

import XCTest
import Foundation
@testable import JARVISMacCockpit

final class BootLifecycleATPTests: XCTestCase {

    // MARK: - Helpers

    /// Build a fresh tracker that writes its timings to a temp dir so tests
    /// do not stomp ~/.jarvis state.
    private func makeTracker(captureAudit: Bool = false) -> (BootLifecycleTracker, URL, AuditCapture) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("atp-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let timingsPath = dir.appendingPathComponent("boot_timings.json").path
        let capture = AuditCapture()
        let captureRef = capture
        let sink: (@Sendable (String, [String: Any]) -> Void)? = captureAudit
            ? { @Sendable event, fields in captureRef.record(event: event, fields: fields) }
            : nil
        let tracker = BootLifecycleTracker(timingsPath: timingsPath, auditSink: sink)
        return (tracker, dir, capture)
    }

    final class AuditCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [(String, [String: Any])] = []
        func record(event: String, fields: [String: Any]) {
            lock.lock(); defer { lock.unlock() }
            events.append((event, fields))
        }
        func snapshot() -> [(String, [String: Any])] {
            lock.lock(); defer { lock.unlock() }
            return events
        }
        func names() -> [String] { snapshot().map { $0.0 } }
    }

    // ================================================================
    // ATP-1: BOOT LIFECYCLE STATE MACHINE
    // ================================================================

    /// ATP-1(a): markReady() called before any compile events should NOT
    /// destroy compiled byte count. Tracker accepts out-of-order calls,
    /// snapshot should remain coherent (no negative bytes, isReady flips
    /// true exactly when markReady fires).
    func test_ATP1_a_outOfOrderReadyBeforeCompile() async {
        let (tracker, dir, _) = makeTracker()
        defer { try? FileManager.default.removeItem(at: dir) }
        await tracker.markReady(totalWallMs: 1000)
        let snap = await tracker.snapshot()
        XCTAssertTrue(snap.isReady, "ATP-1(a): markReady should still flip isReady true")
        XCTAssertEqual(snap.phase, .ready, "ATP-1(a): phase should be .ready")
        XCTAssertGreaterThanOrEqual(snap.bytesCompiled, 0, "ATP-1(a): bytesCompiled must never be negative")
        // FINDING: no monotonicity enforcement — markReady accepted without compile sequence.
        // This is documented as INFORMATIONAL (sink contract is the boundary, tracker is
        // intentionally permissive). Regression catch is here.
    }

    /// ATP-1(d) — F-01 REMEDIATED: failure() after ready() is now rejected
    /// by the monotonicity guard. ready is a one-way latch.
    func test_ATP1_d_failureAfterReady() async {
        let (tracker, dir, capture) = makeTracker(captureAudit: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        await tracker.markReady(totalWallMs: 1000)
        await tracker.markFailed(stage: "post_ready", reason: "anomaly")
        let snap = await tracker.snapshot()
        // F-01 fix: post-ready failure must be rejected, lifecycle stays ready.
        XCTAssertEqual(snap.phase, .ready, "F-01: phase must remain .ready after post-ready failure")
        XCTAssertTrue(snap.isReady, "F-01: isReady must remain true after post-ready failure")
        XCTAssertNil(snap.failure, "F-01: failure field must NOT be populated by a rejected event")
        // Audit must still capture the rejection so it stays diagnosable.
        let names = capture.names()
        XCTAssertTrue(names.contains("boot_lifecycle_post_ready_failure_rejected"),
            "F-01: rejection must emit audit event. Got: \(names)")
    }

    /// ATP-1(e): Tracker queried before any phase reported — must not crash.
    func test_ATP1_e_snapshotBeforeAnyReport() async {
        let (tracker, dir, _) = makeTracker()
        defer { try? FileManager.default.removeItem(at: dir) }
        let snap = await tracker.snapshot()
        XCTAssertEqual(snap.phase, .coldStart, "ATP-1(e): default phase is coldStart")
        XCTAssertFalse(snap.isReady, "ATP-1(e): default isReady is false")
        XCTAssertEqual(snap.phaseIndex, 0)
    }

    /// ATP-1(f): Concurrent reporters racing — tracker is an actor, so writes
    /// serialize. Verify no snapshot returns a partial state.
    func test_ATP1_f_concurrentReportersAreSerialized() async {
        let (tracker, dir, _) = makeTracker()
        defer { try? FileManager.default.removeItem(at: dir) }
        await tracker.recordColdStart(modelsRoot: nil, totalBytes: 1000)
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<50 {
                group.addTask {
                    await tracker.recordCompileStart(name: "text_encoder", index: 1, total: 3, cacheWasCurrent: i % 2 == 0)
                }
                group.addTask {
                    await tracker.recordCompileDone(name: "text_encoder", index: 1, total: 3, cacheWasCurrent: true, modelBytes: 100)
                }
            }
        }
        let snap = await tracker.snapshot()
        XCTAssertEqual(snap.compile?.modelName, "text_encoder")
        XCTAssertGreaterThanOrEqual(snap.bytesCompiled, 0)
        XCTAssertLessThanOrEqual(snap.bytesCompiled, snap.bytesTotal,
            "ATP-1(f): bytesCompiled must be capped at bytesTotal under race")
    }

    /// ATP-1(g): elapsed_ms must never be negative even if monotonic-ish
    /// computation hits a clock skew (Date()-Date() can go negative on
    /// system clock jump back).
    func test_ATP1_g_elapsedMsNonNegativeContract() async {
        let (tracker, dir, _) = makeTracker()
        defer { try? FileManager.default.removeItem(at: dir) }
        await tracker.recordColdStart(modelsRoot: nil, totalBytes: 1000)
        let snap = await tracker.snapshot()
        // Cannot induce clock-jump in unit test, but contract is: elapsed_ms >= 0.
        // FINDING ATP-1(g) LOW: tracker uses wall-clock Date() not monotonic clock.
        // A system clock jump backward during boot would yield negative elapsed_ms.
        // BootSnapshot.elapsedMs is Int — would render as "-7:23 remaining" in UI.
        XCTAssertGreaterThanOrEqual(snap.elapsedMs, 0, "ATP-1(g): elapsed_ms must not be negative")
    }

    /// ATP-1(h) — F-02 REMEDIATED: hostile samples (negative, huge) are
    /// filtered before median; only sane survivors contribute to the ETA.
    func test_ATP1_h_hostileEtaIsSanitized() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("atp-eta-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("boot_timings.json").path
        // Mix: -5000 (negative, drop), 2147483000 (huge, drop), 60000 (sane, keep).
        let hostile = """
        {
          "version": 1,
          "max_samples": 5,
          "samples": [
            {"unix": 100, "wall_ms": -5000, "cache_was_current_count": 0, "models_total": 3},
            {"unix": 200, "wall_ms": 2147483000, "cache_was_current_count": 0, "models_total": 3},
            {"unix": 300, "wall_ms": 60000, "cache_was_current_count": 0, "models_total": 3}
          ]
        }
        """
        try hostile.write(toFile: path, atomically: true, encoding: .utf8)
        let tracker = BootLifecycleTracker(timingsPath: path)
        let exp = expectation(description: "snapshot")
        Task {
            let snap = await tracker.snapshot()
            // F-02: hostile samples dropped, only 60000 survives → median = 60000.
            XCTAssertEqual(snap.etaHintMs, 60000, "F-02: only sane sample (60000) should survive")
            XCTAssertEqual(snap.etaSource, "rolling_median_1", "F-02: source must report survivor count honestly")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5.0)
    }

    /// ATP-1(h) — F-02 corollary: all samples hostile → fall back to
    /// no_prior_estimate, not a crash, not a poisoned median.
    func test_ATP1_h_allHostileEtaFallsBackCleanly() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("atp-eta-allbad-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("boot_timings.json").path
        let allBad = """
        {
          "version": 1,
          "max_samples": 5,
          "samples": [
            {"unix": 100, "wall_ms": -1, "cache_was_current_count": 0, "models_total": 3},
            {"unix": 200, "wall_ms": 999999999, "cache_was_current_count": 0, "models_total": 3}
          ]
        }
        """
        try allBad.write(toFile: path, atomically: true, encoding: .utf8)
        let tracker = BootLifecycleTracker(timingsPath: path)
        let exp = expectation(description: "snapshot")
        Task {
            let snap = await tracker.snapshot()
            XCTAssertNil(snap.etaHintMs, "F-02: zero survivors → nil eta_hint")
            XCTAssertEqual(snap.etaSource, "no_prior_estimate")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5.0)
    }

    // ================================================================
    // ATP-3: /boot/status PAYLOAD CONTRACT (client-side decode robustness)
    // ================================================================

    /// ATP-3(a,b,c): JSON-shape fuzz against jsonObject() round-trip.
    /// We can't reach iOS BootStatusSnapshot.init?(jsonObject:) from this
    /// macOS test target (it lives in the iOS app), but we can fuzz the
    /// server-side snapshot object that produces the wire payload.
    func test_ATP3_payloadShapeStability() async {
        let (tracker, dir, _) = makeTracker()
        defer { try? FileManager.default.removeItem(at: dir) }
        await tracker.recordColdStart(modelsRoot: nil, totalBytes: 1000)
        let snap = await tracker.snapshot()
        let obj = snap.jsonObject()
        XCTAssertNotNil(obj["phase"])
        XCTAssertNotNil(obj["phase_index"])
        XCTAssertNotNil(obj["phase_total"])
        XCTAssertNotNil(obj["elapsed_ms"])
        XCTAssertNotNil(obj["is_ready"])
        // Optional fields must be present-as-NSNull when nil, never missing key.
        XCTAssertNotNil(obj["eta_hint_ms"], "ATP-3(d): eta_hint_ms key must be present (NSNull when nil)")
        XCTAssertNotNil(obj["model_name"], "ATP-3(a): model_name key must always be present")
        XCTAssertNotNil(obj["failure"], "ATP-3: failure key must always be present (NSNull when nil)")
        // Round-trip through JSONSerialization to catch unencodable types.
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: obj),
            "ATP-3: jsonObject() output must always serialize cleanly")
    }

    // ================================================================
    // ATP-5: OPERATOR PRESENCE
    // ================================================================

    /// ATP-5(a): Symlink — O_NOFOLLOW must reject. Build a temp symlink
    /// pointing at /etc/passwd, point HOME at the temp dir, verify fallback.
    /// We can't easily override HOME mid-test, so we test the read primitive
    /// directly by constructing a parallel function call.
    /// Instead: verify the production path with operator.txt seeded by R10b
    /// returns something allowed-list-compliant.
    func test_ATP5_a_productionReadReturnsCleanString() {
        let name = OperatorPresence.readOperatorName()
        XCTAssertFalse(name.isEmpty)
        XCTAssertLessThanOrEqual(name.count, OperatorPresence.maxBytes)
        // Must match the allow-list (regex equivalent).
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 ._-")
        XCTAssertTrue(name.unicodeScalars.allSatisfy { allowed.contains($0) },
            "ATP-5: returned name must satisfy allow-list")
    }

    /// ATP-5(b): Fallback string is never empty and is allow-list compliant.
    func test_ATP5_b_fallbackIsSafe() {
        XCTAssertFalse(OperatorPresence.fallback.isEmpty)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 ._-")
        XCTAssertTrue(OperatorPresence.fallback.unicodeScalars.allSatisfy { allowed.contains($0) })
    }

    /// ATP-5: max bytes contract — caps at 64.
    func test_ATP5_maxBytesContract() {
        XCTAssertEqual(OperatorPresence.maxBytes, 64,
            "ATP-5: maxBytes is the documented UI cap and a security ceiling. Do not change without policy review.")
    }

    // ================================================================
    // ATP-7: PROCESS / PLATFORM HOSTILES
    // ================================================================

    /// ATP-7(d): Persisted timings file with malformed JSON must NOT crash
    /// tracker init; must fall back to no_prior_estimate.
    func test_ATP7_d_malformedTimingsFileSurvivesInit() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("atp-malformed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("boot_timings.json").path
        try "this is not json {{{".write(toFile: path, atomically: true, encoding: .utf8)
        let tracker = BootLifecycleTracker(timingsPath: path)
        let exp = expectation(description: "snapshot")
        Task {
            let snap = await tracker.snapshot()
            XCTAssertNil(snap.etaHintMs, "ATP-7(d): malformed timings → no eta_hint")
            XCTAssertEqual(snap.etaSource, "no_prior_estimate")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5.0)
    }

    /// ATP-7(d-variant): Empty timings file (truncated mid-write simulation).
    func test_ATP7_d_emptyTimingsFileSurvivesInit() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("atp-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("boot_timings.json").path
        try Data().write(to: URL(fileURLWithPath: path))
        let tracker = BootLifecycleTracker(timingsPath: path)
        let exp = expectation(description: "snapshot")
        Task {
            let snap = await tracker.snapshot()
            XCTAssertNil(snap.etaHintMs)
            XCTAssertEqual(snap.etaSource, "no_prior_estimate")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5.0)
    }

    /// ATP-7: Sample with corrupt sample shape (missing fields) is rejected
    /// without crashing init. Sample-level corruption falls through to
    /// no_prior_estimate.
    func test_ATP7_corruptSampleShapeRejected() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("atp-corrupt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("boot_timings.json").path
        let corrupt = """
        {"version": 1, "max_samples": 5, "samples": [{"missing_required_fields": true}]}
        """
        try corrupt.write(toFile: path, atomically: true, encoding: .utf8)
        let tracker = BootLifecycleTracker(timingsPath: path)
        let exp = expectation(description: "snapshot")
        Task {
            let snap = await tracker.snapshot()
            XCTAssertNil(snap.etaHintMs)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5.0)
    }

    // ================================================================
    // ATP-6: AUDIT TAIL — F-05 REMEDIATION
    // ================================================================

    /// ATP-6(a) — F-05 REMEDIATED: when the audit directory is missing,
    /// readGenesisTailStatic returns a single synthetic audit_unavailable
    /// row instead of [] — so the operator sees an honest "I cannot see
    /// the audit log" instead of a silent blank GENESIS LOG.
    func test_ATP6_a_audit_unavailable_surfacing_unit_only() throws {
        let missingDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("atp-no-such-dir-\(UUID().uuidString)")
            .path
        // Intentionally do NOT create the dir.
        let lines = BootView.readGenesisTailStatic(lineCount: 8, auditRoot: missingDir)
        XCTAssertEqual(lines.count, 1, "F-05: must surface one synthetic row when source is gone")
        XCTAssertEqual(lines.first?.event, "audit_unavailable", "F-05: synthetic row must use audit_unavailable event")
        XCTAssertEqual(lines.first?.id, "audit-unavailable")
        XCTAssertEqual(lines.first?.timestamp, "—")
        XCTAssertTrue(lines.first?.fields.contains("directory missing") == true,
            "F-05: reason must explain the failure honestly")
    }

    /// F-05 corollary: empty dir with no .jsonl files → distinct reason.
    func test_ATP6_a_empty_dir_surfaces_distinct_reason() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("atp-empty-audit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let lines = BootView.readGenesisTailStatic(lineCount: 8, auditRoot: dir.path)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines.first?.event, "audit_unavailable")
        XCTAssertTrue(lines.first?.fields.contains("no jsonl files") == true,
            "F-05: empty dir must produce 'no jsonl files' reason")
    }

    // ================================================================
    // Coverage map
    // ================================================================

    /// Documentation-only: which sub-tests are automated here vs left as
    /// reproduction notes in the ATP findings table.
    static func coverageNote() -> String {
        return """
        Automated:
          ATP-1: a (out-of-order ready), d (failure-after-ready), e (empty queue),
                 f (concurrent serialization), g (elapsed_ms contract),
                 h (hostile eta persistence)
          ATP-3: payload shape stability + round-trip
          ATP-5: a (allow-list compliance), b (fallback safety), maxBytes contract
          ATP-7: d (malformed/empty/corrupt timings file)
        Documentation-only (in findings table):
          ATP-1: b, c (require pipeline-level instrumentation)
          ATP-2: gate bypass (requires HTTP harness; covered by smoke in spirit)
          ATP-3: e–g (HTTP fault injection; needs network harness)
          ATP-4: visual lie audit (static code review, see findings table)
          ATP-5: c–g (require symlink creation/HOME override; not portable in CI)
          ATP-6: audit tail integrity (needs file-rotation simulation)
          ATP-7: a (SIGTERM), b (power loss), c–h (platform hostiles)
        """
    }
}
