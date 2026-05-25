import Foundation

public struct CompositeDialogAuditSink: DialogAuditSink {
    private let sinks: [any DialogAuditSink]

    public init(_ sinks: [any DialogAuditSink]) {
        self.sinks = sinks
    }

    public func append(_ event: DialogAuditEvent) throws {
        for sink in sinks {
            try sink.append(event)
        }
    }
}

public struct RedactingLoggerDialogAuditSink: DialogAuditSink {
    private let emit: @Sendable (_ subsystem: String, _ event: String, _ fields: [String: String]) -> Void

    public init(emit: @escaping @Sendable (_ subsystem: String, _ event: String, _ fields: [String: String]) -> Void) {
        self.emit = emit
    }

    public func append(_ event: DialogAuditEvent) throws {
        var fields = event.metadata
        fields["rule"] = event.rule.rawValue
        fields["rule_number"] = String(event.rule.number)
        fields["disposition"] = event.disposition.rawValue
        fields["reason"] = event.reason
        fields["input_digest"] = event.inputDigest
        emit("dialog", "dialog.policy.decision", fields)
    }
}

public struct TamperEvidentDialogAuditSink: DialogAuditSink {
    private let appendRedactedEventJSON: @Sendable (String) throws -> Void

    public init(appendRedactedEventJSON: @escaping @Sendable (String) throws -> Void) {
        self.appendRedactedEventJSON = appendRedactedEventJSON
    }

    public func append(_ event: DialogAuditEvent) throws {
        let data = try JSONEncoder().encode(event)
        guard let json = String(data: data, encoding: .utf8) else { return }
        try appendRedactedEventJSON(json)
    }
}
