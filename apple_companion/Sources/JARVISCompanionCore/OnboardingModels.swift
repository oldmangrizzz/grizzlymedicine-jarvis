import CryptoKit
import Foundation

public enum PersonRole: String, Codable, CaseIterable, Sendable {
    case operatorPrimary = "operator_primary"
    case spouse
    case childAdult = "child_adult"
    case parent
    case caregiver
    case emsTester = "ems_tester"
    case authorizedTester = "authorized_tester"
    case collaborator
}

public enum PersonPermission: String, Codable, CaseIterable, Identifiable, Sendable {
    case observeSelectedSignals = "observe_selected_signals"
    case pairApprovedDevices = "pair_approved_devices"
    case voiceEnrollmentStatus = "voice_enrollment_status"
    case scopedCompanionContext = "scoped_companion_context"
    case evidenceExport = "evidence_export"
    case managePeople = "manage_people"

    public var id: String { rawValue }
}

public struct PersonPermissionScope: Codable, Equatable, Sendable {
    public var role: PersonRole
    public var permissions: [PersonPermission]
    public var allowedSources: [String]
    public var notes: String

    public init(role: PersonRole, permissions: [PersonPermission], allowedSources: [String], notes: String) {
        self.role = role
        self.permissions = permissions
        self.allowedSources = allowedSources
        self.notes = notes
    }

    public static func defaults(for role: PersonRole) -> PersonPermissionScope {
        let allSources = [
            CompanionEvent.Source.iPhone.rawValue,
            CompanionEvent.Source.appleWatch.rawValue,
            CompanionEvent.Source.nativeSpatial.rawValue,
            CompanionEvent.Source.carPlay.rawValue,
            CompanionEvent.Source.homeKit.rawValue,
            CompanionEvent.Source.blink.rawValue,
            CompanionEvent.Source.esp32Future.rawValue,
        ]
        let familySources = [
            CompanionEvent.Source.iPhone.rawValue,
            CompanionEvent.Source.appleWatch.rawValue,
            CompanionEvent.Source.carPlay.rawValue,
            CompanionEvent.Source.homeKit.rawValue,
            CompanionEvent.Source.nativeSpatial.rawValue,
        ]
        let testerSources = [
            CompanionEvent.Source.iPhone.rawValue,
            CompanionEvent.Source.appleWatch.rawValue,
            CompanionEvent.Source.nativeSpatial.rawValue,
            CompanionEvent.Source.blink.rawValue,
            CompanionEvent.Source.esp32Future.rawValue,
        ]
        let supportSources = [
            CompanionEvent.Source.iPhone.rawValue,
            CompanionEvent.Source.appleWatch.rawValue,
            CompanionEvent.Source.homeKit.rawValue,
        ]
        let familyPermissions: [PersonPermission] = [
            .observeSelectedSignals,
            .pairApprovedDevices,
            .voiceEnrollmentStatus,
            .scopedCompanionContext,
            .evidenceExport,
        ]
        let testerPermissions: [PersonPermission] = [
            .observeSelectedSignals,
            .pairApprovedDevices,
            .voiceEnrollmentStatus,
            .evidenceExport,
        ]

        switch role {
        case .operatorPrimary:
            return PersonPermissionScope(
                role: role,
                permissions: PersonPermission.allCases,
                allowedSources: allSources,
                notes: "Primary operator can manage people, devices, voice status, scoped context, and exports."
            )
        case .spouse, .childAdult, .parent:
            return PersonPermissionScope(
                role: role,
                permissions: familyPermissions,
                allowedSources: familySources,
                notes: "Family role: selected Apple/device signals stay inside this person's memory scope."
            )
        case .caregiver:
            return PersonPermissionScope(
                role: role,
                permissions: familyPermissions,
                allowedSources: supportSources,
                notes: "Support role: selected phone/watch/home signals stay inside this person's memory scope."
            )
        case .emsTester, .authorizedTester, .collaborator:
            return PersonPermissionScope(
                role: role,
                permissions: testerPermissions,
                allowedSources: testerSources,
                notes: "Tester role: selected test signals, voice status, devices, and evidence export only."
            )
        }
    }

    public func allows(_ permission: PersonPermission) -> Bool {
        permissions.contains(permission)
    }

    public func allows(source: CompanionEvent.Source) -> Bool {
        allowedSources.contains(source.rawValue)
    }

