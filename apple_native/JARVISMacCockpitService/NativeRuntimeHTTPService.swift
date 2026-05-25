import Combine
import Foundation
@preconcurrency import Network

struct NativeRuntimeHTTPServiceConfiguration: Equatable, Sendable {
    let host: String
    let port: UInt16
    let companionToken: String?
    let allowNonLoopback: Bool

    static let defaultRoutes = [
        "GET /state",
        "GET /skills",
        "GET /companion/skills",
        "POST /companion/turn",
        "POST /companion/transcribe",
        "GET|POST /companion/speech",
        "POST /companion/skill",
    ]

    static func load(env: [String: String] = NativeEnvironment.load()) -> NativeRuntimeHTTPServiceConfiguration {
        let host = clean(env["JARVIS_NATIVE_SERVICE_HOST"]) ?? "127.0.0.1"
        let rawPort = clean(env["JARVIS_NATIVE_SERVICE_PORT"]) ?? "8788"
        let port = UInt16(rawPort) ?? 8788
        let token = clean(env["JARVIS_RUNTIME_COMPANION_TOKEN"]) ?? clean(env["JARVIS_NATIVE_SERVICE_TOKEN"])
        // Non-loopback bind is gated behind a compile-time flag, never a runtime env var.
        // JARVIS_ALLOW_NON_LOOPBACK is intentionally ignored in all configurations;
        // only DEBUG builds compiled with -D JARVIS_INSECURE_BIND may set allowNonLoopback.
        #if DEBUG && JARVIS_INSECURE_BIND
        let allowNonLoopback = clean(env["JARVIS_ALLOW_NON_LOOPBACK"]) == "1"
        #else
        let allowNonLoopback = false
        #endif
        return NativeRuntimeHTTPServiceConfiguration(host: host, port: port, companionToken: token, allowNonLoopback: allowNonLoopback)
    }

    var baseURLText: String {
        "http://\(host):\(port)"
    }

