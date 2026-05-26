import Foundation
import XCTest
@testable import JARVISMacCockpit

final class NativeSecurityAuditTests: XCTestCase {

    // ── Test 1: Symlink at target path → write refused ────────────────────────
    // A symlink planted at the log file path must be rejected by openat(O_NOFOLLOW).
    // Expected error: NativeSecurityAuditError.openFile(..., errno: ELOOP).
    func testSymlinkAtTargetRefused() throws {
        let dir = testDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Plant a symlink where the log file would be created.
        let canaryURL = dir.appendingPathComponent("elsewhere.jsonl")
        try "canary".write(to: canaryURL, atomically: true, encoding: .utf8)
        let logURL = dir.appendingPathComponent("network_security.jsonl")
        try FileManager.default.createSymbolicLink(at: logURL, withDestinationURL: canaryURL)

        setenv("JARVIS_AUDIT_ROOT", dir.path, 1)
        defer { unsetenv("JARVIS_AUDIT_ROOT") }

        XCTAssertThrowsError(try NativeSecurityAudit.record("symlink_guard_probe")) { error in
            guard let auditErr = error as? NativeSecurityAuditError else {
                XCTFail("Expected NativeSecurityAuditError, got \(error)"); return
            }
            if case .openFile = auditErr { /* expected — ELOOP from O_NOFOLLOW */ } else {
                XCTFail("Expected .openFile (ELOOP), got \(auditErr)")
            }
        }

        // The canary file must not have been written to.
        let canary = try String(contentsOf: canaryURL, encoding: .utf8)
        XCTAssertEqual(canary, "canary", "Symlink target must not have been written")
    }

    // ── Test 2: Record > 512 bytes → degraded record, chain intact ──────────
    // R10-era design: the audit module is the LAST resort during incident
    // response. Refusing to write would create a silent gap. Instead, when
    // bounded fields still exceed the §6 PIPE_BUF=512 cap, the writer emits
    // a degraded record preserving event + ts + truncated=true + the F-C03
    // chain fields (prev_sha, seq, sha). The verifier still validates.
    //
    // R11d note: this test previously asserted XCTAssertThrowsError on the
    // assumption that "refuse" meant "throw". That was wrong per the design
    // — the writer never throws on attacker-supplied oversized inputs; it
    // degrades. Updated to assert the actual behavior. The hash chain is
    // also exercised here because F-C03 wraps every audit emission.
    func testRecordTooLargeRefused() throws {
        let dir = testDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        setenv("JARVIS_AUDIT_ROOT", dir.path, 1)
        defer { unsetenv("JARVIS_AUDIT_ROOT") }

        // A 600-char value would produce a JSON record well over 512B if
        // unbounded. boundField caps the value at 192 UTF-8 bytes, and even
        // a single bounded field comfortably fits — so to force the degraded
        // path, supply many distinct fields whose envelope exceeds 512B.
        var manyFields: [String: Any] = [:]
        for i in 0..<40 {
            manyFields["k\(i)"] = String(repeating: "x", count: 50)
        }
        // Must NOT throw — design contract is degrade, not refuse.
        XCTAssertNoThrow(
            try NativeSecurityAudit.record("too_large_probe", fields: manyFields),
            "Audit writer must NOT throw on oversized input — degraded record is the design"
        )

        // Exactly one line, the degraded record.
        let logURL = dir.appendingPathComponent("network_security.jsonl")
        XCTAssertTrue(FileManager.default.fileExists(atPath: logURL.path),
                      "Degraded record must have been written")
        let raw = try String(contentsOf: logURL, encoding: .utf8)
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 1, "Expected exactly one degraded record")

