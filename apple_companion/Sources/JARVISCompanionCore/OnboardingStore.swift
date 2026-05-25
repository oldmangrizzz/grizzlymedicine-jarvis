import Foundation

public enum OnboardingStoreError: Error, Equatable {
    case blankDisplayName
    case consentNotConfirmed([String])
    case unknownPerson(UUID)
    case revokedPerson(UUID)
    case duplicatePairingID(String)
    case blankPairingID
    case permissionDenied(String)
}

public actor OnboardingStore {
    private let fileURL: URL
    private var state: OnboardingState
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public static func defaultFileURL(fileManager: FileManager = .default) throws -> URL {
        let root = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return root
            .appendingPathComponent("JARVISCompanion", isDirectory: true)
            .appendingPathComponent("onboarding.json", isDirectory: false)
    }

    public static func defaultEvidenceExportURL(fileManager: FileManager = .default) throws -> URL {
        let root = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return root
            .appendingPathComponent("JARVISCompanion", isDirectory: true)
            .appendingPathComponent("onboarding-evidence-export.json", isDirectory: false)
    }

    public init(fileURL: URL) throws {
        self.fileURL = fileURL
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
        if FileManager.default.fileExists(atPath: fileURL.path) {
            self.state = try decoder.decode(OnboardingState.self, from: Data(contentsOf: fileURL))
        } else {
            self.state = OnboardingState()
        }
    }

    public func snapshot() -> OnboardingState {
        state
    }

    @discardableResult
    public func authorizePerson(
        displayName: String,
        relationship: String,
        role: PersonRole,
        consentCapture: ConsentCapture,
        now: Date = Date()
    ) async throws -> AuthorizedPerson {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw OnboardingStoreError.blankDisplayName
        }
        let missingConsent = missingConsentStatements(consentCapture)
        guard missingConsent.isEmpty else {
            throw OnboardingStoreError.consentNotConfirmed(missingConsent)
        }

        let consent = ConsentRecord(capture: normalizedConsentCapture(consentCapture), grantedAt: now)
        var person = AuthorizedPerson(
            displayName: name,
            relationship: relationship.trimmingCharacters(in: .whitespacesAndNewlines),
            role: role,
            consent: consent,
            permissionScope: PersonPermissionScope.defaults(for: role),
            now: now
        )
        person.voiceEnrollment = .consentedPendingSamples
        state.persons.append(person)
        try appendEvidence(
            kind: "person_authorized",
            source: "apple_companion_onboarding",
            person: person,
            consentBasis: consent.termsVersion,
            payload: person,
            payloadSummary: "\(person.displayName) authorized as \(person.role.rawValue) with memory scope \(person.memoryScopeID)",
            actor: consent.grantedBy,
            createdAt: now
        )
        try save()
        return person
    }

    @discardableResult
    public func authorizePerson(
        displayName: String,
        relationship: String,
        role: PersonRole,
        consentedBy: String,
        consentScope: String,
        now: Date = Date()
    ) async throws -> AuthorizedPerson {
        try await authorizePerson(
            displayName: displayName,
            relationship: relationship,
            role: role,
            consentCapture: ConsentCapture(
                grantedBy: consentedBy,
                scope: consentScope,
                subjectConsentConfirmed: true,
                memorySeparationConfirmed: true,
                evidenceExportConfirmed: true,
                operatorAttestation: "Operator recorded consent for selected observable signals."
            ),
            now: now
        )
    }

    @discardableResult
    public func pairDevice(
        personID: UUID,
        label: String,
        source: CompanionEvent.Source,
        platform: String,
        pairingID: String,
        now: Date = Date()
    ) async throws -> AuthorizedPerson {
        guard let index = state.persons.firstIndex(where: { $0.id == personID }) else {
            throw OnboardingStoreError.unknownPerson(personID)
        }
        guard state.persons[index].revokedAt == nil else {
            throw OnboardingStoreError.revokedPerson(personID)
        }
        guard state.persons[index].permissionScope.allows(.pairApprovedDevices) else {
            throw OnboardingStoreError.permissionDenied("Role \(state.persons[index].role.rawValue) cannot pair devices.")
        }
        guard state.persons[index].permissionScope.allows(source: source) else {
            throw OnboardingStoreError.permissionDenied("Source \(source.rawValue) is outside this person's role scope.")
        }
        let cleanPairingID = pairingID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanPairingID.isEmpty else {
            throw OnboardingStoreError.blankPairingID
        }
        if state.persons.flatMap(\.devices).contains(where: { $0.pairingID == cleanPairingID && $0.revokedAt == nil }) {
            throw OnboardingStoreError.duplicatePairingID(cleanPairingID)
        }
        let cleanLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let device = PairedDevice(
            label: cleanLabel.isEmpty ? "\(source.rawValue) device" : cleanLabel,
            source: source,
            platform: platform.trimmingCharacters(in: .whitespacesAndNewlines),
            pairingID: cleanPairingID,
            pairedAt: now
        )
        state.persons[index].devices.append(device)
        state.persons[index].updatedAt = now
        let person = state.persons[index]
        try appendEvidence(
            kind: "device_paired",
            source: "apple_companion_onboarding",
            person: person,
            consentBasis: person.consent.termsVersion,
            payload: device,
            payloadSummary: "\(device.label) paired to \(person.displayName) under \(person.memoryScopeID)",
            actor: person.consent.grantedBy,
            createdAt: now
        )
        try save()
        return person
    }

    @discardableResult
    public func updateVoiceEnrollment(
        personID: UUID,
        status: VoiceEnrollmentStatus,
        sampleManifests: [VoiceSampleManifest]? = nil,
        storagePolicy: VoiceSampleStoragePolicy? = nil,
        handoff: VoiceEnrollmentHandoff? = nil,
        deletion: VoiceSampleDeletionRecord? = nil,
        now: Date = Date()
    ) async throws -> AuthorizedPerson {
        guard let index = state.persons.firstIndex(where: { $0.id == personID }) else {
            throw OnboardingStoreError.unknownPerson(personID)
        }
        guard state.persons[index].revokedAt == nil else {
            throw OnboardingStoreError.revokedPerson(personID)
        }
        guard state.persons[index].permissionScope.allows(.voiceEnrollmentStatus) else {
            throw OnboardingStoreError.permissionDenied("Role \(state.persons[index].role.rawValue) cannot store voice enrollment status.")
        }
        state.persons[index].voiceEnrollment = status
        if let sampleManifests {
            state.persons[index].voiceSampleManifests = sampleManifests
        }
        if let storagePolicy {
            state.persons[index].voiceSampleStoragePolicy = storagePolicy
        }
        if let handoff {
            state.persons[index].voiceEnrollmentHandoff = handoff
        }
        if let deletion {
            state.persons[index].voiceSampleDeletion = deletion
        }
        state.persons[index].updatedAt = now
        let person = state.persons[index]
        try appendEvidence(
            kind: "voice_enrollment_status_changed",
            source: "apple_companion_onboarding",
            person: person,
            consentBasis: person.consent.termsVersion,
            payload: VoiceEnrollmentEvidencePayload(
                status: person.voiceEnrollment,
                sampleManifests: person.voiceSampleManifests,
                storagePolicy: person.voiceSampleStoragePolicy,
                handoff: person.voiceEnrollmentHandoff,
                deletion: person.voiceSampleDeletion
            ),
            payloadSummary: "Voice enrollment updated for \(person.displayName): \(voiceEnrollmentSummary(person.voiceEnrollment))",
            actor: person.consent.grantedBy,
            createdAt: now
        )
        try save()
        return person
    }

    @discardableResult
    public func revokeVoiceEnrollment(
        personID: UUID,
        revokedBy: String,
        deletion: VoiceSampleDeletionRecord? = nil,
        now: Date = Date()
    ) async throws -> AuthorizedPerson {
        guard let index = state.persons.firstIndex(where: { $0.id == personID }) else {
            throw OnboardingStoreError.unknownPerson(personID)
        }
        guard state.persons[index].revokedAt == nil else {
            throw OnboardingStoreError.revokedPerson(personID)
        }
        guard state.persons[index].permissionScope.allows(.voiceEnrollmentStatus) else {
            throw OnboardingStoreError.permissionDenied("Role \(state.persons[index].role.rawValue) cannot revoke voice enrollment.")
        }
        var handoff = state.persons[index].voiceEnrollmentHandoff
        handoff?.status = .revoked
        handoff?.completedAt = now
        state.persons[index].voiceEnrollment = .revoked
        state.persons[index].voiceEnrollmentHandoff = handoff
        state.persons[index].voiceSampleDeletion = deletion ?? VoiceSampleDeletionRecord(
            deletedAt: now,
            deletedBy: revokedBy,
            deletedSampleCount: 0,
            reason: "voice_enrollment_revoked"
        )
        state.persons[index].updatedAt = now
        let person = state.persons[index]
        try appendEvidence(
            kind: "voice_enrollment_revoked",
            source: "apple_companion_onboarding",
            person: person,
            consentBasis: person.consent.termsVersion,
            payload: VoiceEnrollmentEvidencePayload(
                status: person.voiceEnrollment,
                sampleManifests: person.voiceSampleManifests,
                storagePolicy: person.voiceSampleStoragePolicy,
                handoff: person.voiceEnrollmentHandoff,
                deletion: person.voiceSampleDeletion
            ),
            payloadSummary: "Voice enrollment revoked for \(person.displayName)",
            actor: revokedBy,
            createdAt: now
        )
        try save()
        return person
    }

    @discardableResult
    public func revokePerson(
        personID: UUID,
        revokedBy: String,
        voiceSampleDeletion: VoiceSampleDeletionRecord? = nil,
        now: Date = Date()
    ) async throws -> AuthorizedPerson {
        guard let index = state.persons.firstIndex(where: { $0.id == personID }) else {
            throw OnboardingStoreError.unknownPerson(personID)
        }
        state.persons[index].revokedAt = now
        state.persons[index].consent.revokedAt = now
        state.persons[index].voiceEnrollment = .revoked
        var handoff = state.persons[index].voiceEnrollmentHandoff
        handoff?.status = .revoked
        handoff?.completedAt = now
        state.persons[index].voiceEnrollmentHandoff = handoff
        state.persons[index].voiceSampleDeletion = voiceSampleDeletion ?? state.persons[index].voiceSampleDeletion
        state.persons[index].updatedAt = now
        for deviceIndex in state.persons[index].devices.indices {
            state.persons[index].devices[deviceIndex].revokedAt = now
        }
        let person = state.persons[index]
        try appendEvidence(
            kind: "person_revoked",
            source: "apple_companion_onboarding",
            person: person,
            consentBasis: person.consent.termsVersion,
            payload: [
                "revoked_by": revokedBy,
                "raw_voice_samples_deleted": voiceSampleDeletion == nil ? "unknown" : "true",
            ],
            payloadSummary: "\(person.displayName) revoked; devices and voice status closed",
            actor: revokedBy,
            createdAt: now
        )
        try save()
        return person
    }

    public func companionEvent(
        for personID: UUID,
        deviceID: String,
        source: CompanionEvent.Source,
        checkIn: String,
        notes: String? = nil
    ) throws -> CompanionEvent {
        guard let person = state.persons.first(where: { $0.id == personID && $0.revokedAt == nil }) else {
            throw OnboardingStoreError.unknownPerson(personID)
        }
        guard person.permissionScope.allows(.observeSelectedSignals) else {
            throw OnboardingStoreError.permissionDenied("Role \(person.role.rawValue) cannot publish companion events.")
        }
        guard person.permissionScope.allows(source: source) else {
            throw OnboardingStoreError.permissionDenied("Source \(source.rawValue) is outside this person's role scope.")
        }
        return CompanionEvent(
            source: source,
            deviceID: deviceID,
            kind: "check_in",
            personID: person.id.uuidString.lowercased(),
            memoryScopeID: person.memoryScopeID,
            checkIn: checkIn,
            notes: notes,
            extra: [
                "person_id": .string(person.id.uuidString.lowercased()),
                "memory_scope_id": .string(person.memoryScopeID),
                "role": .string(person.role.rawValue),
            ]
        )
    }

    @discardableResult
    public func recordEvidenceExport(requestedBy: String, now: Date = Date()) async throws -> EvidenceRecord {
        let payload: [String: String] = [
            "schema_version": "jarvis-companion-onboarding-evidence-v2",
            "person_count": String(state.persons.count),
            "evidence_count": String(state.evidence.count),
            "audit_count": String(state.auditLog.count),
        ]
        let record = try appendEvidence(
            kind: "evidence_export_prepared",
            source: "apple_companion_onboarding",
            person: nil,
            consentBasis: "operator_export",
            payload: payload,
            payloadSummary: "Evidence export prepared with \(state.persons.count) people, \(state.evidence.count) evidence records",
            actor: requestedBy,
            createdAt: now
        )
        try save()
        return record
    }

    public func evidenceBundle(now: Date = Date()) -> OnboardingEvidenceBundle {
        OnboardingEvidenceBundle(exportedAt: now, persons: state.persons, evidence: state.evidence, auditLog: state.auditLog)
    }

    public func evidenceExportData(now: Date = Date()) throws -> Data {
        try encoder.encode(evidenceBundle(now: now))
    }

    @discardableResult
    private func appendEvidence<T: Encodable>(
        kind: String,
        source: String,
        person: AuthorizedPerson?,
        consentBasis: String,
        payload: T,
        payloadSummary: String,
        actor: String,
        deviceID: String? = nil,
        inputMethod: String = "operator_entry",
        createdAt: Date
    ) throws -> EvidenceRecord {
        let previousDigest = state.evidence.last?.payloadDigestSHA256
        let record = try EvidenceRecord.make(
            kind: kind,
            source: source,
            subjectPersonID: person?.id,
            memoryScopeID: person?.memoryScopeID,
            consentBasis: consentBasis,
            payload: payload,
            payloadSummary: payloadSummary,
            actor: actor,
            deviceID: deviceID,
            appSurface: source,
            inputMethod: inputMethod,
            previousRecordDigestSHA256: previousDigest,
            createdAt: createdAt
        )
        state.evidence.append(record)
        state.auditLog.append(AuditLogEntry(
            action: kind,
            actor: actor,
            source: source,
            subjectPersonID: person?.id,
            memoryScopeID: person?.memoryScopeID,
            consentBasis: consentBasis,
            evidenceRecordID: record.id,
            payloadDigestSHA256: record.payloadDigestSHA256,
            createdAt: createdAt
        ))
        return record
    }

    private func missingConsentStatements(_ capture: ConsentCapture) -> [String] {
        var missing: [String] = []
        if !capture.subjectConsentConfirmed {
            missing.append("subject_or_guardian_consent")
        }
        if !capture.memorySeparationConfirmed {
            missing.append("separate_memory_scope")
        }
        if !capture.evidenceExportConfirmed {
            missing.append("exportable_evidence")
        }
        return missing
    }

    private func normalizedConsentCapture(_ capture: ConsentCapture) -> ConsentCapture {
        ConsentCapture(
            grantedBy: capture.grantedBy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "operator" : capture.grantedBy.trimmingCharacters(in: .whitespacesAndNewlines),
            scope: capture.scope.trimmingCharacters(in: .whitespacesAndNewlines),
            subjectConsentConfirmed: capture.subjectConsentConfirmed,
            memorySeparationConfirmed: capture.memorySeparationConfirmed,
            evidenceExportConfirmed: capture.evidenceExportConfirmed,
            operatorAttestation: capture.operatorAttestation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Operator recorded consent for selected observable signals." : capture.operatorAttestation.trimmingCharacters(in: .whitespacesAndNewlines),
            termsVersion: capture.termsVersion
        )
    }

    private func voiceEnrollmentSummary(_ status: VoiceEnrollmentStatus) -> String {
        switch status {
        case .notStarted:
            return "not started"
        case .consentedPendingSamples:
            return "consented, pending samples"
        case .samplesCapturedPendingModel(let sampleCount):
            return "\(sampleCount) samples captured, model pending"
        case .modelEnrollmentBlocked(let sampleCount, let reason):
            return "\(sampleCount) samples captured, model blocked: \(reason)"
        case .enrolled(let modelID):
            return "enrolled model \(modelID)"
        case .revoked:
            return "revoked"
        }
    }

    private func save() throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try encoder.encode(state)
        try data.write(to: fileURL, options: [.atomic])
    }
}
