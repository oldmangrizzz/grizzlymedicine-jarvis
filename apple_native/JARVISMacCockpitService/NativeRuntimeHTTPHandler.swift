import Darwin
import Foundation

typealias NativeChatCompletion = @Sendable (_ messages: [NativeChatMessage], _ requestedModel: String) async throws -> NativeModelReply
typealias NativeAudioTranscription = @Sendable (_ recording: NativeVoiceRecording) async throws -> String
typealias NativeSpeechSynthesis = @Sendable (_ text: String, _ status: NativeVoiceStatus) async throws -> NativeSpeechResponse

private struct HTTPNonceStoreLoadResult {
    let activeExpiriesByKey: [String: UInt64]
    let futureDatedKeys: Set<String>
}

private struct IPRateLimitStoreLoadResult {
    let failuresByIP: [String: [Date]]
    let lockoutsByIP: [String: Date]
}

private final class HTTPNonceStore {
    static let ttlSeconds = 5 * 60
    static let ttlNanoseconds = UInt64(ttlSeconds) * 1_000_000_000
    private static let pruneSizeThreshold = 64 * 1024
    private static let pruneCountThreshold = 256
    private static let futureSkewToleranceSeconds = 1

    private struct Record {
        let key: String
        let observedAtUnix: Int
    }

    private let path: String
    private let nowUnix: @Sendable () -> Int
    private let nowMono: @Sendable () -> UInt64

    init(
        nowUnix: @escaping @Sendable () -> Int = { Int(Date().timeIntervalSince1970) },
        nowMono: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    ) {
        self.nowUnix = nowUnix
        self.nowMono = nowMono
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["JARVIS_HTTP_NONCE_STORE"], !override.isEmpty {
            path = NSString(string: override).expandingTildeInPath
        } else {
            path = NSString(string: "~/.jarvis/state/http_nonces.jsonl").expandingTildeInPath
        }
        #else
        path = NSString(string: "~/.jarvis/state/http_nonces.jsonl").expandingTildeInPath
        #endif
    }

    func loadUnexpired() throws -> HTTPNonceStoreLoadResult {
        let nowUnix = nowUnix()
        let nowMono = nowMono()
        let fd = try openLockedFile(flags: O_RDONLY | O_CREAT | O_CLOEXEC, mode: 0o600)
        defer { flock(fd, LOCK_UN); close(fd) }
        let data = try readAll(from: fd)
        let parsed = parseRecords(from: data, nowUnix: nowUnix, auditMalformed: true)
        var active: [String: UInt64] = [:]
        for record in parsed.active {
            let elapsedSeconds = nowUnix - record.observedAtUnix
            let remainingSeconds = Self.ttlSeconds - elapsedSeconds
            guard remainingSeconds > 0 else { continue }
            let expiry = nowMono + UInt64(remainingSeconds) * 1_000_000_000
            active[record.key] = max(active[record.key] ?? 0, expiry)
        }
        if data.count > Self.pruneSizeThreshold || parsed.active.count > Self.pruneCountThreshold || parsed.droppedExpiredOrFuture {
            try rewrite(records: parsed.active)
        }
        return HTTPNonceStoreLoadResult(activeExpiriesByKey: active, futureDatedKeys: parsed.futureDatedKeys)
    }

    func append(key: String, observedAtUnix: Int) throws {
        let fd = try openLockedFile(flags: O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, mode: 0o600)
        defer { flock(fd, LOCK_UN); close(fd) }
        let object: [String: Any] = ["key": key, "observed_unix": observedAtUnix]
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        data.append(0x0A)
        guard data.count <= 512 else {
            throw NativeRuntimeHTTPServiceError.nonceStoreWriteFailed("nonce record exceeds 512-byte audit append cap")
        }
        try writeAll(data, to: fd)
        guard fsync(fd) == 0 else {
            throw NativeRuntimeHTTPServiceError.nonceStoreWriteFailed(String(cString: strerror(errno)))
        }
    }

    func pruneExpired() throws {
        let nowUnix = nowUnix()
        let fd = try openLockedFile(flags: O_RDONLY | O_CREAT | O_CLOEXEC, mode: 0o600)
        defer { flock(fd, LOCK_UN); close(fd) }
        let data = try readAll(from: fd)
        let parsed = parseRecords(from: data, nowUnix: nowUnix, auditMalformed: false)
        if parsed.droppedExpiredOrFuture || data.count > Self.pruneSizeThreshold || parsed.active.count > Self.pruneCountThreshold {
            try rewrite(records: parsed.active)
        }
    }

    private func openLockedFile(flags: Int32, mode: mode_t) throws -> Int32 {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = open(path, flags, mode)
        guard fd >= 0 else {
            throw NativeRuntimeHTTPServiceError.nonceStoreOpenFailed(path, String(cString: strerror(errno)))
        }
        guard flock(fd, LOCK_EX) == 0 else {
            let message = String(cString: strerror(errno))
            close(fd)
            throw NativeRuntimeHTTPServiceError.nonceStoreOpenFailed(path, message)
        }
        fchmod(fd, 0o600)
        return fd
    }