    enum CodingKeys: String, CodingKey {
        case role
        case permissions
        case allowedSources = "allowed_sources"
        case notes
    }
}

public extension PersonRole {
    var defaultPermissionScope: PersonPermissionScope {
        PersonPermissionScope.defaults(for: self)
    }
}

public enum VoiceEnrollmentStatus: Codable, Equatable, Sendable {
    case notStarted
    case consentedPendingSamples
    case samplesCapturedPendingModel(sampleCount: Int)
    case modelEnrollmentBlocked(sampleCount: Int, reason: String)
    case enrolled(modelID: String)
    case revoked

    enum CodingKeys: String, CodingKey {
        case state
        case sampleCount = "sample_count"
        case modelID = "model_id"
        case reason
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
        case "model_enrollment_blocked":
            self = .modelEnrollmentBlocked(
                sampleCount: try container.decode(Int.self, forKey: .sampleCount),
                reason: try container.decode(String.self, forKey: .reason)
            )
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
        case .modelEnrollmentBlocked(let sampleCount, let reason):
            try container.encode("model_enrollment_blocked", forKey: .state)
            try container.encode(sampleCount, forKey: .sampleCount)
            try container.encode(reason, forKey: .reason)
        case .enrolled(let modelID):
            try container.encode("enrolled", forKey: .state)
            try container.encode(modelID, forKey: .modelID)
        case .revoked:
            try container.encode("revoked", forKey: .state)
        }
    }
}

public struct VoiceSampleManifest: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var personID: UUID
    public var relativePath: String
    public var contentType: String
    public var durationSeconds: Double
    public var byteCount: Int
    public var sha256: String
    public var capturedAt: Date
    public var validatedAt: Date
    public var accepted: Bool
    public var rejectionReasons: [String]

    public init(
        id: UUID = UUID(),
        personID: UUID,
        relativePath: String,
        contentType: String = "audio/mp4",
        durationSeconds: Double,
        byteCount: Int,
        sha256: String,
        capturedAt: Date = Date(),
        validatedAt: Date = Date(),
        accepted: Bool,
        rejectionReasons: [String] = []
    ) {
        self.id = id
        self.personID = personID
        self.relativePath = relativePath
        self.contentType = contentType
        self.durationSeconds = durationSeconds
        self.byteCount = byteCount
        self.sha256 = sha256
        self.capturedAt = capturedAt
        self.validatedAt = validatedAt
        self.accepted = accepted
        self.rejectionReasons = rejectionReasons
    }

    enum CodingKeys: String, CodingKey {
        case id
        case personID = "person_id"
        case relativePath = "relative_path"
        case contentType = "content_type"
        case durationSeconds = "duration_seconds"
        case byteCount = "byte_count"
        case sha256
        case capturedAt = "captured_at"
        case validatedAt = "validated_at"
        case accepted
        case rejectionReasons = "rejection_reasons"
    }
}

public struct VoiceSampleStoragePolicy: Codable, Equatable, Sendable {
    public var storageClass: String
    public var directoryHint: String
    public var rawSamplesLeaveDevice: Bool
    public var retention: String
    public var expiresAt: Date?
    public var excludesFromBackup: Bool
    public var fileProtection: String
    public var transportSecurity: String
    public var remoteRawSampleRetention: String
    public var deleteRawSamplesOnRevoke: Bool

