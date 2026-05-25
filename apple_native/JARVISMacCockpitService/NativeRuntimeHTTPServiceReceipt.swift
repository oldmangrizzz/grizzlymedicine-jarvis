import Foundation
#if canImport(Darwin)
import Darwin
#endif

@main
struct NativeRuntimeHTTPServiceReceipt {
    static func main() async throws {
        setenv("JARVIS_NATIVE_VOICE_BACKEND", "native-jarvis-receipt-voice", 1)
        setenv("JARVIS_NATIVE_VOICE_ID", "receipt-jarvis", 1)
        setenv("JARVIS_NATIVE_VOICE_CONFIRMED", "1", 1)
        setenv("JARVIS_NATIVE_VOICE_ENDPOINT", "receipt://native-voice", 1)
        let nonceStore = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/native-http-receipt-nonces-\(UUID().uuidString).jsonl")
        setenv("JARVIS_HTTP_NONCE_STORE", nonceStore.path, 1)
        let configuration = NativeRuntimeHTTPServiceConfiguration(
            host: "127.0.0.1",
            port: 18_788,
            companionToken: "receipt-token"
        )
        let handler = try NativeRuntimeHTTPHandler(
            chatCompletion: { _, _ in
                NativeModelReply(model: "receipt-model", text: "Receipt committed by native HTTP service.")
            },
            speechSynthesis: { _, status in
                NativeSpeechResponse(
                    ok: true,
                    code: "native_voice_ready",
                    error: nil,
                    reason: "Receipt native JARVIS voice synthesis.",
                    spoken: true,
                    backend: "native-jarvis-receipt-voice",
                    backendKind: "native_jarvis_voice",
                    contentType: "audio/wav",
                    audioBase64: Data("receipt-native-jarvis-voice".utf8).base64EncodedString(),
                    synthesisSeconds: 0.01,
                    fallbackPolicy: "none",
                    wrongVoiceFallbackAllowed: false,
                    systemVoiceFallbackAllowed: false,
                    nativeSystemVoiceAllowed: false,
                    pythonTTSAllowed: false,
                    hardVoiceInvariant: "jarvis_voice_or_no_voice",
                    status: status
                )
            }
        )
        let server = NativeRuntimeHTTPServer(configuration: configuration, handler: handler)
        try server.start()
        defer { server.stop() }

        let client = ReceiptHTTPClient(baseURL: try require(URL(string: configuration.baseURLText), "base URL"))
        try await waitForService(client)

        let state = try await client.request(path: "/state")
        try expect(state.status == 200, "/state should return 200")
        try expect(state.bool("ok") == true, "/state should be ok")
        try expect(state.string("runtime") == "native-swift-cpp", "/state should expose native runtime")
        try expect(state.bool("python_beta_path") == false, "/state should block Python beta path")

        let unauthorized = try await client.request(path: "/companion/skills")
        try expect(unauthorized.status == 401, "protected companion routes should require token")

        let skills = try await client.request(path: "/companion/skills", token: "receipt-token")
        try expect(skills.status == 200, "/companion/skills should return 200 got \(skills.status): \(skills.text)")
        try expect(skills.text.contains("native_skill_catalog"), "skill catalog should include native registry")
        try expect(skills.text.contains("python_beta_path"), "skill catalog should include Python beta path flag")

        let turn = try await client.request(
            path: "/companion/turn",
            method: "POST",
            token: "receipt-token",
            body: ["text": "native HTTP receipt turn"]
        )
        try expect(turn.status == 200, "/companion/turn should return 200 with receipt model")
        try expect(turn.string("reply") == "Receipt committed by native HTTP service.", "turn should commit receipt reply")
        try expect(turn.string("model") == "receipt-model", "turn should report receipt model")
        try expect(turn.bool("python_beta_path") == false, "turn should stay off Python beta path")

        let speech = try await client.request(
            path: "/companion/speech",
            method: "POST",
            token: "receipt-token",
            body: ["text": "speak this"]
        )
        try expect(speech.status == 200, "/companion/speech should speak through native voice")
        try expect(speech.string("code") == "native_voice_ready", "speech policy should return native_voice_ready")
        try expect(speech.bool("spoken") == true, "speech policy should report real spoken audio")
        try expect((speech.string("audio_base64") ?? "").isEmpty == false, "speech policy must return native audio")
        try expect(speech.bool("speech_allowed") == true, "speech policy should allow configured native voice")
        try expect(speech.bool("native_system_voice_fallback") == false, "system voice fallback must remain disabled")
        try expect(speech.bool("system_voice_fallback_allowed") == false, "system voice fallback symbol must remain false")
        try expect(speech.bool("python_tts_allowed") == false, "Python TTS must remain blocked")
        try expect(speech.text.contains("\"backend\":\"native-jarvis-receipt-voice\""), "speech receipt should identify native JARVIS backend")

        let transcribe = try await client.request(
            path: "/companion/transcribe",
            method: "POST",
            token: "receipt-token",
            body: [:]
        )
        try expect(transcribe.status == 400, "/companion/transcribe should explicitly reject missing audio")
        try expect(transcribe.string("status") == "bad_request", "transcribe missing audio should be explicit")

        let replayNonce = "0123456789abcdef0123456789abcdef"
        let replayTimestamp = Int(Date().timeIntervalSince1970)
        let firstReplayUse = try await client.request(path: "/companion/skills", token: "receipt-token", nonce: replayNonce, timestamp: replayTimestamp)
        try expect(firstReplayUse.status == 200, "first nonce use should pass before restart")
        server.stop()
        let restartedHandler = try NativeRuntimeHTTPHandler(chatCompletion: { _, _ in
            NativeModelReply(model: "receipt-model", text: "Receipt committed by native HTTP service.")
        }, speechSynthesis: { _, status in
            NativeSpeechResponse(ok: true, code: "native_voice_ready", error: nil, reason: "Receipt native JARVIS voice synthesis.", spoken: true, backend: "native-jarvis-receipt-voice", backendKind: "native_jarvis_voice", contentType: "audio/wav", audioBase64: Data("receipt-native-jarvis-voice".utf8).base64EncodedString(), synthesisSeconds: 0.01, fallbackPolicy: "none", wrongVoiceFallbackAllowed: false, systemVoiceFallbackAllowed: false, nativeSystemVoiceAllowed: false, pythonTTSAllowed: false, hardVoiceInvariant: "jarvis_voice_or_no_voice", status: status)
        })
        let restarted = NativeRuntimeHTTPServer(configuration: configuration, handler: restartedHandler)
        try restarted.start()
        defer { restarted.stop() }
        try await waitForService(client)
        let replay = try await client.request(path: "/companion/skills", token: "receipt-token", nonce: replayNonce, timestamp: replayTimestamp)
        try expect(replay.status == 401, "replayed nonce after restart should return 401 got \(replay.status): \(replay.text)")
        try expect(replay.text.contains("nonce_reuse"), "replayed nonce should report nonce_reuse")

        print("{\"ok\":true,\"receipt\":\"native-runtime-http-service\",\"state\":true,\"skills\":true,\"turn\":true,\"native_voice\":true,\"transcribe_missing_audio_blocked\":true,\"restart_replay_refused\":true,\"python_beta_path\":false}")
    }