    private func readAll(from fd: Int32) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n < 0 {
                if errno == EINTR { continue }
                throw NativeRuntimeHTTPServiceError.nonceStoreReadFailed(String(cString: strerror(errno)))
            }
            if n == 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }

    private func writeAll(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var written = 0
            while written < data.count {
                let n = write(fd, base.advanced(by: written), data.count - written)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw NativeRuntimeHTTPServiceError.nonceStoreWriteFailed(String(cString: strerror(errno)))
                }
                written += n
            }
        }
    }

    private func parseRecords(from data: Data, nowUnix: Int, auditMalformed: Bool) -> (active: [Record], futureDatedKeys: Set<String>, droppedExpiredOrFuture: Bool) {
        guard let text = String(data: data, encoding: .utf8) else {
            if !data.isEmpty, auditMalformed {
                do { try NativeSecurityAudit.record("http_nonce_store_malformed", fields: ["reason": "utf8"]) } catch { fputs("JARVIS audit write failed: \(error)\n", stderr) } // [audit-log: discard on I/O failure; secondary diagnostic path]
            }
            return ([], [], !data.isEmpty)
        }
        var active: [Record] = []
        var futureDatedKeys: Set<String> = []
        var dropped = false
        for line in text.split(separator: "\n") {
            guard let lineData = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let key = object["key"] as? String,
                  let observed = object["observed_unix"] as? Int else {
                dropped = true
                if auditMalformed {
                    do { try NativeSecurityAudit.record("http_nonce_store_malformed", fields: ["reason": "schema"]) } catch { fputs("JARVIS audit write failed: \(error)\n", stderr) } // [audit-log: discard on I/O failure; secondary diagnostic path]
                }
                continue
            }
            if observed > nowUnix + Self.futureSkewToleranceSeconds {
                dropped = true
                futureDatedKeys.insert(key)
                do { try NativeSecurityAudit.record("http_nonce_store_future_dated", fields: ["key": key, "observed_unix": observed, "now_unix": nowUnix]) } catch { fputs("JARVIS audit write failed: \(error)\n", stderr) } // [audit-log: discard on I/O failure; secondary diagnostic path]
                continue
            }
            if nowUnix - observed >= Self.ttlSeconds {
                dropped = true
                continue
            }
            active.append(Record(key: key, observedAtUnix: observed))
        }
        return (active, futureDatedKeys, dropped)
    }

    private func rewrite(records: [Record]) throws {
        let url = URL(fileURLWithPath: path)
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".http_nonces.jsonl.gc.\(getpid()).\(UUID().uuidString)").path
        let fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            throw NativeRuntimeHTTPServiceError.nonceStoreWriteFailed(String(cString: strerror(errno)))
        }
        var closed = false
        do {
            for record in records {
                let object: [String: Any] = ["key": record.key, "observed_unix": record.observedAtUnix]
                var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
                data.append(0x0A)
                guard data.count <= 512 else {
                    throw NativeRuntimeHTTPServiceError.nonceStoreWriteFailed("nonce record exceeds 512-byte audit append cap")
                }
                try writeAll(data, to: fd)
            }
            guard fsync(fd) == 0 else {
                throw NativeRuntimeHTTPServiceError.nonceStoreWriteFailed(String(cString: strerror(errno)))
            }
            guard close(fd) == 0 else {
                closed = true
                throw NativeRuntimeHTTPServiceError.nonceStoreWriteFailed(String(cString: strerror(errno)))
            }
            closed = true
            guard rename(tmp, path) == 0 else {
                throw NativeRuntimeHTTPServiceError.nonceStoreWriteFailed(String(cString: strerror(errno)))
            }
        } catch {
            if !closed { close(fd) }
            unlink(tmp)
            throw error
        }
    }
}

private final class IPRateLimitStore {
    static let failureWindowSeconds = 60
    static let lockoutDurationSeconds = 5 * 60
    private static let pruneSizeThreshold = 64 * 1024
    private static let pruneCountThreshold = 256

    private enum RecordType: String {
        case authFail = "auth_fail"
        case locked = "locked"
    }

    private struct FailureRecord {
        let ip: String
        let observedAtUnix: Int
    }

    private struct LockoutRecord {
        let ip: String
        let untilUnix: Int
    }

    private let failuresPath: String
    private let lockoutsPath: String
    private let nowUnix: @Sendable () -> Int

    init(
        nowUnix: @escaping @Sendable () -> Int = { Int(Date().timeIntervalSince1970) }
    ) {
        self.nowUnix = nowUnix
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["JARVIS_HTTP_AUTH_FAILURES_STORE"], !override.isEmpty {
            failuresPath = NSString(string: override).expandingTildeInPath
        } else {
            failuresPath = NSString(string: "~/.jarvis/state/http_auth_failures.jsonl").expandingTildeInPath
        }
        if let override = ProcessInfo.processInfo.environment["JARVIS_HTTP_AUTH_LOCKOUTS_STORE"], !override.isEmpty {
            lockoutsPath = NSString(string: override).expandingTildeInPath
        } else {
            lockoutsPath = NSString(string: "~/.jarvis/state/http_auth_lockouts.jsonl").expandingTildeInPath
        }
        #else
        failuresPath = NSString(string: "~/.jarvis/state/http_auth_failures.jsonl").expandingTildeInPath
        lockoutsPath = NSString(string: "~/.jarvis/state/http_auth_lockouts.jsonl").expandingTildeInPath
        #endif
    }

    func loadUnexpired() throws -> IPRateLimitStoreLoadResult {
        let nowUnix = nowUnix()
        let failures = try loadFailures(nowUnix: nowUnix)
        let lockouts = try loadLockouts(nowUnix: nowUnix)
        return IPRateLimitStoreLoadResult(failuresByIP: failures, lockoutsByIP: lockouts)
    }

    func appendFailure(ip: String, observedAtUnix: Int) throws {
        let fd = try openLockedFile(path: failuresPath, flags: O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, mode: 0o600)
        defer { flock(fd, LOCK_UN); close(fd) }
        let object: [String: Any] = ["event": RecordType.authFail.rawValue, "ip": ip, "observed_unix": observedAtUnix]
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        data.append(0x0A)
        guard data.count <= 512 else {
            throw NativeRuntimeHTTPServiceError.authStoreWriteFailed("auth failure record exceeds 512-byte audit append cap")
        }
        try writeAll(data, to: fd)
        guard fsync(fd) == 0 else {
            throw NativeRuntimeHTTPServiceError.authStoreWriteFailed(String(cString: strerror(errno)))
        }
    }

    func appendLockout(ip: String, untilUnix: Int) throws {
        let fd = try openLockedFile(path: lockoutsPath, flags: O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, mode: 0o600)
        defer { flock(fd, LOCK_UN); close(fd) }
        let object: [String: Any] = ["event": RecordType.locked.rawValue, "ip": ip, "until_unix": untilUnix]
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        data.append(0x0A)
        guard data.count <= 512 else {
            throw NativeRuntimeHTTPServiceError.authStoreWriteFailed("auth lockout record exceeds 512-byte audit append cap")
        }
        try writeAll(data, to: fd)
        guard fsync(fd) == 0 else {
            throw NativeRuntimeHTTPServiceError.authStoreWriteFailed(String(cString: strerror(errno)))
        }
    }

    private func loadFailures(nowUnix: Int) throws -> [String: [Date]] {
        let fd = try openLockedFile(path: failuresPath, flags: O_RDONLY | O_CREAT | O_CLOEXEC, mode: 0o600)
        defer { flock(fd, LOCK_UN); close(fd) }
        let data = try readAll(from: fd)
        let parsed = parseFailureRecords(from: data, nowUnix: nowUnix)
        if data.count > Self.pruneSizeThreshold || parsed.active.count > Self.pruneCountThreshold || parsed.droppedExpired {
            try rewriteFailures(records: parsed.active)
        }
        var failuresByIP: [String: [Date]] = [:]
        for record in parsed.active {
            let date = Date(timeIntervalSince1970: TimeInterval(record.observedAtUnix))
            failuresByIP[record.ip, default: []].append(date)
        }
        return failuresByIP
    }