    public init(
        storageClass: String = "app_sandbox_application_support",
        directoryHint: String = "JARVISCompanion/VoiceSamples",
        rawSamplesLeaveDevice: Bool = false,
        retention: String = "operator_revocation_or_model_handoff",
        expiresAt: Date? = nil,
        excludesFromBackup: Bool = true,
        fileProtection: String = "complete when supported by the platform",
        transportSecurity: String = "raw samples are not transported until an explicit recognition backend, API contract, and retention/deletion policy are selected",
        remoteRawSampleRetention: String = "none; no remote enrollment backend selected",
        deleteRawSamplesOnRevoke: Bool = true
    ) {
        self.storageClass = storageClass
        self.directoryHint = directoryHint
        self.rawSamplesLeaveDevice = rawSamplesLeaveDevice
        self.retention = retention
        self.expiresAt = expiresAt
        self.excludesFromBackup = excludesFromBackup
        self.fileProtection = fileProtection
        self.transportSecurity = transportSecurity
        self.remoteRawSampleRetention = remoteRawSampleRetention
        self.deleteRawSamplesOnRevoke = deleteRawSamplesOnRevoke
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        storageClass = try container.decodeIfPresent(String.self, forKey: .storageClass) ?? "app_sandbox_application_support"
        directoryHint = try container.decodeIfPresent(String.self, forKey: .directoryHint) ?? "JARVISCompanion/VoiceSamples"
        rawSamplesLeaveDevice = try container.decodeIfPresent(Bool.self, forKey: .rawSamplesLeaveDevice) ?? false
        retention = try container.decodeIfPresent(String.self, forKey: .retention) ?? "operator_revocation_or_model_handoff"
        expiresAt = try container.decodeIfPresent(Date.self, forKey: .expiresAt)
        excludesFromBackup = try container.decodeIfPresent(Bool.self, forKey: .excludesFromBackup) ?? true
        fileProtection = try container.decodeIfPresent(String.self, forKey: .fileProtection) ?? "complete when supported by the platform"
        transportSecurity = try container.decodeIfPresent(String.self, forKey: .transportSecurity) ?? "raw samples are not transported until an explicit recognition backend, API contract, and retention/deletion policy are selected"
        remoteRawSampleRetention = try container.decodeIfPresent(String.self, forKey: .remoteRawSampleRetention) ?? "none; no remote enrollment backend selected"
        deleteRawSamplesOnRevoke = try container.decodeIfPresent(Bool.self, forKey: .deleteRawSamplesOnRevoke) ?? true
    }

    enum CodingKeys: String, CodingKey {
        case storageClass = "storage_class"
        case directoryHint = "directory_hint"
        case rawSamplesLeaveDevice = "raw_samples_leave_device"
        case retention
        case expiresAt = "expires_at"
        case excludesFromBackup = "excludes_from_backup"
        case fileProtection = "file_protection"
        case transportSecurity = "transport_security"
        case remoteRawSampleRetention = "remote_raw_sample_retention"
        case deleteRawSamplesOnRevoke = "delete_raw_samples_on_revoke"
    }

    public static let localOnlyPendingBackend = VoiceSampleStoragePolicy()
}

public enum VoiceEnrollmentHandoffStatus: String, Codable, Equatable, Sendable {
    case notReady = "not_ready"
    case blocked
    case submitted
    case completed
    case revoked
}

public struct VoiceEnrollmentHandoff: Codable, Equatable, Sendable {
    public var status: VoiceEnrollmentHandoffStatus
    public var sampleCount: Int
    public var sampleDigestsSHA256: [String]
    public var backend: String?
    public var handoffID: String?
    public var modelID: String?
    public var blockedReason: String?
    public var transportPolicy: String
    public var requestedAt: Date
    public var completedAt: Date?

    public init(
        status: VoiceEnrollmentHandoffStatus,
        sampleCount: Int,
        sampleDigestsSHA256: [String],
        backend: String? = nil,
        handoffID: String? = nil,
        modelID: String? = nil,
        blockedReason: String? = nil,
        transportPolicy: String = VoiceSampleStoragePolicy.localOnlyPendingBackend.transportSecurity,
        requestedAt: Date = Date(),
        completedAt: Date? = nil
    ) {
        self.status = status
        self.sampleCount = sampleCount
        self.sampleDigestsSHA256 = sampleDigestsSHA256
        self.backend = backend
        self.handoffID = handoffID
        self.modelID = modelID
        self.blockedReason = blockedReason
        self.transportPolicy = transportPolicy
        self.requestedAt = requestedAt
        self.completedAt = completedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decodeIfPresent(VoiceEnrollmentHandoffStatus.self, forKey: .status) ?? .notReady
        sampleCount = try container.decodeIfPresent(Int.self, forKey: .sampleCount) ?? 0
        sampleDigestsSHA256 = try container.decodeIfPresent([String].self, forKey: .sampleDigestsSHA256) ?? []
        backend = try container.decodeIfPresent(String.self, forKey: .backend)
        handoffID = try container.decodeIfPresent(String.self, forKey: .handoffID)
        modelID = try container.decodeIfPresent(String.self, forKey: .modelID)
        blockedReason = try container.decodeIfPresent(String.self, forKey: .blockedReason)
        transportPolicy = try container.decodeIfPresent(String.self, forKey: .transportPolicy) ?? VoiceSampleStoragePolicy.localOnlyPendingBackend.transportSecurity
        requestedAt = try container.decodeIfPresent(Date.self, forKey: .requestedAt) ?? Date()
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
    }

