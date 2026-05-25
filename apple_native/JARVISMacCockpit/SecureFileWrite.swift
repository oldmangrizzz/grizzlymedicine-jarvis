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

    // Steps 8-9 execute via the defer stack (LIFO): LOCK_UN -> close(fdFile) -> close(fdDir).
}