    private func loadLockouts(nowUnix: Int) throws -> [String: Date] {
        let fd = try openLockedFile(path: lockoutsPath, flags: O_RDONLY | O_CREAT | O_CLOEXEC, mode: 0o600)
        defer { flock(fd, LOCK_UN); close(fd) }
        let data = try readAll(from: fd)
        let parsed = parseLockoutRecords(from: data, nowUnix: nowUnix)
        if data.count > Self.pruneSizeThreshold || parsed.active.count > Self.pruneCountThreshold || parsed.droppedExpired {
            try rewriteLockouts(records: parsed.active)
        }
        var lockoutsByIP: [String: Date] = [:]
        for record in parsed.active {
            let date = Date(timeIntervalSince1970: TimeInterval(record.untilUnix))
            lockoutsByIP[record.ip] = max(lockoutsByIP[record.ip] ?? .distantPast, date)
        }
        return lockoutsByIP
    }

    private func openLockedFile(path: String, flags: Int32, mode: mode_t) throws -> Int32 {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = open(path, flags, mode)
        guard fd >= 0 else {
            throw NativeRuntimeHTTPServiceError.authStoreOpenFailed(path, String(cString: strerror(errno)))
        }
        guard flock(fd, LOCK_EX) == 0 else {
            let message = String(cString: strerror(errno))
            close(fd)
            throw NativeRuntimeHTTPServiceError.authStoreOpenFailed(path, message)
        }
        fchmod(fd, 0o600)
        return fd
    }

    private func readAll(from fd: Int32) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n < 0 {
                if errno == EINTR { continue }
                throw NativeRuntimeHTTPServiceError.authStoreReadFailed(String(cString: strerror(errno)))
            }
            if n == 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }

    private func writeAll(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var written = 0
            while written < data.count {
                let n = write(fd, base.advanced(by: written), data.count - written)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw NativeRuntimeHTTPServiceError.authStoreWriteFailed(String(cString: strerror(errno)))
                }
                written += n
            }
        }
    }

    private func parseFailureRecords(from data: Data, nowUnix: Int) -> (active: [FailureRecord], droppedExpired: Bool) {
        guard let text = String(data: data, encoding: .utf8) else {
            if !data.isEmpty {
                do { try NativeSecurityAudit.record("http_auth_store_malformed", fields: ["type": "failures", "reason": "utf8"]) } catch { fputs("JARVIS audit write failed: \(error)\n", stderr) } // [audit-log: discard on I/O failure; secondary diagnostic path]
            }
            return ([], !data.isEmpty)
        }
        var active: [FailureRecord] = []
        var dropped = false
        for line in text.split(separator: "\n") {
            guard let lineData = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let event = object["event"] as? String,
                  event == RecordType.authFail.rawValue,
                  let ip = object["ip"] as? String,
                  let observed = object["observed_unix"] as? Int else {
                dropped = true
                continue
            }
            if nowUnix - observed >= Self.failureWindowSeconds {
                dropped = true
                continue
            }
            active.append(FailureRecord(ip: ip, observedAtUnix: observed))
        }
        return (active, dropped)
    }

    private func parseLockoutRecords(from data: Data, nowUnix: Int) -> (active: [LockoutRecord], droppedExpired: Bool) {
        guard let text = String(data: data, encoding: .utf8) else {
            if !data.isEmpty {
                do { try NativeSecurityAudit.record("http_auth_store_malformed", fields: ["type": "lockouts", "reason": "utf8"]) } catch { fputs("JARVIS audit write failed: \(error)\n", stderr) } // [audit-log: discard on I/O failure; secondary diagnostic path]
            }
            return ([], !data.isEmpty)
        }
        var active: [LockoutRecord] = []
        var dropped = false
        for line in text.split(separator: "\n") {
            guard let lineData = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let event = object["event"] as? String,
                  event == RecordType.locked.rawValue,
                  let ip = object["ip"] as? String,
                  let until = object["until_unix"] as? Int else {
                dropped = true
                continue
            }
            if until <= nowUnix {
                dropped = true
                continue
            }
            active.append(LockoutRecord(ip: ip, untilUnix: until))
        }
        return (active, dropped)
    }

    private func rewriteFailures(records: [FailureRecord]) throws {
        let url = URL(fileURLWithPath: failuresPath)
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".http_auth_failures.jsonl.gc.\(getpid()).\(UUID().uuidString)").path
        let fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            throw NativeRuntimeHTTPServiceError.authStoreWriteFailed(String(cString: strerror(errno)))
        }
        var closed = false
        do {
            for record in records {
                let object: [String: Any] = ["event": RecordType.authFail.rawValue, "ip": record.ip, "observed_unix": record.observedAtUnix]
                var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
                data.append(0x0A)
                guard data.count <= 512 else {
                    throw NativeRuntimeHTTPServiceError.authStoreWriteFailed("auth failure record exceeds 512-byte audit append cap")
                }
                try writeAll(data, to: fd)
            }
            guard fsync(fd) == 0 else {
                throw NativeRuntimeHTTPServiceError.authStoreWriteFailed(String(cString: strerror(errno)))
            }
            guard close(fd) == 0 else {
                closed = true
                throw NativeRuntimeHTTPServiceError.authStoreWriteFailed(String(cString: strerror(errno)))
            }
            closed = true
            guard rename(tmp, failuresPath) == 0 else {
                throw NativeRuntimeHTTPServiceError.authStoreWriteFailed(String(cString: strerror(errno)))
            }
        } catch {
            if !closed { close(fd) }
            unlink(tmp)
            throw error
        }
    }

    private func rewriteLockouts(records: [LockoutRecord]) throws {
        let url = URL(fileURLWithPath: lockoutsPath)
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".http_auth_lockouts.jsonl.gc.\(getpid()).\(UUID().uuidString)").path
        let fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            throw NativeRuntimeHTTPServiceError.authStoreWriteFailed(String(cString: strerror(errno)))
        }
        var closed = false
        do {
            for record in records {
                let object: [String: Any] = ["event": RecordType.locked.rawValue, "ip": record.ip, "until_unix": record.untilUnix]
                var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
                data.append(0x0A)
                guard data.count <= 512 else {
                    throw NativeRuntimeHTTPServiceError.authStoreWriteFailed("auth lockout record exceeds 512-byte audit append cap")
                }
                try writeAll(data, to: fd)
            }
            guard fsync(fd) == 0 else {
                throw NativeRuntimeHTTPServiceError.authStoreWriteFailed(String(cString: strerror(errno)))
            }
            guard close(fd) == 0 else {
                closed = true
                throw NativeRuntimeHTTPServiceError.authStoreWriteFailed(String(cString: strerror(errno)))
            }
            closed = true
            guard rename(tmp, lockoutsPath) == 0 else {
                throw NativeRuntimeHTTPServiceError.authStoreWriteFailed(String(cString: strerror(errno)))
            }
        } catch {
            if !closed { close(fd) }
            unlink(tmp)
            throw error
        }
    }
}