    public static func notReady(sampleCount: Int, sampleDigestsSHA256: [String]) -> VoiceEnrollmentHandoff {
        VoiceEnrollmentHandoff(
            status: .notReady,
            sampleCount: sampleCount,
            sampleDigestsSHA256: sampleDigestsSHA256,
            blockedReason: sampleCount == 0 ? "No accepted voice samples are available." : nil,
            transportPolicy: VoiceSampleStoragePolicy.localOnlyPendingBackend.transportSecurity
        )
    }

    public static func blockedNoBackend(sampleCount: Int, sampleDigestsSHA256: [String]) -> VoiceEnrollmentHandoff {
        VoiceEnrollmentHandoff(
            status: .blocked,
            sampleCount: sampleCount,
            sampleDigestsSHA256: sampleDigestsSHA256,
            backend: "unselected",
            blockedReason: "No recognition backend/API with retention, model ID, and deletion terms is selected.",
            transportPolicy: VoiceSampleStoragePolicy.localOnlyPendingBackend.transportSecurity
        )
    }

    enum CodingKeys: String, CodingKey {
        case status
        case sampleCount = "sample_count"
        case sampleDigestsSHA256 = "sample_digests_sha256"
        case backend
        case handoffID = "handoff_id"
        case modelID = "model_id"
        case blockedReason = "blocked_reason"
        case transportPolicy = "transport_policy"
        case requestedAt = "requested_at"
        case completedAt = "completed_at"
    }
}

public struct VoiceSampleDeletionRecord: Codable, Equatable, Sendable {
    public var deletedAt: Date
    public var deletedBy: String
    public var deletedSampleCount: Int
    public var reason: String

    public init(deletedAt: Date = Date(), deletedBy: String, deletedSampleCount: Int, reason: String) {
        self.deletedAt = deletedAt
        self.deletedBy = deletedBy
        self.deletedSampleCount = deletedSampleCount
        self.reason = reason
    }

    enum CodingKeys: String, CodingKey {
        case deletedAt = "deleted_at"
        case deletedBy = "deleted_by"
        case deletedSampleCount = "deleted_sample_count"
        case reason
    }
}

public struct VoiceEnrollmentEvidencePayload: Codable, Equatable, Sendable {
    public var status: VoiceEnrollmentStatus
    public var sampleManifests: [VoiceSampleManifest]
    public var storagePolicy: VoiceSampleStoragePolicy?
    public var handoff: VoiceEnrollmentHandoff?
    public var deletion: VoiceSampleDeletionRecord?

    public init(
        status: VoiceEnrollmentStatus,
        sampleManifests: [VoiceSampleManifest],
        storagePolicy: VoiceSampleStoragePolicy?,
        handoff: VoiceEnrollmentHandoff?,
        deletion: VoiceSampleDeletionRecord?
    ) {
        self.status = status
        self.sampleManifests = sampleManifests
        self.storagePolicy = storagePolicy
        self.handoff = handoff
        self.deletion = deletion
    }

    enum CodingKeys: String, CodingKey {
        case status
        case sampleManifests = "sample_manifests"
        case storagePolicy = "storage_policy"
        case handoff
        case deletion
    }
}

public struct ConsentAcknowledgement: Codable, Equatable, Identifiable, Sendable {
    public var key: String
    public var text: String
    public var acceptedAt: Date

    public var id: String { key }

    public init(key: String, text: String, acceptedAt: Date = Date()) {
        self.key = key
        self.text = text
        self.acceptedAt = acceptedAt
    }

    enum CodingKeys: String, CodingKey {
        case key
        case text
        case acceptedAt = "accepted_at"
    }
}

public struct ConsentCapture: Codable, Equatable, Sendable {
    public var grantedBy: String
    public var scope: String
    public var subjectConsentConfirmed: Bool
    public var memorySeparationConfirmed: Bool
    public var evidenceExportConfirmed: Bool
    public var operatorAttestation: String
    public var termsVersion: String

