import Foundation
import JARVISCompanionCore

struct CloudCompanionClient: Sendable {
    let baseURL: URL
    let deviceToken: String
    let session: URLSession

    init(baseURL: URL, deviceToken: String = "", session: URLSession = .shared) {
        self.baseURL = baseURL
        self.deviceToken = deviceToken
        self.session = session
    }

    func pair(code: String, deviceID: String, label: String, platform: String) async throws -> CloudPairResponse {
        try await perform(path: "/app/pair", body: PairRequest(
            code: code,
            deviceId: deviceID,
            label: label,
            platform: platform
        ))
    }

    func status() async throws -> CloudStatusResponse {
        try await perform(path: "/app/status", body: TokenRequest(deviceToken: deviceToken))
    }

    func send(event: CompanionEvent, deviceID: String) async throws -> CloudOKResponse {
        try await perform(path: "/app/event", body: EventRequest(
            deviceToken: deviceToken,
            source: event.source,
            deviceId: event.deviceID ?? deviceID,
            kind: event.kind,
            timestamp: event.timestamp ?? Date().timeIntervalSince1970,
            personId: nil,
            memoryScopeId: nil,
            payload: event,
            dream: nil
        ))
    }

    func requestTurn(text: String, requestID: String, deviceID: String) async throws -> CloudTurnRequestResponse {
        try await perform(path: "/app/turn", body: TurnRequest(
            deviceToken: deviceToken,
            requestId: requestID,
            deviceId: deviceID,
            requestedBy: "ios_companion",
            text: text,
            createdAt: Date().timeIntervalSince1970
        ))
    }

    func realtimeTurn(text: String, deviceID: String) async throws -> CloudRealtimeTurnResponse {
        try await perform(path: "/app/realtime-turn", body: RealtimeTurnRequest(
            deviceToken: deviceToken,
            deviceId: deviceID,
            text: text
        ))
    }

    func controlStatus(requestID: String) async throws -> CloudControlRequest? {
        try await perform(path: "/app/control-status", body: ControlStatusRequest(
            deviceToken: deviceToken,
            requestId: requestID
        ))
    }

    private func perform<RequestBody: Encodable, ResponseBody: Decodable>(
        path: String,
        body: RequestBody
    ) async throws -> ResponseBody {
        let url = endpoint(path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CloudCompanionClientError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            if let error = try? JSONDecoder().decode(CloudErrorResponse.self, from: data) {
                throw CloudCompanionClientError.server(error.error)
            }
            throw CloudCompanionClientError.httpStatus(httpResponse.statusCode)
        }
        return try JSONDecoder().decode(ResponseBody.self, from: data)
    }

    private func endpoint(_ path: String) -> URL {
        let cleanPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return baseURL.appending(path: cleanPath)
    }
}

enum CloudCompanionClientError: LocalizedError, Equatable {
    case invalidResponse
    case httpStatus(Int)
    case server(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "The cloud endpoint did not return an HTTP response."
        case .httpStatus(let status):
            return "Cloud endpoint returned HTTP \(status)."
        case .server(let message):
            return message
        }
    }
}

struct CloudErrorResponse: Decodable, Sendable {
    let ok: Bool?
    let error: String
}

struct CloudOKResponse: Codable, Equatable, Sendable {
    let ok: Bool
}

struct CloudPairResponse: Codable, Equatable, Sendable {
    let ok: Bool
    let deviceToken: String
    let deviceId: String
    let mode: String
}

struct CloudStatusResponse: Codable, Equatable, Sendable {
    let ok: Bool
    let mode: String
    let deviceId: String?
    let runtime: CloudRuntimeState?
    let ambient: CloudRuntimeState?
    let dream: CloudRuntimeState?
    let tts: CloudRuntimeState?
    let latestTurn: CloudRuntimeState?
    let skillCatalog: CloudSkillCatalog?
}

struct CloudRuntimeState: Codable, Equatable, Sendable {
    let key: String?
    let source: String?
    let updatedAt: Double?
    let payload: JSONValue?
}

struct CloudSkillCatalog: Codable, Equatable, Sendable {
    let key: String?
    let updatedAt: Double?
    let skills: [JSONValue]?
}

struct CloudTurnRequestResponse: Codable, Equatable, Sendable {
    let ok: Bool
    let requestId: String
    let status: String
}

struct CloudControlRequest: Codable, Equatable, Sendable {
    let requestId: String
    let status: String
    let ok: Bool?
    let output: JSONValue?
    let refused: Bool?
    let reason: String?
    let error: String?
    let authorizationRequired: Bool?
}

struct CloudRealtimeTurnResponse: Codable, Equatable, Sendable {
    let reply: String?
    let driftToPrototype: Double?
    let endocrine: JSONValue?
    let ecTone: JSONValue?
    let ethicsConflict: JSONValue?
    let model: String?

    enum CodingKeys: String, CodingKey {
        case reply
        case driftToPrototype = "drift_to_prototype"
        case endocrine
        case ecTone = "ec_tone"
        case ethicsConflict = "ethics_conflict"
        case model
    }
}

private struct TokenRequest: Encodable {
    let deviceToken: String
}

private struct PairRequest: Encodable {
    let code: String
    let deviceId: String
    let label: String
    let platform: String
}

private struct EventRequest: Encodable {
    let deviceToken: String
    let source: String
    let deviceId: String
    let kind: String
    let timestamp: TimeInterval
    let personId: String?
    let memoryScopeId: String?
    let payload: CompanionEvent
    let dream: JSONValue?
}

private struct TurnRequest: Encodable {
    let deviceToken: String
    let requestId: String
    let deviceId: String
    let requestedBy: String
    let text: String
    let createdAt: TimeInterval
}

private struct RealtimeTurnRequest: Encodable {
    let deviceToken: String
    let deviceId: String
    let text: String
}

private struct ControlStatusRequest: Encodable {
    let deviceToken: String
    let requestId: String
}
