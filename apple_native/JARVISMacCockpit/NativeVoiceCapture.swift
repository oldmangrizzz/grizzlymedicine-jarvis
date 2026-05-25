import AVFoundation
import Foundation

@MainActor
final class NativeVoiceCapture: ObservableObject {
    @Published private(set) var isRecording = false

    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?
    private let maxBytes = 6_000_000

    func start() async throws {
        guard !isRecording else {
            return
        }
        guard await requestMicrophoneAccess() else {
            throw NativeVoiceError.microphoneDenied
        }

        let url: URL
        do {
            url = try newRecordingURL()
        } catch {
            throw NativeVoiceError.recordingStorageUnavailable(auditDetail(error.localizedDescription))
        }
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        guard recorder.record(forDuration: 30) else {
            throw NativeVoiceError.recordingDidNotStart
        }
        self.recorder = recorder
        recordingURL = url
        isRecording = true
    }

    func stopAndCapture() throws -> NativeVoiceRecording {
        guard isRecording else {
            throw NativeVoiceError.noRecording
        }
        recorder?.stop()
        recorder = nil
        isRecording = false
        guard let url = recordingURL else {
            throw NativeVoiceError.noRecording
        }
        defer {
            try? FileManager.default.removeItem(at: url) // TODO(removal-cond: log as WRITE_FAILED cleanup event once this defer can reach an audit sink)
            recordingURL = nil
        }
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        let size = values.fileSize ?? 0
        guard size > 128 else {
            throw NativeVoiceError.recordingTooShort
        }
        guard size <= maxBytes else {
            throw NativeVoiceError.recordingTooLarge
        }
        return NativeVoiceRecording(data: try Data(contentsOf: url), contentType: "audio/m4a")
    }

    func cancel() {
        recorder?.stop()
        recorder = nil
        isRecording = false
        if let recordingURL {
            try? FileManager.default.removeItem(at: recordingURL) // TODO(removal-cond: log as WRITE_FAILED cleanup event once cancel() can reach an audit sink)
        }
        recordingURL = nil
    }

    private func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .denied, .restricted:
            return false
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        @unknown default:
            return false
        }
    }

    private func newRecordingURL() throws -> URL {
        let root = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = root
            .appendingPathComponent("JARVISMacCockpit", isDirectory: true)
            .appendingPathComponent("Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        pruneStaleRecordings(in: directory)
        return directory.appendingPathComponent("jarvis-mac-command-\(UUID().uuidString).m4a")
    }

    private func pruneStaleRecordings(in directory: URL) {
        guard let urls = try? FileManager.default.contentsOfDirectory( // TODO(removal-cond: log directory-list failure as INTERNAL_ERROR once audit sink available here)
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        let cutoff = Date().addingTimeInterval(-60 * 60)
        for url in urls where url.lastPathComponent.hasPrefix("jarvis-mac-command-") {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if modified < cutoff {
                try? FileManager.default.removeItem(at: url) // TODO(removal-cond: log stale-recording removal failure as WRITE_FAILED once audit sink available here)
            }
        }
    }
}

struct NativeVoiceRecording {
    let data: Data
    let contentType: String
}

enum NativeVoiceError: LocalizedError {
    case microphoneDenied
    case noRecording
    case recordingDidNotStart
    case recordingStorageUnavailable(String)
    case recordingTooLarge
    case recordingTooShort

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            return "Microphone permission is required for native JARVIS voice commands."
        case .noRecording:
            return "No voice recording was captured."
        case .recordingDidNotStart:
            return "The microphone did not start recording."
        case .recordingStorageUnavailable(let detail):
            return "Native voice recording storage is unavailable: \(detail)"
        case .recordingTooLarge:
            return "The recording is too large. Try a shorter command."
        case .recordingTooShort:
            return "The recording was too short. Tap, speak, then tap again."
        }
    }
}

struct NativeTranscriptionClient {
    private let env: [String: String]
    private let session: URLSession

    init(env: [String: String] = NativeEnvironment.load(), session: URLSession = .jarvisPinned) {
        self.env = env
        self.session = session
    }

