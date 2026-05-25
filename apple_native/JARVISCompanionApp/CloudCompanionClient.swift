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

    func register(deviceID: String, label: String, platform: String) async throws -> CloudPairResponse {
        try await perform(path: "/app/register", body: RegisterRequest(
            deviceId: deviceID,
            label: label,
            platform: platform
        ))
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

    func dreamStatus() async throws -> DreamStatus {
        try await perform(path: "/app/dream", body: TokenRequest(deviceToken: deviceToken))
    }

    func markDream(kind: String, summary: String, source: String = "ios_companion") async throws -> CloudDreamMarkResponse {
        try await perform(path: "/app/dream/mark", body: DreamMarkRequest(
            deviceToken: deviceToken,
            kind: kind,
            summary: summary,
            source: source
        ))
    }

    func send(event: CompanionEvent, deviceID: String) async throws -> CloudEventResponse {
        try await perform(path: "/app/event", body: EventRequest(
            deviceToken: deviceToken,
            source: event.source,
            deviceId: event.deviceID ?? deviceID,
            kind: event.kind,
            timestamp: event.timestamp ?? Date().timeIntervalSince1970,
            personId: event.personID,
            memoryScopeId: event.memoryScopeID,
            payload: event,
            dream: nil
        ))
    }

    func publishOnboardingEvidence(_ record: EvidenceRecord) async throws -> CloudOKResponse {
        try await perform(path: "/app/onboarding-evidence", body: OnboardingEvidenceRequest(
            deviceToken: deviceToken,
            recordId: record.id.uuidString.lowercased(),
            kind: record.kind,
            source: record.source,
            timestamp: record.createdAt.timeIntervalSince1970,
            personId: record.subjectPersonID?.uuidString.lowercased(),
            memoryScopeId: record.memoryScopeID,
            consentBasis: record.consentBasis,
            payloadDigestSHA256: record.payloadDigestSHA256,
            payloadSummary: record.payloadSummary,
            payload: record.payload,
            actor: record.provenance.actor,
            provenance: record.provenance
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

    func speech(text: String, deviceID: String) async throws -> CloudSpeechResponse {
        try await perform(path: "/app/speech", body: SpeechRequest(
            deviceToken: deviceToken,
            deviceId: deviceID,
            text: text
        ))
    }

    func transcribeAudio(audioBase64: String, contentType: String, deviceID: String) async throws -> CloudTranscriptionResponse {
        try await perform(path: "/app/transcribe", body: TranscriptionRequest(
            deviceToken: deviceToken,
            deviceId: deviceID,
            audioBase64: audioBase64,
            contentType: contentType
        ))
    }

    func recordVoiceEnrollment(person: AuthorizedPerson) async throws -> CloudVoiceEnrollmentResponse {
        let handoff = person.voiceEnrollmentHandoff
        return try await perform(path: "/app/voice-enrollment", body: VoiceEnrollmentStatusRequest(
            deviceToken: deviceToken,
            personId: person.id.uuidString.lowercased(),
            memoryScopeId: person.memoryScopeID,
            status: person.voiceEnrollment.cloudStatus,
            sampleCount: person.voiceEnrollment.sampleCount ?? person.voiceSampleManifests.filter(\.accepted).count,
            sampleDigestsSHA256: person.voiceSampleManifests.filter(\.accepted).map(\.sha256),
            backend: handoff?.backend,
            handoffId: handoff?.handoffID,
            modelId: handoff?.modelID ?? person.voiceEnrollment.modelID,
            blockedReason: handoff?.blockedReason ?? person.voiceEnrollment.blockedReason,
            storagePolicy: person.voiceSampleStoragePolicy ?? .localOnlyPendingBackend,
            revokedAt: person.voiceSampleDeletion?.deletedAt.timeIntervalSince1970
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
            if let error = try? decodeBoundedJSON(data, as: CloudErrorResponse.self) {
                throw CloudCompanionClientError.server(error.error)
            }
            throw CloudCompanionClientError.httpStatus(httpResponse.statusCode)
        }
        return try decodeBoundedJSON(data, as: ResponseBody.self)
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

struct CloudEventResponse: Codable, Equatable, Sendable {
    let ok: Bool
    let dream: DreamStatus?
}

struct CloudDreamMarkResponse: Codable, Equatable, Sendable {
    let ok: Bool
    let kind: String
    let timestamp: Double
    let dream: DreamStatus
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

struct CloudSpeechResponse: Codable, Equatable, Sendable {
    let ok: Bool
    let code: String?
    let error: String?
    let reason: String?
    let spoken: Bool?
    let backend: String?
    let backendKind: String?
    let contentType: String?
    let audioBase64: String?
    let synthesisSeconds: Double?
    let missing: [String]?
    let fallbackPolicy: String?
    let wrongVoiceFallbackAllowed: Bool?
    let systemVoiceFallbackAllowed: Bool?
    let nativeSystemVoiceAllowed: Bool?
    let pythonTTSAllowed: Bool?
    let hardVoiceInvariant: String?

    var unavailabilityText: String {
        if let reason, !reason.isEmpty {
            return reason
        }
        if let error, !error.isEmpty {
            return error
        }
        if let code, !code.isEmpty {
            return code
        }
        return "Native JARVIS voice is unavailable; no fallback voice was used."
    }

    enum CodingKeys: String, CodingKey {
        case ok
        case code
        case error
        case reason
        case spoken
        case backend
        case backendKind = "backend_kind"
        case contentType = "content_type"
        case audioBase64 = "audio_base64"
        case synthesisSeconds = "synthesis_seconds"
        case missing
        case fallbackPolicy = "fallback_policy"
        case wrongVoiceFallbackAllowed = "wrong_voice_fallback_allowed"
        case systemVoiceFallbackAllowed = "system_voice_fallback_allowed"
        case nativeSystemVoiceAllowed = "native_system_voice_allowed"
        case pythonTTSAllowed = "python_tts_allowed"
        case hardVoiceInvariant = "hard_voice_invariant"
    }
}

struct CloudTranscriptionResponse: Codable, Equatable, Sendable {
    let ok: Bool
    let transcript: String
}

struct CloudVoiceEnrollmentResponse: Codable, Equatable, Sendable {
    let ok: Bool
    let personId: String
    let status: String
    let id: String?

    enum CodingKeys: String, CodingKey {
        case ok
        case personId = "person_id"
        case status
        case id
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

private struct RegisterRequest: Encodable {
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

private struct OnboardingEvidenceRequest: Encodable {
    let deviceToken: String
    let recordId: String
    let kind: String
    let source: String
    let timestamp: TimeInterval
    let personId: String?
    let memoryScopeId: String?
    let consentBasis: String
    let payloadDigestSHA256: String
    let payloadSummary: String
    let payload: JSONValue
    let actor: String
    let provenance: EvidenceProvenance
}

private struct DreamMarkRequest: Encodable {
    let deviceToken: String
    let kind: String
    let summary: String
    let source: String
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

private struct SpeechRequest: Encodable {
    let deviceToken: String
    let deviceId: String
    let text: String
}

private struct TranscriptionRequest: Encodable {
    let deviceToken: String
    let deviceId: String
    let audioBase64: String
    let contentType: String

    enum CodingKeys: String, CodingKey {
        case deviceToken
        case deviceId
        case audioBase64 = "audio_base64"
        case contentType = "content_type"
    }
}

private struct VoiceEnrollmentStatusRequest: Encodable {
    let deviceToken: String
    let personId: String
    let memoryScopeId: String?
    let status: String
    let sampleCount: Int
    let sampleDigestsSHA256: [String]
    let backend: String?
    let handoffId: String?
    let modelId: String?
    let blockedReason: String?
    let storagePolicy: VoiceSampleStoragePolicy
    let revokedAt: TimeInterval?

    enum CodingKeys: String, CodingKey {
        case deviceToken
        case personId = "person_id"
        case memoryScopeId = "memory_scope_id"
        case status
        case sampleCount = "sample_count"
        case sampleDigestsSHA256 = "sample_digests_sha256"
        case backend
        case handoffId = "handoff_id"
        case modelId = "model_id"
        case blockedReason = "blocked_reason"
        case storagePolicy = "storage_policy"
        case revokedAt = "revoked_at"
    }
}

private struct ControlStatusRequest: Encodable {
    let deviceToken: String
    let requestId: String
}

private extension VoiceEnrollmentStatus {
    var cloudStatus: String {
        switch self {
        case .notStarted:
            return "not_started"
        case .consentedPendingSamples:
            return "consented_pending_samples"
        case .samplesCapturedPendingModel:
            return "samples_captured_pending_model"
        case .modelEnrollmentBlocked:
            return "model_enrollment_blocked"
        case .enrolled:
            return "enrolled"
        case .revoked:
            return "revoked"
        }
    }

    var sampleCount: Int? {
        switch self {
        case .samplesCapturedPendingModel(let sampleCount):
            return sampleCount
        case .modelEnrollmentBlocked(let sampleCount, _):
            return sampleCount
        default:
            return nil
        }
    }

    var modelID: String? {
        if case .enrolled(let modelID) = self {
            return modelID
        }
        return nil
    }

    var blockedReason: String? {
        if case .modelEnrollmentBlocked(_, let reason) = self {
            return reason
        }
        return nil
    }
}