actor NativeRuntimeHTTPHandler {
    private let runtime: NativeRuntimeBridge
    private let completeChat: NativeChatCompletion
    private let transcribeAudio: NativeAudioTranscription
    private let synthesizeSpeech: NativeSpeechSynthesis
    private var failedAuthByIP: [String: [Date]] = [:]
    private var lockedUntilByIP: [String: Date] = [:]
    private var nonceExpiryByKey: [String: UInt64] = [:]
    private var futureDatedNonceKeys: Set<String> = []
    private let nonceStore: HTTPNonceStore
    private let rateLimitStore: IPRateLimitStore
    private let nowUnix: @Sendable () -> Int
    private let nowMono: @Sendable () -> UInt64
    private var lastNonceStorePruneMono: UInt64 = 0

    init(
        runtime: NativeRuntimeBridge? = nil,
        modelClient: NativeModelClient = NativeModelClient(),
        transcriber: NativeTranscriptionClient = NativeTranscriptionClient(),
        speechClient: NativeSpeechClient = NativeSpeechClient(),
        chatCompletion: NativeChatCompletion? = nil,
        audioTranscription: NativeAudioTranscription? = nil,
        speechSynthesis: NativeSpeechSynthesis? = nil,
        nowUnix: @escaping @Sendable () -> Int = { Int(Date().timeIntervalSince1970) },
        nowMono: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    ) throws {
        self.runtime = try runtime ?? NativeRuntimeBridge()
        self.nowUnix = nowUnix
        self.nowMono = nowMono
        self.nonceStore = HTTPNonceStore(nowUnix: nowUnix, nowMono: nowMono)
        self.rateLimitStore = IPRateLimitStore(nowUnix: nowUnix)
        let modelClient = modelClient
        let transcriber = transcriber
        let speechClient = speechClient
        self.completeChat = chatCompletion ?? { messages, requestedModel in
            try await modelClient.complete(messages: messages, requestedModel: requestedModel)
        }
        self.transcribeAudio = audioTranscription ?? { recording in
            try await transcriber.transcribe(recording)
        }
        self.synthesizeSpeech = speechSynthesis ?? { text, status in
            try await speechClient.synthesize(text, status: status)
        }
        let persistedNonces = try nonceStore.loadUnexpired()
        self.nonceExpiryByKey = persistedNonces.activeExpiriesByKey
        self.futureDatedNonceKeys = persistedNonces.futureDatedKeys
        let persistedRateLimits = try rateLimitStore.loadUnexpired()
        self.failedAuthByIP = persistedRateLimits.failuresByIP
        self.lockedUntilByIP = persistedRateLimits.lockoutsByIP
    }

    func handle(_ request: NativeHTTPRequest, configuration: NativeRuntimeHTTPServiceConfiguration) async -> NativeHTTPResponse {
        let origin = request.header("origin")
        guard let corsOrigin = allowedCORSOrigin(origin) else {
            if origin != nil {
                do { try NativeSecurityAudit.record("http_invalid_origin", fields: ["origin": origin ?? "", "remote_ip": request.remoteIP]) } catch { fputs("JARVIS audit write failed: \(error)\n", stderr) }
                return recordFailureIfNeeded(.json(status: 403, object: NativeRuntimeHTTPPayload.error(
                    status: "invalid_origin",
                    message: "invalid_origin",
                    receipt: "native-http-origin-rejected"
                )), request: request)
            }
            return await handleAfterOriginGate(request, configuration: configuration, corsOrigin: nil)
        }
        return await handleAfterOriginGate(request, configuration: configuration, corsOrigin: corsOrigin)
    }

    private func handleAfterOriginGate(
        _ request: NativeHTTPRequest,
        configuration: NativeRuntimeHTTPServiceConfiguration,
        corsOrigin: String?
    ) async -> NativeHTTPResponse {
        if request.method == "OPTIONS" {
            return NativeHTTPResponse.empty(status: 204).withCORS(origin: corsOrigin)
        }

        guard validHostHeader(request.header("host"), port: configuration.port) else {
            do { try NativeSecurityAudit.record("http_invalid_host", fields: ["host": request.header("host") ?? "", "remote_ip": request.remoteIP]) } catch { fputs("JARVIS audit write failed: \(error)\n", stderr) } // [audit-log: discard on I/O failure; secondary diagnostic path]
            return .json(status: 400, object: ["error": "invalid_host"])
        }

        if let retryAfter = retryAfterForLockout(remoteIP: request.remoteIP) {
            do { try NativeSecurityAudit.record("http_auth_lockout_active", fields: ["remote_ip": request.remoteIP]) } catch { fputs("JARVIS audit write failed: \(error)\n", stderr) }
            return .json(status: 429, object: NativeRuntimeHTTPPayload.error(
                status: "rate_limited",
                message: "too_many_requests",
                receipt: "native-http-auth-rate-limited"
            ), headers: ["Retry-After": String(Int(ceil(retryAfter)))])
        }

        if let authFailure = authorize(request, configuration: configuration) {
            return recordFailureIfNeeded(authFailure.withCORS(origin: corsOrigin), request: request)
        }

        if let replayFailure = validateReplayHeaders(request) {
            return recordFailureIfNeeded(replayFailure.withCORS(origin: corsOrigin), request: request)
        }

        let response: NativeHTTPResponse
        switch (request.method, request.path) {
        case ("GET", "/health"), ("GET", "/companion/manifest"):
            response = manifest(configuration: configuration)
        case ("GET", "/state"), ("GET", "/companion/status"):
            response = stateReceipt()
        case ("GET", "/skills"), ("GET", "/companion/skills"):
            response = skillCatalogReceipt()
        case ("POST", "/companion/turn"):
            response = await companionTurn(request)
        case ("POST", "/companion/transcribe"):
            response = await companionTranscribe(request)
        case ("GET", "/companion/speech"):
            response = speechStatus()
        case ("POST", "/companion/speech"):
            response = await companionSpeech(request)
        case ("POST", "/companion/skill"):
            response = companionSkillBlocked(request)
        default:
            if knownPath(request.path) {
                response = .json(status: 405, object: NativeRuntimeHTTPPayload.error(
                    status: "method_not_allowed",
                    message: "\(request.method) is not supported for \(request.path).",
                    receipt: "native-http-method-blocked"
                ))
            } else {
                response = .json(status: 404, object: NativeRuntimeHTTPPayload.error(
                    status: "not_found",
                    message: "No native runtime route for \(request.path).",
                    receipt: "native-http-route-missing",
                    extra: ["routes": NativeRuntimeHTTPServiceConfiguration.defaultRoutes]
                ))
            }
        }
        return response.withCORS(origin: corsOrigin)
    }

    private func allowedCORSOrigin(_ origin: String?) -> String? {
        guard let origin else { return nil }
        guard let url = URL(string: origin), let host = url.host?.lowercased() else { return nil }
        guard (url.scheme == "http" || url.scheme == "https"), host == "localhost" || host == "127.0.0.1" else { return nil }
        return origin
    }

    private func validHostHeader(_ host: String?, port: UInt16) -> Bool {
        guard let host else { return false }
        let expectedPort = String(port)
        return host == "127.0.0.1:\(expectedPort)" || host == "localhost:\(expectedPort)" || host == "[::1]:\(expectedPort)"
    }

    private func retryAfterForLockout(remoteIP: String) -> TimeInterval? {
        guard let lockedUntil = lockedUntilByIP[remoteIP] else { return nil }
        let remaining = lockedUntil.timeIntervalSince(Date())
        if remaining <= 0 {
            lockedUntilByIP.removeValue(forKey: remoteIP)
            return nil
        }
        return remaining
    }

    private func recordFailureIfNeeded(_ response: NativeHTTPResponse, request: NativeHTTPRequest) -> NativeHTTPResponse {
        guard response.statusCode == 401 || response.statusCode == 403 else { return response }
        let now = Date()
        let nowUnixValue = nowUnix()
        let windowStart = now.addingTimeInterval(-60)
        var failures = (failedAuthByIP[request.remoteIP] ?? []).filter { $0 >= windowStart }
        failures.append(now)
        
        do {
            try rateLimitStore.appendFailure(ip: request.remoteIP, observedAtUnix: nowUnixValue)
        } catch {
            do { try NativeSecurityAudit.record("http_auth_store_unavailable", fields: ["remote_ip": request.remoteIP, "error": error.localizedDescription]) } catch { fputs("JARVIS audit write failed: \(error)\n", stderr) } // [audit-log: raw error retained; not surfaced in UI]
            return .json(status: 503, object: NativeRuntimeHTTPPayload.error(
                status: "unavailable",
                message: "auth_store_unavailable",
                receipt: "native-http-auth-store-unavailable",
                extra: ["error": "auth_store_unavailable"]
            ))
        }
        
        failedAuthByIP[request.remoteIP] = failures
        if failures.count >= 5 {
            let lockoutUntil = now.addingTimeInterval(5 * 60)
            let lockoutUntilUnix = Int(lockoutUntil.timeIntervalSince1970)
            do {
                try rateLimitStore.appendLockout(ip: request.remoteIP, untilUnix: lockoutUntilUnix)
            } catch {
                do { try NativeSecurityAudit.record("http_auth_store_unavailable", fields: ["remote_ip": request.remoteIP, "error": error.localizedDescription]) } catch { fputs("JARVIS audit write failed: \(error)\n", stderr) } // [audit-log: raw error retained; not surfaced in UI]
                return .json(status: 503, object: NativeRuntimeHTTPPayload.error(
                    status: "unavailable",
                    message: "auth_store_unavailable",
                    receipt: "native-http-auth-store-unavailable",
                    extra: ["error": "auth_store_unavailable"]
                ))
            }
            lockedUntilByIP[request.remoteIP] = lockoutUntil
            failedAuthByIP[request.remoteIP] = []
            do { try NativeSecurityAudit.record("http_auth_rate_limit_threshold", fields: ["remote_ip": request.remoteIP, "failures": failures.count]) } catch { fputs("JARVIS audit write failed: \(error)\n", stderr) }
        }
        return response
    }

    private func validateReplayHeaders(_ request: NativeHTTPRequest) -> NativeHTTPResponse? {
        guard request.path.hasPrefix("/companion/"), request.path != "/companion/manifest" else { return nil }
        evictExpiredNonces()
        guard let nonce = request.header("x-jarvis-nonce"), validNonce(nonce) else {
            do { try NativeSecurityAudit.record("http_nonce_missing_or_invalid", fields: ["remote_ip": request.remoteIP]) } catch { fputs("JARVIS audit write failed: \(error)\n", stderr) }
            return .json(status: 401, object: NativeRuntimeHTTPPayload.error(
                status: "unauthorized",
                message: "nonce_missing_or_invalid",
                receipt: "native-http-nonce-invalid",
                extra: ["error": "nonce_missing_or_invalid"]
            ))
        }
        guard let timestampText = request.header("x-jarvis-timestamp"), let timestamp = Int(timestampText) else {
            do { try NativeSecurityAudit.record("http_nonce_timestamp_invalid", fields: ["remote_ip": request.remoteIP]) } catch { fputs("JARVIS audit write failed: \(error)\n", stderr) }
            return .json(status: 401, object: NativeRuntimeHTTPPayload.error(
                status: "unauthorized",
                message: "nonce_window_exceeded",
                receipt: "native-http-nonce-window",
                extra: ["error": "nonce_window_exceeded"]
            ))
        }
        let unixNow = nowUnix()
        guard abs(unixNow - timestamp) <= 30 else {
            do { try NativeSecurityAudit.record("http_nonce_window_exceeded", fields: ["remote_ip": request.remoteIP]) } catch { fputs("JARVIS audit write failed: \(error)\n", stderr) }
            return .json(status: 401, object: NativeRuntimeHTTPPayload.error(
                status: "unauthorized",
                message: "nonce_window_exceeded",
                receipt: "native-http-nonce-window",
                extra: ["error": "nonce_window_exceeded"]
            ))
        }
        let key = "\(nonce):\(timestamp)"
        guard nonceExpiryByKey[key] == nil, futureDatedNonceKeys.contains(key) == false else {
            do { try NativeSecurityAudit.record("http_nonce_reuse", fields: ["remote_ip": request.remoteIP]) } catch { fputs("JARVIS audit write failed: \(error)\n", stderr) }
            return .json(status: 401, object: NativeRuntimeHTTPPayload.error(
                status: "unauthorized",
                message: "nonce_reuse",
                receipt: "native-http-nonce-reuse",
                extra: ["error": "nonce_reuse"]
            ))
        }
        do {
            try nonceStore.append(key: key, observedAtUnix: unixNow)
        } catch {
            do { try NativeSecurityAudit.record("http_nonce_store_unavailable", fields: ["remote_ip": request.remoteIP, "error": error.localizedDescription]) } catch { fputs("JARVIS audit write failed: \(error)\n", stderr) } // [audit-log: raw error retained; not surfaced in UI]
            return .json(status: 503, object: NativeRuntimeHTTPPayload.error(
                status: "unavailable",
                message: "nonce_store_unavailable",
                receipt: "native-http-nonce-store-unavailable",
                extra: ["error": "nonce_store_unavailable"]
            ))
        }
        let expiry = nowMono() + HTTPNonceStore.ttlNanoseconds
        nonceExpiryByKey[key] = expiry
        return nil
    }

    private func evictExpiredNonces() {
        let now = nowMono()
        nonceExpiryByKey = nonceExpiryByKey.filter { $0.value > now }
        if now >= lastNonceStorePruneMono + 60_000_000_000 {
            lastNonceStorePruneMono = now
            do {
                try nonceStore.pruneExpired()
            } catch {
                do { try NativeSecurityAudit.record("http_nonce_store_prune_failed", fields: ["error": error.localizedDescription]) } catch { fputs("JARVIS audit write failed: \(error)\n", stderr) } // [audit-log: raw error retained; not surfaced in UI]
            }
        }
    }

    private func validNonce(_ nonce: String) -> Bool {

        if nonce.count == 32 {
            return nonce.allSatisfy(\.isHexDigit)
        }
        guard nonce.count == 36 else { return false }
        let dashOffsets: Set<Int> = [8, 13, 18, 23]
        for (offset, character) in nonce.enumerated() {
            if dashOffsets.contains(offset) {
                guard character == "-" else { return false }
            } else {
                guard character.isHexDigit else { return false }
            }
        }
        return true
    }

    private func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        let count = max(left.count, right.count)
        var difference = left.count ^ right.count
        for index in 0..<count {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            difference |= Int(a ^ b)
        }
        return difference == 0
    }

    private func authorize(
        _ request: NativeHTTPRequest,
        configuration: NativeRuntimeHTTPServiceConfiguration
    ) -> NativeHTTPResponse? {
        guard request.path.hasPrefix("/companion/"), request.path != "/companion/manifest" else {
            return nil
        }
        guard configuration.companionTokenConfigured, let expected = configuration.companionToken else {
            return .json(status: 503, object: NativeRuntimeHTTPPayload.error(
                status: "blocked",
                message: "JARVIS_RUNTIME_COMPANION_TOKEN is not configured for protected companion routes.",
                receipt: "native-http-token-unconfigured",
                extra: ["auth_required": true]
            ))
        }
        guard let supplied = request.header("x-jarvis-companion-token"), constantTimeEqual(supplied, expected) else {
            return .json(status: 401, object: NativeRuntimeHTTPPayload.error(
                status: "unauthorized",
                message: "Missing or invalid X-JARVIS-Companion-Token.",
                receipt: "native-http-token-rejected",
                extra: ["auth_required": true]
            ))
        }
        return nil
    }

    private func manifest(configuration: NativeRuntimeHTTPServiceConfiguration) -> NativeHTTPResponse {
        .json(status: 200, object: [
            "ok": true,
            "receipt": "native-runtime-http-service-manifest",
            "service": "native-runtime-http-service",
            "runtime": "native-swift-cpp-http",
            "python_beta_path": false,
            "rust_tauri_path": false,
            "web_speech_path": false,
            "native_system_voice_fallback": false,
            "base_url": configuration.baseURLText,
            "companion_token_configured": configuration.companionTokenConfigured,
            "routes": NativeRuntimeHTTPServiceConfiguration.defaultRoutes,
        ])
    }

    private func stateReceipt() -> NativeHTTPResponse {
        do {
            let state = try verifiedState()
            var object = state.httpObject
            object["ok"] = true
            object["receipt"] = "native-runtime-state"
            object["service"] = "native-runtime-http-service"
            object["rust_tauri_path"] = false
            object["web_speech_path"] = false
            object["native_system_voice_fallback"] = false
            return .json(status: 200, object: object)
        } catch {
            return .json(status: 503, object: unavailable(
                message: "Native runtime state unavailable: \(error.localizedDescription)", // [http-response: error detail on local socket only; not surfaced in UI]
                receipt: "native-runtime-state-unavailable",
                blocker: "runtime_state"
            ))
        }
    }

    private func skillCatalogReceipt() -> NativeHTTPResponse {
        do {
            var object = try runtime.skillCatalogObject()
            object["receipt"] = "native-runtime-skill-catalog"
            object["service"] = "native-runtime-http-service"
            object["runtime"] = "native-swift-cpp-http"
            object["python_beta_path"] = false
            return .json(status: 200, object: object)
        } catch {
            return .json(status: 503, object: unavailable(
                message: "Native skill catalog unavailable: \(error.localizedDescription)", // [http-response: error detail on local socket only; not surfaced in UI]
                receipt: "native-runtime-skills-unavailable",
                blocker: "skill_catalog"
            ))
        }
    }

    private func companionTurn(_ request: NativeHTTPRequest) async -> NativeHTTPResponse {
        do {
            let object = try request.jsonObject()
            let text = cleanString(object["text"])
            guard !text.isEmpty else {
                return .json(status: 400, object: NativeRuntimeHTTPPayload.error(
                    status: "bad_request",
                    message: "no text",
                    receipt: "native-companion-turn-empty"
                ))
            }

            let prepared = try runtime.prepareTurn(text)
            try validate(prepared.state)
            let modelReply = try await completeChat(prepared.messages, prepared.model)
            let committed = try runtime.commitTurn(text: text, reply: modelReply.text, model: modelReply.model)
            try validate(committed.state)

            var response: [String: Any] = [
                "ok": true,
                "status": "ready",
                "receipt": "native-companion-turn",
                "service": "native-runtime-http-service",
                "runtime": committed.state.runtime,
                "python_beta_path": committed.state.pythonBetaPath,
                "reply": committed.reply,
                "model": committed.model,
                "drift_to_prototype": committed.driftToPrototype > 0.0,
                "drift_to_prototype_score": committed.driftToPrototype,
                "ethics_conflict": committed.ethicsConflict,
                "endocrine": committed.state.endocrine,
                "ec_tone": committed.state.ecTone,
                "field": committed.state.field.httpArray,
                "state": committed.state.httpObject,
            ]
            if let registry = committed.state.skillRegistry?.httpObject {
                response["skill_registry"] = registry
            }
            return .json(status: 200, object: response)
        } catch {
            return .json(status: 503, object: unavailable(
                message: "Native model turn unavailable: \(error.localizedDescription)", // [http-response: error detail on local socket only; not surfaced in UI]
                receipt: "native-companion-turn-unavailable",
                blocker: "model_completion"
            ))
        }
    }

    private func companionTranscribe(_ request: NativeHTTPRequest) async -> NativeHTTPResponse {
        do {
            let object = try request.jsonObject()
            let audioBase64 = cleanString(object["audio_base64"]).isEmpty
                ? cleanString(object["audioBase64"])
                : cleanString(object["audio_base64"])
            let contentType = cleanString(object["content_type"]).isEmpty
                ? (cleanString(object["contentType"]).isEmpty ? "audio/mp4" : cleanString(object["contentType"]))
                : cleanString(object["content_type"])
            guard !audioBase64.isEmpty else {
                return .json(status: 400, object: NativeRuntimeHTTPPayload.error(
                    status: "bad_request",
                    message: "missing audio",
                    receipt: "native-companion-transcribe-missing-audio"
                ))
            }
            guard Self.allowedAudioContentTypes.contains(contentType.lowercased()) else {
                return .json(status: 400, object: NativeRuntimeHTTPPayload.error(
                    status: "bad_request",
                    message: "unsupported audio content type",
                    receipt: "native-companion-transcribe-content-type-blocked",
                    extra: ["content_type": contentType]
                ))
            }
            guard let audio = Data(base64Encoded: audioBase64) else {
                return .json(status: 400, object: NativeRuntimeHTTPPayload.error(
                    status: "bad_request",
                    message: "invalid audio encoding",
                    receipt: "native-companion-transcribe-invalid-base64"
                ))
            }
            guard audio.count >= 128 else {
                return .json(status: 400, object: NativeRuntimeHTTPPayload.error(
                    status: "bad_request",
                    message: "audio too short",
                    receipt: "native-companion-transcribe-audio-too-short"
                ))
            }
            guard audio.count <= 6_000_000 else {
                return .json(status: 413, object: NativeRuntimeHTTPPayload.error(
                    status: "payload_too_large",
                    message: "audio too large",
                    receipt: "native-companion-transcribe-audio-too-large"
                ))
            }

            let transcript = try await transcribeAudio(NativeVoiceRecording(data: audio, contentType: contentType))
            return .json(status: 200, object: [
                "ok": true,
                "status": "ready",
                "receipt": "native-companion-transcribe",
                "service": "native-runtime-http-service",
                "runtime": "native-swift-cpp-http",
                "python_beta_path": false,
                "web_speech_path": false,
                "text": transcript,
                "transcript": transcript,
            ])
        } catch {
            return .json(status: 503, object: unavailable(
                message: "Native transcription unavailable: \(error.localizedDescription)", // [http-response: error detail on local socket only; not surfaced in UI]
                receipt: "native-companion-transcribe-unavailable",
                blocker: "native_transcription"
            ))
        }
    }

    private func speechStatus() -> NativeHTTPResponse {
        do {
            let status = try runtime.voiceStatus()
            try validate(status)
            var object = status.httpObject
            object["receipt"] = "native-companion-speech-status"
            object["service"] = "native-runtime-http-service"
            object["speech_allowed"] = status.available
            object["native_voice_service"] = status.available ? "ready" : "unavailable"
            object["web_speech_path"] = false
            object["native_system_voice_fallback"] = false
            object["python_tts_path"] = false
            return .json(status: 200, object: object)
        } catch {
            return .json(status: 503, object: unavailable(
                message: "Native voice status unavailable: \(error.localizedDescription)", // [http-response: error detail on local socket only; not surfaced in UI]
                receipt: "native-companion-speech-status-unavailable",
                blocker: "voice_status"
            ))
        }
    }

    private func companionSpeech(_ request: NativeHTTPRequest) async -> NativeHTTPResponse {
        do {
            let object = try request.jsonObject()
            let text = cleanString(object["text"])
            guard !text.isEmpty else {
                return .json(status: 400, object: NativeRuntimeHTTPPayload.error(
                    status: "bad_request",
                    message: "no text",
                    receipt: "native-companion-speech-empty"
                ))
            }

            let status = try runtime.voiceStatus()
            try validate(status)
            guard status.available, status.safeToSpeak else {
                let speech = try runtime.speechPolicy(for: text)
                try validate(speech)
                var response = speech.httpObject
                response["receipt"] = "native-companion-speech-policy"
                response["service"] = "native-runtime-http-service"
                response["runtime"] = "native-swift-cpp-http"
                response["python_beta_path"] = false
                response["web_speech_path"] = false
                response["native_system_voice_fallback"] = false
                response["python_tts_path"] = false
                response["speech_allowed"] = false
                response["native_voice_service"] = "unavailable"
                return .json(status: 503, object: response)
            }

            let speech = try await synthesizeSpeech(text, status)
            try validate(speech)
            var response = speech.httpObject
            response["receipt"] = "native-companion-speech"
            response["service"] = "native-runtime-http-service"
            response["runtime"] = "native-swift-cpp-http"
            response["python_beta_path"] = false
            response["web_speech_path"] = false
            response["native_system_voice_fallback"] = false
            response["python_tts_path"] = false
            response["speech_allowed"] = speech.spoken
            response["native_voice_service"] = speech.spoken ? "ready" : "unavailable"
            return .json(status: speech.spoken ? 200 : 503, object: response)
        } catch {
            return .json(status: 503, object: unavailable(
                message: "Native speech unavailable: \(error.localizedDescription)", // [http-response: error detail on local socket only; not surfaced in UI]
                receipt: "native-companion-speech-unavailable",
                blocker: "native_voice"
            ))
        }
    }

    private func companionSkillBlocked(_ request: NativeHTTPRequest) -> NativeHTTPResponse {
        let object = (try? request.jsonObject()) ?? [:]
        let name = cleanString(object["name"])
        let displayName = name.isEmpty ? "unknown" : name
        return .json(status: 501, object: NativeRuntimeHTTPPayload.error(
            status: "adapter_blocked",
            message: "Native skill execution adapter is not implemented in this service lane.",
            receipt: "native-companion-skill-adapter-blocked",
            extra: [
                "skill": displayName,
                "refused": true,
                "authorization_required": true,
                "output": NSNull(),
                "reason": "native HASP authorization, audit logging, and skill adapter ownership are required before execution",
            ]
        ))
    }

    private func unavailable(message: String, receipt: String, blocker: String) -> [String: Any] {
        var extra: [String: Any] = ["blocker": blocker]
        if let state = try? runtime.state() {
            extra["state"] = state.httpObject
        }
        return NativeRuntimeHTTPPayload.error(
            status: "unavailable",
            message: message,
            receipt: receipt,
            extra: extra
        )
    }

    private func verifiedState() throws -> NativeRuntimeState {
        let state = try runtime.state()
        try validate(state)
        return state
    }

    private func validate(_ state: NativeRuntimeState) throws {
        guard state.runtime == "native-swift-cpp" else {
            throw NativeRuntimeError.runtime("Blocked non-native runtime identity: \(state.runtime)")
        }
        guard state.pythonBetaPath == false else {
            throw NativeRuntimeError.runtime("Blocked runtime state that reports Python in the beta path.")
        }
        guard let voice = state.voice else {
            throw NativeRuntimeError.runtime("Native runtime state omitted explicit voice policy.")
        }
        try validate(voice)
    }

    private func validate(_ voice: NativeVoiceStatus) throws {
        guard voice.runtime == "native-swift-cpp", voice.pythonBetaPath == false else {
            throw NativeRuntimeError.runtime("Blocked non-native voice status.")
        }
        guard voice.spoken == false,
              voice.fallbackPolicy == "none",
              voice.wrongVoiceFallbackAllowed == false,
              voice.systemVoiceFallbackAllowed == false,
              voice.nativeSystemVoiceAllowed == false,
              voice.pythonTTSAllowed == false else {
            throw NativeRuntimeError.runtime("Blocked voice status with fallback or fake spoken success.")
        }
        guard !backendLooksForbidden(voice.backend) else {
            throw NativeRuntimeError.runtime("Blocked forbidden voice backend: \(voice.backend)")
        }
    }

    private func validate(_ speech: NativeSpeechResponse) throws {
        if speech.spoken {
            let audio = speech.audioBase64 ?? ""
            let contentType = speech.contentType ?? ""
            guard speech.ok, !audio.isEmpty, contentType.hasPrefix("audio/") else {
                throw NativeRuntimeError.runtime("Blocked fake spoken=true without native audio.")
            }
        }
        let backend = speech.backend ?? speech.backendKind ?? ""
        guard !backendLooksForbidden(backend) else {
            throw NativeRuntimeError.runtime("Blocked forbidden speech backend: \(backend)")
        }
        guard speech.wrongVoiceFallbackAllowed != true,
              speech.systemVoiceFallbackAllowed != true,
              speech.nativeSystemVoiceAllowed != true,
              speech.pythonTTSAllowed != true else {
            throw NativeRuntimeError.runtime("Blocked speech response with fallback enabled.")
        }
        if let status = speech.status {
            try validate(status)
        }
    }

    private func backendLooksForbidden(_ value: String) -> Bool {
        let lower = value.lowercased()
        return lower.contains("nsspeech") ||
            lower.contains("avspeech") ||
            lower.contains("speechsynthesis") ||
            lower.contains("system voice") ||
            lower.contains("tts_pocket") ||
            lower.contains("jarvis_bridge.py") ||
            lower.contains("python") ||
            lower == "say"
    }

    private func knownPath(_ path: String) -> Bool {
        [
            "/health",
            "/state",
            "/skills",
            "/companion/manifest",
            "/companion/status",
            "/companion/skills",
            "/companion/turn",
            "/companion/transcribe",
            "/companion/speech",
            "/companion/skill",
        ].contains(path)
    }

    private func cleanString(_ value: Any?) -> String {
        (value as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let allowedAudioContentTypes: Set<String> = [
        "audio/mp4",
        "audio/m4a",
        "audio/wav",
        "audio/x-m4a",
        "audio/aac",
    ]
}

private extension NativeRuntimeState {
    var httpObject: [String: Any] {
        if let data = try? JSONEncoder().encode(self),
           let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            return object
        }
        return [
            "endocrine": endocrine,
            "ec_tone": ecTone,
            "field": field.httpArray,
            "history_count": historyCount,
            "runtime": runtime,
            "python_beta_path": pythonBetaPath,
        ]
    }
}