    var configuredModel: String {
        clean(env["JARVIS_NATIVE_STT_MODEL"]) ?? "nova-3"
    }

    var statusText: String {
        clean(env["DEEPGRAM_API_KEY"]) == nil ? "Deepgram key missing" : "Deepgram \(configuredModel)"
    }

    func transcribe(_ recording: NativeVoiceRecording) async throws -> String {
        guard let apiKey = clean(env["DEEPGRAM_API_KEY"]) else {
            throw NativeTranscriptionError.missingAPIKey
        }
        guard var components = URLComponents(string: "https://api.deepgram.com/v1/listen") else {
            throw NativeTranscriptionError.invalidEndpoint
        }
        components.queryItems = [
            URLQueryItem(name: "model", value: configuredModel),
            URLQueryItem(name: "language", value: "en-US"),
            URLQueryItem(name: "smart_format", value: "true"),
            URLQueryItem(name: "mip_opt_out", value: "true"),
        ]
        guard let url = components.url else {
            throw NativeTranscriptionError.invalidEndpoint
        }
        try NativeURLAllowlist.load().validate(url, category: .voiceTranscription)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "authorization")
        request.setValue(recording.contentType, forHTTPHeaderField: "content-type")
        request.httpBody = recording.data

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NativeTranscriptionError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let correlationID = NativeUpstreamErrorAudit.record(client: "voice_transcription", url: url, status: http.statusCode, body: data)
            throw NativeTranscriptionError.httpStatus(http.statusCode, correlationID)
        }
        let payload = try JSONDecoder().decode(DeepgramResponse.self, from: data)
        let transcript = payload.results.channels.first?.alternatives.first?.transcript
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !transcript.isEmpty else {
            throw NativeTranscriptionError.emptyTranscript
        }
        return transcript
    }

    private func clean(_ value: String?) -> String? {
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct NativeSpeechClient {
    private let env: [String: String]
    private let session: URLSession

    init(env: [String: String] = NativeEnvironment.load(), session: URLSession = .jarvisPinned) {
        self.env = env
        self.session = session
    }

    var configuredBackend: String {
        clean(env["JARVIS_NATIVE_VOICE_BACKEND"]) ?? "native-jarvis-deepgram-aura"
    }

    var configuredVoice: String {
        clean(env["JARVIS_NATIVE_VOICE_ID"]) ??
            clean(env["JARVIS_NATIVE_VOICE"]) ??
            clean(env["DEEPGRAM_TTS_MODEL"]) ??
            "aura-2-orion-en"
    }

    func synthesize(_ text: String, status: NativeVoiceStatus) async throws -> NativeSpeechResponse {
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanText.isEmpty else {
            throw NativeSpeechError.noText
        }
        guard status.available, status.safeToSpeak, status.voiceConfirmed else {
            throw NativeSpeechError.voiceNotReady(status.reason)
        }
        guard let apiKey = clean(env["DEEPGRAM_API_KEY"]) else {
            throw NativeSpeechError.missingAPIKey
        }
        let backend = configuredBackend
        guard backendLooksNativeJarvis(backend) else {
            throw NativeSpeechError.invalidBackend(backend)
        }
        let voice = configuredVoice
        guard voice.lowercased().hasPrefix("aura-") else {
            throw NativeSpeechError.invalidVoice(voice)
        }
        guard var components = URLComponents(string: "https://api.deepgram.com/v1/speak") else {
            throw NativeSpeechError.invalidEndpoint
        }
        components.queryItems = [
            URLQueryItem(name: "model", value: voice),
        ]
        guard let url = components.url else {
            throw NativeSpeechError.invalidEndpoint
        }
        try NativeURLAllowlist.load().validate(url, category: .voiceSpeech)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("audio/mpeg", forHTTPHeaderField: "accept")
        request.httpBody = try JSONEncoder().encode(DeepgramSpeakRequest(text: cleanText))

        let start = Date()
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NativeSpeechError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let correlationID = NativeUpstreamErrorAudit.record(client: "voice_speech", url: url, status: http.statusCode, body: data)
            throw NativeSpeechError.httpStatus(http.statusCode, correlationID)
        }
        guard data.count > 128 else {
            throw NativeSpeechError.emptyAudio
        }
        let contentType = http.value(forHTTPHeaderField: "content-type")?
            .split(separator: ";", maxSplits: 1)
            .first
            .map(String.init) ?? "audio/mpeg"

        return NativeSpeechResponse(
            ok: true,
            code: "native_voice_ready",
            error: nil,
            reason: "Native JARVIS voice synthesized by \(backend).",
            spoken: true,
            backend: backend,
            backendKind: "native_jarvis_voice",
            contentType: contentType,
            audioBase64: data.base64EncodedString(),
            synthesisSeconds: Date().timeIntervalSince(start),
            fallbackPolicy: "none",
            wrongVoiceFallbackAllowed: false,
            systemVoiceFallbackAllowed: false,
            nativeSystemVoiceAllowed: false,
            pythonTTSAllowed: false,
            hardVoiceInvariant: "jarvis_voice_or_no_voice",
            status: status
        )
    }

    private func clean(_ value: String?) -> String? {
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func backendLooksNativeJarvis(_ value: String) -> Bool {
        let lower = value.lowercased()
        return lower.contains("native") &&
            lower.contains("jarvis") &&
            !lower.contains("python") &&
            !lower.contains("system voice") &&
            !lower.contains("nsspeech") &&
            !lower.contains("avspeech") &&
            !lower.contains("speechsynthesis") &&
            !lower.contains("web speech") &&
            !lower.contains("tts_pocket") &&
            !lower.contains("jarvis_bridge.py")
    }
}

private struct DeepgramSpeakRequest: Encodable {
    let text: String
}

private struct DeepgramResponse: Decodable {
    struct Results: Decodable {
        let channels: [Channel]
    }

    struct Channel: Decodable {
        let alternatives: [Alternative]
    }

    struct Alternative: Decodable {
        let transcript: String
    }

    let results: Results
}

enum NativeTranscriptionError: LocalizedError {
    case emptyTranscript
    case httpStatus(Int, String)
    case invalidEndpoint
    case invalidResponse
    case missingAPIKey

    var errorDescription: String? {
        switch self {
        case .emptyTranscript:
            return "JARVIS did not hear words in that recording."
        case .httpStatus(let status, let correlationID):
            return "upstream_error client=voice_transcription status=\(status) correlation_id=\(correlationID)"
        case .invalidEndpoint:
            return "The native transcription endpoint is invalid."
        case .invalidResponse:
            return "The transcription endpoint did not return HTTP."
        case .missingAPIKey:
            return "DEEPGRAM_API_KEY is missing from the native runtime environment."
        }
    }
}

enum NativeSpeechError: LocalizedError {
    case emptyAudio
    case httpStatus(Int, String)
    case invalidBackend(String)
    case invalidEndpoint
    case invalidResponse
    case invalidVoice(String)
    case missingAPIKey
    case noText
    case voiceNotReady(String)

    var errorDescription: String? {
        switch self {
        case .emptyAudio:
            return "Native voice service returned empty audio."
        case .httpStatus(let status, let correlationID):
            return "upstream_error client=voice_speech status=\(status) correlation_id=\(correlationID)"
        case .invalidBackend(let backend):
            return "Blocked non-JARVIS native voice backend: \(backend)"
        case .invalidEndpoint:
            return "The native voice endpoint is invalid."
        case .invalidResponse:
            return "The native voice endpoint did not return HTTP."
        case .invalidVoice(let voice):
            return "Blocked unsupported native JARVIS voice id: \(voice)"
        case .missingAPIKey:
            return "DEEPGRAM_API_KEY is missing from the native runtime environment."
        case .noText:
            return "No text was provided for native JARVIS voice."
        case .voiceNotReady(let reason):
            return "Native JARVIS voice is not ready: \(reason)"
        }
    }
}
