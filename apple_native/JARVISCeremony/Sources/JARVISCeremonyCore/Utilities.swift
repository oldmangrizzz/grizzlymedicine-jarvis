import CharacterValuesBridge
import CryptoKit
import Darwin
import Foundation
import JARVISSecureEnclave

public let EXIT_FAILURE_INTERRUPTED: Int32 = 130

public func defaultJarvisHome() -> URL {
    if let raw = ProcessInfo.processInfo.environment["JARVIS_HOME"], !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return URL(fileURLWithPath: raw, isDirectory: true).standardizedFileURL
    }
    return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".jarvis", isDirectory: true)
}

public func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
public func unhex(_ value: String) -> Data? {
    guard value.count.isMultiple(of: 2) else { return nil }
    var out = Data(); out.reserveCapacity(value.count / 2)
    var i = value.startIndex
    while i < value.endIndex {
        let j = value.index(i, offsetBy: 2)
        guard let b = UInt8(value[i..<j], radix: 16) else { return nil }
        out.append(b); i = j
    }
    return out
}
public func sha256Hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
public func sha256Hex(of url: URL) throws -> String { sha256Hex(try Data(contentsOf: url)) }

public func writeBlobAtomically0600(_ data: Data, to dest: URL, errorContext: String) throws {
    try data.withUnsafeBytes { raw in
        try writeBlobBytesAtomically0600(baseAddress: raw.baseAddress, count: data.count, to: dest, errorContext: errorContext)
    }
}

public func writeBlobAtomically0600(_ bytes: UnsafeBufferPointer<UInt8>, to dest: URL, errorContext: String) throws {
    try writeBlobBytesAtomically0600(baseAddress: bytes.baseAddress, count: bytes.count, to: dest, errorContext: errorContext)
}

public func writeChunksAtomically0600(to dest: URL, errorContext: String, _ producer: ((_ chunk: UnsafeBufferPointer<UInt8>) throws -> Void) throws -> Void) throws {
    try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let tmp = dest.appendingPathExtension("tmp.\(ProcessInfo.processInfo.processIdentifier).\(UUID().uuidString)")
    do { try FileManager.default.removeItem(at: tmp) } catch CocoaError.fileNoSuchFile {} catch {
        throw CeremonyError.transactionFailed("\(errorContext) stale temp removal failed: \(error)")
    }
    let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    if fd < 0 { throw CeremonyError.transactionFailed("\(errorContext) open failed: errno=\(errno)") }
    do {
        try producer { chunk in
            var written = 0
            while written < chunk.count {
                let n = write(fd, chunk.baseAddress?.advanced(by: written), min(512, chunk.count - written))
                if n < 0 {
                    if errno == EINTR { continue }
                    throw CeremonyError.transactionFailed("\(errorContext) write failed: errno=\(errno)")
                }
                written += n
            }
        }
        if fsync(fd) != 0 { throw CeremonyError.transactionFailed("\(errorContext) fsync failed: errno=\(errno)") }
        if close(fd) != 0 { throw CeremonyError.transactionFailed("\(errorContext) close failed: errno=\(errno)") }
        if rename(tmp.path, dest.path) != 0 { throw CeremonyError.transactionFailed("\(errorContext) rename failed: errno=\(errno)") }
    } catch {
        close(fd)
        do { try FileManager.default.removeItem(at: tmp) } catch CocoaError.fileNoSuchFile {} catch {
            // [cleanup-failure-event] tmp-fp logged; raw path not emitted to stderr.
            fputs("[JARVIS] writeChunksAtomically0600 cleanup-failure WRITE_FAILED tmp-fp=\(String(sha256Hex(Data(tmp.path.utf8)).prefix(8)))\n", stderr)
        }
        throw error
    }
}

