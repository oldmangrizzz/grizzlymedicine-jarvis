import Foundation
import XCTest
@testable import JARVISMacCockpit

final class HTTPIPRateLimitRestartTests: XCTestCase {
    private let failureWindowSeconds = 60
    private let lockoutDurationSeconds = 5 * 60

    func testFailureCountSurvivesRestart() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/test-artifacts/http-ip-ratelimit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let failuresStore = root.appendingPathComponent("http_auth_failures.jsonl")
        let lockoutsStore = root.appendingPathComponent("http_auth_lockouts.jsonl")
        let auditRoot = root.appendingPathComponent("audit", isDirectory: true)
        setenv("JARVIS_HTTP_AUTH_FAILURES_STORE", failuresStore.path, 1)
        setenv("JARVIS_HTTP_AUTH_LOCKOUTS_STORE", lockoutsStore.path, 1)
        setenv("JARVIS_AUDIT_ROOT", auditRoot.path, 1)
        defer {
            unsetenv("JARVIS_HTTP_AUTH_FAILURES_STORE")
            unsetenv("JARVIS_HTTP_AUTH_LOCKOUTS_STORE")
            unsetenv("JARVIS_AUDIT_ROOT")
        }

        let configuration = NativeRuntimeHTTPServiceConfiguration(host: "127.0.0.1", port: 8788, companionToken: "test-token", allowNonLoopback: false)
        
        let firstHandler = try NativeRuntimeHTTPHandler()
        for _ in 1...4 {
            let response = await firstHandler.handle(badAuthRequest(), configuration: configuration)
            XCTAssertEqual(response.statusCode, 401, "auth failure should return 401")
        }
        
        let restartedHandler = try NativeRuntimeHTTPHandler()
        let fifthFailure = await restartedHandler.handle(badAuthRequest(), configuration: configuration)
        XCTAssertEqual(fifthFailure.statusCode, 401, "fifth failure should return 401")
        
