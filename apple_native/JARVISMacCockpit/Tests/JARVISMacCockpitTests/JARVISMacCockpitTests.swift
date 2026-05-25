import XCTest
@testable import JARVISMacCockpit

final class JARVISMacCockpitTests: XCTestCase {
    @MainActor
    func testCutoverIllegalTransitionsRefuseAndAudit() throws {
        var auditEvents: [[String: String]] = []
        AuditLogger.testSink = { auditEvents.append($0) }
        defer { AuditLogger.testSink = nil }

        let organ = "CharacterValues"
        let model = CutoverViewModel()

        XCTAssertThrowsError(try model.beginShadow(organ))
        XCTAssertEqual(auditEvents.last?["transition"], "Idle→Shadow")
        XCTAssertTrue(auditEvents.last?["reason"]?.contains("preflight") == true)

        XCTAssertThrowsError(try model.commitNative(organ))
        XCTAssertEqual(auditEvents.last?["transition"], "Idle→Committed")
        XCTAssertTrue(auditEvents.last?["reason"]?.contains("Shadow") == true)

        try model.preflight(organ)
        try model.snapshot(organ)
        try model.beginShadow(organ)
        try model.commitNative(organ)
        XCTAssertThrowsError(try model.commitNative(organ))
        XCTAssertEqual(auditEvents.last?["transition"], "Committed→Committed")
        XCTAssertTrue(auditEvents.last?["reason"]?.contains("Shadow") == true)

        XCTAssertThrowsError(try model.abort(organ))
        XCTAssertEqual(auditEvents.last?["transition"], "Committed→Committed")
        XCTAssertTrue(auditEvents.last?["reason"]?.contains("committed") == true)
        XCTAssertGreaterThanOrEqual(auditEvents.count, 4)
    }

    @MainActor
    func testCutoverNilOrganPathsRefuseAndAuditEachAction() throws {
        var auditEvents: [[String: String]] = []
        AuditLogger.testSink = { auditEvents.append($0) }
        defer { AuditLogger.testSink = nil }
        let model = CutoverViewModel()

        XCTAssertThrowsError(try model.preflight(nil))
        XCTAssertThrowsError(try model.snapshot(nil))
        XCTAssertThrowsError(try model.beginShadow(nil))
        XCTAssertThrowsError(try model.commitNative(nil))
        XCTAssertEqual(auditEvents.map { $0["reason"] }, Array(repeating: "organ selection is required", count: 4))
        XCTAssertEqual(auditEvents.map { $0["organ"] }, Array(repeating: "none", count: 4))
    }

    @MainActor
    func testCutoverStateMutationUsesFSMMethods() throws {
        let model = CutoverViewModel()
        XCTAssertEqual(model.organs.first?.state, .idle)
        XCTAssertEqual(model.organs.first?.preflightPassed, false)
        try model.preflight("CharacterValues")
        XCTAssertEqual(model.organs.first?.state, .preflight)
        XCTAssertEqual(model.organs.first?.preflightPassed, true)
    }

    func testRuntimeMountStateAndHUDPlumbing() throws {
        let runtime = try NativeRuntimeBridge()
        let state = try runtime.state()
        XCTAssertEqual(state.runtime, "native-swift-cpp")
        XCTAssertFalse(state.pythonBetaPath)
        XCTAssertTrue(state.mounted)
        XCTAssertNotNil(state.pheromind)
        XCTAssertNotNil(state.swarm)
        XCTAssertNotNil(state.cusum)
        XCTAssertEqual(state.identityContinuity?.ok, true)
        XCTAssertGreaterThanOrEqual(state.endocrine["cortisol"] ?? -1, 0)
        XCTAssertLessThanOrEqual(state.endocrine["cortisol"] ?? 2, 1)
    }

