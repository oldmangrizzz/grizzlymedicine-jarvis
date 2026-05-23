import Foundation

public enum OnboardingStoreError: Error, Equatable {
    case blankDisplayName
    case unknownPerson(UUID)
    case duplicatePairingID(String)
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
        consentedBy: String,
        consentScope: String,
        now: Date = Date()
    ) async throws -> AuthorizedPerson {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw OnboardingStoreError.blankDisplayName
        }
        let consent = ConsentRecord(grantedBy: consentedBy, grantedAt: now, scope: consentScope)
        var person = AuthorizedPerson(
            displayName: name,
            relationship: relationship.trimmingCharacters(in: .whitespacesAndNewlines),
            role: role,
            consent: consent,
            now: now
        )
        person.voiceEnrollment = .consentedPendingSamples
        state.persons.append(person)
        try state.evidence.append(EvidenceRecord.make(
            kind: "person_authorized",
            source: "apple_companion_onboarding",
            subjectPersonID: person.id,
            consentBasis: consent.termsVersion,
            payload: person,
            payloadSummary: "\(person.displayName) authorized as \(person.role.rawValue)",
            createdAt: now
        ))
        try save()
        return person
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
        if state.persons.flatMap(\.devices).contains(where: { $0.pairingID == pairingID && $0.revokedAt == nil }) {
            throw OnboardingStoreError.duplicatePairingID(pairingID)
        }
        let device = PairedDevice(
            label: label.trimmingCharacters(in: .whitespacesAndNewlines),
            source: source,
            platform: platform.trimmingCharacters(in: .whitespacesAndNewlines),
            pairingID: pairingID.trimmingCharacters(in: .whitespacesAndNewlines),
            pairedAt: now
        )
        state.persons[index].devices.append(device)
        state.persons[index].updatedAt = now
        let person = state.persons[index]
        try state.evidence.append(EvidenceRecord.make(
            kind: "device_paired",
            source: "apple_companion_onboarding",
            subjectPersonID: personID,
            consentBasis: person.consent.termsVersion,
            payload: device,
            payloadSummary: "\(device.label) paired to \(person.displayName)",
            createdAt: now
        ))
        try save()
        return person
    }

    @discardableResult
    public func updateVoiceEnrollment(
        personID: UUID,
        status: VoiceEnrollmentStatus,
        now: Date = Date()
    ) async throws -> AuthorizedPerson {
        guard let index = state.persons.firstIndex(where: { $0.id == personID }) else {
            throw OnboardingStoreError.unknownPerson(personID)
        }
        state.persons[index].voiceEnrollment = status
        state.persons[index].updatedAt = now
        let person = state.persons[index]
        try state.evidence.append(EvidenceRecord.make(
            kind: "voice_enrollment_status_changed",
            source: "apple_companion_onboarding",
            subjectPersonID: personID,
            consentBasis: person.consent.termsVersion,
            payload: person.voiceEnrollment,
            payloadSummary: "Voice enrollment updated for \(person.displayName)",
            createdAt: now
        ))
        try save()
        return person
    }

    @discardableResult
    public func revokePerson(personID: UUID, revokedBy: String, now: Date = Date()) async throws -> AuthorizedPerson {
        guard let index = state.persons.firstIndex(where: { $0.id == personID }) else {
            throw OnboardingStoreError.unknownPerson(personID)
        }
        state.persons[index].revokedAt = now
        state.persons[index].consent.revokedAt = now
        state.persons[index].voiceEnrollment = .revoked
        state.persons[index].updatedAt = now
        for deviceIndex in state.persons[index].devices.indices {
            state.persons[index].devices[deviceIndex].revokedAt = now
        }
        let person = state.persons[index]
        try state.evidence.append(EvidenceRecord.make(
            kind: "person_revoked",
            source: "apple_companion_onboarding",
            subjectPersonID: personID,
            consentBasis: person.consent.termsVersion,
            payload: ["revoked_by": revokedBy],
            payloadSummary: "\(person.displayName) revoked",
            createdAt: now
        ))
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
        return CompanionEvent(
            source: source,
            deviceID: deviceID,
            kind: "check_in",
            checkIn: checkIn,
            notes: notes,
            extra: [
                "person_id": .string(person.id.uuidString),
                "memory_scope_id": .string(person.memoryScopeID),
                "role": .string(person.role.rawValue),
            ]
        )
    }

    private func save() throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try encoder.encode(state)
        try data.write(to: fileURL, options: [.atomic])
    }
}
