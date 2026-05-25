import Foundation

struct NativeConvexConfiguration: Equatable {
    let deploymentURL: URL?
    let token: String
    let enabled: Bool
    let runner: String
    let source: String
    let pollSeconds: Double
    let batchLimit: Int

    static func fromEnvironment(_ env: [String: String] = NativeEnvironment.load()) -> NativeConvexConfiguration {
        let urlText = clean(env["CONVEX_URL"]) ?? clean(env["JARVIS_CONVEX_URL"])
        let url = urlText.flatMap { URL(string: $0.trimmingCharacters(in: CharacterSet(charactersIn: "/"))) }
        let token = clean(env["JARVIS_CONVEX_REALTIME_TOKEN"]) ?? ""
        let realtimeFlag = clean(env["JARVIS_CONVEX_REALTIME"]) ?? "1"
        let poll = min(30.0, max(0.10, Double(clean(env["JARVIS_CONVEX_CONTROL_POLL_SECONDS"]) ?? "") ?? 0.75))
        let limit = min(25, max(1, Int(clean(env["JARVIS_CONVEX_CONTROL_BATCH"]) ?? "") ?? 10))
        return NativeConvexConfiguration(
            deploymentURL: url,
            token: token,
            enabled: url != nil && !token.isEmpty && realtimeFlag != "0",
            runner: clean(env["JARVIS_CONVEX_NATIVE_RUNNER"]) ?? "native_mac_cockpit",
            source: "native-swift-convex-worker",
            pollSeconds: poll,
            batchLimit: limit
        )
    }

    var disabledReason: String {
        if deploymentURL == nil {
            return "CONVEX_URL/JARVIS_CONVEX_URL is not configured."
        }
        if token.isEmpty {
            return "JARVIS_CONVEX_REALTIME_TOKEN is not configured."
        }
        return "JARVIS_CONVEX_REALTIME=0."
    }