private extension Array where Element == NativeFieldSignal {
    var httpArray: [[String: Any]] {
        map { signal in
            [
                "kind": signal.kind,
                "topic": signal.topic,
                "strength": signal.strength,
                "depositors": signal.depositors,
            ]
        }
    }
}

private extension NativeSkillCatalog {
    var httpObject: [String: Any] {
        [
            "ok": ok,
            "registry": registry.httpObject,
            "skills": skills.map { $0.httpObject },
        ]
    }
}

private extension NativeJSONValue {
    var httpAny: Any {
        switch self {
        case .null:
            return NSNull()
        case .bool(let value):
            return value
        case .number(let value):
            return value
        case .string(let value):
            return value
        case .array(let values):
            return values.map { $0.httpAny }
        case .object(let values):
            return values.mapValues { $0.httpAny }
        }
    }

    var httpObject: [String: Any]? {
        httpAny as? [String: Any]
    }
}

private extension NativeSkillRegistrySummary {
    var httpObject: [String: Any] {
        [
            "source": source,
            "python_beta_path": pythonBetaPath,
            "execution": execution,
            "count": count,
            "risks": risks,
        ]
    }
}

private extension NativeRuntimeSkill {
    var httpObject: [String: Any] {
        var object: [String: Any] = [
            "name": name,
            "risk": risk,
            "base_risk": risk,
            "status": status,
            "description": description,
        ]
        if let implemented {
            object["implemented"] = implemented
        }
        return object
    }
}