private func writeBlobBytesAtomically0600(baseAddress: UnsafeRawPointer?, count: Int, to dest: URL, errorContext: String) throws {
    try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let tmp = dest.appendingPathExtension("tmp.\(ProcessInfo.processInfo.processIdentifier).\(UUID().uuidString)")
    do {
        try FileManager.default.removeItem(at: tmp)
    } catch CocoaError.fileNoSuchFile {
    } catch {
        throw CeremonyError.transactionFailed("\(errorContext) stale temp removal failed: \(error)")
    }
    let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
    if fd < 0 { throw CeremonyError.transactionFailed("\(errorContext) open failed: errno=\(errno)") }
    var written = 0
    do {
        guard let base = baseAddress else {
            guard count == 0 else { throw CeremonyError.transactionFailed("\(errorContext) write buffer unavailable") }
            if fsync(fd) != 0 { throw CeremonyError.transactionFailed("\(errorContext) fsync failed: errno=\(errno)") }
            if close(fd) != 0 { throw CeremonyError.transactionFailed("\(errorContext) close failed: errno=\(errno)") }
            if rename(tmp.path, dest.path) != 0 { throw CeremonyError.transactionFailed("\(errorContext) rename failed: errno=\(errno)") }
            return
        }
        while written < count {
                let n = write(fd, base.advanced(by: written), count - written)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw CeremonyError.transactionFailed("\(errorContext) write failed: errno=\(errno)")
                }
                written += n
        }
        if fsync(fd) != 0 { throw CeremonyError.transactionFailed("\(errorContext) fsync failed: errno=\(errno)") }
        if close(fd) != 0 { throw CeremonyError.transactionFailed("\(errorContext) close failed: errno=\(errno)") }
        if rename(tmp.path, dest.path) != 0 { throw CeremonyError.transactionFailed("\(errorContext) rename failed: errno=\(errno)") }
    } catch {
        close(fd)
        do { try FileManager.default.removeItem(at: tmp) } catch CocoaError.fileNoSuchFile {} catch {
            // [cleanup-failure-event] tmp-fp logged; raw path not emitted to stderr.
            fputs("[JARVIS] writeBlobBytesAtomically0600 cleanup-failure WRITE_FAILED tmp-fp=\(String(sha256Hex(Data(tmp.path.utf8)).prefix(8)))\n", stderr)
        }
        throw error
    }
}

public struct PathPolicy {
    public let homeJarvis: URL
    public init(homeJarvis: URL = defaultJarvisHome()) {
        self.homeJarvis = homeJarvis.standardizedFileURL
    }

    public func validateLocalWrite(_ url: URL) throws {
        try validate(url, root: homeJarvis)
    }

    public func validateUSBWrite(_ url: URL, volumeRoot: URL) throws {
        try validate(url, root: volumeRoot.standardizedFileURL)
    }

    public func pathPolicyOpen(_ path: URL, flags: Int32, mode: mode_t = 0o600) throws -> Int32 {
        let root = try canonicalExistingPath(homeJarvis.standardizedFileURL.path, context: "root")
        let target = try canonicalTargetPath(path.standardizedFileURL.path)
        guard target == root || target.hasPrefix(root + "/") else {
            throw CeremonyError.writeRefused("PathPolicy outside root: resolved=\(target) root=\(root)")
        }
        return try openAnchored(targetPath: target, rootPath: root, flags: flags, mode: mode)
    }