    private static func clean(_ value: String?) -> String? {
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct NativeControlRequest: Decodable, Equatable, Identifiable {
    var id: String { requestId }

    let requestId: String
    let status: String
    let requestedBy: String
    let deviceId: String?
    let name: String
    let args: NativeJSONValue?
    let authorizationIntent: String?
    let createdAt: Double
    let runner: String?

    var objectArgs: [String: NativeJSONValue] {
        args?.objectValue ?? [:]
    }
}

struct NativeControlResult: Equatable {
    let ok: Bool
    let skill: String
    let output: NativeJSONValue
    let refused: Bool
    let reason: String?
    let error: String?
    let authorizationRequired: Bool

    var status: String {
        ok ? "done" : refused ? "refused" : "error"
    }
}

struct NativeConvexClient {
    let configuration: NativeConvexConfiguration
    let session: URLSession

    init(configuration: NativeConvexConfiguration = .fromEnvironment(), session: URLSession = .jarvisPinned) {
        self.configuration = configuration
        self.session = session
    }

    func publishState(key: String, source: String, payload: NativeJSONValue, updatedAt: Date = Date()) async throws -> NativeJSONValue {
        try ensureEnabled()
        return try await mutation(path: "realtime:publishState", args: [
            "clientToken": .string(configuration.token),
            "key": .string(key),
            "source": .string(source),
            "updatedAt": .number(updatedAt.timeIntervalSince1970),
            "payload": payload,
        ])
    }

    func publishSkillCatalog(_ catalog: NativeSkillCatalog, key: String = "default", updatedAt: Date = Date()) async throws -> NativeJSONValue {
        try ensureEnabled()
        let skills = try catalog.skills.map { try NativeJSONValue.fromEncodable($0) }
        return try await mutation(path: "realtime:publishSkillCatalog", args: [
            "clientToken": .string(configuration.token),
            "key": .string(key),
            "updatedAt": .number(updatedAt.timeIntervalSince1970),
            "skills": .array(skills),
        ])
    }

    func pendingControlRequests(limit: Int) async throws -> [NativeControlRequest] {
        try ensureEnabled()
        let value = try await query(path: "realtime:pendingControlRequests", args: [
            "clientToken": .string(configuration.token),
            "limit": .number(Double(limit)),
        ])
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode([NativeControlRequest].self, from: data)
    }

    func claimControlRequest(requestId: String, runner: String, claimedAt: Date = Date()) async throws -> NativeControlRequest? {
        try ensureEnabled()
        let value = try await mutation(path: "realtime:claimControlRequest", args: [
            "clientToken": .string(configuration.token),
            "requestId": .string(requestId),
            "runner": .string(runner),
            "claimedAt": .number(claimedAt.timeIntervalSince1970),
        ])
        if case .null = value {
            return nil
        }
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(NativeControlRequest.self, from: data)
    }

    func completeControlRequest(requestId: String, result: NativeControlResult, completedAt: Date = Date()) async throws -> NativeJSONValue {
        try ensureEnabled()
        var args: [String: NativeJSONValue] = [
            "clientToken": .string(configuration.token),
            "requestId": .string(requestId),
            "status": .string(result.status),
            "completedAt": .number(completedAt.timeIntervalSince1970),
            "ok": .bool(result.ok),
            "output": result.output,
            "refused": .bool(result.refused),
            "authorizationRequired": .bool(result.authorizationRequired),
        ]
        if let reason = result.reason, !reason.isEmpty {
            args["reason"] = .string(reason)
        }
        if let error = result.error, !error.isEmpty {
            args["error"] = .string(error)
        }
        return try await mutation(path: "realtime:completeControlRequest", args: args)
    }

    private func query(path: String, args: [String: NativeJSONValue]) async throws -> NativeJSONValue {
        try await call(kind: "query", path: path, args: args)
    }

    private func mutation(path: String, args: [String: NativeJSONValue]) async throws -> NativeJSONValue {
        try await call(kind: "mutation", path: path, args: args)
    }

    private func call(kind: String, path: String, args: [String: NativeJSONValue]) async throws -> NativeJSONValue {
        guard let deploymentURL = configuration.deploymentURL else {
            throw NativeConvexError.disabled(configuration.disabledReason)
        }
        try NativeURLAllowlist.load().validate(deploymentURL, category: .convex)
        var request = URLRequest(url: deploymentURL.appending(path: "api/\(kind)"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.httpBody = try JSONEncoder().encode(NativeConvexRequest(
            path: path,
            args: .object(args),
            format: "json"
        ))

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NativeConvexError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let correlationID = NativeUpstreamErrorAudit.record(client: "convex", url: request.url ?? deploymentURL, status: http.statusCode, body: data)
            throw NativeConvexError.httpStatus(http.statusCode, correlationID)
        }

        if let envelope = try? decodeBoundedJSON(data, as: NativeConvexEnvelope.self, maxBytes: 8 << 20), let status = envelope.status {
            guard status == "success" else {
                throw NativeConvexError.server(envelope.errorMessage ?? "Convex \(kind) \(path) failed")
            }
            return envelope.value ?? .null
        }
        return try decodeBoundedJSON(data, as: NativeJSONValue.self, maxBytes: 8 << 20)
    }

    private func ensureEnabled() throws {
        guard configuration.enabled else {
            throw NativeConvexError.disabled(configuration.disabledReason)
        }
    }
}

private struct NativeConvexRequest: Encodable {
    let path: String
    let args: NativeJSONValue
    let format: String
}

private struct NativeConvexEnvelope: Decodable {
    let status: String?
    let value: NativeJSONValue?
    let errorMessage: String?
}

enum NativeConvexError: LocalizedError, Equatable {
    case disabled(String)
    case httpStatus(Int, String)
    case invalidResponse
    case server(String)

    var errorDescription: String? {
        switch self {
        case .disabled(let reason):
            return "Convex realtime disabled: \(reason)"
        case .httpStatus(let status, let correlationID):
            return "upstream_error client=convex status=\(status) correlation_id=\(correlationID)"
        case .invalidResponse:
            return "Convex endpoint did not return HTTP."
        case .server(let message):
            return message
        }
    }
}
