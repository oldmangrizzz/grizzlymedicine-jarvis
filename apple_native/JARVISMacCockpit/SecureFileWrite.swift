import Darwin
import Foundation

// ── NativeSecurityAuditError ─────────────────────────────────────────────────
// Typed errors from appendBoundedAuditRecord.
// Every errno is surfaced; no silent fallback (AGENTS.md §4 / §6 append discipline).
enum NativeSecurityAuditError: Error, CustomStringConvertible, LocalizedError {
    case recordTooLarge(actual: Int)
    case openDir(path: String, errno: Int32)
    case openFile(path: String, errno: Int32)
    case lockFile(path: String, errno: Int32)
    case writeFile(path: String, errno: Int32)
    case fsyncFile(path: String, errno: Int32)
    case fsyncDir(path: String, errno: Int32)
    /// R11l α.3 F-KE02: chain integrity verification failed under LOCK_EX
    /// prior to append. Carries the underlying AuditChainVerifyError so
    /// callers can emit the correct audit tag (.auditEventTag on the inner).
    case chainIntegrity(path: String, reason: AuditChainVerifyError)
    /// R11l α.3 F-KE03: fstat or chflags syscall failure during UF_APPEND
    /// arming. Defense-in-depth surface — see SecureFileWrite header note.
    case ufAppend(path: String, op: String, errno: Int32)

    var errorDescription: String? { description }

    var description: String {
        switch self {
        case let .recordTooLarge(n):
            "audit record \(n)B exceeds PIPE_BUF=512 atomic append cap"
        case let .openDir(p, e):
            "openDir(\(p)): errno=\(e)"
        case let .openFile(p, e):
            "openFile(\(p)): errno=\(e)"
        case let .lockFile(p, e):
            "flock LOCK_EX \(p): errno=\(e)"
        case let .writeFile(p, e):
            "write(\(p)): errno=\(e)"
        case let .fsyncFile(p, e):
            "fsync(file) \(p): errno=\(e)"
        case let .fsyncDir(p, e):
            "fsync(dir) \(p): errno=\(e)"
        case let .chainIntegrity(p, r):
            "audit chain integrity failure \(p): \(r) [tag=\(r.auditEventTag)]"
        case let .ufAppend(p, op, e):
            "UF_APPEND \(op)(\(p)): errno=\(e)"
        }
    }
}

