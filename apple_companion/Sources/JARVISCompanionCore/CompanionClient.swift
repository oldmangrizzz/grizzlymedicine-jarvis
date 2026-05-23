import Foundation

public struct CompanionConfiguration: Equatable, Sendable {
    public var baseURL: URL
    public var token: String

    public init(baseURL: URL, token: String) {
        self.baseURL = baseURL
        self.token = token
    }
}

public enum CompanionClientError: Error, Equatable {
    case emptyToken
    case invalidBaseURL
    case httpStatus(Int, String)
    case noHTTPResponse
}

public enum CompanionRequestBuilder {
    public static let tokenHeader = "X-JARVIS-Companion-Token"

    public static func request(
        baseURL: URL,
        path: String,
        method: String = "GET",
        token: String? = nil,
        body: Data? = nil
    ) throws -> URLRequest {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw CompanionClientError.invalidBaseURL
        }
        let cleanPath = path.hasPrefix("/") ? path : "/" + path
        components.path = cleanPath
        guard let url = components.url else {
            throw CompanionClientError.invalidBaseURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token {
            guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CompanionClientError.emptyToken
            }
            request.setValue(token, forHTTPHeaderField: tokenHeader)
        }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }
}

public actor CompanionClient {
    private let configuration: CompanionConfiguration
    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(configuration: CompanionConfiguration, session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.sortedKeys]
        self.decoder = JSONDecoder()
    }

    public func manifest() async throws -> CompanionManifest {
        let request = try CompanionRequestBuilder.request(
            baseURL: configuration.baseURL,
            path: "/companion/manifest"
        )
        return try await perform(request)
    }

    public func status() async throws -> AmbientStatus {
        let request = try CompanionRequestBuilder.request(
            baseURL: configuration.baseURL,
            path: "/companion/status",
            token: configuration.token
        )
        return try await perform(request)
    }

    public func dream() async throws -> DreamStatus {
        let request = try CompanionRequestBuilder.request(
            baseURL: configuration.baseURL,
            path: "/companion/dream",
            token: configuration.token
        )
        return try await perform(request)
    }

    public func skills() async throws -> CompanionSkillCatalog {
        let request = try CompanionRequestBuilder.request(
            baseURL: configuration.baseURL,
            path: "/companion/skills",
            token: configuration.token
        )
        return try await perform(request)
    }

    public func turn(text: String) async throws -> CompanionTurnResponse {
        let body = try encoder.encode(CompanionTurnRequest(text: text))
        let request = try CompanionRequestBuilder.request(
            baseURL: configuration.baseURL,
            path: "/companion/turn",
            method: "POST",
            token: configuration.token,
            body: body
        )
        return try await perform(request)
    }

    public func runSkill(_ command: CompanionSkillCommand) async throws -> CompanionSkillResult {
        let body = try encoder.encode(command)
        let request = try CompanionRequestBuilder.request(
            baseURL: configuration.baseURL,
            path: "/companion/skill",
            method: "POST",
            token: configuration.token,
            body: body
        )
        return try await perform(request)
    }

    public func runSkill(
        name: String,
        args: [String: JSONValue] = [:],
        authorizationCode: String? = nil
    ) async throws -> CompanionSkillResult {
        try await runSkill(CompanionSkillCommand(
            name: name,
            args: args,
            authorizationCode: authorizationCode
        ))
    }

    public func send(event: CompanionEvent) async throws -> CompanionEventResponse {
        let body = try encoder.encode(event)
        let request = try CompanionRequestBuilder.request(
            baseURL: configuration.baseURL,
            path: "/companion/event",
            method: "POST",
            token: configuration.token,
            body: body
        )
        return try await perform(request)
    }

    public func markDream(kind: String, summary: String, source: String = "apple_companion") async throws -> DreamStatus {
        let body = try encoder.encode(["kind": kind, "summary": summary, "source": source])
        let request = try CompanionRequestBuilder.request(
            baseURL: configuration.baseURL,
            path: "/companion/dream/mark",
            method: "POST",
            token: configuration.token,
            body: body
        )
        let response: CompanionEventResponse = try await perform(request)
        guard let dream = response.dream else {
            throw CompanionClientError.noHTTPResponse
        }
        return dream
    }

    private func perform<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CompanionClientError.noHTTPResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw CompanionClientError.httpStatus(http.statusCode, body)
        }
        return try decoder.decode(T.self, from: data)
    }
}