    var companionTokenConfigured: Bool {
        !(companionToken ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var routeSummary: String {
        Self.defaultRoutes.joined(separator: ", ")
    }

    private static func clean(_ value: String?) -> String? {
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum NativeRuntimeHTTPRunState: String, Sendable {
    case stopped
    case starting
    case ready
    case failed
}

struct NativeRuntimeHTTPServiceStatus: Equatable, Sendable {
    let state: NativeRuntimeHTTPRunState
    let baseURLText: String
    let message: String
    let routeSummary: String
    let companionTokenConfigured: Bool

    static func stopped(configuration: NativeRuntimeHTTPServiceConfiguration) -> NativeRuntimeHTTPServiceStatus {
        NativeRuntimeHTTPServiceStatus(
            state: .stopped,
            baseURLText: configuration.baseURLText,
            message: "Native HTTP service stopped",
            routeSummary: configuration.routeSummary,
            companionTokenConfigured: configuration.companionTokenConfigured
        )
    }

    static func starting(configuration: NativeRuntimeHTTPServiceConfiguration) -> NativeRuntimeHTTPServiceStatus {
        NativeRuntimeHTTPServiceStatus(
            state: .starting,
            baseURLText: configuration.baseURLText,
            message: "Starting native HTTP service",
            routeSummary: configuration.routeSummary,
            companionTokenConfigured: configuration.companionTokenConfigured
        )
    }

    static func ready(configuration: NativeRuntimeHTTPServiceConfiguration, port: UInt16?) -> NativeRuntimeHTTPServiceStatus {
        let activePort = port ?? configuration.port
        let activeConfiguration = NativeRuntimeHTTPServiceConfiguration(
            host: configuration.host,
            port: activePort,
            companionToken: configuration.companionToken,
            allowNonLoopback: configuration.allowNonLoopback
        )
        return NativeRuntimeHTTPServiceStatus(
            state: .ready,
            baseURLText: activeConfiguration.baseURLText,
            message: "Native HTTP service ready",
            routeSummary: activeConfiguration.routeSummary,
            companionTokenConfigured: activeConfiguration.companionTokenConfigured
        )
    }

    static func failed(configuration: NativeRuntimeHTTPServiceConfiguration, error: String) -> NativeRuntimeHTTPServiceStatus {
        NativeRuntimeHTTPServiceStatus(
            state: .failed,
            baseURLText: configuration.baseURLText,
            message: error,
            routeSummary: configuration.routeSummary,
            companionTokenConfigured: configuration.companionTokenConfigured
        )
    }
}

@MainActor
final class NativeRuntimeHTTPServiceController: ObservableObject {
    @Published private(set) var status: NativeRuntimeHTTPServiceStatus

    private var server: NativeRuntimeHTTPServer?

    init(configuration: NativeRuntimeHTTPServiceConfiguration = .load()) {
        status = .stopped(configuration: configuration)
    }

    func start() {
        guard server == nil else {
            return
        }
        let configuration = NativeRuntimeHTTPServiceConfiguration.load()
        status = .starting(configuration: configuration)
        do {
            let handler = try NativeRuntimeHTTPHandler()
            let server = NativeRuntimeHTTPServer(configuration: configuration, handler: handler) { [weak self] nextStatus in
                Task { @MainActor in
                    self?.status = nextStatus
                }
            }
            self.server = server
            try server.start()
        } catch {
            status = .failed(configuration: configuration, error: error.localizedDescription) // [internal-state: not surfaced in UI]
        }
    }

    func stop() {
        server?.stop()
        server = nil
        status = .stopped(configuration: NativeRuntimeHTTPServiceConfiguration.load())
    }

}

final class NativeRuntimeHTTPServer {
    private let configuration: NativeRuntimeHTTPServiceConfiguration
    private let handler: NativeRuntimeHTTPHandler
    private let onStatusChange: @Sendable (NativeRuntimeHTTPServiceStatus) -> Void
    private let queue = DispatchQueue(label: "ai.realjarvis.native-runtime-http-service")
    private var listener: NWListener?

    init(
        configuration: NativeRuntimeHTTPServiceConfiguration,
        handler: NativeRuntimeHTTPHandler,
        onStatusChange: @escaping @Sendable (NativeRuntimeHTTPServiceStatus) -> Void = { _ in }
    ) {
        self.configuration = configuration
        self.handler = handler
        self.onStatusChange = onStatusChange
    }

    func start() throws {
        guard listener == nil else {
            return
        }
        guard let port = NWEndpoint.Port(rawValue: configuration.port) else {
            throw NativeRuntimeHTTPServiceError.invalidPort(configuration.port)
        }
        try verifyBirthCertOrThrow()
        try validateBindHost()

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(
            host: NWEndpoint.Host(configuration.host),
            port: port
        )

        let listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { [configuration, onStatusChange] state in
            switch state {
            case .ready:
                onStatusChange(.ready(configuration: configuration, port: nil))
            case .failed(let error):
                onStatusChange(.failed(configuration: configuration, error: error.localizedDescription)) // [internal-state: not surfaced in UI]
            case .cancelled:
                onStatusChange(.stopped(configuration: configuration))
            case .setup, .waiting:
                onStatusChange(.starting(configuration: configuration))
            @unknown default:
                onStatusChange(.failed(configuration: configuration, error: "Unknown native HTTP listener state"))
            }
        }
        listener.newConnectionHandler = { [configuration, handler, queue] connection in
            let requestConnection = NativeRuntimeHTTPConnection(
                connection: connection,
                configuration: configuration,
                handler: handler,
                queue: queue
            )
            Task {
                await requestConnection.start()
            }
        }
        self.listener = listener
        onStatusChange(.starting(configuration: configuration))
        listener.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        onStatusChange(.stopped(configuration: configuration))
    }

    private func verifyBirthCertOrThrow() throws {
        let verification = NativeBirthCertificateVerifier.verify()
        switch verification.result {
        case .verified:
            try NativeSecurityAudit.record("http_listener_birth_cert_verified", fields: ["path": verification.path])
        case .missing:
            try NativeSecurityAudit.record("http_listener_birth_cert_failed", fields: ["path": verification.path, "reason": verification.reason])
            throw NativeRuntimeHTTPServiceError.birthCertMissing(path: verification.path)
        case .invalidSignature, .malformed:
            try NativeSecurityAudit.record("http_listener_birth_cert_failed", fields: ["path": verification.path, "reason": verification.reason])
            throw NativeRuntimeHTTPServiceError.birthCertInvalid(reason: verification.reason)
        }
    }

    private func validateBindHost() throws {
        let host = configuration.host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if host == "127.0.0.1" || host == "::1" {
            return
        }
        // Non-loopback is only ever permitted in DEBUG builds compiled with -D JARVIS_INSECURE_BIND.
        // Release builds hard-fail here regardless of the allowNonLoopback configuration value.
        #if DEBUG && JARVIS_INSECURE_BIND
        guard configuration.allowNonLoopback else {
            do { try NativeSecurityAudit.record("http_service_non_loopback_refused", fields: ["host": configuration.host]) } catch { fputs("JARVIS audit write failed: \(error)\n", stderr) } // [audit-log: discard on I/O failure; secondary diagnostic path]
            throw NativeRuntimeHTTPServiceError.nonLoopbackBindRefused(configuration.host)
        }
        do { try NativeSecurityAudit.record("http_service_bound_non_loopback", fields: ["host": configuration.host]) } catch { fputs("JARVIS audit write failed: \(error)\n", stderr) } // [audit-log: discard on I/O failure; secondary diagnostic path]
        #else
        do { try NativeSecurityAudit.record("http_service_non_loopback_refused", fields: ["host": configuration.host]) } catch { fputs("JARVIS audit write failed: \(error)\n", stderr) } // [audit-log: discard on I/O failure; secondary diagnostic path]
        throw NativeRuntimeHTTPServiceError.nonLoopbackBindRefused(configuration.host)
        #endif
    }
}

private actor NativeRuntimeHTTPConnection {
    private let connection: NWConnection
    private let configuration: NativeRuntimeHTTPServiceConfiguration
    private let handler: NativeRuntimeHTTPHandler
    private let queue: DispatchQueue
    private var buffer = Data()
    private let maxHeaderBytes = 16_384
    private let maxBodyBytes = 8_500_000

    init(
        connection: NWConnection,
        configuration: NativeRuntimeHTTPServiceConfiguration,
        handler: NativeRuntimeHTTPHandler,
        queue: DispatchQueue
    ) {
        self.connection = connection
        self.configuration = configuration
        self.handler = handler
        self.queue = queue
    }

    func start() {
        connection.start(queue: queue)
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { content, _, isComplete, error in
            Task {
                await self.handleReceive(content: content, isComplete: isComplete, error: error)
            }
        }
    }

    private func handleReceive(content: Data?, isComplete: Bool, error: NWError?) {
        if let error {
            send(.json(status: 400, object: NativeRuntimeHTTPPayload.error(
                status: "bad_request",
                message: "HTTP receive failed: \(error.localizedDescription)", // [http-response: NWError on local socket; not surfaced in UI]
                receipt: "native-http-receive-error"
            )))
            return
        }
        if let content, !content.isEmpty {
            buffer.append(content)
        }

        do {
            if let request = try parseRequest() {
                Task {
                    let response = await handler.handle(request, configuration: configuration)
                    send(response)
                }
                return
            }
        } catch let error as NativeRuntimeHTTPServiceError {
            send(.json(status: error.httpStatus, object: NativeRuntimeHTTPPayload.error(
                status: error.status,
                message: error.localizedDescription, // [http-response: parse error on local socket; not surfaced in UI]
                receipt: "native-http-parse-error"
            )))
            return
        } catch {
            send(.json(status: 400, object: NativeRuntimeHTTPPayload.error(
                status: "bad_request",
                message: error.localizedDescription, // [http-response: parse error on local socket; not surfaced in UI]
                receipt: "native-http-parse-error"
            )))
            return
        }

        if isComplete {
            send(.json(status: 400, object: NativeRuntimeHTTPPayload.error(
                status: "bad_request",
                message: "Incomplete HTTP request",
                receipt: "native-http-incomplete-request"
            )))
            return
        }
        receive()
    }

    private func send(_ response: NativeHTTPResponse) {
        let connection = connection
        connection.send(content: response.wireData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func parseRequest() throws -> NativeHTTPRequest? {
        let marker = Data("\r\n\r\n".utf8)
        guard let headerRange = buffer.range(of: marker) else {
            if buffer.count > maxHeaderBytes {
                throw NativeRuntimeHTTPServiceError.headerTooLarge
            }
            return nil
        }

        let headerEnd = headerRange.upperBound
        guard headerEnd <= maxHeaderBytes else {
            throw NativeRuntimeHTTPServiceError.headerTooLarge
        }
        let headerData = buffer[..<headerRange.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            throw NativeRuntimeHTTPServiceError.invalidHeaderEncoding
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            throw NativeRuntimeHTTPServiceError.invalidRequestLine
        }
        let parts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else {
            throw NativeRuntimeHTTPServiceError.invalidRequestLine
        }

        var headers: [String: String] = [:]
        var seenContentLength = false
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else {
                continue
            }
            let name = line[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if name == "content-length" {
                guard !seenContentLength else {
                    throw NativeRuntimeHTTPServiceError.duplicateContentLength
                }
                seenContentLength = true
            }
            headers[name] = value
        }

        // Transfer-Encoding is unimplemented and introduces request-smuggling risk.
        if headers["transfer-encoding"] != nil {
            throw NativeRuntimeHTTPServiceError.transferEncodingRejected
        }

        let contentLength: Int
        if let clText = headers["content-length"] {
            guard let cl = Int(clText), cl >= 0 else {
                throw NativeRuntimeHTTPServiceError.invalidContentLength
            }
            contentLength = cl
        } else {
            contentLength = 0
        }
        guard contentLength <= maxBodyBytes else {
            throw NativeRuntimeHTTPServiceError.bodyTooLarge
        }
        guard buffer.count >= headerEnd + contentLength else {
            return nil
        }
        let body = Data(buffer[headerEnd..<(headerEnd + contentLength)])
        return NativeHTTPRequest(
            method: parts[0].uppercased(),
            target: parts[1],
            headers: headers,
            body: body,
            remoteIP: Self.remoteIP(from: connection.endpoint)
        )
    }

    private static func remoteIP(from endpoint: NWEndpoint) -> String {
        switch endpoint {
        case .hostPort(let host, _):
            return String(describing: host)
        default:
            return "unknown"
        }
    }
}

struct NativeHTTPRequest: Sendable {
    let method: String
    let target: String
    let headers: [String: String]
    let body: Data
    let remoteIP: String

    var path: String {
        String(target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? Substring(target))
    }

    func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }

    func jsonObject() throws -> [String: Any] {
        guard !body.isEmpty else {
            return [:]
        }
        do {
            try assertJSONDepth(body, maxDepth: 16)
        } catch {
            throw NativeRuntimeHTTPServiceError.jsonDepthExceeded
        }
        let value = try JSONSerialization.jsonObject(with: body)
        guard let object = value as? [String: Any] else {
            throw NativeRuntimeHTTPServiceError.invalidJSON
        }
        return object
    }
}

struct NativeHTTPResponse: Sendable {
    let statusCode: Int
    let reason: String
    let headers: [String: String]
    let body: Data

    var wireData: Data {
        var head = "HTTP/1.1 \(statusCode) \(reason)\r\n"
        var allHeaders = headers
        allHeaders["Content-Length"] = String(body.count)
        allHeaders["Connection"] = "close"
        for key in allHeaders.keys.sorted() {
            head += "\(key): \(allHeaders[key] ?? "")\r\n"
        }
        head += "\r\n"
        var data = Data(head.utf8)
        data.append(body)
        return data
    }

    static func json(status: Int, object: [String: Any], headers extraHeaders: [String: String] = [:]) -> NativeHTTPResponse {
        let body = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{\"ok\":false,\"error\":\"json encoding failed\"}".utf8)
        var headers = [
            "Content-Type": "application/json; charset=utf-8",
            "Cache-Control": "no-store",
        ]
        for (key, value) in extraHeaders {
            headers[key] = value
        }
        return NativeHTTPResponse(
            statusCode: status,
            reason: reasonPhrase(for: status),
            headers: headers,
            body: body
        )
    }

    static func empty(status: Int, headers extraHeaders: [String: String] = [:]) -> NativeHTTPResponse {
        NativeHTTPResponse(
            statusCode: status,
            reason: reasonPhrase(for: status),
            headers: extraHeaders,
            body: Data()
        )
    }

    func withCORS(origin: String?) -> NativeHTTPResponse {
        guard let origin else { return self }
        var next = headers
        next["Access-Control-Allow-Origin"] = origin
        next["Access-Control-Allow-Headers"] = "content-type, accept, x-jarvis-companion-token, x-jarvis-nonce, x-jarvis-timestamp"
        next["Access-Control-Allow-Methods"] = "GET, POST, OPTIONS"
        next["Vary"] = "Origin"
        return NativeHTTPResponse(statusCode: statusCode, reason: reason, headers: next, body: body)
    }

    private static func reasonPhrase(for status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 413: return "Payload Too Large"
        case 429: return "Too Many Requests"
        case 431: return "Request Header Fields Too Large"
        case 500: return "Internal Server Error"
        case 501: return "Not Implemented"
        case 503: return "Service Unavailable"
        default: return "HTTP"
        }
    }
}

enum NativeRuntimeHTTPPayload {
    static func error(status: String, message: String, receipt: String, extra: [String: Any] = [:]) -> [String: Any] {
        var object: [String: Any] = [
            "ok": false,
            "status": status,
            "error": message,
            "receipt": receipt,
            "runtime": "native-swift-cpp-http",
            "python_beta_path": false,
        ]
        for (key, value) in extra {
            object[key] = value
        }
        return object
    }
}

enum NativeRuntimeHTTPServiceError: LocalizedError {
    case authStoreOpenFailed(String, String)
    case authStoreReadFailed(String)
    case authStoreWriteFailed(String)
    case birthCertInvalid(reason: String)
    case birthCertMissing(path: String)
    case bodyTooLarge
    case duplicateContentLength
    case headerTooLarge
    case invalidContentLength
    case invalidHeaderEncoding
    case invalidJSON
    case invalidPort(UInt16)
    case invalidRequestLine
    case jsonDepthExceeded
    case nonLoopbackBindRefused(String)
    case nonceStoreOpenFailed(String, String)
    case nonceStoreReadFailed(String)
    case nonceStoreWriteFailed(String)
    case transferEncodingRejected

    var httpStatus: Int {
        switch self {
        case .birthCertInvalid, .birthCertMissing: return 500
        case .bodyTooLarge: return 413
        case .headerTooLarge: return 431
        case .duplicateContentLength, .invalidContentLength, .invalidHeaderEncoding,
             .invalidJSON, .invalidRequestLine, .invalidPort,
             .jsonDepthExceeded, .transferEncodingRejected: return 400
        case .authStoreOpenFailed, .authStoreReadFailed, .authStoreWriteFailed: return 500
        case .nonLoopbackBindRefused, .nonceStoreOpenFailed, .nonceStoreReadFailed, .nonceStoreWriteFailed: return 500
        }
    }

    var status: String {
        switch self {
        case .authStoreOpenFailed: return "auth_store_open_failed"
        case .authStoreReadFailed: return "auth_store_read_failed"
        case .authStoreWriteFailed: return "auth_store_write_failed"
        case .birthCertInvalid: return "birth_cert_invalid"
        case .birthCertMissing: return "birth_cert_missing"
        case .bodyTooLarge: return "payload_too_large"
        case .duplicateContentLength: return "duplicate_content_length"
        case .headerTooLarge: return "headers_too_large"
        case .invalidContentLength: return "invalid_content_length"
        case .invalidHeaderEncoding: return "invalid_header_encoding"
        case .invalidJSON: return "invalid_json"
        case .invalidPort: return "invalid_port"
        case .invalidRequestLine: return "invalid_request_line"
        case .jsonDepthExceeded: return "json_depth_exceeded"
        case .nonLoopbackBindRefused: return "non_loopback_bind_refused"
        case .nonceStoreOpenFailed: return "nonce_store_open_failed"
        case .nonceStoreReadFailed: return "nonce_store_read_failed"
        case .nonceStoreWriteFailed: return "nonce_store_write_failed"
        case .transferEncodingRejected: return "transfer_encoding_rejected"
        }
    }

    var errorDescription: String? {
        switch self {
        case .authStoreOpenFailed(let path, let reason):
            return "HTTP auth store open failed at \(path): \(reason)"
        case .authStoreReadFailed(let reason):
            return "HTTP auth store read failed: \(reason)"
        case .authStoreWriteFailed(let reason):
            return "HTTP auth store write failed: \(reason)"
        case .birthCertInvalid(let reason):
            return "Birth certificate verification failed: \(reason)"
        case .birthCertMissing(let path):
            return "Birth certificate missing at \(path)."
        case .bodyTooLarge:
            return "HTTP request body exceeds the native service limit."
        case .headerTooLarge:
            return "HTTP request headers exceed the native service limit."
        case .duplicateContentLength:
            return "HTTP request contains duplicate Content-Length headers."
        case .invalidContentLength:
            return "HTTP Content-Length must be a non-negative integer."
        case .invalidHeaderEncoding:
            return "HTTP request headers are not valid UTF-8."
        case .invalidJSON:
            return "HTTP request body must be a JSON object."
        case .invalidPort(let port):
            return "Invalid native HTTP service port: \(port)."
        case .invalidRequestLine:
            return "HTTP request line is invalid."
        case .jsonDepthExceeded:
            return "HTTP request body JSON nesting exceeds the permitted depth."
        case .nonLoopbackBindRefused(let host):
            return "NonLoopbackBindRefused: native HTTP service refuses to bind to non-loopback address \(host)."
        case .nonceStoreOpenFailed(let path, let reason):
            return "HTTP nonce store open failed at \(path): \(reason)"
        case .nonceStoreReadFailed(let reason):
            return "HTTP nonce store read failed: \(reason)"
        case .nonceStoreWriteFailed(let reason):
            return "HTTP nonce store write failed: \(reason)"
        case .transferEncodingRejected:
            return "HTTP Transfer-Encoding is not supported by this service."
        }
    }
}