    public init(
        grantedBy: String,
        scope: String,
        subjectConsentConfirmed: Bool,
        memorySeparationConfirmed: Bool,
        evidenceExportConfirmed: Bool,
        operatorAttestation: String,
        termsVersion: String = "jarvis-companion-consent-v2"
    ) {
        self.grantedBy = grantedBy
        self.scope = scope
        self.subjectConsentConfirmed = subjectConsentConfirmed
        self.memorySeparationConfirmed = memorySeparationConfirmed
        self.evidenceExportConfirmed = evidenceExportConfirmed
        self.operatorAttestation = operatorAttestation
        self.termsVersion = termsVersion
    }

    public var allRequiredStatementsConfirmed: Bool {
        subjectConsentConfirmed && memorySeparationConfirmed && evidenceExportConfirmed
    }

    public func acknowledgements(acceptedAt: Date) -> [ConsentAcknowledgement] {
        [
            ConsentAcknowledgement(
                key: "subject_or_guardian_consent",
                text: "Consent recorded for selected observable companion signals and voice enrollment status.",
                acceptedAt: acceptedAt
            ),
            ConsentAcknowledgement(
                key: "separate_memory_scope",
                text: "This person receives a separate memory scope; other people's events are not merged into it.",
                acceptedAt: acceptedAt
            ),
            ConsentAcknowledgement(
                key: "exportable_evidence",
                text: "Consent, device, voice status, and audit records can be exported as evidence.",
                acceptedAt: acceptedAt
            ),
        ]
    }
}

public struct ConsentRecord: Codable, Equatable, Sendable {
    public var grantedBy: String
    public var grantedAt: Date
    public var scope: String
    public var termsVersion: String
    public var subjectConsentConfirmed: Bool
    public var memorySeparationConfirmed: Bool
    public var evidenceExportConfirmed: Bool
    public var operatorAttestation: String
    public var acknowledgements: [ConsentAcknowledgement]
    public var revokedAt: Date?

    public init(
        grantedBy: String,
        grantedAt: Date = Date(),
        scope: String,
        termsVersion: String = "jarvis-companion-consent-v2",
        subjectConsentConfirmed: Bool = true,
        memorySeparationConfirmed: Bool = true,
        evidenceExportConfirmed: Bool = true,
        operatorAttestation: String = "Operator recorded consent for selected observable signals.",
        acknowledgements: [ConsentAcknowledgement]? = nil
    ) {
        self.grantedBy = grantedBy
        self.grantedAt = grantedAt
        self.scope = scope
        self.termsVersion = termsVersion
        self.subjectConsentConfirmed = subjectConsentConfirmed
        self.memorySeparationConfirmed = memorySeparationConfirmed
        self.evidenceExportConfirmed = evidenceExportConfirmed
        self.operatorAttestation = operatorAttestation
        self.acknowledgements = acknowledgements ?? ConsentCapture(
            grantedBy: grantedBy,
            scope: scope,
            subjectConsentConfirmed: subjectConsentConfirmed,
            memorySeparationConfirmed: memorySeparationConfirmed,
            evidenceExportConfirmed: evidenceExportConfirmed,
            operatorAttestation: operatorAttestation,
            termsVersion: termsVersion
        ).acknowledgements(acceptedAt: grantedAt)
        self.revokedAt = nil
    }

    public init(capture: ConsentCapture, grantedAt: Date = Date()) {
        self.init(
            grantedBy: capture.grantedBy,
            grantedAt: grantedAt,
            scope: capture.scope,
            termsVersion: capture.termsVersion,
            subjectConsentConfirmed: capture.subjectConsentConfirmed,
            memorySeparationConfirmed: capture.memorySeparationConfirmed,
            evidenceExportConfirmed: capture.evidenceExportConfirmed,
            operatorAttestation: capture.operatorAttestation,
            acknowledgements: capture.acknowledgements(acceptedAt: grantedAt)
        )
    }

