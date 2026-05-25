import Foundation
#if canImport(Darwin)
import Darwin
#endif

struct NativeModelClient {
    private let env: [String: String]
    private let session: URLSession

    init(env: [String: String] = NativeEnvironment.load(), session: URLSession = .jarvisPinned) {
        self.env = env
        self.session = session
    }

    var configuredModel: String {
        clean(env["JARVIS_NATIVE_MODEL"]) ?? "glm-5.1"
    }

    var configuredBaseURLText: String {
        clean(env["JARVIS_NATIVE_MODEL_BASE"]) ?? clean(env["OLLAMA_BASE_URL"]) ?? "https://ollama.com"
    }

    func complete(messages: [NativeChatMessage], requestedModel: String) async throws -> NativeModelReply {
        let baseURLText = configuredBaseURLText
        guard let baseURL = URL(string: baseURLText.trimmingCharacters(in: CharacterSet(charactersIn: "/"))) else {
            throw NativeModelError.invalidBaseURL(baseURLText)
        }
        try NativeURLAllowlist.load().validate(baseURL, category: .model)

        var request = URLRequest(url: baseURL.appending(path: "api/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("application/json", forHTTPHeaderField: "accept")
        if let apiKey = clean(env["OLLAMA_API_KEY"]) {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "authorization")
        }
        request.httpBody = try JSONEncoder().encode(NativeModelRequest(
            model: clean(requestedModel) ?? configuredModel,
            messages: messages,
            stream: false,
            options: ["temperature": 0.5]
        ))

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NativeModelError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let correlationID = NativeUpstreamErrorAudit.record(client: "model", url: request.url ?? baseURL, status: http.statusCode, body: data)
            throw NativeModelError.httpStatus(http.statusCode, correlationID)
        }
        let payload = try decodeBoundedJSON(data, as: NativeModelResponse.self, maxBytes: 4 << 20)
        let reply = payload.message?.content.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !reply.isEmpty else {
            throw NativeModelError.emptyReply
        }
        return NativeModelReply(model: payload.model ?? requestedModel, text: reply)
    }

    private func clean(_ value: String?) -> String? {
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct NativeModelReply: Equatable {
    let model: String
    let text: String
}

private struct NativeModelRequest: Encodable {
    let model: String
    let messages: [NativeChatMessage]
    let stream: Bool
    let options: [String: Double]
}

private struct NativeModelResponse: Decodable {
    struct Message: Decodable {
        let role: String?
        let content: String
    }

    let model: String?
    let message: Message?
}

enum NativeModelError: LocalizedError {
    case emptyReply
    case httpStatus(Int, String)
    case invalidBaseURL(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .emptyReply:
            return "The model returned an empty reply."
        case .httpStatus(let status, let correlationID):
            return "upstream_error client=model status=\(status) correlation_id=\(correlationID)"
        case .invalidBaseURL(let value):
            return "Invalid model endpoint URL: \(value)"
        case .invalidResponse:
            return "The model endpoint did not return HTTP."
        }
    }
}

enum NativeEnvironment {
    /// Environment resolution order: current process environment wins; then values
    /// from JARVIS_ENV_FILE if set; otherwise ~/.jarvis/config/env.
    static func load(path: String? = nil) -> [String: String] {
        let env = ProcessInfo.processInfo.environment
        let filePath = path ?? env["JARVIS_ENV_FILE"] ?? "~/.jarvis/config/env"
        let expanded = NSString(string: filePath).expandingTildeInPath
        guard let text = try? String(contentsOfFile: expanded, encoding: .utf8) else {
            return env
        }
        var values = env
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#"), let equals = line.firstIndex(of: "=") else {
                continue
            }
            let key = line[..<equals].trimmingCharacters(in: .whitespacesAndNewlines)
            var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value.removeFirst()
                value.removeLast()
            }
            if !key.isEmpty, values[key] == nil {
                values[key] = value
            }
        }
        return values
    }

    static func applyToProcess(path: String? = nil) {
        let values = load(path: path)
        for (key, value) in values where shouldExportToNativeProcess(key) {
            setenv(key, value, 0)
        }
    }

    private static func shouldExportToNativeProcess(_ key: String) -> Bool {
        key.hasPrefix("JARVIS_") ||
            key.hasPrefix("DEEPGRAM_") ||
            key.hasPrefix("OLLAMA_")
    }
}
