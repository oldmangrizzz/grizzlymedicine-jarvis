// JARVISLog.swift
// Swift bridge into the C++ RedactingLogger via the C ABI.
//
// IMPORTANT — operator content never goes to OSLog:
//   OSLog entries are readable by system diagnostic tools, crash reporters, and
//   Apple diagnostic uploads.  This file intentionally does NOT use OSLog.
//   All structured logs flow through the C++ ring-buffer logger, which enforces
//   redaction by default for every field defined in SENSITIVE_FIELDS.md.
//
// Usage:
//   // Configure once at launch (optional — defaults are sensible):
//   JARVISLog.configure()
//
//   // Emit a plain INFO entry:
//   JARVISLog.info(subsystem: "runtime", event: "boot",
//                  fields: ["version": "1.0"])
//
//   // Emit an entry with operator-content (automatically redacted unless
//   // the "voice" subsystem has been opted in):
//   JARVISLog.info(subsystem: "voice", event: "utterance",
//                  fields: ["voice_text": transcript])
//
//   // Enable full logging for a specific subsystem (operator must opt in
//   // explicitly at runtime — default is REDACTED):
//   JARVISLog.setSubsystemOptIn("voice", enabled: true)

import Foundation
#if canImport(NativeRuntimeModule)
import NativeRuntimeModule
#endif

// ─── Log level ────────────────────────────────────────────────────────────────

public enum JARVISLogLevel: Int32, Sendable {
    case trace = 0
    case debug = 1
    case info  = 2
    case warn  = 3
    case error = 4
    case fatal = 5

    fileprivate var label: String {
        switch self {
        case .trace: return "TRACE"
        case .debug: return "DEBUG"
        case .info:  return "INFO"
        case .warn:  return "WARN"
        case .error: return "ERROR"
        case .fatal: return "FATAL"
        }
    }
}

// ─── Logger facade ────────────────────────────────────────────────────────────

public enum JARVISLog {

    // ── Configuration ─────────────────────────────────────────────────────────

    /// Configure the logger.  Call once at launch before the first emit.
    /// All parameters are optional; omitting a parameter uses the default.
    ///
    /// - Parameters:
    ///   - logDirectory:     Directory for .jsonl segment files.
    ///                       Default: ~/Library/Logs/JARVIS
    ///   - maxDiskBytes:     Total bytes cap for all segments.
    ///                       Default: 104 857 600 (100 MB)
    ///   - maxSegmentBytes:  Per-file size before rotation.
    ///                       Default: 10 485 760  (10 MB)
    ///   - minLevel:         Minimum level to record.  Default: .trace
    public static func configure(
        logDirectory:    URL?            = nil,
        maxDiskBytes:    UInt64          = 100 * 1024 * 1024,
        maxSegmentBytes: UInt64          = 10  * 1024 * 1024,
        minLevel:        JARVISLogLevel  = .trace
    ) {
        var config: [String: Any] = [
            "max_disk_bytes": maxDiskBytes,
            "max_seg_bytes":  maxSegmentBytes,
            "min_level":      minLevel.label,
        ]
        if let dir = logDirectory {
            config["log_dir"] = dir.path
        }
        guard let data = try? JSONSerialization.data(withJSONObject: config,
                                                      options: []),
              let json = String(data: data, encoding: .utf8) else { return }
        json.withCString { JARVISLog_configure($0) }
    }

    // ── Redaction control ─────────────────────────────────────────────────────

    /// Enable or disable full (un-redacted) logging for a named subsystem.
    ///
    /// DEFAULT: ALL subsystems are redacted.  Opt-in must be explicit.
    /// This decision must be reviewed by the operator before production use.
    public static func setSubsystemOptIn(_ subsystem: String, enabled: Bool) {
        subsystem.withCString {
            JARVISLog_set_subsystem_optin($0, enabled ? 1 : 0)
        }
    }

    // ── Core emit ─────────────────────────────────────────────────────────────