    public var isActive: Bool {
        revokedAt == nil && subjectConsentConfirmed && memorySeparationConfirmed && evidenceExportConfirmed
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        grantedBy = try container.decode(String.self, forKey: .grantedBy)
        grantedAt = try container.decode(Date.self, forKey: .grantedAt)
        scope = try container.decode(String.self, forKey: .scope)
        termsVersion = try container.decodeIfPresent(String.self, forKey: .termsVersion) ?? "jarvis-companion-consent-v1"
        subjectConsentConfirmed = try container.decodeIfPresent(Bool.self, forKey: .subjectConsentConfirmed) ?? true
        memorySeparationConfirmed = try container.decodeIfPresent(Bool.self, forKey: .memorySeparationConfirmed) ?? true
        evidenceExportConfirmed = try container.decodeIfPresent(Bool.self, forKey: .evidenceExportConfirmed) ?? true
        operatorAttestation = try container.decodeIfPresent(String.self, forKey: .operatorAttestation) ?? "Legacy consent record imported."
        acknowledgements = try container.decodeIfPresent([ConsentAcknowledgement].self, forKey: .acknowledgements) ?? ConsentCapture(
            grantedBy: grantedBy,
            scope: scope,
            subjectConsentConfirmed: subjectConsentConfirmed,
            memorySeparationConfirmed: memorySeparationConfirmed,
            evidenceExportConfirmed: evidenceExportConfirmed,
            operatorAttestation: operatorAttestation,
            termsVersion: termsVersion
        ).acknowledgements(acceptedAt: grantedAt)
        revokedAt = try container.decodeIfPresent(Date.self, forKey: .revokedAt)
    }

    enum CodingKeys: String, CodingKey {
        case grantedBy = "granted_by"
        case grantedAt = "granted_at"
        case scope
        case termsVersion = "terms_version"
        case subjectConsentConfirmed = "subject_consent_confirmed"
        case memorySeparationConfirmed = "memory_separation_confirmed"
        case evidenceExportConfirmed = "evidence_export_confirmed"
        case operatorAttestation = "operator_attestation"
        case acknowledgements
        case revokedAt = "revoked_at"
    }
}

public struct MemoryScopeRecord: Codable, Equatable, Sendable {
    public var id: String
    public var ownerPersonID: UUID
    public var boundary: String
    public var storageClass: String
    public var createdAt: Date

    public init(
        id: String,
        ownerPersonID: UUID,
        boundary: String = "per_person_scope_no_cross_person_merge",
        storageClass: String = "app_sandbox_application_support",
        createdAt: Date = Date()
    ) {
        self.id = id
        self.ownerPersonID = ownerPersonID
        self.boundary = boundary
        self.storageClass = storageClass
        self.createdAt = createdAt
    }

    public static func makeID(for personID: UUID) -> String {
        "person." + personID.uuidString.lowercased()
    }

    enum CodingKeys: String, CodingKey {
        case id
        case ownerPersonID = "owner_person_id"
        case boundary
        case storageClass = "storage_class"
        case createdAt = "created_at"
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
    public var permissionScope: PersonPermissionScope
    public var memoryScopeID: String
    public var memoryScope: MemoryScopeRecord
    public var consent: ConsentRecord
    public var voiceEnrollment: VoiceEnrollmentStatus
    public var voiceSampleManifests: [VoiceSampleManifest]
    public var voiceSampleStoragePolicy: VoiceSampleStoragePolicy?
    public var voiceEnrollmentHandoff: VoiceEnrollmentHandoff?
    public var voiceSampleDeletion: VoiceSampleDeletionRecord?
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
        permissionScope: PersonPermissionScope? = nil,
        now: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        self.relationship = relationship
        self.role = role
        self.permissionScope = permissionScope ?? PersonPermissionScope.defaults(for: role)
        self.memoryScopeID = MemoryScopeRecord.makeID(for: id)
        self.memoryScope = MemoryScopeRecord(id: self.memoryScopeID, ownerPersonID: id, createdAt: now)
        self.consent = consent
        self.voiceEnrollment = .notStarted
        self.voiceSampleManifests = []
        self.voiceSampleStoragePolicy = nil
        self.voiceEnrollmentHandoff = nil
        self.voiceSampleDeletion = nil
        self.devices = []
        self.createdAt = now
        self.updatedAt = now
        self.revokedAt = nil
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        relationship = try container.decodeIfPresent(String.self, forKey: .relationship) ?? ""
        role = try container.decode(PersonRole.self, forKey: .role)
        consent = try container.decode(ConsentRecord.self, forKey: .consent)
        voiceEnrollment = try container.decodeIfPresent(VoiceEnrollmentStatus.self, forKey: .voiceEnrollment) ?? .notStarted
        voiceSampleManifests = try container.decodeIfPresent([VoiceSampleManifest].self, forKey: .voiceSampleManifests) ?? []
        voiceSampleStoragePolicy = try container.decodeIfPresent(VoiceSampleStoragePolicy.self, forKey: .voiceSampleStoragePolicy)
        voiceEnrollmentHandoff = try container.decodeIfPresent(VoiceEnrollmentHandoff.self, forKey: .voiceEnrollmentHandoff)
        voiceSampleDeletion = try container.decodeIfPresent(VoiceSampleDeletionRecord.self, forKey: .voiceSampleDeletion)
        devices = try container.decodeIfPresent([PairedDevice].self, forKey: .devices) ?? []
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        revokedAt = try container.decodeIfPresent(Date.self, forKey: .revokedAt)
        permissionScope = try container.decodeIfPresent(PersonPermissionScope.self, forKey: .permissionScope) ?? PersonPermissionScope.defaults(for: role)
        memoryScopeID = try container.decodeIfPresent(String.self, forKey: .memoryScopeID) ?? MemoryScopeRecord.makeID(for: id)
        memoryScope = try container.decodeIfPresent(MemoryScopeRecord.self, forKey: .memoryScope) ?? MemoryScopeRecord(
            id: memoryScopeID,
            ownerPersonID: id,
            createdAt: createdAt
        )
    }

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case relationship
        case role
        case permissionScope = "permission_scope"
        case memoryScopeID = "memory_scope_id"
        case memoryScope = "memory_scope"
        case consent
        case voiceEnrollment = "voice_enrollment"
        case voiceSampleManifests = "voice_sample_manifests"
        case voiceSampleStoragePolicy = "voice_sample_storage_policy"
        case voiceEnrollmentHandoff = "voice_enrollment_handoff"
        case voiceSampleDeletion = "voice_sample_deletion"
        case devices
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case revokedAt = "revoked_at"
    }
}

