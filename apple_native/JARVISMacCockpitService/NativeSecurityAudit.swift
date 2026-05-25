import Foundation

struct NativeSecurityAudit {
    /// Records a security audit event.
    /// Throws on any I/O failure — no silent fallback (AGENTS.md §4).
    /// Per-field string values are bounded to 192 UTF-8 bytes; if the assembled
    /// JSON record still exceeds the §6 PIPE_BUF=512 cap, a degraded record
    /// preserving only event + ts + a `truncated:true` flag is appended so the
    /// audit chain never has a silent gap on attacker-supplied oversized inputs.
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

    private static func boundField(_ value: Any) -> Any {
        guard let s = value as? String else { return value }
        guard let utf8 = s.data(using: .utf8), utf8.count > perFieldByteCap else { return s }
        var cut = perFieldByteCap
        while cut > 0 && (utf8[cut] & 0xC0) == 0x80 { cut -= 1 }
        let head = String(data: utf8.prefix(cut), encoding: .utf8) ?? ""
        return head + "\u{2026}"
    }

    private static func writeLine(_ object: [String: Any], event: String) throws {
        let configuredRoot = ProcessInfo.processInfo.environment["JARVIS_AUDIT_ROOT"]
        let rootPath = NSString(
            string: (configuredRoot?.isEmpty == false ? configuredRoot : "~/.jarvis/audit") ?? "~/.jarvis/audit"
        ).expandingTildeInPath
        let rootURL = URL(fileURLWithPath: rootPath)
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        data.append(0x0A)
        if data.count > recordByteCap {
            // Field-bounding was insufficient (e.g. very many fields). Fall back
            // to a degraded record that preserves chain continuity: event, ts,
            // truncated=true. This is NOT silent fallback (AGENTS.md §2): the
            // record is appended and audit chain stays whole; the diagnostic
            // flag tells the verifier the original payload exceeded §6.
            let degraded: [String: Any] = [
                "event": event,
                "ts": Int(Date().timeIntervalSince1970),
                "truncated": true
            ]
            var degradedData = try JSONSerialization.data(withJSONObject: degraded, options: [.sortedKeys])
            degradedData.append(0x0A)
            try appendBoundedAuditRecord(parentDir: rootURL, file: "network_security.jsonl", record: degradedData)
            return
        }
        try appendBoundedAuditRecord(parentDir: rootURL, file: "network_security.jsonl", record: data)
    }
}
