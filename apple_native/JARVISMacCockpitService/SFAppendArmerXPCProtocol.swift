import Foundation

// SFAppendArmerXPCProtocol — V4R R11l α.3.1 (F-KE03 in-threat-model coverage).
//
// XPC contract between the privileged JARVISAuditArmer LaunchDaemon (runs
// as root) and the cockpit SFAppendArmClient (runs as operator). The helper
// arms the kernel-level SF_APPEND flag on a single audit-chain file per
// call; both setting and clearing SF_APPEND require super-user on Darwin
// per chflags(2), so this helper exists as the ONLY in-perimeter path that
// can place that flag on the operator's audit-root files.
//
// SECURITY MODEL (binding, see helper-side path validation):
//   - The helper validates the requesting peer's EUID via the XPC audit
//     token; only the audit-root-owner UID may invoke armSFAppend.
//   - The helper validates the path via realpath: must canonicalize to a
//     regular file inside ~peer/.jarvis/audit/, must already have UF_APPEND
//     set (defense-in-depth from α.3), must be owned by the peer EUID.
//   - There is NO clear-SF_APPEND surface in this protocol. Rotation is
//     R1 = out of scope (α.3.1 lock). A future rotation surface would be
//     a separate XPC method with its own audit-chain'd authorization path.
//
// Mach service name: ai.realjarvis.audit.armer — pinned in both
//   ai.realjarvis.audit.armer.plist (LaunchDaemon)
//   SFAppendArmClient (cockpit XPC connection target)
public let sfAppendArmerMachServiceName: String = "ai.realjarvis.audit.armer"

// NSError domain emitted by the helper on refusal / failure. Distinct from
// cockpit-side errors so the audit chain can scope-label the source.
public let sfAppendArmerErrorDomain: String = "ai.realjarvis.audit.armer.error"

// Error codes (extern symbolic — keep in sync with helper switch statement).
public enum SFAppendArmerErrorCode: Int {
    case ok = 0
    case peerEuidMismatch = 1
    case pathRealpathFailed = 2
    case pathOutsideAuditRoot = 3
    case pathNotRegularFile = 4
    case pathUfAppendNotSet = 5
    case pathOwnerUidMismatch = 6
    case chflagsFailed = 7
    case helperAuditWriteFailed = 8
    case internalError = 9
}

// @objc protocol required for NSXPCInterface. Single method: armSFAppend.
// path is the absolute realpath of the audit-chain file to arm.
// reply is invoked exactly once with (success, error) where error is non-nil
// iff success == false.
@objc public protocol SFAppendArmerXPCProtocol {
    func armSFAppend(path: String, reply: @escaping (Bool, NSError?) -> Void)
}