public struct EvidenceProvenance: Codable, Equatable, Sendable {
    public var actor: String
    public var deviceID: String?
    public var appSurface: String
    public var inputMethod: String
    public var previousRecordDigestSHA256: String?

    public init(
        actor: String,
        deviceID: String? = nil,
        appSurface: String,
        inputMethod: String = "operator_entry",
        previousRecordDigestSHA256: String? = nil
    ) {
        self.actor = actor
        self.deviceID = deviceID
        self.appSurface = appSurface
        self.inputMethod = inputMethod
        self.previousRecordDigestSHA256 = previousRecordDigestSHA256
    }

    enum CodingKeys: String, CodingKey {
        case actor
        case deviceID = "device_id"
        case appSurface = "app_surface"
        case inputMethod = "input_method"
        case previousRecordDigestSHA256 = "previous_record_digest_sha256"
    }
}

public struct EvidenceRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var kind: String
    public var source: String
    public var subjectPersonID: UUID?
    public var memoryScopeID: String?
    public var consentBasis: String
    public var payloadDigestSHA256: String
    public var payloadSummary: String
    public var payload: JSONValue
    public var provenance: EvidenceProvenance
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        kind: String,
        source: String,
        subjectPersonID: UUID?,
        memoryScopeID: String? = nil,
        consentBasis: String,
        payloadDigestSHA256: String,
        payloadSummary: String,
        payload: JSONValue = .null,
        provenance: EvidenceProvenance,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.source = source
        self.subjectPersonID = subjectPersonID
        self.memoryScopeID = memoryScopeID
        self.consentBasis = consentBasis
        self.payloadDigestSHA256 = payloadDigestSHA256
        self.payloadSummary = payloadSummary
        self.payload = payload
        self.provenance = provenance
        self.createdAt = createdAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        kind = try container.decode(String.self, forKey: .kind)
        source = try container.decode(String.self, forKey: .source)
        subjectPersonID = try container.decodeIfPresent(UUID.self, forKey: .subjectPersonID)
        memoryScopeID = try container.decodeIfPresent(String.self, forKey: .memoryScopeID)
        consentBasis = try container.decode(String.self, forKey: .consentBasis)
        payloadDigestSHA256 = try container.decode(String.self, forKey: .payloadDigestSHA256)
        payloadSummary = try container.decode(String.self, forKey: .payloadSummary)
        payload = try container.decodeIfPresent(JSONValue.self, forKey: .payload) ?? .null
        provenance = try container.decodeIfPresent(EvidenceProvenance.self, forKey: .provenance) ?? EvidenceProvenance(
            actor: "unknown",
            appSurface: source,
            inputMethod: "legacy_record"
        )
        createdAt = try container.decode(Date.self, forKey: .createdAt)
    }

    public static func make<T: Encodable>(
        kind: String,
        source: String,
        subjectPersonID: UUID?,
        memoryScopeID: String? = nil,
        consentBasis: String,
        payload: T,
        payloadSummary: String,
        actor: String = "operator",
        deviceID: String? = nil,
        appSurface: String? = nil,
        inputMethod: String = "operator_entry",
        previousRecordDigestSHA256: String? = nil,
        createdAt: Date = Date()
    ) throws -> EvidenceRecord {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(payload)
        let payloadJSON = try JSONDecoder().decode(JSONValue.self, from: data)
        return EvidenceRecord(
            kind: kind,
            source: source,
            subjectPersonID: subjectPersonID,
            memoryScopeID: memoryScopeID,
            consentBasis: consentBasis,
            payloadDigestSHA256: SHA256.hash(data: data).hexString,
            payloadSummary: payloadSummary,
            payload: payloadJSON,
            provenance: EvidenceProvenance(
                actor: actor,
                deviceID: deviceID,
                appSurface: appSurface ?? source,
                inputMethod: inputMethod,
                previousRecordDigestSHA256: previousRecordDigestSHA256
            ),
            createdAt: createdAt
        )
    }

    enum CodingKeys: String, CodingKey {
        case id
        case kind
        case source
        case subjectPersonID = "subject_person_id"
        case memoryScopeID = "memory_scope_id"
        case consentBasis = "consent_basis"
        case payloadDigestSHA256 = "payload_digest_sha256"
        case payloadSummary = "payload_summary"
        case payload
        case provenance
        case createdAt = "created_at"
    }
}

