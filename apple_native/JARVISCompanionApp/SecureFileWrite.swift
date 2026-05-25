import Darwin
import Foundation

enum SecureFileWriteError: Error, CustomStringConvertible, LocalizedError {
    case createDirectory(context: String, path: String, underlying: Error)
    case removeStaleTemporary(context: String, path: String, underlying: Error)
    case openTemporary(context: String, path: String, errno: Int32)
    case writeTemporary(context: String, path: String, errno: Int32)
    case fsyncTemporary(context: String, path: String, errno: Int32)
    case closeTemporary(context: String, path: String, errno: Int32)
    case renameIntoPlace(context: String, temporaryPath: String, destinationPath: String, errno: Int32)
    case cleanupTemporary(context: String, path: String, underlying: Error)

    var errorDescription: String? { description }

    var description: String {
        switch self {
        case let .createDirectory(context, path, underlying):
            "\(context): could not prepare secure storage directory at \(path): \(underlying)"
        case let .removeStaleTemporary(context, path, underlying):
            "\(context): could not remove stale secure-write temporary file at \(path): \(underlying)"
        case let .openTemporary(context, path, errno):
            "\(context): could not exclusively create secure temporary file at \(path) (errno=\(errno))"
        case let .writeTemporary(context, path, errno):
            "\(context): could not fully write secure temporary file at \(path) (errno=\(errno))"
        case let .fsyncTemporary(context, path, errno):
            "\(context): could not fsync secure temporary file at \(path) (errno=\(errno))"
        case let .closeTemporary(context, path, errno):
            "\(context): could not close secure temporary file at \(path) (errno=\(errno))"
        case let .renameIntoPlace(context, temporaryPath, destinationPath, errno):
            "\(context): could not install secure file from \(temporaryPath) to \(destinationPath) (errno=\(errno))"
        case let .cleanupTemporary(context, path, underlying):
            "\(context): secure-write cleanup failed for temporary file at \(path): \(underlying)"
        }
    }
}

func writeBlobAtomically0600(_ data: Data, to destination: URL, context: String) throws {
    try data.withUnsafeBytes { rawBuffer in
        try writeBlobAtomically0600(
            baseAddress: rawBuffer.baseAddress,
            count: data.count,
            to: destination,
            context: context
        )
    }
}

private func writeBlobAtomically0600(baseAddress: UnsafeRawPointer?, count: Int, to destination: URL, context: String) throws {
    let directory = destination.deletingLastPathComponent()
    do {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    } catch {
        throw SecureFileWriteError.createDirectory(context: context, path: directory.path, underlying: error)
    }

    let temporary = destination.appendingPathExtension("tmp.\(ProcessInfo.processInfo.processIdentifier).\(UUID().uuidString)")
    do {
        try FileManager.default.removeItem(at: temporary)
    } catch CocoaError.fileNoSuchFile {
    } catch {
        throw SecureFileWriteError.removeStaleTemporary(context: context, path: temporary.path, underlying: error)
    }

    var fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else {
        throw SecureFileWriteError.openTemporary(context: context, path: temporary.path, errno: errno)
    }

    do {
        if count > 0 {
            guard let baseAddress else {
                throw SecureFileWriteError.writeTemporary(context: context, path: temporary.path, errno: EFAULT)
            }
            var written = 0
            while written < count {
                let result = write(fd, baseAddress.advanced(by: written), count - written)
                if result < 0 {
                    if errno == EINTR { continue }
                    throw SecureFileWriteError.writeTemporary(context: context, path: temporary.path, errno: errno)
                }
                if result == 0 {
                    throw SecureFileWriteError.writeTemporary(context: context, path: temporary.path, errno: EIO)
                }
                written += result
            }
        }

        if fsync(fd) != 0 {
            throw SecureFileWriteError.fsyncTemporary(context: context, path: temporary.path, errno: errno)
        }
        let closeResult = close(fd)
        fd = -1
        if closeResult != 0 {
            throw SecureFileWriteError.closeTemporary(context: context, path: temporary.path, errno: errno)
        }
        if rename(temporary.path, destination.path) != 0 {
            throw SecureFileWriteError.renameIntoPlace(
                context: context,
                temporaryPath: temporary.path,
                destinationPath: destination.path,
                errno: errno
            )
        }
    } catch {
        if fd >= 0 {
            _ = close(fd)
            fd = -1
        }
        do {
            try FileManager.default.removeItem(at: temporary)
        } catch CocoaError.fileNoSuchFile {
        } catch let cleanupError {
            throw SecureFileWriteError.cleanupTemporary(context: context, path: temporary.path, underlying: cleanupError)
        }
        throw error
    }
}

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
    guard record.count <= 512 else {
        throw NativeSecurityAuditError.recordTooLarge(actual: record.count)
    }

    let fdDir = open(parentDir.path, O_RDONLY | O_NOFOLLOW | O_DIRECTORY | O_CLOEXEC)
    guard fdDir >= 0 else {
        throw NativeSecurityAuditError.openDir(path: parentDir.path, errno: errno)
    }
    defer { close(fdDir) }

    let filePath = "\(parentDir.path)/\(file)"
    let fdFile = openat(fdDir, file, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
    guard fdFile >= 0 else {
        throw NativeSecurityAuditError.openFile(path: filePath, errno: errno)
    }
    defer { close(fdFile) }

    while flock(fdFile, LOCK_EX) != 0 {
        let e = errno
        guard e == EINTR else {
            throw NativeSecurityAuditError.lockFile(path: filePath, errno: e)
        }
    }
    defer { _ = flock(fdFile, LOCK_UN) }

    try record.withUnsafeBytes { buf in
        guard let base = buf.baseAddress else { return }
        var sent = 0
        while sent < record.count {
            let n = write(fdFile, base.advanced(by: sent), record.count - sent)
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

    if fsync(fdFile) != 0 {
        throw NativeSecurityAuditError.fsyncFile(path: filePath, errno: errno)
    }
    if fsync(fdDir) != 0 {
        throw NativeSecurityAuditError.fsyncDir(path: parentDir.path, errno: errno)
    }
}