    /// Emit a structured log entry.
    ///
    /// - Parameters:
    ///   - level:      Severity level.
    ///   - subsystem:  Short ASCII label identifying the source component.
    ///   - event:      Machine-readable event identifier.
    ///   - fields:     Key-value pairs.  Values for sensitive field names (see
    ///                 SENSITIVE_FIELDS.md) are redacted unless the subsystem
    ///                 has been explicitly opted in via setSubsystemOptIn(_:enabled:).
    public static func emit(
        _ level:      JARVISLogLevel,
        subsystem:    String,
        event:        String,
        fields:       [String: String] = [:]
    ) {
        guard let data = try? JSONSerialization.data(withJSONObject: fields,
                                                      options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return }
        subsystem.withCString { cSub in
            event.withCString { cEvt in
                json.withCString { cFields in
                    JARVISLog_emit(level.rawValue, cSub, cEvt, cFields)
                }
            }
        }
    }

    /// Emit with mixed-type field values (string, Int, Double, Bool).
    public static func emit(
        _ level:   JARVISLogLevel,
        subsystem: String,
        event:     String,
        fields:    [String: Any]
    ) {
        // Convert all values to String for the string-keyed overload.
        // Numbers and booleans are preserved as JSON literals by passing a
        // non-string Any, which JSONSerialization will handle correctly.
        guard let data = try? JSONSerialization.data(withJSONObject: fields,
                                                      options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return }
        subsystem.withCString { cSub in
            event.withCString { cEvt in
                json.withCString { cFields in
                    JARVISLog_emit(level.rawValue, cSub, cEvt, cFields)
                }
            }
        }
    }

    // ── Convenience level methods ─────────────────────────────────────────────

    public static func trace(subsystem: String, event: String,
                              fields: [String: String] = [:]) {
        emit(.trace, subsystem: subsystem, event: event, fields: fields)
    }

    public static func debug(subsystem: String, event: String,
                              fields: [String: String] = [:]) {
        emit(.debug, subsystem: subsystem, event: event, fields: fields)
    }

    public static func info(subsystem: String, event: String,
                             fields: [String: String] = [:]) {
        emit(.info, subsystem: subsystem, event: event, fields: fields)
    }

    public static func warn(subsystem: String, event: String,
                             fields: [String: String] = [:]) {
        emit(.warn, subsystem: subsystem, event: event, fields: fields)
    }

    public static func error(subsystem: String, event: String,
                              fields: [String: String] = [:]) {
        emit(.error, subsystem: subsystem, event: event, fields: fields)
    }

    public static func fatal(subsystem: String, event: String,
                              fields: [String: String] = [:]) {
        emit(.fatal, subsystem: subsystem, event: event, fields: fields)
    }

    // ── Diagnostics ───────────────────────────────────────────────────────────

    /// Total bytes currently stored in the log directory.
    public static var bytesOnDisk: UInt64 {
        JARVISLog_bytes_on_disk()
    }

    // ── Lifecycle ─────────────────────────────────────────────────────────────

    /// Flush the queue and shut down the background writer.
    /// Call from the application's termination handler.
    public static func shutdown() {
        JARVISLog_shutdown()
    }
}

// ─── Sensitive-field helpers ──────────────────────────────────────────────────
//
// Swift callers can check whether a field name is sensitive before constructing
// log payloads (e.g. to short-circuit expensive serialisation when redacted).

public extension JARVISLog {

    /// The canonical set of sensitive field names (mirrors SENSITIVE_FIELDS.md).
    /// Values for these fields are ALWAYS redacted unless the emitting
    /// subsystem has been explicitly opted in.
    static let sensitiveFieldNames: Set<String> = [
        "operator_content",
        "transcript",
        "belief",
        "memory",
        "voice_text",
        "prompt",
        "response",
        "utterance",
        "reply",
        "input_text",
        "output_text",
        "raw_llm_response",
        "raw_stt_text",
        "tts_input",
        "conversation_turn",
        "system_prompt",
        "user_message",
        "jarvis_message",
        "sensitive",
    ]

    /// Returns true if the given field name will be redacted by default.
    static func isSensitiveField(_ name: String) -> Bool {
        sensitiveFieldNames.contains(name)
    }
}
