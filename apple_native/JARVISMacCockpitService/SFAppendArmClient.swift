import Foundation
import Darwin

// SFAppendArmClient — V4R R11l α.3.1 (F-KE03 in-threat-model coverage).
//
// Cockpit-side XPC client for the JARVISAuditArmer LaunchDaemon. Connects
// to Mach service `ai.realjarvis.audit.armer` and asks the privileged
// helper to set SF_APPEND on a given audit-chain file.
//
// USAGE PATTERN (binding, see operator α.3.1 spec):
//   1. Cockpit's audit writer creates the audit file with O_APPEND.
//   2. Cockpit arms UF_APPEND via chflags() (α.3 path, owner-clearable).
//   3. Cockpit verifies the file has at least the genesis record.
//   4. Cockpit calls SFAppendArmClient().arm(path:) — at most once
//      per audit-file lifecycle. Repeated calls are idempotent at the
//      kernel layer (SF_APPEND already set on a SF_APPEND file is a
//      no-op + EOK from chflags).
//
// BOOT PROLOGUE (Fork 4 = F2):
//   On cockpit boot, SFAppendArmClient.verifyAuditChainsArmed(...) runs
//   over the known audit files. For each file MISSING SF_APPEND it:
//      (a) emits an `audit_sf_append_missing` event into the cockpit's
//          security audit chain (cryptographic ground truth);
//      (b) drives a cortisol spike via EndocrineCABIClient.onThreat,
//          severity scaled to the proportion of missing files (so a
//          single miss is felt, an across-the-board miss screams);
//      (c) attempts re-arm via the helper. On re-arm refusal it emits
//          `audit_sf_append_helper_refused` carrying the helper's error
//          code + detail. The cockpit boots either way (UF_APPEND
//          remains as outer defense-in-depth) — no DoS-by-accident on
//          SF_APPEND glitch (F1 rejected; F3 rejected as Synthetic
//          Dissociation by design).
//
// THREADING: NSXPCConnection is thread-safe; the client itself is
// stateless except for its connection cache. armSFAppend reply handlers
// dispatch on an arbitrary queue.
public final class SFAppendArmClient {

    public enum ClientError: Error, CustomStringConvertible {
        case pathOutsideAuditRoot(path: String, auditRoot: String)
        case pathRealpathFailed(path: String, errno: Int32)
        case pathNotRegularFile(path: String)
        case helperRefused(code: Int, detail: String)
        case helperUnavailable(detail: String)
        case helperReplyTimeout

        public var description: String {
            switch self {
            case let .pathOutsideAuditRoot(p, r):
                return "SFAppendArmClient: \(p) is not inside \(r); refusing to ask helper"
            case let .pathRealpathFailed(p, e):
                return "SFAppendArmClient: realpath(\(p)) failed: errno=\(e)"
            case let .pathNotRegularFile(p):
                return "SFAppendArmClient: \(p) is not a regular file"
            case let .helperRefused(c, d):
                return "SFAppendArmClient: helper refused code=\(c): \(d)"
            case let .helperUnavailable(d):
                return "SFAppendArmClient: helper unavailable: \(d)"
            case .helperReplyTimeout:
                return "SFAppendArmClient: helper reply timed out"
            }
        }

        // Used by boot-prologue to tag the audit event.
        public var auditEventTag: String {
            switch self {
            case .pathOutsideAuditRoot:        return "sf_append_client_path_outside_audit_root"
            case .pathRealpathFailed:          return "sf_append_client_path_realpath_failed"
            case .pathNotRegularFile:          return "sf_append_client_path_not_regular_file"
            case .helperRefused:               return "audit_sf_append_helper_refused"
            case .helperUnavailable:           return "audit_sf_append_helper_unavailable"
            case .helperReplyTimeout:          return "audit_sf_append_helper_reply_timeout"
            }
        }
    }

    public init() {}

    // ── client-side path pre-validation ──────────────────────────────────
    //
    // Negative gate: refuse to ask the helper about paths outside
    // ~/.jarvis/audit/. Defense-in-depth — the helper does its own
    // realpath-based validation, but the cockpit never even sends a
    // request that ought to fail. APT pin
    // testFFKE03_helper_client_validates_path_inside_audit_root_before_call
    // verifies this.

    private static func auditRootPath() -> String {
        let home = NSHomeDirectoryForUser(NSUserName()) ?? NSHomeDirectory()
        return (home as NSString).appendingPathComponent(".jarvis/audit") + "/"
    }