// ── appendBoundedAuditRecord ──────────────────────────────────────────────────
// §6 audit-append discipline (AGENTS.md): O_APPEND under flock, <= PIPE_BUF=512.
// Mirrors audit_log.cpp writeRecordLocked (lines 611-652) + append (lines 694-724).
//
// Syscall sequence:
//   1. open(parentDir, O_RDONLY|O_NOFOLLOW|O_DIRECTORY|O_CLOEXEC)          -> fd_dir
//   2. openat(fd_dir, filename,
//             O_WRONLY|O_APPEND|O_CREAT|O_NOFOLLOW|O_CLOEXEC, 0600)        -> fd_file
//   3. flock(fd_file, LOCK_EX)                                     (EINTR-retry loop)
//   4. guard record.count <= 512                                   PIPE_BUF atomic cap
//   5. write() loop until complete                                 partial-write tolerant
//   6. fsync(fd_file)                                              data durable before unlock
//   7. fsync(fd_dir)                                               new-file creation durable
//   8. flock(fd_file, LOCK_UN)                                    \
//   9. close(fd_file); close(fd_dir)                               (deferred LIFO order)
//
// All errnos surface as NativeSecurityAuditError. No silent fallback.
func appendBoundedAuditRecord(parentDir: URL, file: String, record: Data) throws {
    // Step 4 (checked first -- fail fast before acquiring any OS resources).
    guard record.count <= 512 else {
        throw NativeSecurityAuditError.recordTooLarge(actual: record.count)
    }

    // Step 1: open the parent directory.
    // O_NOFOLLOW: ELOOP if the last component of parentDir.path is a symlink.
    // O_DIRECTORY: ENOTDIR if the path is not a directory.
    let fdDir = Darwin.open(parentDir.path, O_RDONLY | O_NOFOLLOW | O_DIRECTORY | O_CLOEXEC)
    guard fdDir >= 0 else {
        throw NativeSecurityAuditError.openDir(path: parentDir.path, errno: errno)
    }
    defer { Darwin.close(fdDir) }                       // Step 9b: close fd_dir (last, LIFO)

    // Step 2: open (or create) the log file relative to fd_dir.
    // O_NOFOLLOW: ELOOP if 'file' is a symlink -- prevents symlink-plant attack.
    // O_APPEND:   every write atomically seeks to EOF; combined with flock below,
    //             concurrent appends never interleave records.
    // O_CREAT:    creates the file if absent; mode 0600 via second open arg and umask.
    let filePath = "\(parentDir.path)/\(file)"
    let fdFile = Darwin.openat(
        fdDir, file,
        O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
        mode_t(0o600)
    )
    guard fdFile >= 0 else {
        throw NativeSecurityAuditError.openFile(path: filePath, errno: errno)
    }
    defer { Darwin.close(fdFile) }                      // Step 9a: close fd_file (second, LIFO)

    // Step 2b: F-KE03 / α.3 B.1 — UF_APPEND defense-in-depth verify on open.
    // THREAT MODEL NOTE: UF_APPEND is owner-settable + owner-clearable per
    // chflags(2). uid=operator attacker can clear it just as easily as we
    // set it. This is NOT primary control; primary integrity is the F-KE02
    // hash-chain verify in appendChainedAuditRecord. SF_APPEND (root-only,
    // attacker-resistant) requires privileged helper — deferred to α.3.1.
    // We still verify here because adjacent threats (other-UID processes,
    // accidental corruption, bug-class tamper) ARE blocked by UF_APPEND,
    // and a missing flag on a pre-existing file is a tripwire signal.
    var stOnOpen = Darwin.stat()
    if Darwin.fstat(fdFile, &stOnOpen) != 0 {
        throw NativeSecurityAuditError.ufAppend(path: filePath, op: "fstat", errno: errno)
    }
    let wasArmedOnOpenBounded = (stOnOpen.st_flags & UInt32(UF_APPEND)) != 0
    if stOnOpen.st_size > 0 && !wasArmedOnOpenBounded {
        // Tripwire — write to stderr, NOT through NativeSecurityAudit (would
        // recurse). Don't refuse: refusing would create a DoS surface where
        // anyone who can clear the flag blocks all audit.
        FileHandle.standardError.write(Data(
            "audit_uf_append_missing: \(filePath) (re-arming post-write)\n".utf8
        ))
    }

    // Step 3: acquire exclusive advisory lock; retry only on EINTR.
    // Note: bare 'flock(_:_:)' to avoid Swift resolving 'Darwin.flock' as the
    // struct type (struct flock from fcntl.h) rather than the flock(2) function.
    while flock(fdFile, LOCK_EX) != 0 {
        let e = errno
        guard e == EINTR else {
            throw NativeSecurityAuditError.lockFile(path: filePath, errno: e)
        }
    }
    defer { _ = flock(fdFile, LOCK_UN) }                // Step 8: LOCK_UN (first, LIFO)

    // Step 5: write loop -- tolerate partial writes (POSIX does not guarantee that a
    // single write(2) completes the entire buffer, even for O_APPEND writes <= PIPE_BUF).
    try record.withUnsafeBytes { buf in
        guard let base = buf.baseAddress else { return }
        var sent = 0
        while sent < record.count {
            let n = Darwin.write(fdFile, base.advanced(by: sent), record.count - sent)
            if n < 0 {
                let e = errno
                if e == EINTR { continue }
                throw NativeSecurityAuditError.writeFile(path: filePath, errno: e)
            }
            if n == 0 {
                throw NativeSecurityAuditError.writeFile(path: filePath, errno: EIO)
            }
            sent += n
        }
    }

    // Step 6: fsync the file before releasing the lock so readers see a complete record.
    if Darwin.fsync(fdFile) != 0 {
        throw NativeSecurityAuditError.fsyncFile(path: filePath, errno: errno)
    }

    // Step 7: fsync the directory so a newly-created file's directory entry is durable.
    if Darwin.fsync(fdDir) != 0 {
        throw NativeSecurityAuditError.fsyncDir(path: parentDir.path, errno: errno)
    }

    // Step 7b: F-KE03 / α.3 B.1 — arm UF_APPEND post-fsync.
    // Idempotent — already-set flag is a no-op (caught by the fstat check).
    // ENOTSUP tolerated for non-flag-supporting filesystems (rare on APFS;
    // possible on smbfs/nfs/synthetic FUSE mounts). Any other errno surfaces.
    var stPostWriteBounded = Darwin.stat()
    if Darwin.fstat(fdFile, &stPostWriteBounded) != 0 {
        throw NativeSecurityAuditError.ufAppend(path: filePath, op: "fstat", errno: errno)
    }
    if (stPostWriteBounded.st_flags & UInt32(UF_APPEND)) == 0 {
        let newFlags = stPostWriteBounded.st_flags | UInt32(UF_APPEND)
        if Darwin.fchflags(fdFile, newFlags) != 0 {
            let e = errno
            if e != ENOTSUP {
                throw NativeSecurityAuditError.ufAppend(path: filePath, op: "fchflags", errno: e)
            }
        }
    }

    // Steps 8-9 execute via the defer stack (LIFO): LOCK_UN -> close(fdFile) -> close(fdDir).
}