public struct AuditLogEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var action: String
    public var actor: String
    public var source: String
    public var subjectPersonID: UUID?
    public var memoryScopeID: String?
    public var consentBasis: String?
    public var evidenceRecordID: UUID?
    public var payloadDigestSHA256: String?
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        action: String,
        actor: String,
        source: String,
        subjectPersonID: UUID? = nil,
        memoryScopeID: String? = nil,
        consentBasis: String? = nil,
        evidenceRecordID: UUID? = nil,
        payloadDigestSHA256: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.action = action
        self.actor = actor
        self.source = source
        self.subjectPersonID = subjectPersonID
        self.memoryScopeID = memoryScopeID
        self.consentBasis = consentBasis
        self.evidenceRecordID = evidenceRecordID
        self.payloadDigestSHA256 = payloadDigestSHA256
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case action
        case actor
        case source
        case subjectPersonID = "subject_person_id"
        case memoryScopeID = "memory_scope_id"
        case consentBasis = "consent_basis"
        case evidenceRecordID = "evidence_record_id"
        case payloadDigestSHA256 = "payload_digest_sha256"
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
    public var auditLog: [AuditLogEntry]

    public init(persons: [AuthorizedPerson] = [], evidence: [EvidenceRecord] = [], auditLog: [AuditLogEntry] = []) {
        self.persons = persons
        self.evidence = evidence
        self.auditLog = auditLog
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        persons = try container.decodeIfPresent([AuthorizedPerson].self, forKey: .persons) ?? []
        evidence = try container.decodeIfPresent([EvidenceRecord].self, forKey: .evidence) ?? []
        auditLog = try container.decodeIfPresent([AuditLogEntry].self, forKey: .auditLog) ?? []
    }

    enum CodingKeys: String, CodingKey {
        case persons
        case evidence
        case auditLog = "audit_log"
    }
}

public struct OnboardingEvidenceBundle: Codable, Equatable, Sendable {
    public var schemaVersion: String
    public var exportedAt: Date
    public var persons: [AuthorizedPerson]
    public var evidence: [EvidenceRecord]
    public var auditLog: [AuditLogEntry]

    public init(
        schemaVersion: String = "jarvis-companion-onboarding-evidence-v2",
        exportedAt: Date = Date(),
        persons: [AuthorizedPerson],
        evidence: [EvidenceRecord],
        auditLog: [AuditLogEntry]
    ) {
        self.schemaVersion = schemaVersion
        self.exportedAt = exportedAt
        self.persons = persons
        self.evidence = evidence
        self.auditLog = auditLog
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case exportedAt = "exported_at"
        case persons
        case evidence
        case auditLog = "audit_log"
    }
}