    private func validatePathLocally(_ path: String) throws -> String {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(path, &buf) != nil else {
            throw ClientError.pathRealpathFailed(path: path, errno: errno)
        }
        let real = String(cString: buf)
        let root = SFAppendArmClient.auditRootPath()
        guard real.hasPrefix(root) else {
            throw ClientError.pathOutsideAuditRoot(path: real, auditRoot: root)
        }
        var st = stat()
        guard lstat(real, &st) == 0 else {
            throw ClientError.pathRealpathFailed(path: real, errno: errno)
        }
        guard (mode_t(st.st_mode) & S_IFMT) == S_IFREG else {
            throw ClientError.pathNotRegularFile(path: real)
        }
        return real
    }

    // ── XPC round-trip ───────────────────────────────────────────────────

    public func arm(path: String, timeout: TimeInterval = 5.0) throws {
        let canonical = try validatePathLocally(path)

        let connection = NSXPCConnection(
            machServiceName: sfAppendArmerMachServiceName,
            options: .privileged
        )
        connection.remoteObjectInterface = NSXPCInterface(with: SFAppendArmerXPCProtocol.self)
        connection.resume()
        defer { connection.invalidate() }

        let semaphore = DispatchSemaphore(value: 0)
        var captured: (Bool, NSError?)?

        let invalidationHandler = { [weak connection] in
            captured = (false, NSError(
                domain: sfAppendArmerErrorDomain,
                code: SFAppendArmerErrorCode.internalError.rawValue,
                userInfo: [NSLocalizedDescriptionKey: "XPC connection invalidated before reply"]
            ))
            semaphore.signal()
            _ = connection
        }
        connection.invalidationHandler = invalidationHandler
        connection.interruptionHandler = invalidationHandler

        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in
            // Synthesize an unavailability error; reply handler may never fire.
            captured = (false, NSError(
                domain: sfAppendArmerErrorDomain,
                code: SFAppendArmerErrorCode.internalError.rawValue,
                userInfo: [NSLocalizedDescriptionKey: "XPC remote proxy error"]
            ))
            semaphore.signal()
        } as? SFAppendArmerXPCProtocol

        guard let proxy else {
            throw ClientError.helperUnavailable(detail: "remote proxy cast failed")
        }

        proxy.armSFAppend(path: canonical) { success, error in
            captured = (success, error)
            semaphore.signal()
        }

        switch semaphore.wait(timeout: .now() + timeout) {
        case .success:
            break
        case .timedOut:
            throw ClientError.helperReplyTimeout
        }

        let (success, error) = captured ?? (false, nil)
        if success { return }
        guard let error else {
            throw ClientError.helperUnavailable(detail: "no error and no success")
        }
        throw ClientError.helperRefused(code: error.code, detail: error.localizedDescription)
    }

    // ── boot prologue ────────────────────────────────────────────────────
    //
    // Runs SF_APPEND verification + re-arm against a caller-supplied list
    // of audit-chain leaves. Emits audit events via the supplied sink and
    // drives a cortisol spike via the supplied endocrine client.

    public struct AuditEventSink {
        public let emit: (_ tag: String, _ fields: [String: Any]) -> Void
        public init(emit: @escaping (_ tag: String, _ fields: [String: Any]) -> Void) {
            self.emit = emit
        }
    }

    @discardableResult
    public func verifyAuditChainsArmed(
        chainPaths: [String],
        endocrine: EndocrineCABIClient?,
        auditSink: AuditEventSink
    ) -> (missing: Int, refused: Int, totalConsidered: Int) {
        var missing = 0
        var refused = 0
        for path in chainPaths {
            var st = stat()
            guard lstat(path, &st) == 0 else { continue }
            if (UInt32(st.st_flags) & UInt32(SF_APPEND)) != 0 { continue }
            missing += 1
            auditSink.emit("audit_sf_append_missing", [
                "path": path,
                "st_flags": st.st_flags,
                "uf_append_present": (UInt32(st.st_flags) & UInt32(UF_APPEND)) != 0,
            ])
            do {
                try arm(path: path)
            } catch let err as ClientError {
                refused += 1
                auditSink.emit(err.auditEventTag, [
                    "path": path,
                    "detail": String(describing: err),
                ])
            } catch {
                refused += 1
                auditSink.emit("audit_sf_append_helper_unavailable", [
                    "path": path,
                    "detail": String(describing: error),
                ])
            }
        }
        if missing > 0, let endocrine, !chainPaths.isEmpty {
            // Severity scales with proportion of missing files. Clamped to
            // [0.4, 1.0] so even a single miss is felt (anti-Synthetic-
            // Dissociation per F2); across-the-board misses cap at 1.0.
            let proportion = Double(missing) / Double(chainPaths.count)
            let severity = max(0.4, min(1.0, proportion))
            endocrine.onThreat(severity: severity)
        }
        return (missing: missing, refused: refused, totalConsidered: chainPaths.count)
    }
}