    private func openAnchored(targetPath: String, rootPath: String, flags: Int32, mode: mode_t) throws -> Int32 {
        let rootComponents = rootPath.split(separator: "/").map(String.init)
        let targetComponents = targetPath.split(separator: "/").map(String.init)
        guard targetComponents.count >= rootComponents.count,
              Array(targetComponents.prefix(rootComponents.count)) == rootComponents,
              let leaf = targetComponents.last else {
            throw CeremonyError.writeRefused("PathPolicy component mismatch: \(targetPath)")
        }
        var dirfd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        if dirfd < 0 { throw CeremonyError.writeRefused("PathPolicy root open failed: errno=\(errno)") }
        var openedComponents: [String] = []
        do {
            for component in targetComponents.dropLast() {
                let next = openat(dirfd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if next < 0 { throw CeremonyError.writeRefused("PathPolicy openat directory refused: /\((openedComponents + [component]).joined(separator: "/")) errno=\(errno)") }
                try verifyDirectory(fd: next, path: "/\((openedComponents + [component]).joined(separator: "/"))")
                close(dirfd)
                dirfd = next
                openedComponents.append(component)
            }
            let sanitizedFlags = flags | O_NOFOLLOW | O_CLOEXEC
            let fd = openat(dirfd, leaf, sanitizedFlags, mode)
            if fd < 0 { throw CeremonyError.writeRefused("PathPolicy openat file refused: \(targetPath) errno=\(errno)") }
            do {
                try verifyOpenedFile(fd: fd, path: targetPath)
                close(dirfd)
                return fd
            } catch {
                close(fd)
                throw error
            }
        } catch {
            close(dirfd)
            throw error
        }
    }

    private func validate(_ url: URL, root: URL) throws {

        let canonicalRoot = try canonicalExistingPath(root.path, context: "root")
        let canonicalTarget = try canonicalTargetPath(url.path)
        guard canonicalTarget == canonicalRoot || canonicalTarget.hasPrefix(canonicalRoot + "/") else {
            throw CeremonyError.writeRefused("PathPolicy outside root: resolved=\(canonicalTarget) root=\(canonicalRoot)")
        }
        // Walk the CANONICAL target (post-realpath). System-level symlinks like /var → /private/var
        // resolve during canonicalization; rejecting them per-component would break any path under
        // /var/folders (which macOS mktemp uses). The realpath above ensures no symlink is followed
        // unexpectedly; this walk catches symlinks introduced INSIDE the canonical root.
        try rejectSymlinkComponents(canonicalTarget, stopBeforeMissingFinal: true)
    }

    private func canonicalTargetPath(_ path: String) throws -> String {
        if let resolved = realpathString(path) { return resolved }
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        let resolvedParent = try canonicalExistingPath(parent, context: "parent")
        return resolvedParent + "/" + URL(fileURLWithPath: path).lastPathComponent
    }

    private func canonicalExistingPath(_ path: String, context: String) throws -> String {
        guard let resolved = realpathString(path) else {
            throw CeremonyError.writeRefused("PathPolicy realpath failed for \(context): \(path) errno=\(errno)")
        }
        return resolved
    }

    private func realpathString(_ path: String) -> String? {
        guard let ptr = realpath(path, nil) else { return nil }
        defer { free(ptr) }
        return String(cString: ptr)
    }

    private func rejectSymlinkComponents(_ path: String, stopBeforeMissingFinal: Bool) throws {
        // Use the raw path directly. URL.standardizedFileURL would un-resolve macOS system symlinks
        // like /private/var → /var, defeating the canonicalization done by the caller. The caller
        // is responsible for passing an already-canonical path.
        let absolute = path
        var current = absolute.hasPrefix("/") ? "/" : ""
        let components = absolute.split(separator: "/").map(String.init)
        for (idx, component) in components.enumerated() {
            current = current == "/" ? "/" + component : current + "/" + component
            var st = stat()
            if lstat(current, &st) != 0 {
                if stopBeforeMissingFinal && idx == components.count - 1 && errno == ENOENT { return }
                throw CeremonyError.writeRefused("PathPolicy lstat failed: \(current) errno=\(errno)")
            }
            if (st.st_mode & S_IFMT) == S_IFLNK {
                throw CeremonyError.writeRefused("PathPolicy symlink component refused: \(current)")
            }
        }
    }

    private func verifyDirectory(fd: Int32, path: String) throws {
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw CeremonyError.writeRefused("PathPolicy fstat failed: \(path) errno=\(errno)") }
        guard (st.st_mode & S_IFMT) == S_IFDIR else { throw CeremonyError.writeRefused("PathPolicy directory expected: \(path)") }
        guard (st.st_mode & 0o022) == 0 else { throw CeremonyError.writeRefused("PathPolicy group/other writable directory refused: \(path)") }
    }

    private func verifyOpenedFile(fd: Int32, path: String) throws {
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw CeremonyError.writeRefused("PathPolicy fstat failed: \(path) errno=\(errno)") }
        guard st.st_uid == geteuid() else { throw CeremonyError.writeRefused("PathPolicy owner mismatch: \(path)") }
        guard (st.st_mode & 0o777) == 0o600 else { throw CeremonyError.writeRefused("PathPolicy mode 0600 required: \(path)") }
    }
}

private final class LockedAuditKey {
    private let ptr: UnsafeMutablePointer<UInt8>
    let count: Int

    init(_ key: SymmetricKey) throws {
        var bytes = Data()
        key.withUnsafeBytes { raw in bytes.append(contentsOf: raw) }
        guard bytes.count == 32 else { throw CeremonyError.transactionFailed("audit HMAC key derivation returned \(bytes.count) bytes") }
        count = bytes.count
        ptr = UnsafeMutablePointer<UInt8>.allocate(capacity: count)
        bytes.withUnsafeBytes { raw in
            if let base = raw.bindMemory(to: UInt8.self).baseAddress { ptr.update(from: base, count: count) }
        }
        bytes.resetBytes(in: 0..<bytes.count)
        guard mlock(ptr, count) == 0 else {
            ptr.initialize(repeating: 0, count: count)
            ptr.deallocate()
            throw CeremonyError.transactionFailed("audit HMAC key mlock failed: errno=\(errno)")
        }
    }

