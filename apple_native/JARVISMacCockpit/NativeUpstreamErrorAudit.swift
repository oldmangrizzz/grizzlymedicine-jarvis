import Foundation

struct NativeUpstreamErrorAudit {
    static func record(client: String, url: URL, status: Int, body: Data) -> String {
        let correlationID = UUID().uuidString
        append(correlationID: correlationID, outcome: outcomeEnum(status: status))
        return correlationID
    }

    private static func outcomeEnum(status: Int) -> String {
        switch status {
        case 500...599: return "UPSTREAM_5XX"
        case 400...499: return "UPSTREAM_INVALID"
        default: return "UPSTREAM_TIMEOUT"
        }
    }

    private static func append(correlationID: String, outcome: String) {
        let object: [String: Any] = [
            "correlation_id": correlationID,
            "timestamp_unix": Int(Date().timeIntervalSince1970),
            "outcome_enum": outcome,
        ]
        writeLine(object)
    }

    private static func writeLine(_ object: [String: Any]) {
        do {
            let configuredRoot = ProcessInfo.processInfo.environment["JARVIS_AUDIT_ROOT"]
            let root = configuredRoot ?? NSString(string: "~/.jarvis/audit").expandingTildeInPath
            try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
            let path = root + "/upstream_errors.jsonl"
            if !FileManager.default.fileExists(atPath: path) {
                FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            data.append(0x0A)
            guard data.count <= 512 else { return }
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            return
        }
    }
}
