import CryptoKit
import Foundation

public enum PersonRole: String, Codable, CaseIterable, Sendable {
    case operatorPrimary = "operator_primary"
    case spouse
    case childAdult = "child_adult"
    case parent
    case caregiver
    case emsTester = "ems_tester"
    case collaborator
}

public enum VoiceEnrollmentStatus: Codable, Equatable, Sendable {
    case notStarted
    case consentedPendingSamples
    case samplesCapturedPendingModel(sampleCount: Int)
    case enrolled(modelID: String)
    case revoked

    enum CodingKeys: String, CodingKey {
        case state
        case sampleCount = "sample_count"
        case modelID = "model_id"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let state = try container.decode(String.self, forKey: .state)
        switch state {
        case "not_started":
            self = .notStarted
        case "consented_pending_samples":
            self = .consentedPendingSamples
        case "samples_captured_pending_model":
            self = .samplesCapturedPendingModel(sampleCount: try container.decode(Int.self, forKey: .sampleCount))
        case "enrolled":
            self = .enrolled(modelID: try container.decode(String.self, forKey: .modelID))
        case "revoked":
            self = .revoked
        default:
            throw DecodingError.dataCorruptedError(forKey: .state, in: container, debugDescription: "unknown voice enrollment state")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .notStarted:
            try container.encode("not_started", forKey: .state)
        case .consentedPendingSamples:
            try container.encode("consented_pending_samples", forKey: .state)
        case .samplesCapturedPendingModel(let sampleCount):
            try container.encode("samples_captured_pending_model", forKey: .state)
            try container.encode(sampleCount, forKey: .sampleCount)
        case .enrolled(let modelID):
            try container.encode("enrolled", forKey: .state)
            try container.encode(modelID, forKey: .modelID)
        case .revoked:
            try container.encode("revoked", forKey: .state)
        }
    }
}

public struct ConsentRecord: Codable, Equatable, Sendable {
    public var grantedBy: String
    public var grantedAt: Date
    public var scope: String
    public var termsVersion: String
    public var revokedAt: Date?

    public init(grantedBy: String, grantedAt: Date = Date(), scope: String, termsVersion: String = "jarvis-companion-consent-v1") {
        self.grantedBy = grantedBy
        self.grantedAt = grantedAt
        self.scope = scope
        self.termsVersion = termsVersion
        self.revokedAt = nil
    }

    enum CodingKeys: String, CodingKey {
        case grantedBy = "granted_by"
        case grantedAt = "granted_at"
        case scope
        case termsVersion = "terms_version"
        case revokedAt = "revoked_at"
    }
}

public struct PairedDevice: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var label: String
    public var source: String
    public var platform: String
    public var pairingID: String
    public var pairedAt: Date
    public var revokedAt: Date?

    public init(id: UUID = UUID(), label: String, source: CompanionEvent.Source, platform: String, pairingID: String, pairedAt: Date = Date()) {
        self.id = id
        self.label = label
        self.source = source.rawValue
        self.platform = platform
        self.pairingID = pairingID
        self.pairedAt = pairedAt
        self.revokedAt = nil
    }

    enum CodingKeys: String, CodingKey {
        case id
        case label
        case source
        case platform
        case pairingID = "pairing_id"
        case pairedAt = "paired_at"
        case revokedAt = "revoked_at"
    }
}

public struct AuthorizedPerson: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var displayName: String
    public var relationship: String
    public var role: PersonRole
    public var memoryScopeID: String
    public var consent: ConsentRecord
    public var voiceEnrollment: VoiceEnrollmentStatus
    public var devices: [PairedDevice]
    public var createdAt: Date
    public var updatedAt: Date
    public var revokedAt: Date?

    public init(
        id: UUID = UUID(),
        displayName: String,
        relationship: String,
        role: PersonRole,
        consent: ConsentRecord,
        now: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        self.relationship = relationship
        self.role = role
        self.memoryScopeID = "person." + id.uuidString.lowercased()
        self.consent = consent
        self.voiceEnrollment = .notStarted
        self.devices = []
        self.createdAt = now
        self.updatedAt = now
        self.revokedAt = nil
    }

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case relationship
        case role
        case memoryScopeID = "memory_scope_id"
        case consent
        case voiceEnrollment = "voice_enrollment"
        case devices
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case revokedAt = "revoked_at"
    }
}

public struct EvidenceRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var kind: String
    public var source: String
    public var subjectPersonID: UUID?
    public var consentBasis: String
    public var payloadDigestSHA256: String
    public var payloadSummary: String
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        kind: String,
        source: String,
        subjectPersonID: UUID?,
        consentBasis: String,
        payloadDigestSHA256: String,
        payloadSummary: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.source = source
        self.subjectPersonID = subjectPersonID
        self.consentBasis = consentBasis
        self.payloadDigestSHA256 = payloadDigestSHA256
        self.payloadSummary = payloadSummary
        self.createdAt = createdAt
    }

    public static func make<T: Encodable>(
        kind: String,
        source: String,
        subjectPersonID: UUID?,
        consentBasis: String,
        payload: T,
        payloadSummary: String,
        createdAt: Date = Date()
    ) throws -> EvidenceRecord {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(payload)
        return EvidenceRecord(
            kind: kind,
            source: source,
            subjectPersonID: subjectPersonID,
            consentBasis: consentBasis,
            payloadDigestSHA256: SHA256.hash(data: data).hexString,
            payloadSummary: payloadSummary,
            createdAt: createdAt
        )
    }

    enum CodingKeys: String, CodingKey {
        case id
        case kind
        case source
        case subjectPersonID = "subject_person_id"
        case consentBasis = "consent_basis"
        case payloadDigestSHA256 = "payload_digest_sha256"
        case payloadSummary = "payload_summary"
        case createdAt = "created_at"
    }
}

extension Digest {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

public struct OnboardingState: Codable, Equatable, Sendable {
    public var persons: [AuthorizedPerson]
    public var evidence: [EvidenceRecord]

    public init(persons: [AuthorizedPerson] = [], evidence: [EvidenceRecord] = []) {
        self.persons = persons
        self.evidence = evidence
    }
}