// ── appendChainedAuditRecord ─────────────────────────────────────────────────
// R11d F-C03: tamper-evident hash chain.
//
// Same syscall discipline as appendBoundedAuditRecord, but the LOCK_EX critical
// section is widened to include reading the prior tail record so the chain
// computation cannot race with another writer.
//
// Sequence:
//   1. open dir, open file (same as bounded variant)
//   2. flock(LOCK_EX) — covers BOTH the tail-read and the append
//   3. seek+read the last <= 1024 bytes; extract the last complete line (the
//      prior record, or nil if file is empty)
//   4. build(priorTail) -> Data — caller computes prev_sha, seq, sha from the
//      tail bytes and returns the final on-wire record (with trailing newline)
//   5. enforce <= PIPE_BUF
//   6. write, fsync(file), fsync(dir), unlock, close (same as bounded variant)
//
// Note on LOCK_SH read alternative: a separate read-tail function under LOCK_SH
// followed by a LOCK_EX append would have a TOCTOU window where another writer
// could append between the two locks, producing a chain that skips a record.
// LOCK_EX from the start is the safe path. A standalone LOCK_SH reader stays
// out of the write path — the offline verifier tool linearly scans the file
// without any locking (audit files are append-only).
func appendChainedAuditRecord(
    parentDir: URL,
    file: String,
    tailScanWindow: Int = 1024,
    build: (Data?) throws -> Data
) throws {
    let fdDir = Darwin.open(parentDir.path, O_RDONLY | O_NOFOLLOW | O_DIRECTORY | O_CLOEXEC)
    guard fdDir >= 0 else {
        throw NativeSecurityAuditError.openDir(path: parentDir.path, errno: errno)
    }
    defer { Darwin.close(fdDir) }

    let filePath = "\(parentDir.path)/\(file)"
    // O_RDWR (not O_WRONLY) so we can seek+read the tail under the same fd.
    // O_APPEND still ensures every write atomically seeks to EOF.
    let fdFile = Darwin.openat(
        fdDir, file,
        O_RDWR | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
        mode_t(0o600)
    )
    guard fdFile >= 0 else {
        throw NativeSecurityAuditError.openFile(path: filePath, errno: errno)
    }
    defer { Darwin.close(fdFile) }

    // F-KE03 / α.3 B.1 — UF_APPEND defense-in-depth verify on open (chained).
    // Mirrors the bounded variant's threat-model note: UF_APPEND is owner-
    // settable + owner-clearable; primary integrity is the F-KE02 chain-walk
    // performed below under LOCK_EX. See SecureFileWrite.swift header / α.3.1.
    var stOnOpen = Darwin.stat()
    if Darwin.fstat(fdFile, &stOnOpen) != 0 {
        throw NativeSecurityAuditError.ufAppend(path: filePath, op: "fstat", errno: errno)
    }
    let wasArmedOnOpenChained = (stOnOpen.st_flags & UInt32(UF_APPEND)) != 0
    if stOnOpen.st_size > 0 && !wasArmedOnOpenChained {
        FileHandle.standardError.write(Data(
            "audit_uf_append_missing: \(filePath) (re-arming post-write)\n".utf8
        ))
    }

    while flock(fdFile, LOCK_EX) != 0 {
        let e = errno
        guard e == EINTR else {
            throw NativeSecurityAuditError.lockFile(path: filePath, errno: e)
        }
    }
    defer { _ = flock(fdFile, LOCK_UN) }

    // R11l α.3 F-KE02: read FULL chain under LOCK_EX and verify integrity
    // before computing the next record. The prior tail-scrape (a fixed-window
    // pread of the last 1024 bytes) trusted record-N's reported sha/seq
    // without verifying records 1..N-1. An attacker at uid=operator could
    // truncate the chain to a forged single line whose sha self-consistent;
    // the writer would then build on that forged tail.
    //
    // Mitigation: read the entire file, run AuditChainVerify.verify, and use
    // the verified tail. requireNonEmpty=false here — legitimate first-write
    // on a freshly O_CREAT'd file produces size 0 which is not a truncate.
    // Callers who know the chain MUST be non-empty (boot-time post-anchor
    // verifier) should call AuditChainVerify.verify directly with
    // requireNonEmpty=true.
    //
    // Performance: linear in chain size; audit chain is bounded by operator
    // policy + rotation. tailScanWindow parameter retained for API stability
    // but no longer used as a scan window — kept as a no-op for future use
    // (e.g., chunked verification).
    _ = tailScanWindow
    let size = Darwin.lseek(fdFile, 0, SEEK_END)
    var priorTail: Data? = nil
    if size > 0 {
        var buf = [UInt8](repeating: 0, count: Int(size))
        let nRead = buf.withUnsafeMutableBytes { mb -> ssize_t in
            guard let base = mb.baseAddress else { return -1 }
            return Darwin.pread(fdFile, base, Int(size), 0)
        }
        guard nRead >= 0 else {
            throw NativeSecurityAuditError.writeFile(path: filePath, errno: errno)
        }
        if Int64(nRead) != Int64(size) {
            throw NativeSecurityAuditError.writeFile(path: filePath, errno: EIO)
        }
        let contents = Data(buf.prefix(Int(nRead)))

        // verifyAuditChain throws AuditChainVerifyError on any tamper. We
        // translate to NativeSecurityAuditError.chainIntegrity to preserve
        // this function's typed-error contract while surfacing the
        // underlying reason for audit emission.
        let verified: (tailSha: String, tailSeq: Int)?
        do {
            verified = try AuditChainVerify.verify(contents, requireNonEmpty: false)
        } catch let e as AuditChainVerifyError {
            throw NativeSecurityAuditError.chainIntegrity(path: filePath, reason: e)
        }

        if let tail = verified {
            // Synthesize a minimal priorTail JSON containing only the verified
            // sha/seq. The build closure (NativeSecurityAudit.writeLine) reads
            // exactly these two fields to compute prev_sha + next seq.
            let stub: [String: Any] = ["sha": tail.tailSha, "seq": tail.tailSeq]
            priorTail = try JSONSerialization.data(withJSONObject: stub, options: [.sortedKeys])
        }
    }

    let record = try build(priorTail)

    guard record.count <= 512 else {
        throw NativeSecurityAuditError.recordTooLarge(actual: record.count)
    }

    try record.withUnsafeBytes { buf in
        guard let base = buf.baseAddress else { return }
        var sent = 0
        while sent < record.count {
            let n = Darwin.write(fdFile, base.advanced(by: sent), record.count - sent)
            if n < 0 {
                let e = errno
                if e == EINTR { continue }
                throw NativeSecurityAuditError.writeFile(path: filePath, errno: e)
            }
            if n == 0 {
                throw NativeSecurityAuditError.writeFile(path: filePath, errno: EIO)
            }
            sent += n
        }
    }

    if Darwin.fsync(fdFile) != 0 {
        throw NativeSecurityAuditError.fsyncFile(path: filePath, errno: errno)
    }
    if Darwin.fsync(fdDir) != 0 {
        throw NativeSecurityAuditError.fsyncDir(path: parentDir.path, errno: errno)
    }

    // F-KE03 / α.3 B.1 — arm UF_APPEND post-fsync (chained variant).
    // Idempotent. ENOTSUP tolerated for non-flag-supporting filesystems.
    var stPostWriteChained = Darwin.stat()
    if Darwin.fstat(fdFile, &stPostWriteChained) != 0 {
        throw NativeSecurityAuditError.ufAppend(path: filePath, op: "fstat", errno: errno)
    }
    if (stPostWriteChained.st_flags & UInt32(UF_APPEND)) == 0 {
        let newFlags = stPostWriteChained.st_flags | UInt32(UF_APPEND)
        if Darwin.fchflags(fdFile, newFlags) != 0 {
            let e = errno
            if e != ENOTSUP {
                throw NativeSecurityAuditError.ufAppend(path: filePath, op: "fchflags", errno: e)
            }
        }
    }
}
