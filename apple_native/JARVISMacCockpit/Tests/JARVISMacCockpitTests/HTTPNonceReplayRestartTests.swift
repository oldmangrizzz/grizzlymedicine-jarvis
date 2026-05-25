import Foundation
import XCTest
@testable import JARVISMacCockpit

final class HTTPNonceReplayRestartTests: XCTestCase {
    private let ttlSeconds = 5 * 60

    func testHTTPNonceRestartReplayUsesPersistedObservedUnixAndRejectsFutureDatedRecords() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/test-artifacts/http-nonce-restart-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let nonceStore = root.appendingPathComponent("http_nonces.jsonl")
        let auditRoot = root.appendingPathComponent("audit", isDirectory: true)
        setenv("JARVIS_HTTP_NONCE_STORE", nonceStore.path, 1)
        setenv("JARVIS_AUDIT_ROOT", auditRoot.path, 1)
        defer {
            unsetenv("JARVIS_HTTP_NONCE_STORE")
            unsetenv("JARVIS_AUDIT_ROOT")
        }

        let configuration = NativeRuntimeHTTPServiceConfiguration(host: "127.0.0.1", port: 8788, companionToken: "test-token", allowNonLoopback: false)
        let timestamp = Int(Date().timeIntervalSince1970)
        let nonceN = "0123456789abcdef0123456789abcdef"

        let firstHandler = try NativeRuntimeHTTPHandler()
        let firstUse = await firstHandler.handle(request(nonce: nonceN, timestamp: timestamp), configuration: configuration)
        XCTAssertEqual(firstUse.statusCode, 200, "first nonce use at logical T=0 should be accepted")

        try writeNonceRecords(to: nonceStore, records: [("\(nonceN):\(timestamp)", timestamp - (ttlSeconds - 30))])
        let restartedAtT30 = try NativeRuntimeHTTPHandler()
        let replayAtT30 = await restartedAtT30.handle(request(nonce: nonceN, timestamp: timestamp), configuration: configuration)
        XCTAssertEqual(replayAtT30.statusCode, 401, "nonce replay after restart inside TTL must be rejected")
        XCTAssertTrue(responseText(replayAtT30).contains("nonce_reuse"))

        try writeNonceRecords(to: nonceStore, records: [("\(nonceN):\(timestamp)", timestamp - (ttlSeconds + 10))])
        let restartedAtT70 = try NativeRuntimeHTTPHandler()
        let nonceM = "fedcba9876543210fedcba9876543210"
        let freshAfterExpiry = await restartedAtT70.handle(request(nonce: nonceM, timestamp: timestamp), configuration: configuration)
        XCTAssertEqual(freshAfterExpiry.statusCode, 200, "fresh nonce after stale persisted state is pruned should be accepted")

        let nonceP = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        try writeNonceRecords(to: nonceStore, records: [("\(nonceP):\(timestamp)", timestamp + 5 * 60)])
        let restartedWithFutureRecord = try NativeRuntimeHTTPHandler()
        let futureDatedReplay = await restartedWithFutureRecord.handle(request(nonce: nonceP, timestamp: timestamp), configuration: configuration)
        XCTAssertEqual(futureDatedReplay.statusCode, 401, "future-dated persisted nonce record must fail closed on matching submit")
        XCTAssertTrue(responseText(futureDatedReplay).contains("nonce_reuse"))
        let auditText = try String(contentsOf: auditRoot.appendingPathComponent("network_security.jsonl"), encoding: .utf8)
        XCTAssertTrue(auditText.contains("http_nonce_store_future_dated"), "future-dated nonce record must be audited")
    }

    private func request(nonce: String, timestamp: Int) -> NativeHTTPRequest {
        NativeHTTPRequest(
            method: "GET",
            target: "/companion/skills",
            headers: [
                "host": "127.0.0.1:8788",
                "x-jarvis-companion-token": "test-token",
                "x-jarvis-nonce": nonce,
                "x-jarvis-timestamp": String(timestamp),
            ],
            body: Data(),
            remoteIP: "127.0.0.1"
        )
    }

    private func writeNonceRecords(to url: URL, records: [(String, Int)]) throws {
        let lines = try records.map { key, observedAtUnix -> String in
            let data = try JSONSerialization.data(withJSONObject: ["key": key, "observed_unix": observedAtUnix], options: [.sortedKeys])
            return String(decoding: data, as: UTF8.self)
        }.joined(separator: "\n") + "\n"
        try Data(lines.utf8).write(to: url)
    }

    private func responseText(_ response: NativeHTTPResponse) -> String {
        String(data: response.body, encoding: .utf8) ?? ""
    }
}