    private static func waitForService(_ client: ReceiptHTTPClient) async throws {
        var lastError: Error?
        for _ in 0..<30 {
            do {
                let health = try await client.request(path: "/health")
                if health.status == 200 {
                    return
                }
            } catch {
                lastError = error
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        if let lastError {
            throw lastError
        }
        throw ReceiptFailure.failed("native HTTP service did not become ready")
    }
}

private struct ReceiptHTTPClient {
    let baseURL: URL
    let session = URLSession.shared

    func request(
        path: String,
        method: String = "GET",
        token: String? = nil,
        body: [String: Any]? = nil,
        nonce: String? = nil,
        timestamp: Int? = nil
    ) async throws -> ReceiptHTTPResult {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw ReceiptFailure.failed("invalid receipt base URL")
        }
        components.path = path.hasPrefix("/") ? path : "/" + path
        let url = try require(components.url, "receipt request URL")
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 5
        request.setValue("application/json", forHTTPHeaderField: "accept")
        if let token {
            request.setValue(token, forHTTPHeaderField: "x-jarvis-companion-token")
            request.setValue(nonce ?? UUID().uuidString, forHTTPHeaderField: "x-jarvis-nonce")
            request.setValue(String(timestamp ?? Int(Date().timeIntervalSince1970)), forHTTPHeaderField: "x-jarvis-timestamp")
        }
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
            request.setValue("application/json", forHTTPHeaderField: "content-type")
        }
        // Host allowlist guard: destination is always the local native runtime HTTP server
        // (127.0.0.1). Reject any request that resolves outside loopback — this client
        // must never contact external hosts.
        let allowedHosts: Set<String> = ["127.0.0.1", "localhost", "::1"]
        guard let requestHost = request.url?.host, allowedHosts.contains(requestHost) else {
            throw ReceiptFailure.failed("receipt client host rejected: \(request.url?.host ?? "<nil>") is not in loopback allowlist")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ReceiptFailure.failed("no HTTP response for \(path)")
        }
        let text = String(data: data, encoding: .utf8) ?? ""
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return ReceiptHTTPResult(status: http.statusCode, object: object, text: text)
    }
}

private struct ReceiptHTTPResult {
    let status: Int
    let object: [String: Any]
    let text: String

    func string(_ key: String) -> String? {
        object[key] as? String
    }

    func bool(_ key: String) -> Bool? {
        object[key] as? Bool
    }
}

private enum ReceiptFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message):
            return message
        }
    }
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() {
        throw ReceiptFailure.failed(message)
    }
}

private func require<T>(_ value: T?, _ message: String) throws -> T {
    guard let value else {
        throw ReceiptFailure.failed(message)
    }
    return value
}