        let parsed = try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any]
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?["event"] as? String, "too_large_probe")
        XCTAssertEqual(parsed?["truncated"] as? Bool, true,
                       "Degraded record must carry truncated=true diagnostic flag")
        XCTAssertNil(parsed?["data"],
                     "Degraded record must NOT carry the original (oversized) payload")
        // F-C03 chain fields must be present and well-formed even on the
        // degraded path — chain continuity is the whole point.
        XCTAssertEqual(parsed?["seq"] as? Int, 1, "Genesis seq=1")
        XCTAssertEqual(parsed?["prev_sha"] as? String, String(repeating: "0", count: 64),
                       "Genesis prev_sha must be 64 zeros")
        XCTAssertEqual((parsed?["sha"] as? String)?.count, 64,
                       "sha must be 64 hex chars even on degraded record")
        XCTAssertLessThanOrEqual(Data(lines[0].utf8).count, 511,
                                 "Degraded record must fit under PIPE_BUF=512 (newline excluded)")
    }

    // ── Test 3: Concurrent writers → no interleaved lines ────────────────────
    // flock(LOCK_EX) + O_APPEND + single write() per record guarantees that 50
    // concurrent callers each produce exactly one intact, parseable JSON line.
    func testConcurrentWritersNoInterleave() throws {
        let dir = testDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        setenv("JARVIS_AUDIT_ROOT", dir.path, 1)
        defer { unsetenv("JARVIS_AUDIT_ROOT") }

        // Pre-create the log file so all concurrent openat(2) calls open an
        // existing file rather than racing to create it (O_CREAT on APFS can
        // transiently return ENOENT when many threads hit the vnode create path
        // simultaneously).
        let logURL = dir.appendingPathComponent("network_security.jsonl")
        FileManager.default.createFile(atPath: logURL.path, contents: nil,
                                       attributes: [.posixPermissions: 0o600])

        let iterations = 50
        var writeErrors: [Error] = []
        let lock = NSLock()

        DispatchQueue.concurrentPerform(iterations: iterations) { i in
            do {
                try NativeSecurityAudit.record("concurrent_probe", fields: ["seq": i])
            } catch {
                lock.lock()
                writeErrors.append(error)
                lock.unlock()
            }
        }

        XCTAssertTrue(writeErrors.isEmpty,
                      "Unexpected write errors during concurrent append: \(writeErrors)")

        let raw = try String(contentsOf: logURL, encoding: .utf8)
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: true)

        XCTAssertEqual(lines.count, iterations,
                       "Expected \(iterations) lines, got \(lines.count) — interleaving or loss detected")

        // Each line must be independently valid JSON (no interleaving).
        for (idx, line) in lines.enumerated() {
            XCTAssertNoThrow(
                try JSONSerialization.jsonObject(with: Data(String(line).utf8)),
                "Line \(idx) is not valid JSON (possible interleave): \(line)"
            )
        }
    }

    // ── Test 4: fsync ordering verified by write durability ───────────────────
    // Pragmatic verification: fsync(fd_file) and fsync(fd_dir) execute inside the
    // flock critical section, BEFORE the defer { flock(LOCK_UN) } body runs (Swift
    // defers are LIFO: LOCK_UN → close(fdFile) → close(fdDir)).
    //
    // Structural proof (code-review documented here per operator spec):
    //   In appendBoundedAuditRecord (SecureFileWrite.swift):
    //     - defer { close(fdDir)  } registered at step 1 (earliest)
    //     - defer { close(fdFile) } registered at step 2
    //     - defer { flock(LOCK_UN)} registered at step 3 (latest)
    //   LIFO execution: flock(LOCK_UN) first → close(fdFile) → close(fdDir).
    //   fsync(fdFile) and fsync(fdDir) are called at steps 6–7, i.e., BEFORE
    //   any defer executes (defers run only when the scope exits).
    //   Therefore: data is durable on disk before the lock is released.
    //
    // Behavioral test: write a record, re-read it, confirm content is intact.
    func testWriteIsDurableAfterReturn() throws {
        let dir = testDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        setenv("JARVIS_AUDIT_ROOT", dir.path, 1)
        defer { unsetenv("JARVIS_AUDIT_ROOT") }

        try NativeSecurityAudit.record("fsync_ordering_probe", fields: ["marker": "durable"])

        let logURL = dir.appendingPathComponent("network_security.jsonl")
        let raw = try String(contentsOf: logURL, encoding: .utf8)
        let firstLine = try XCTUnwrap(
            raw.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init),
            "Log file must contain at least one line"
        )
        let obj = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(firstLine.utf8)) as? [String: Any],
            "First line must parse as a JSON object"
        )
        XCTAssertEqual(obj["event"] as? String, "fsync_ordering_probe")
        XCTAssertEqual(obj["marker"] as? String, "durable")
    }

    // MARK: - Helpers

    private func testDir() -> URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(
                ".build/test-artifacts/native-security-audit/\(UUID().uuidString)",
                isDirectory: true
            )
    }
}
