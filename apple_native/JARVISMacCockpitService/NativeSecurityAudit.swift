import CryptoKit
import Foundation

struct NativeSecurityAudit {
    /// Records a security audit event.
    /// Throws on any I/O failure — no silent fallback (AGENTS.md §4).
    /// Per-field string values are bounded to 192 UTF-8 bytes; if the assembled
    /// JSON record still exceeds the §6 PIPE_BUF=512 cap, a degraded record
    /// preserving only event + ts + a `truncated:true` flag + chain fields is
    /// appended so the audit chain never has a silent gap on attacker-supplied
    /// oversized inputs.
    ///
    /// R11d F-C03: every record carries `prev_sha`, `seq`, and `sha` fields
    /// forming an append-only hash chain. Verifier tool at
    /// JARVISAuditVerifySwift validates chain continuity offline.
    static func record(_ event: String, fields: [String: Any] = [:]) throws {
        var bounded: [String: Any] = [:]
        for (k, v) in fields {
            bounded[k] = boundField(v)
        }
        bounded["event"] = event
        bounded["ts"] = Int(Date().timeIntervalSince1970)
        try writeLine(bounded, event: event)
    }

    private static let perFieldByteCap = 192
    private static let recordByteCap = 512
    static let chainGenesisPrevSha = String(repeating: "0", count: 64)

    private static func boundField(_ value: Any) -> Any {
        guard let s = value as? String else { return value }
        guard let utf8 = s.data(using: .utf8), utf8.count > perFieldByteCap else { return s }
        var cut = perFieldByteCap
        while cut > 0 && (utf8[cut] & 0xC0) == 0x80 { cut -= 1 }
        let head = String(data: utf8.prefix(cut), encoding: .utf8) ?? ""
        return head + "\u{2026}"
    }

    private static func writeLine(_ object: [String: Any], event: String) throws {
        // R11d F-C02: env override gated behind compile flag. Audit modules
        // MUST NOT call NativeInsecurePathOverride.resolve here — that would
        // recurse infinitely (the override audit emission writes through this
        // same writeLine path). Override traces come from sibling-module
        // emissions; the audit module honors the env silently in debug+flag
        // builds and ignores it everywhere else.
        #if DEBUG && JARVIS_INSECURE_PATHS
        let configuredRoot = ProcessInfo.processInfo.environment["JARVIS_AUDIT_ROOT"]
        let rootPath = NSString(
            string: (configuredRoot?.isEmpty == false ? configuredRoot : "~/.jarvis/audit") ?? "~/.jarvis/audit"
        ).expandingTildeInPath
        #else
        let rootPath = NSString(string: "~/.jarvis/audit").expandingTildeInPath
        #endif
        let rootURL = URL(fileURLWithPath: rootPath)
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        try appendChainedAuditRecord(parentDir: rootURL, file: "network_security.jsonl") { priorTail in
            // Step 1: derive chain fields from priorTail.
            let prevSha: String
            let seq: Int
            if let tail = priorTail, !tail.isEmpty {
                let parsed = (try? JSONSerialization.jsonObject(with: tail)) as? [String: Any]
                prevSha = (parsed?["sha"] as? String) ?? chainGenesisPrevSha
                seq = ((parsed?["seq"] as? Int) ?? 0) + 1
            } else {
                prevSha = chainGenesisPrevSha
                seq = 1
            }

            // Step 2: build the chained payload and check its size. If it
            // doesn't fit under 512B with chain fields, degrade — but the
            // degraded record ALSO carries chain fields so the chain stays
            // continuous.
            var payload = object
            payload["prev_sha"] = prevSha
            payload["seq"] = seq

            var preShaData = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            // +newline +sha field = approx +75B. If the prehash record is
            // already > recordByteCap - 75, the final won't fit. Be precise:
            // compute the sha-bearing record, then check.
            let sha = sha256Hex(preShaData)
            payload["sha"] = sha
            var finalData = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            finalData.append(0x0A)

            if finalData.count > recordByteCap {
                // Degrade: event + ts + truncated + chain fields.
                var degraded: [String: Any] = [
                    "event": event,
                    "ts": Int(Date().timeIntervalSince1970),
                    "truncated": true,
                    "prev_sha": prevSha,
                    "seq": seq
                ]
                preShaData = try JSONSerialization.data(withJSONObject: degraded, options: [.sortedKeys])
                degraded["sha"] = sha256Hex(preShaData)
                finalData = try JSONSerialization.data(withJSONObject: degraded, options: [.sortedKeys])
                finalData.append(0x0A)
            }

            return finalData
        }
    }

    private static func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
