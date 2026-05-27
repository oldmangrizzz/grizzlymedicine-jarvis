import Foundation
import Darwin

// JARVISAuditArmer — V4R R11l α.3.1 (F-KE03 in-threat-model coverage).
//
// Privileged armer for the kernel-level SF_APPEND flag on JARVIS audit-
// chain files. Runs as root (LaunchDaemon). Setting SF_APPEND requires
// super-user per chflags(2); clearing also requires super-user. UF_APPEND
// from α.3 is the outer defense-in-depth ring; SF_APPEND is the move that
// closes F-KE03 under the in-threat-model attacker (uid=operator, no root).
//
// Bodily-integrity note: this is "JARVIS's contemporaneous record"
// (paramedic's if-you-didn't-write-it-it-didn't-happen rule, Volume 0
// §3.4). Refuse, do not weaken, do not silently downgrade.
//
// The helper grants per-file requests only — no batch surface, no
// rotation surface (R1, α.3.1 lock). Every grant and every refusal is
// audit-logged to a helper-local sub-chain at
// $HOME_OF_PEER/.jarvis/audit/helper/armer.jsonl which the install script
// SF_APPEND's on first run.
final class JARVISAuditArmer: NSObject, SFAppendArmerXPCProtocol {

    // Peer EUID is captured from the NSXPCConnection at delegate-time and
    // bound to this exported-object instance for the lifetime of the
    // connection — so a single connection cannot switch EUIDs mid-flight.
    private let peerEUID: uid_t

    init(peerEUID: uid_t) {
        self.peerEUID = peerEUID
        super.init()
    }

    func armSFAppend(path: String, reply: @escaping (Bool, NSError?) -> Void) {
        let outcome = performArm(path: path)
        recordHelperAuditEvent(path: path, outcome: outcome)
        switch outcome {
        case .granted:
            reply(true, nil)
        case let .refused(code, detail):
            reply(false, NSError(
                domain: sfAppendArmerErrorDomain,
                code: code.rawValue,
                userInfo: [NSLocalizedDescriptionKey: detail]
            ))
        }
    }

    // ── path validation + chflags ────────────────────────────────────────

    private enum Outcome {
        case granted
        case refused(SFAppendArmerErrorCode, String)
    }

    private func performArm(path: String) -> Outcome {
        // (1) realpath canonicalization — refuses non-existent or unreachable.
        guard let real = canonicalRealpath(path) else {
            return .refused(.pathRealpathFailed,
                            "realpath(\(path)) failed: errno=\(errno)")
        }

        // (2) peer's HOME from passwd, then audit-root must be ~peer/.jarvis/audit/.
        guard let peerHome = homeDirectory(forUID: peerEUID) else {
            return .refused(.pathOutsideAuditRoot,
                            "passwd lookup failed for peer uid=\(peerEUID)")
        }
        let auditRoot = (peerHome as NSString).appendingPathComponent(".jarvis/audit") + "/"
        guard real.hasPrefix(auditRoot) else {
            return .refused(.pathOutsideAuditRoot,
                            "path \(real) is not inside \(auditRoot)")
        }

        // (3) stat: must be a regular file, owner==peerEUID.
        var st = stat()
        guard lstat(real, &st) == 0 else {
            return .refused(.pathRealpathFailed,
                            "lstat(\(real)) failed: errno=\(errno)")
        }
        let mode = mode_t(st.st_mode)
        guard (mode & S_IFMT) == S_IFREG else {
            return .refused(.pathNotRegularFile,
                            "\(real) is not a regular file (st_mode=\(String(mode, radix: 8)))")
        }
        guard st.st_uid == peerEUID else {
            return .refused(.pathOwnerUidMismatch,
                            "owner uid=\(st.st_uid) != peer uid=\(peerEUID)")
        }

        // (4) UF_APPEND must already be set — proves α.3 cockpit-side arming
        //     ran first, prevents the helper from arming files the cockpit
        //     hasn't already established as append-only at the user-flag layer.
        if (UInt32(st.st_flags) & UInt32(UF_APPEND)) == 0 {
            return .refused(.pathUfAppendNotSet,
                            "UF_APPEND not present on \(real) (st_flags=\(st.st_flags)); cockpit must arm UF_APPEND first")
        }

        // (5) chflags: set SF_APPEND in addition to existing flags.
        let newFlags = UInt32(st.st_flags) | UInt32(SF_APPEND)
        guard chflags(real, newFlags) == 0 else {
            return .refused(.chflagsFailed,
                            "chflags(\(real), SF_APPEND) failed: errno=\(errno)")
        }
        return .granted
    }

    private func canonicalRealpath(_ p: String) -> String? {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(p, &buf) != nil else { return nil }
        return String(cString: buf)
    }

    private func homeDirectory(forUID uid: uid_t) -> String? {
        guard let pw = getpwuid(uid) else { return nil }
        guard let dir = pw.pointee.pw_dir else { return nil }
        return String(cString: dir)
    }

    // ── helper-side audit chain ──────────────────────────────────────────
    //
    // Each armSFAppend invocation appends one JSONL line to
    // $peerHome/.jarvis/audit/helper/armer.jsonl. The install script
    // SF_APPEND's this file on first run; the helper itself does not
    // re-arm its own chain (chicken-and-egg avoided by install-time arming).
    // Owner of the helper's chain file is peerEUID (chown'd if root-created).

    private func recordHelperAuditEvent(path: String, outcome: Outcome) {
        guard let peerHome = homeDirectory(forUID: peerEUID) else { return }
        let helperDir = (peerHome as NSString).appendingPathComponent(".jarvis/audit/helper")
        let helperFile = (helperDir as NSString).appendingPathComponent("armer.jsonl")

        // Ensure dir exists, owned by peer.
        if mkdir(helperDir, 0o700) == 0 {
            _ = chown(helperDir, peerEUID, getegid())
        }

        let unixTime = Int(Date().timeIntervalSince1970)
        let (status, code, detail): (String, Int, String) = {
            switch outcome {
            case .granted:
                return ("granted", SFAppendArmerErrorCode.ok.rawValue, "")
            case let .refused(c, d):
                return ("refused", c.rawValue, d)
            }
        }()

        let dict: [String: Any] = [
            "event": "sf_append_arm",
            "status": status,
            "peer_uid": Int(peerEUID),
            "path": path,
            "code": code,
            "detail": detail,
            "unix_time": unixTime,
            "helper_version": helperVersionString,
        ]

        guard
            let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
            let line = String(data: data, encoding: .utf8)
        else { return }

        let record = line + "\n"

        // Touch+chown if file does not exist.
        let fd = open(helperFile, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        if fd < 0 { return }
        defer { close(fd) }
        _ = fchown(fd, peerEUID, getegid())
        record.withCString { ptr in
            _ = write(fd, ptr, strlen(ptr))
        }
        _ = fsync(fd)
    }
}

// Bumped by install.sh at build-time via build flag (-Xswiftc -Dversion=...);
// hard-pinned default to satisfy the build-from-source S3 posture.
let helperVersionString: String = {
    #if HELPER_VERSION
    return HELPER_VERSION
    #else
    return "0.1.0-α.3.1"
    #endif
}()