        let lockedRequest = await restartedHandler.handle(badAuthRequest(), configuration: configuration)
        XCTAssertEqual(lockedRequest.statusCode, 429, "sixth failure should trigger lockout with 429")
        XCTAssertTrue(responseText(lockedRequest).contains("rate_limited"))
    }

    func testLockoutSurvivesRestart() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/test-artifacts/http-ip-lockout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let failuresStore = root.appendingPathComponent("http_auth_failures.jsonl")
        let lockoutsStore = root.appendingPathComponent("http_auth_lockouts.jsonl")
        let auditRoot = root.appendingPathComponent("audit", isDirectory: true)
        setenv("JARVIS_HTTP_AUTH_FAILURES_STORE", failuresStore.path, 1)
        setenv("JARVIS_HTTP_AUTH_LOCKOUTS_STORE", lockoutsStore.path, 1)
        setenv("JARVIS_AUDIT_ROOT", auditRoot.path, 1)
        defer {
            unsetenv("JARVIS_HTTP_AUTH_FAILURES_STORE")
            unsetenv("JARVIS_HTTP_AUTH_LOCKOUTS_STORE")
            unsetenv("JARVIS_AUDIT_ROOT")
        }

        let configuration = NativeRuntimeHTTPServiceConfiguration(host: "127.0.0.1", port: 8788, companionToken: "test-token", allowNonLoopback: false)
        
        let firstHandler = try NativeRuntimeHTTPHandler()
        for _ in 1...5 {
            let response = await firstHandler.handle(badAuthRequest(), configuration: configuration)
            XCTAssertTrue(response.statusCode == 401 || response.statusCode == 429, "failures should return 401 or trigger 429")
        }
        
        let restartedHandler = try NativeRuntimeHTTPHandler()
        let lockedRequest = await restartedHandler.handle(goodAuthRequest(), configuration: configuration)
        XCTAssertEqual(lockedRequest.statusCode, 429, "lockout should persist after restart")
        XCTAssertTrue(responseText(lockedRequest).contains("rate_limited"))
        let text = responseText(lockedRequest)
        XCTAssertTrue(text.contains("\"receipt\":\"native-http-auth-rate-limited\""))
    }

    func testExpiredFailuresPruned() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/test-artifacts/http-ip-expired-failures-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let failuresStore = root.appendingPathComponent("http_auth_failures.jsonl")
        let lockoutsStore = root.appendingPathComponent("http_auth_lockouts.jsonl")
        let auditRoot = root.appendingPathComponent("audit", isDirectory: true)
        setenv("JARVIS_HTTP_AUTH_FAILURES_STORE", failuresStore.path, 1)
        setenv("JARVIS_HTTP_AUTH_LOCKOUTS_STORE", lockoutsStore.path, 1)
        setenv("JARVIS_AUDIT_ROOT", auditRoot.path, 1)
        defer {
            unsetenv("JARVIS_HTTP_AUTH_FAILURES_STORE")
            unsetenv("JARVIS_HTTP_AUTH_LOCKOUTS_STORE")
            unsetenv("JARVIS_AUDIT_ROOT")
        }

        let now = Int(Date().timeIntervalSince1970)
        let staleFailure = now - (failureWindowSeconds + 10)
        try writeFailureRecords(to: failuresStore, records: [("127.0.0.1", staleFailure)])
        
        let configuration = NativeRuntimeHTTPServiceConfiguration(host: "127.0.0.1", port: 8788, companionToken: "test-token", allowNonLoopback: false)
        let handler = try NativeRuntimeHTTPHandler()
        
        for _ in 1...4 {
            let response = await handler.handle(badAuthRequest(), configuration: configuration)
            XCTAssertEqual(response.statusCode, 401, "should return 401, stale failure pruned")
        }
        
        let fifthRequest = await handler.handle(badAuthRequest(), configuration: configuration)
        XCTAssertEqual(fifthRequest.statusCode, 401, "fifth failure without stale data should return 401, not trigger lockout")
    }

    func testExpiredLockoutsPruned() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/test-artifacts/http-ip-expired-lockouts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let failuresStore = root.appendingPathComponent("http_auth_failures.jsonl")
        let lockoutsStore = root.appendingPathComponent("http_auth_lockouts.jsonl")
        let auditRoot = root.appendingPathComponent("audit", isDirectory: true)
        setenv("JARVIS_HTTP_AUTH_FAILURES_STORE", failuresStore.path, 1)
        setenv("JARVIS_HTTP_AUTH_LOCKOUTS_STORE", lockoutsStore.path, 1)
        setenv("JARVIS_AUDIT_ROOT", auditRoot.path, 1)
        defer {
            unsetenv("JARVIS_HTTP_AUTH_FAILURES_STORE")
            unsetenv("JARVIS_HTTP_AUTH_LOCKOUTS_STORE")
            unsetenv("JARVIS_AUDIT_ROOT")
        }

        let now = Int(Date().timeIntervalSince1970)
        let expiredLockout = now - 10
        try writeLockoutRecords(to: lockoutsStore, records: [("127.0.0.1", expiredLockout)])
        
        let configuration = NativeRuntimeHTTPServiceConfiguration(host: "127.0.0.1", port: 8788, companionToken: "test-token", allowNonLoopback: false)
        let handler = try NativeRuntimeHTTPHandler()
        
        let response = await handler.handle(goodAuthRequest(), configuration: configuration)
        XCTAssertEqual(response.statusCode, 200, "expired lockout should be pruned, request should succeed")
    }

    func testStoreAppendFailureReturns503() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/test-artifacts/http-ip-store-503-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let failuresStore = root.appendingPathComponent("http_auth_failures.jsonl")
        let auditRoot = root.appendingPathComponent("audit", isDirectory: true)
        setenv("JARVIS_HTTP_AUTH_FAILURES_STORE", failuresStore.path, 1)
        setenv("JARVIS_AUDIT_ROOT", auditRoot.path, 1)
        defer {
            unsetenv("JARVIS_HTTP_AUTH_FAILURES_STORE")
            unsetenv("JARVIS_AUDIT_ROOT")
        }

        let configuration = NativeRuntimeHTTPServiceConfiguration(host: "127.0.0.1", port: 8788, companionToken: "test-token", allowNonLoopback: false)
        let handler = try NativeRuntimeHTTPHandler()
        
        try Data().write(to: failuresStore)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: failuresStore.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: failuresStore.path)
        }
        
        let response = await handler.handle(badAuthRequest(), configuration: configuration)
        XCTAssertEqual(response.statusCode, 503, "append failure should return 503")
        let text = responseText(response)
        XCTAssertTrue(text.contains("\"receipt\":\"native-http-auth-store-unavailable\""))
    }

    func testRecordSizeUnder512Bytes() throws {
        let ip = String(repeating: "a", count: 100)
        let now = Int(Date().timeIntervalSince1970)
        
        let failureObject: [String: Any] = ["event": "auth_fail", "ip": ip, "observed_unix": now]
        let failureData = try JSONSerialization.data(withJSONObject: failureObject, options: [.sortedKeys])
        XCTAssertLessThanOrEqual(failureData.count + 1, 512, "failure record with newline must be ≤512 bytes")
        
        let lockoutObject: [String: Any] = ["event": "locked", "ip": ip, "until_unix": now]
        let lockoutData = try JSONSerialization.data(withJSONObject: lockoutObject, options: [.sortedKeys])
        XCTAssertLessThanOrEqual(lockoutData.count + 1, 512, "lockout record with newline must be ≤512 bytes")
    }

    private func badAuthRequest() -> NativeHTTPRequest {
        NativeHTTPRequest(
            method: "GET",
            target: "/companion/skills",
            headers: [
                "host": "127.0.0.1:8788",
                "x-jarvis-companion-token": "wrong-token",
            ],
            body: Data(),
            remoteIP: "127.0.0.1"
        )
    }

    private func goodAuthRequest() -> NativeHTTPRequest {
        NativeHTTPRequest(
            method: "GET",
            target: "/companion/manifest",
            headers: [
                "host": "127.0.0.1:8788",
            ],
            body: Data(),
            remoteIP: "127.0.0.1"
        )
    }

    private func writeFailureRecords(to url: URL, records: [(String, Int)]) throws {
        let lines = try records.map { ip, observedAtUnix -> String in
            let data = try JSONSerialization.data(withJSONObject: ["event": "auth_fail", "ip": ip, "observed_unix": observedAtUnix], options: [.sortedKeys])
            return String(decoding: data, as: UTF8.self)
        }.joined(separator: "\n") + "\n"
        try Data(lines.utf8).write(to: url)
    }

    private func writeLockoutRecords(to url: URL, records: [(String, Int)]) throws {
        let lines = try records.map { ip, untilUnix -> String in
            let data = try JSONSerialization.data(withJSONObject: ["event": "locked", "ip": ip, "until_unix": untilUnix], options: [.sortedKeys])
            return String(decoding: data, as: UTF8.self)
        }.joined(separator: "\n") + "\n"
        try Data(lines.utf8).write(to: url)
    }

    private func responseText(_ response: NativeHTTPResponse) -> String {
        String(data: response.body, encoding: .utf8) ?? ""
    }
}