    func testPrepareCommitUpdatesStateAndAuditMountSurvives() throws {
        let runtime = try NativeRuntimeBridge()
        let prepared = try runtime.prepareTurn("status check")
        XCTAssertTrue(prepared.ok)
        XCTAssertTrue(prepared.state.mounted)
        let committed = try runtime.commitTurn(text: "status check", reply: "Runtime mounted. Standing by.", model: prepared.model)
        XCTAssertTrue(committed.ok)
        XCTAssertEqual(committed.state.historyCount, 1)
        XCTAssertTrue(committed.state.mounted)
        XCTAssertGreaterThanOrEqual(committed.state.pheromind?.volatility ?? -1, 0)
    }

    func testAuditLogShape() throws {
        let runtime = try NativeRuntimeBridge()
        let audit = try runtime.auditLog()
        XCTAssertTrue(audit.ok)
        XCTAssertEqual(audit.runtime, "native-swift-cpp")
        XCTAssertFalse(audit.pythonBetaPath)
    }
}

extension JARVISMacCockpitTests {
    func testOperatorMessageStripsPath() {
        // Pre-condition: a CocoaError with an embedded absolute path (typical from
        // FileManager / Data(contentsOf:)) does surface the path in localizedDescription.
        let testPath = "/Users/jarvis/.jarvis/secrets/soul_anchor.key"
        let rawError = CocoaError(.fileReadNoSuchFile, userInfo: [
            NSFilePathErrorKey: testPath,
            NSLocalizedDescriptionKey: "The file \"\(testPath)\" couldn't be opened because there is no such file.",
        ])
        let rawLeak = rawError.localizedDescription
        XCTAssertTrue(rawLeak.contains(testPath), "Pre-condition: raw localizedDescription must contain the injected path")

        // operatorMessage(_:) must NEVER surface a path separator in its output.
        let uiString = operatorMessage(.internalError)
        XCTAssertFalse(uiString.contains("/"), "UI-facing operatorMessage must not contain path separators")
        XCTAssertFalse(uiString.contains(testPath), "UI-facing operatorMessage must not contain the injected path")
        XCTAssertTrue(uiString.contains("INTERNAL_ERROR"), "UI-facing operatorMessage must carry the operator error code")

        // auditDetail(_:) must scrub the path and replace it with a fingerprint token.
        let scrubbed = auditDetail(rawLeak)
        XCTAssertFalse(scrubbed.contains(testPath), "auditDetail must not pass raw path through")
        XCTAssertTrue(scrubbed.contains("[path:"), "auditDetail must replace path with [path:<fp>] token")

        // sha256prefix8 must produce exactly 8 hex characters.
        let fp = sha256prefix8(testPath)
        XCTAssertEqual(fp.count, 8)
        XCTAssertTrue(fp.allSatisfy { $0.isHexDigit }, "Fingerprint must be hex")

        // auditDetail with unredacted:true must return the string verbatim.
        let verbatim = auditDetail(rawLeak, unredacted: true)
        XCTAssertEqual(verbatim, rawLeak, "unredacted: true must return the string unchanged")
    }
}

extension JARVISMacCockpitTests {
    func testUpstreamErrorAuditPersistsOnlyCorrelationTimestampOutcome() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/test-artifacts/upstream-audit", isDirectory: true)
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        setenv("JARVIS_AUDIT_ROOT", root.path, 1)
        defer { unsetenv("JARVIS_AUDIT_ROOT") }
        let correlation = NativeUpstreamErrorAudit.record(client: "model", url: try XCTUnwrap(URL(string: "https://example.invalid/path")), status: 503, body: Data("secret-body".utf8))
        let data = try Data(contentsOf: root.appendingPathComponent("upstream_errors.jsonl"))
        let line = try XCTUnwrap(String(data: data, encoding: .utf8)?.split(separator: "\n").last)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(String(line).utf8)) as? [String: Any])
        XCTAssertEqual(object["correlation_id"] as? String, correlation)
        XCTAssertEqual(object["outcome_enum"] as? String, "UPSTREAM_5XX")
        XCTAssertNotNil(object["timestamp_unix"])
        XCTAssertNil(object["host"])
        XCTAssertNil(object["status"])
        XCTAssertNil(object["body_b64"])
        XCTAssertNil(object["client"])
    }
}