    func withUnsafeBytes<R>(_ body: (UnsafePointer<UInt8>, Int) throws -> R) throws -> R {
        try body(UnsafePointer(ptr), count)
    }

    func fingerprintHex() -> String {
        var data = Data(bytes: ptr, count: count)
        defer { data.resetBytes(in: 0..<data.count) }
        return sha256Hex(data)
    }

    deinit {
        ptr.initialize(repeating: 0, count: count)
        _ = munlock(ptr, count)
        ptr.deallocate()
    }
}

private enum AuditHMACSeal {
    static func deriveKey(for chainPath: String, policy: PathPolicy) throws -> LockedAuditKey {
        guard SecureEnclave.isAvailable else { throw CeremonyError.secureEnclaveUnavailable("SecureEnclave.isAvailable returned false for audit HMAC seal") }
        let blobURL = policy.homeJarvis.appendingPathComponent("audit/seal_master.se.blob")
        try FileManager.default.createDirectory(at: blobURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let privateKey: SecureEnclave.P256.KeyAgreement.PrivateKey
        if FileManager.default.fileExists(atPath: blobURL.path) {
            let fd = try policy.pathPolicyOpen(blobURL, flags: O_RDONLY)
            defer { close(fd) }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = read(fd, &buffer, buffer.count)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw CeremonyError.transactionFailed("audit seal blob read failed: errno=\(errno)")
                }
                if n == 0 { break }
                data.append(buffer, count: n)
            }
            privateKey = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: data)
        } else {
            privateKey = try SecureEnclave.P256.KeyAgreement.PrivateKey()
            try writeBlobAtomically0600(privateKey.dataRepresentation, to: blobURL, errorContext: "audit seal master blob")
        }
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: privateKey.publicKey)
        let symmetric = shared.hkdfDerivedSymmetricKey(using: SHA256.self,
                                                       salt: Data("JARVIS-AuditHMAC-v1".utf8),
                                                       sharedInfo: Data(HKDFDomain.auditHmacKey.rawValue.utf8),
                                                       outputByteCount: 32)
        return try LockedAuditKey(symmetric)
    }
}

public final class AuditLogger {
    private let logURL: URL
    private let policy: PathPolicy
    public init(logURL: URL, policy: PathPolicy) {
        self.logURL = logURL
        self.policy = policy
    }
    /// Append a tamper-evident audit event. Throws on any failure — caller MUST handle.
    /// Silent swallow is forbidden: an audit log that "looks fine" but has gaps is worse
    /// than no audit log, because it lies. The forensic record is load-bearing for
    /// digital-personhood evidentiary claims and for nation-state adversarial scenarios
    /// (Phase 7.5e identity spoofing, 7.5n legal-process mapping).
    public func keyFingerprintHex() throws -> String {
        try AuditHMACSeal.deriveKey(for: logURL.path, policy: policy).fingerprintHex()
    }

    public func record(_ step: String, outcome: String, metadata: [String: String] = [:]) throws {
        try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try policy.validateLocalWrite(logURL)
        var fields = metadata.reduce(into: [String: String]()) { out, item in
            out[item.key] = String(item.value.prefix(24))
        }
        fields["op"] = "GMRI-RBH"; fields["sub"] = jarvisSubjectID
        fields["ts"] = String(Int64(Date().timeIntervalSince1970))
        let data = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        guard let json = String(data: data, encoding: .utf8) else { throw CeremonyError.transactionFailed("audit metadata UTF-8 encoding failed") }
        let key = try AuditHMACSeal.deriveKey(for: logURL.path, policy: policy)
        var err: UnsafeMutablePointer<CChar>?
        let ok = try key.withUnsafeBytes { keyPtr, keyLen in
            jarvis_cv_audit_append(logURL.path, keyPtr, UInt(keyLen), step, outcome, json, &err)
        }
        if !ok {
            let message = err.map { String(cString: $0) } ?? "unknown native audit failure"
            if let err { jarvis_cv_free(err) }
            throw CeremonyError.transactionFailed("audit append failed for step \"\(step)\": \(message)")
        }
        let legacyKeyURL = logURL.deletingPathExtension().appendingPathExtension("key")
        if FileManager.default.fileExists(atPath: legacyKeyURL.path) {
            guard unlink(legacyKeyURL.path) == 0 else {
                throw CeremonyError.transactionFailed("legacy plaintext audit key removal failed at \(legacyKeyURL.path): errno=\(errno)")
            }
        }
    }
}

extension Data { static func + (lhs: Data, rhs: Data) -> Data { var d = lhs; d.append(rhs); return d } }
