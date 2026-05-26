// SecureFileRead — V4R R11l α.2 (F-KD01 / F-KD02 / F-KD03 / F-KD04)
//
// Shared §7-discipline reader for ~/.jarvis/identity/ files. Parallels
// SecureFileWrite for the read side. Closes four R11k red-team findings:
//
//   F-KD01 (HIGH) — Swift BC verifier used Data(contentsOf:, .mappedIfSafe)
//   at 4 sites; final-component symlinks followed; mmap pages can be
//   re-faulted after open. Route through fd-anchored reader.
//
//   F-KD02 (HIGH) — NativeAuditChainAnchor.loadAuxCertificateData same
//   anti-pattern (bare Data(contentsOf:)). Same fix.
//
//   F-KD03 (HIGH) — Runtime §7 readers never verified that the IMMEDIATE
//   PARENT directory (~/.jarvis/identity/) had mode 0700 + uid==operator.
//   Attacker at uid=operator can chmod 0755 the dir, mv the real file
//   out, plant a 0600 replacement — O_NOFOLLOW on the leaf passes (not
//   a symlink), fstat-on-leaf passes. The widened parent dir is the only
//   pre-attack signal, and we were not reading it. Now: fstat the parent
//   dirfd before opening the leaf. Mode/uid mismatch → reject + audit.
//
//   F-KD04 (HIGH) — O_NOFOLLOW only blocks the final component. An
//   attacker who plants ~/.jarvis -> /tmp/attacker still wins because
//   path resolution follows the intermediate symlink before O_NOFOLLOW
//   fires on the leaf. Now: realpath() the parent path under operator
//   uid (resolves any pre-existing intermediate symlinks the operator
//   placed legitimately, e.g. /var -> /private/var), then walk every
//   component of the resolved path via openat(O_DIRECTORY|O_NOFOLLOW).
//   Any symlink injected between realpath and walk is caught by ELOOP
//   at the openat boundary.
//
// Race-safety analysis:
//
//   1. realpath(parentPath) -> resolvedParent (absolute, symlink-free
//      at the moment of resolution).
//   2. Walk resolvedParent components from "/" via openat with
//      O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC. The parent's components were
//      symlink-free at step 1; any injection between step 1 and step 2
//      raises ELOOP. The final openat returns the dirfd of the immediate
//      parent — pinned to that inode, not the path.
//   3. fstat(parentDirFd) verifies mode==0o700 and uid==operator.
//      Attacker who chmodded the dir before our walk is caught here.
//   4. openat(parentDirFd, leafBasename, O_RDONLY|O_NOFOLLOW|O_CLOEXEC).
//      Operates relative to the pinned parent inode — no path traversal.
//      Final-component symlink blocked by O_NOFOLLOW. Even if the
//      attacker swaps the leaf between step 3 and step 4, openat from
//      the pinned dirfd cannot follow a renamed directory; the new
//      leaf must satisfy the leaf-fstat policy.
//   5. fstat(leafFd) verifies regular file + mode + uid + size policy.
//   6. read(leafFd) with partial-read loop. POSIX does not guarantee a
//      single read() returns the full count even on small regular files.
//
// Tests / ceremony seam:
//
//   The helper accepts an absolute path. Callers responsible for
//   resolving tildes / env overrides (via NativeInsecurePathOverride or
//   NSString.expandingTildeInPath) BEFORE calling in. The helper does
//   not consult environment variables itself — that responsibility
//   stays with the caller's resolveCanonicalPath function so the
//   one-shot insecure-override audit telemetry (R11d F-C02) keeps
//   firing exactly once per (envVar, value).
//
// Error model:
//
//   SecureFileReadError carries the resolved absolute path + a typed
//   Reason. Callers translate to their domain error (e.g.,
//   NativeColdRootPinError.pinFileMalformed, NativeBirthCertificate-
//   VerifierError.unreadable). `.absent` is distinguished from other
//   failures so callers can choose between fail-closed and fall-through.

import Darwin
import Foundation

// MARK: - Policy

struct SecureFileReadPolicy: Equatable, Sendable {
    /// Required mode (low 9 bits) of the immediate parent directory.
    /// Default 0o700 matches every ~/.jarvis/identity/ writer in the
    /// codebase. Pass nil to skip the mode check (rare; surface a code
    /// comment when nil is used).
    var requireParentMode: mode_t? = 0o700

    /// Required UID of the immediate parent directory. nil ⇒ getuid().
    var requireParentUID: uid_t? = nil