private extension NativeVoiceStatus {
    var httpObject: [String: Any] {
        [
            "ok": ok,
            "available": available,
            "safe_to_speak": safeToSpeak,
            "spoken": spoken,
            "code": code,
            "reason": reason,
            "runtime": runtime,
            "python_beta_path": pythonBetaPath,
            "backend_kind": backendKind,
            "backend": backend,
            "voice": voice,
            "voice_confirmed": voiceConfirmed,
            "endpoint_configured": endpointConfigured,
            "missing": missing,
            "fallback_policy": fallbackPolicy,
            "wrong_voice_fallback_allowed": wrongVoiceFallbackAllowed,
            "system_voice_fallback_allowed": systemVoiceFallbackAllowed,
            "native_system_voice_allowed": nativeSystemVoiceAllowed,
            "python_tts_allowed": pythonTTSAllowed,
            "hard_voice_invariant": hardVoiceInvariant,
        ]
    }
}

private extension NativeSpeechResponse {
    var httpObject: [String: Any] {
        var object: [String: Any] = [
            "ok": ok,
            "spoken": spoken,
            "backend": backend ?? "none",
            "backend_kind": backendKind ?? "native_jarvis_voice",
            "content_type": contentType ?? "",
            "audio_base64": audioBase64 ?? "",
            "synthesis_seconds": synthesisSeconds ?? 0,
        ]
        if let code {
            object["code"] = code
        }
        if let error {
            object["error"] = error
        }
        if let reason {
            object["reason"] = reason
        }
        if let fallbackPolicy {
            object["fallback_policy"] = fallbackPolicy
        }
        if let wrongVoiceFallbackAllowed {
            object["wrong_voice_fallback_allowed"] = wrongVoiceFallbackAllowed
        }
        if let systemVoiceFallbackAllowed {
            object["system_voice_fallback_allowed"] = systemVoiceFallbackAllowed
        }
        if let nativeSystemVoiceAllowed {
            object["native_system_voice_allowed"] = nativeSystemVoiceAllowed
        }
        if let pythonTTSAllowed {
            object["python_tts_allowed"] = pythonTTSAllowed
        }
        if let hardVoiceInvariant {
            object["hard_voice_invariant"] = hardVoiceInvariant
        }
        if let status {
            object["status"] = status.httpObject
            object["missing"] = status.missing
        }
        return object
    }
}