    /// Required mode (low 9 bits) of the leaf file. Default 0o600 matches
    /// every §7 writer. nil ⇒ skip (e.g., SBOM whose mode is not
    /// runtime-controlled).
    var requireLeafMode: mode_t? = 0o600

    /// Required UID of the leaf file. nil ⇒ getuid().
    var requireLeafUID: uid_t? = nil

    /// Require the leaf to be a regular file (S_IFREG). Always true for
    /// every current §7 caller; exposed as a knob for forward use.
    var requireRegularFile: Bool = true

    /// Hard upper bound on leaf size in bytes. fstat-reported size is
    /// compared before any allocation. Default 16 MiB — every current
    /// §7 leaf is < 64 KiB.
    var maxSize: Int = 16 * 1024 * 1024

    /// If set, the leaf size MUST equal this value exactly (used by
    /// fixed-size keys like the 32-byte cold-root pin).
    var expectedSize: Int? = nil
}

// MARK: - Errors

struct SecureFileReadError: Error, CustomStringConvertible, LocalizedError {
    enum Reason: Equatable, Sendable {
        case pathNotAbsolute
        case pathEmpty
        case absent
        case symlinkRefused(atComponent: String)
        case realpathFailed(errno: Int32)
        case openComponent(component: String, errno: Int32)
        case openLeaf(errno: Int32)
        case fstatParent(errno: Int32)
        case fstatLeaf(errno: Int32)
        case parentNotDirectory(mode: mode_t)
        case parentModeMismatch(actual: mode_t, expected: mode_t)
        case parentUIDMismatch(actual: uid_t, expected: uid_t)
        case leafNotRegular(mode: mode_t)
        case leafModeMismatch(actual: mode_t, expected: mode_t)
        case leafUIDMismatch(actual: uid_t, expected: uid_t)
        case leafTooLarge(size: off_t, max: Int)
        case leafSizeMismatch(actual: off_t, expected: Int)
        case shortRead(got: Int, expected: Int)
        case readErrno(errno: Int32)
    }

    let path: String
    let reason: Reason

    var errorDescription: String? { description }

    var description: String {
        switch reason {
        case .pathNotAbsolute:
            return "SecureFileRead(\(path)): path is not absolute"
        case .pathEmpty:
            return "SecureFileRead(\(path)): path is empty"
        case .absent:
            return "SecureFileRead(\(path)): absent"
        case let .symlinkRefused(c):
            return "SecureFileRead(\(path)): symlink refused at component '\(c)' (ELOOP under O_NOFOLLOW)"
        case let .realpathFailed(e):
            return "SecureFileRead(\(path)): realpath errno=\(e)"
        case let .openComponent(c, e):
            return "SecureFileRead(\(path)): open intermediate component '\(c)' errno=\(e)"
        case let .openLeaf(e):
            return "SecureFileRead(\(path)): open leaf errno=\(e)"
        case let .fstatParent(e):
            return "SecureFileRead(\(path)): fstat parent dir errno=\(e)"
        case let .fstatLeaf(e):
            return "SecureFileRead(\(path)): fstat leaf errno=\(e)"
        case let .parentNotDirectory(m):
            return "SecureFileRead(\(path)): parent is not a directory (mode=\(String(m, radix: 8)))"
        case let .parentModeMismatch(a, e):
            return "SecureFileRead(\(path)): parent mode mismatch actual=\(String(a, radix: 8)) expected=\(String(e, radix: 8))"
        case let .parentUIDMismatch(a, e):
            return "SecureFileRead(\(path)): parent uid mismatch actual=\(a) expected=\(e)"
        case let .leafNotRegular(m):
            return "SecureFileRead(\(path)): leaf is not a regular file (mode=\(String(m, radix: 8)))"
        case let .leafModeMismatch(a, e):
            return "SecureFileRead(\(path)): leaf mode mismatch actual=\(String(a, radix: 8)) expected=\(String(e, radix: 8))"
        case let .leafUIDMismatch(a, e):
            return "SecureFileRead(\(path)): leaf uid mismatch actual=\(a) expected=\(e)"
        case let .leafTooLarge(s, m):
            return "SecureFileRead(\(path)): leaf size \(s) exceeds maxSize \(m)"
        case let .leafSizeMismatch(a, e):
            return "SecureFileRead(\(path)): leaf size mismatch actual=\(a) expected=\(e)"
        case let .shortRead(g, e):
            return "SecureFileRead(\(path)): short read got=\(g) expected=\(e)"
        case let .readErrno(e):
            return "SecureFileRead(\(path)): read errno=\(e)"
        }
    }
}

// MARK: - Public API

/// Result of openSection7Anchored. Caller OWNS `fd` and must `Darwin.close(fd)`.
struct SecureFileReadHandle {
    let fd: Int32
    let st: stat
    let resolvedPath: String
}

/// Opens an absolute path under full §7 discipline: realpath of the parent,
/// per-component openat walk under O_NOFOLLOW, parent dir mode/uid verify,
/// leaf open under O_NOFOLLOW from the pinned parent dirfd, leaf fstat
/// verify (regular file + mode + uid + size). Returns the open leaf fd and
/// its stat. Caller is responsible for closing `fd`.
///
/// Throws `SecureFileReadError` with a typed Reason. `.absent` is distinct
/// from other failures so callers can choose between fail-closed and
/// fall-through (e.g., NativeColdRootPin falls through ENOENT to the
/// "fail-closed: no pin" branch; OperatorPresence treats ENOENT as the
/// "fall back to display name" branch).
func openSection7Anchored(
    path: String,
    policy: SecureFileReadPolicy = .init()
) throws -> SecureFileReadHandle {
    // 0) Path well-formedness.
    guard !path.isEmpty else {
        throw SecureFileReadError(path: path, reason: .pathEmpty)
    }
    guard path.hasPrefix("/") else {
        throw SecureFileReadError(path: path, reason: .pathNotAbsolute)
    }

    // 1) Split into parent + leaf basename.
    let url = URL(fileURLWithPath: path)
    let leafName = url.lastPathComponent
    guard !leafName.isEmpty, leafName != "/" else {
        throw SecureFileReadError(path: path, reason: .pathEmpty)
    }
    let parentPath = url.deletingLastPathComponent().path

    // 2) realpath the parent. Resolves any pre-existing intermediate
    //    symlinks (e.g., /var -> /private/var on macOS) to an absolute,
    //    symlink-free path. ENOENT here means the parent does not exist
    //    -> the file is effectively absent.
    guard let resolvedParentCStr = realpath(parentPath, nil) else {
        let e = errno
        if e == ENOENT || e == ENOTDIR {
            throw SecureFileReadError(path: path, reason: .absent)
        }
        throw SecureFileReadError(path: path, reason: .realpathFailed(errno: e))
    }
    let resolvedParent = String(cString: resolvedParentCStr)
    free(resolvedParentCStr)

    // 3) Walk resolvedParent's components from "/" via openat with
    //    O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC. Any symlink injected between
    //    realpath and this walk raises ELOOP at the offending openat.
    guard resolvedParent.hasPrefix("/") else {
        // realpath returned a non-absolute path. Defensive — should never
        // happen on Darwin.
        throw SecureFileReadError(path: path, reason: .pathNotAbsolute)
    }
    let components = resolvedParent
        .split(separator: "/", omittingEmptySubsequences: true)
        .map(String.init)

    // Open "/" as the starting dirfd. The root is opened WITHOUT
    // O_NOFOLLOW because it is the filesystem root, not a symlink.
    let rootFd = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard rootFd >= 0 else {
        throw SecureFileReadError(path: path,
                                  reason: .openComponent(component: "/", errno: errno))
    }
    var dirfd: Int32 = rootFd

    for comp in components {
        let next = Darwin.openat(
            dirfd, comp,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        let e = errno
        Darwin.close(dirfd)
        if next < 0 {
            if e == ELOOP || e == EMLINK {
                throw SecureFileReadError(path: path,
                                          reason: .symlinkRefused(atComponent: comp))
            }
            if e == ENOENT || e == ENOTDIR {
                throw SecureFileReadError(path: path, reason: .absent)
            }
            throw SecureFileReadError(path: path,
                                      reason: .openComponent(component: comp, errno: e))
        }
        dirfd = next
    }
    // dirfd == immediate parent dirfd. Pinned to the parent inode.

    // 4) Parent dir verification — F-KD03.
    do {
        var pst = stat()
        guard fstat(dirfd, &pst) == 0 else {
            let e = errno
            Darwin.close(dirfd)
            throw SecureFileReadError(path: path, reason: .fstatParent(errno: e))
        }
        let parentMode = mode_t(pst.st_mode) & 0o777
        let parentIsDir = (mode_t(pst.st_mode) & S_IFMT) == S_IFDIR
        guard parentIsDir else {
            Darwin.close(dirfd)
            throw SecureFileReadError(path: path,
                                      reason: .parentNotDirectory(mode: parentMode))
        }
        let expectedParentUID = policy.requireParentUID ?? getuid()
        guard pst.st_uid == expectedParentUID else {
            Darwin.close(dirfd)
            throw SecureFileReadError(
                path: path,
                reason: .parentUIDMismatch(actual: pst.st_uid, expected: expectedParentUID)
            )
        }
        if let expectedParentMode = policy.requireParentMode {
            guard parentMode == expectedParentMode else {
                Darwin.close(dirfd)
                throw SecureFileReadError(
                    path: path,
                    reason: .parentModeMismatch(actual: parentMode, expected: expectedParentMode)
                )
            }
        }
    }

    // 5) Open leaf via openat under the verified parent dirfd.
    let leafFd = Darwin.openat(
        dirfd, leafName,
        O_RDONLY | O_NOFOLLOW | O_CLOEXEC
    )
    let openLeafErrno = errno
    Darwin.close(dirfd)
    if leafFd < 0 {
        if openLeafErrno == ELOOP || openLeafErrno == EMLINK {
            throw SecureFileReadError(path: path,
                                      reason: .symlinkRefused(atComponent: leafName))
        }
        if openLeafErrno == ENOENT || openLeafErrno == ENOTDIR {
            throw SecureFileReadError(path: path, reason: .absent)
        }
        throw SecureFileReadError(path: path,
                                  reason: .openLeaf(errno: openLeafErrno))
    }

    // 6) Leaf fstat verification.
    var lst = stat()
    guard fstat(leafFd, &lst) == 0 else {
        let e = errno
        Darwin.close(leafFd)
        throw SecureFileReadError(path: path, reason: .fstatLeaf(errno: e))
    }
    let leafMode = mode_t(lst.st_mode) & 0o777
    if policy.requireRegularFile {
        let isRegular = (mode_t(lst.st_mode) & S_IFMT) == S_IFREG
        guard isRegular else {
            Darwin.close(leafFd)
            throw SecureFileReadError(path: path,
                                      reason: .leafNotRegular(mode: leafMode))
        }
    }
    let expectedLeafUID = policy.requireLeafUID ?? getuid()
    guard lst.st_uid == expectedLeafUID else {
        Darwin.close(leafFd)
        throw SecureFileReadError(
            path: path,
            reason: .leafUIDMismatch(actual: lst.st_uid, expected: expectedLeafUID)
        )
    }
    if let expectedLeafMode = policy.requireLeafMode {
        guard leafMode == expectedLeafMode else {
            Darwin.close(leafFd)
            throw SecureFileReadError(
                path: path,
                reason: .leafModeMismatch(actual: leafMode, expected: expectedLeafMode)
            )
        }
    }
    if let expectedSize = policy.expectedSize {
        guard lst.st_size == off_t(expectedSize) else {
            Darwin.close(leafFd)
            throw SecureFileReadError(
                path: path,
                reason: .leafSizeMismatch(actual: lst.st_size, expected: expectedSize)
            )
        }
    }
    guard lst.st_size <= off_t(policy.maxSize) else {
        Darwin.close(leafFd)
        throw SecureFileReadError(
            path: path,
            reason: .leafTooLarge(size: lst.st_size, max: policy.maxSize)
        )
    }

    return SecureFileReadHandle(
        fd: leafFd,
        st: lst,
        resolvedPath: resolvedParent + "/" + leafName
    )
}

/// Convenience wrapper: open + read-to-EOF (partial-read loop) + close.
/// Returns the file contents. The buffer is sized to the leaf's fstat-
/// reported size, capped by `policy.maxSize`. Files that grow between
/// fstat and read are read only up to the fstat-reported size.
func readSection7Anchored(
    path: String,
    policy: SecureFileReadPolicy = .init()
) throws -> Data {
    let handle = try openSection7Anchored(path: path, policy: policy)
    defer { Darwin.close(handle.fd) }

    let size = Int(handle.st.st_size)
    if size == 0 {
        return Data()
    }

    var buffer = [UInt8](repeating: 0, count: size)
    var totalRead = 0
    while totalRead < size {
        let remaining = size - totalRead
        let advance = totalRead
        let n: ssize_t = buffer.withUnsafeMutableBytes { mb -> ssize_t in
            guard let base = mb.baseAddress else { return -1 }
            return Darwin.read(handle.fd, base.advanced(by: advance), remaining)
        }
        if n < 0 {
            let e = errno
            if e == EINTR { continue }
            throw SecureFileReadError(path: path, reason: .readErrno(errno: e))
        }
        if n == 0 {
            throw SecureFileReadError(
                path: path,
                reason: .shortRead(got: totalRead, expected: size)
            )
        }
        totalRead += n
    }
    return Data(buffer)
}
