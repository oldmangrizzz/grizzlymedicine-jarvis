import AVFoundation
import CryptoKit
import JARVISCompanionCore
import SwiftUI

struct VoiceRegistrationView: View {
    @EnvironmentObject private var appState: CompanionAppState
    @StateObject private var model = VoiceRegistrationViewModel.make()

    var body: some View {
        NavigationStack {
            Form {
                Section("Person") {
                    Picker("Save voice for", selection: $model.selectedPersonID) {
                        Text("Choose person").tag(Optional<UUID>.none)
                        ForEach(model.people) { person in
                            Text(person.displayName).tag(Optional(person.id))
                        }
                    }
                    Text(model.selectedPersonSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Button("Refresh list") {
                        Task { await model.refresh() }
                    }
                }

                Section("Voice samples") {
                    Text("\(model.sampleCount) accepted sample\(model.sampleCount == 1 ? "" : "s") captured")
                    Text(model.instruction)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text(model.qualitySummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)

                    if model.isRecording {
                        Button("Stop recording") {
                            Task { await model.stopRecording(appState: appState) }
                        }
                        .foregroundStyle(GMRITheme.color.danger)
                    } else {
                        Button("Record sample") {
                            Task { await model.startRecording() }
                        }
                        .disabled(model.selectedPersonID == nil || model.isBusy)
                    }
                }

                Section("Enrollment handoff") {
                    Text(model.enrollmentStatusText)
                        .textSelection(.enabled)
                    Text(model.storagePolicyText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                Section("Deletion and revocation") {
                    Button("Delete raw voice samples", role: .destructive) {
                        Task { await model.deleteRawSamples(appState: appState) }
                    }
                    .disabled(model.selectedPersonID == nil || model.isRecording || model.sampleCount == 0 || model.isBusy)

                    Button("Revoke voice registration and delete samples", role: .destructive) {
                        Task { await model.revokeVoiceRegistration(appState: appState) }
                    }
                    .disabled(model.selectedPersonID == nil || model.isRecording || model.isBusy)
                }

                if !model.message.isEmpty {
                    Section("Status") {
                        Text(model.message)
                            .textSelection(.enabled)
                    }
                }

                if !model.errorText.isEmpty {
                    Section("Needs attention") {
                        Text(model.errorText)
                            .foregroundStyle(GMRITheme.color.danger)
                            .textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("Voice Samples")
            .task { await model.refresh() }
        }
    }
}

@MainActor
final class VoiceRegistrationViewModel: ObservableObject {
    @Published var people: [AuthorizedPerson] = []
    @Published var selectedPersonID: UUID? {
        didSet {
            reloadLocalSampleSnapshot()
        }
    }
    @Published private(set) var sampleCount: Int = 0
    @Published private(set) var isRecording: Bool = false
    @Published private(set) var isBusy: Bool = false
    @Published private(set) var message: String = ""
    @Published private(set) var errorText: String = ""
    @Published private(set) var qualitySummary: String = "No accepted samples yet."
    @Published private(set) var enrollmentStatusText: String = "Voice enrollment has not started."
    @Published private(set) var storagePolicyText: String = LocalVoiceSampleStore.storagePolicySummary
    @Published private(set) var selectedPersonSummary: String = "Choose a person. Consent and memory scope are checked before recording."

    let instruction = "Capture three short, consented samples in a quiet room. Samples are quality-checked locally and remain on this device until a recognition backend/API with retention and deletion terms is selected."

    private let store: OnboardingStore?
    private let sampleStore = LocalVoiceSampleStore()
    private var recorder: AVAudioRecorder?
    private var currentRecordingURL: URL?

    static func make() -> VoiceRegistrationViewModel {
        do {
            return try VoiceRegistrationViewModel()
        } catch {
            return VoiceRegistrationViewModel(errorText: "Could not open onboarding store: \(error.localizedDescription)")
        }
    }

    init() throws {
        self.store = try OnboardingStore(fileURL: OnboardingStore.defaultFileURL())
    }

    private init(errorText: String) {
        self.store = nil
        self.errorText = errorText
    }

    func refresh() async {
        guard let store else {
            return
        }
        do {
            let state = await store.snapshot()
            people = state.persons.filter { $0.revokedAt == nil }
            if let selectedPersonID, !people.contains(where: { $0.id == selectedPersonID }) {
                self.selectedPersonID = people.first?.id
            } else if selectedPersonID == nil {
                selectedPersonID = people.first?.id
            }
            try await sampleStore.reconcileIndex(for: people.map(\.id))
            try await syncLocalSampleMetadataIntoStore(store: store)
            let refreshedState = await store.snapshot()
            people = refreshedState.persons.filter { $0.revokedAt == nil }
            reloadLocalSampleSnapshot()
        } catch {
            errorText = "Could not refresh voice samples: \(error.localizedDescription)"
        }
    }

    func startRecording() async {
        guard let personID = selectedPersonID else {
            errorText = "Add a trusted person before recording voice samples."
            return
        }
        guard let person = people.first(where: { $0.id == personID }) else {
            errorText = "Refresh the person list before recording voice samples."
            return
        }
        guard person.consent.isActive else {
            errorText = "Consent is not active for this person."
            return
        }
        guard person.permissionScope.allows(.voiceEnrollmentStatus) else {
            errorText = "This role does not include voice enrollment status."
            return
        }
        guard !isRecording else {
            return
        }

        do {
            let granted = await requestMicrophoneAccess()
            guard granted else {
                errorText = "Microphone permission is required for voice registration."
                return
            }

            let url = try sampleStore.prepareRecordingURL(for: personID)

            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.allowBluetoothHFP, .defaultToSpeaker])
            try session.setActive(true)

            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ]
            let newRecorder = try AVAudioRecorder(url: url, settings: settings)
            newRecorder.isMeteringEnabled = true
            guard newRecorder.record() else {
                throw VoiceRegistrationError.recordingDidNotStart
            }

            recorder = newRecorder
            currentRecordingURL = url
            isRecording = true
            message = "Recording. Speak a short natural phrase, then stop."
            errorText = ""
        } catch {
            isRecording = false
            recorder = nil
            currentRecordingURL = nil
            errorText = "Recording failed: \(error.localizedDescription)"
        }
    }

    func stopRecording(appState: CompanionAppState? = nil) async {
        guard isRecording else {
            return
        }
        recorder?.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        recorder = nil
        isRecording = false

        guard let url = currentRecordingURL, let personID = selectedPersonID else {
            currentRecordingURL = nil
            return
        }
        currentRecordingURL = nil

        isBusy = true
        defer { isBusy = false }
        do {
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw VoiceRegistrationError.sampleMissing
            }
            guard let store else {
                throw VoiceRegistrationError.storeUnavailable
            }
            let manifest = try await sampleStore.validateAndIndexSample(at: url, personID: personID)
            let manifests = try sampleStore.acceptedManifests(for: personID)
            let enrollment = enrollmentFields(for: manifests)
            let updated = try await store.updateVoiceEnrollment(
                personID: personID,
                status: enrollment.status,
                sampleManifests: manifests,
                storagePolicy: .localOnlyPendingBackend,
                handoff: enrollment.handoff
            )
            await refresh()
            let cloudNote = await syncEnrollmentToCloud(updated, appState: appState)
            message = captureMessage(sampleCount: manifests.count, manifest: manifest, handoff: enrollment.handoff, cloudNote: cloudNote)
            errorText = ""
        } catch VoiceRegistrationError.sampleRejected(let reasons) {
            try? sampleStore.deleteSampleFile(at: url)
            await refresh()
            errorText = "Sample rejected and deleted: \(reasons.joined(separator: "; "))"
        } catch {
            errorText = "Could not save voice sample status: \(error.localizedDescription)"
        }
    }

    func deleteRawSamples(appState: CompanionAppState? = nil) async {
        guard let personID = selectedPersonID else {
            errorText = "Choose a person first."
            return
        }
        guard let store else {
            errorText = "People list is unavailable."
            return
        }

        isBusy = true
        defer { isBusy = false }
        do {
            let deletion = try sampleStore.deleteSamples(
                for: personID,
                deletedBy: "operator",
                reason: "operator_deleted_raw_voice_samples"
            )
            let handoff = VoiceEnrollmentHandoff.notReady(sampleCount: 0, sampleDigestsSHA256: [])
            let updated = try await store.updateVoiceEnrollment(
                personID: personID,
                status: .consentedPendingSamples,
                sampleManifests: [],
                storagePolicy: .localOnlyPendingBackend,
                handoff: handoff,
                deletion: deletion
            )
            await refresh()
            let cloudNote = await syncEnrollmentToCloud(updated, appState: appState)
            message = "Deleted \(deletion.deletedSampleCount) raw voice sample\(deletion.deletedSampleCount == 1 ? "" : "s") from local storage.\(cloudNote)"
            errorText = ""
        } catch {
            errorText = "Could not delete voice samples: \(error.localizedDescription)"
        }
    }

    func revokeVoiceRegistration(appState: CompanionAppState? = nil) async {
        guard let personID = selectedPersonID else {
            errorText = "Choose a person first."
            return
        }
        guard let store else {
            errorText = "People list is unavailable."
            return
        }

        isBusy = true
        defer { isBusy = false }
        do {
            let deletion = try sampleStore.deleteSamples(
                for: personID,
                deletedBy: "operator",
                reason: "voice_enrollment_revoked"
            )
            let updated = try await store.revokeVoiceEnrollment(
                personID: personID,
                revokedBy: "operator",
                deletion: deletion
            )
            await refresh()
            let cloudNote = await syncEnrollmentToCloud(updated, appState: appState)
            message = "Voice registration revoked. Deleted \(deletion.deletedSampleCount) raw sample\(deletion.deletedSampleCount == 1 ? "" : "s").\(cloudNote)"
            errorText = ""
        } catch {
            errorText = "Could not revoke voice registration: \(error.localizedDescription)"
        }
    }

    private func requestMicrophoneAccess() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return true
        case .denied:
            return false
        case .undetermined:
            return await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        @unknown default:
            return false
        }
    }

    private func reloadLocalSampleSnapshot() {
        guard let personID = selectedPersonID else {
            sampleCount = 0
            qualitySummary = "Choose a person to inspect local voice samples."
            enrollmentStatusText = "Voice enrollment has not started."
            selectedPersonSummary = "Choose a person. Consent and memory scope are checked before recording."
            return
        }
        let manifests = (try? sampleStore.acceptedManifests(for: personID)) ?? []
        sampleCount = manifests.count
        if let last = manifests.sorted(by: { $0.capturedAt < $1.capturedAt }).last {
            qualitySummary = String(
                format: "Last accepted: %.1fs, %.1f KB, sha256 %@...",
                last.durationSeconds,
                Double(last.byteCount) / 1024.0,
                String(last.sha256.prefix(12))
            )
        } else {
            qualitySummary = "No accepted samples yet. Record at least three samples of 2-20 seconds each."
        }
        let person = people.first(where: { $0.id == personID })
        enrollmentStatusText = Self.voiceLabel(for: person?.voiceEnrollment ?? .notStarted, handoff: person?.voiceEnrollmentHandoff)
        if let person {
            selectedPersonSummary = "Memory: \(person.memoryScopeID). Consent: \(person.consent.isActive ? "active" : "not active")."
        } else {
            selectedPersonSummary = "Refresh the person list before recording."
        }
    }

    private func syncLocalSampleMetadataIntoStore(store: OnboardingStore) async throws {
        for person in people {
            let manifests = try sampleStore.acceptedManifests(for: person.id)
            guard !manifests.isEmpty else {
                continue
            }
            let enrollment = enrollmentFields(for: manifests)
            let oldDigests = person.voiceSampleManifests.map(\.sha256)
            let newDigests = manifests.map(\.sha256)
            guard oldDigests != newDigests ||
                person.voiceSampleStoragePolicy == nil ||
                person.voiceEnrollmentHandoff?.status != enrollment.handoff.status ||
                person.voiceEnrollment != enrollment.status else {
                continue
            }
            _ = try await store.updateVoiceEnrollment(
                personID: person.id,
                status: enrollment.status,
                sampleManifests: manifests,
                storagePolicy: .localOnlyPendingBackend,
                handoff: enrollment.handoff
            )
        }
    }

    private func enrollmentFields(for manifests: [VoiceSampleManifest]) -> (status: VoiceEnrollmentStatus, handoff: VoiceEnrollmentHandoff) {
        let digests = manifests.map(\.sha256)
        if manifests.count >= LocalVoiceSampleStore.requiredSampleCount {
            let handoff = VoiceEnrollmentHandoff.blockedNoBackend(sampleCount: manifests.count, sampleDigestsSHA256: digests)
            return (
                .modelEnrollmentBlocked(sampleCount: manifests.count, reason: handoff.blockedReason ?? "No recognition backend selected."),
                handoff
            )
        }
        return (
            .samplesCapturedPendingModel(sampleCount: manifests.count),
            VoiceEnrollmentHandoff.notReady(sampleCount: manifests.count, sampleDigestsSHA256: digests)
        )
    }

    private func captureMessage(
        sampleCount: Int,
        manifest: VoiceSampleManifest,
        handoff: VoiceEnrollmentHandoff,
        cloudNote: String
    ) -> String {
        let base = String(
            format: "%d/%d accepted samples captured. Last sample passed quality checks (%.1fs, %.1f KB). ",
            sampleCount,
            LocalVoiceSampleStore.requiredSampleCount,
            manifest.durationSeconds,
            Double(manifest.byteCount) / 1024.0
        )
        if handoff.status == .blocked {
            return base + "Model enrollment is blocked: \(handoff.blockedReason ?? "No backend selected.")\(cloudNote)"
        }
        return base + "Capture \(LocalVoiceSampleStore.requiredSampleCount - sampleCount) more before model handoff.\(cloudNote)"
    }

    private func syncEnrollmentToCloud(_ person: AuthorizedPerson, appState: CompanionAppState?) async -> String {
        guard let appState else {
            return ""
        }
        await appState.ensureRegistered()
        guard appState.isPaired else {
            return " Cloud metadata not synced: device is not paired."
        }
        do {
            let response = try await appState.makeCloudClient().recordVoiceEnrollment(person: person)
            return response.ok ? " Cloud metadata synced." : " Cloud metadata was not accepted."
        } catch {
            return " Cloud metadata sync failed: \(error.localizedDescription)"
        }
    }

    static func voiceLabel(for status: VoiceEnrollmentStatus, handoff: VoiceEnrollmentHandoff? = nil) -> String {
        switch status {
        case .notStarted:
            return "Voice not started"
        case .consentedPendingSamples:
            return "Consent recorded; waiting for local samples"
        case .samplesCapturedPendingModel(let sampleCount):
            return "\(sampleCount) accepted sample\(sampleCount == 1 ? "" : "s") saved; model handoff not ready"
        case .modelEnrollmentBlocked(let sampleCount, let reason):
            let backend = handoff?.backend ?? "unselected"
            return "\(sampleCount) samples ready; enrollment blocked for backend '\(backend)': \(reason)"
        case .enrolled(let modelID):
            return "Voice model enrolled: \(modelID)"
        case .revoked:
            return "Voice registration revoked"
        }
    }
}

@MainActor
struct LocalVoiceSampleStore: Sendable {
    static let requiredSampleCount = 3
    static let minimumDurationSeconds = 2.0
    static let maximumDurationSeconds = 20.0
    static let minimumByteCount = 8_192
    static let maximumByteCount = 6_000_000
    static let storagePolicySummary = "Raw samples stay under Application Support/JARVISCompanion/VoiceSamples, are excluded from backup, use platform file protection when available, and are not uploaded until a recognition backend/API with retention, model ID, and deletion terms is selected."

    private var fileManager: FileManager { .default }

    func prepareRecordingURL(for personID: UUID) throws -> URL {
        let directory = try sampleDirectory(for: personID, create: true)
        let url = directory.appendingPathComponent("\(UUID().uuidString.lowercased()).m4a")
        try applyStoragePolicy(to: directory)
        return url
    }

    func validateAndIndexSample(at url: URL, personID: UUID) async throws -> VoiceSampleManifest {
        let manifest = try await makeManifest(for: url, personID: personID)
        guard manifest.accepted else {
            throw VoiceRegistrationError.sampleRejected(manifest.rejectionReasons)
        }
        try applyStoragePolicy(to: url)
        var index = try loadIndex()
        index.samples.removeAll { $0.id == manifest.id || $0.relativePath == manifest.relativePath }
        index.samples.append(manifest)
        try saveIndex(index)
        return manifest
    }

    func acceptedManifests(for personID: UUID) throws -> [VoiceSampleManifest] {
        let index = try loadIndex()
        return index.samples
            .filter { $0.personID == personID && $0.accepted && fileManager.fileExists(atPath: absoluteURL(for: $0).path) }
            .sorted { $0.capturedAt < $1.capturedAt }
    }

    func reconcileIndex(for personIDs: [UUID]) async throws {
        try ensureRootDirectory()
        var index = try loadIndex()
        index.samples.removeAll { !fileManager.fileExists(atPath: absoluteURL(for: $0).path) }
        let knownRelativePaths = Set(index.samples.map(\.relativePath))
        var relativePaths = knownRelativePaths

        for personID in personIDs {
            let directory = try sampleDirectory(for: personID, create: true)
            try applyStoragePolicy(to: directory)
            let files = (try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .creationDateKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for file in files where file.pathExtension.lowercased() == "m4a" {
                let relativePath = self.relativePath(for: file, personID: personID)
                guard !relativePaths.contains(relativePath) else {
                    continue
                }
                if let manifest = try? await makeManifest(for: file, personID: personID), manifest.accepted {
                    index.samples.append(manifest)
                    relativePaths.insert(relativePath)
                }
            }
        }
        try saveIndex(index)
    }

    func deleteSamples(for personID: UUID, deletedBy: String, reason: String) throws -> VoiceSampleDeletionRecord {
        var index = try loadIndex()
        let indexedCount = index.samples.filter { $0.personID == personID }.count
        let directory = try sampleDirectory(for: personID, create: false)
        let rawFileCount = ((try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []).count
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
        index.samples.removeAll { $0.personID == personID }
        try saveIndex(index)
        return VoiceSampleDeletionRecord(
            deletedBy: deletedBy,
            deletedSampleCount: max(indexedCount, rawFileCount),
            reason: reason
        )
    }

    func deleteSampleFile(at url: URL) throws {
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        var index = try loadIndex()
        index.samples.removeAll { absoluteURL(for: $0) == url }
        try saveIndex(index)
    }

    private func makeManifest(for url: URL, personID: UUID) async throws -> VoiceSampleManifest {
        guard fileManager.fileExists(atPath: url.path) else {
            throw VoiceRegistrationError.sampleMissing
        }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .creationDateKey])
        let byteCount = values.fileSize ?? 0
        var reasons: [String] = []
        if values.isRegularFile != true {
            reasons.append("not a regular file")
        }
        if url.pathExtension.lowercased() != "m4a" {
            reasons.append("sample must be an m4a recording")
        }
        if byteCount < Self.minimumByteCount {
            reasons.append("file is too small (minimum \(Self.minimumByteCount) bytes)")
        }
        if byteCount > Self.maximumByteCount {
            reasons.append("file is too large (maximum \(Self.maximumByteCount) bytes)")
        }

        let data = byteCount <= Self.maximumByteCount ? try Data(contentsOf: url) : Data()
        if data.count >= 12 {
            let brand = String(data: data.subdata(in: 4..<8), encoding: .ascii)
            if brand != "ftyp" {
                reasons.append("missing m4a/mp4 ftyp header")
            }
        } else {
            reasons.append("file header is incomplete")
        }

        let duration = try await AVURLAsset(url: url).load(.duration).seconds
        if !duration.isFinite || duration <= 0 {
            reasons.append("audio duration could not be read")
        } else {
            if duration < Self.minimumDurationSeconds {
                reasons.append(String(format: "duration %.1fs is under %.1fs", duration, Self.minimumDurationSeconds))
            }
            if duration > Self.maximumDurationSeconds {
                reasons.append(String(format: "duration %.1fs exceeds %.1fs", duration, Self.maximumDurationSeconds))
            }
        }

        let digest = data.isEmpty ? "" : SHA256.hash(data: data).hexString
        return VoiceSampleManifest(
            personID: personID,
            relativePath: relativePath(for: url, personID: personID),
            contentType: "audio/mp4",
            durationSeconds: duration.isFinite ? duration : 0,
            byteCount: byteCount,
            sha256: digest,
            capturedAt: values.creationDate ?? Date(),
            validatedAt: Date(),
            accepted: reasons.isEmpty,
            rejectionReasons: reasons
        )
    }

    private func sampleDirectory(for personID: UUID, create: Bool) throws -> URL {
        let directory = try rootDirectory(create: create)
            .appendingPathComponent(personID.uuidString.lowercased(), isDirectory: true)
        if create {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try applyStoragePolicy(to: directory)
        }
        return directory
    }

    private func rootDirectory(create: Bool) throws -> URL {
        let root = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = root
            .appendingPathComponent("JARVISCompanion", isDirectory: true)
            .appendingPathComponent("VoiceSamples", isDirectory: true)
        if create {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try applyStoragePolicy(to: directory)
        }
        return directory
    }

    private func ensureRootDirectory() throws {
        _ = try rootDirectory(create: true)
    }

    private func indexURL() throws -> URL {
        try rootDirectory(create: true).appendingPathComponent("index.json", isDirectory: false)
    }

    private func loadIndex() throws -> VoiceSampleIndex {
        let url = try indexURL()
        guard fileManager.fileExists(atPath: url.path) else {
            return VoiceSampleIndex()
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(VoiceSampleIndex.self, from: Data(contentsOf: url))
    }

    private func saveIndex(_ index: VoiceSampleIndex) throws {
        let url = try indexURL()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(index)
        try writeBlobAtomically0600(data, to: url, context: "companion voice sample index")
        try applyStoragePolicy(to: url)
    }

    private func relativePath(for url: URL, personID: UUID) -> String {
        "\(personID.uuidString.lowercased())/\(url.lastPathComponent)"
    }

    private func absoluteURL(for manifest: VoiceSampleManifest) -> URL {
        let root = (try? rootDirectory(create: false)) ?? URL(fileURLWithPath: "")
        return manifest.relativePath.split(separator: "/").reduce(root) { partial, component in
            partial.appendingPathComponent(String(component))
        }
    }

    private func applyStoragePolicy(to url: URL) throws {
        var mutableURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try mutableURL.setResourceValues(values)
        #if os(iOS)
        try? fileManager.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
        #endif
    }
}

private struct VoiceSampleIndex: Codable {
    var policy: VoiceSampleStoragePolicy
    var samples: [VoiceSampleManifest]

    init(policy: VoiceSampleStoragePolicy = .localOnlyPendingBackend, samples: [VoiceSampleManifest] = []) {
        self.policy = policy
        self.samples = samples
    }

    enum CodingKeys: String, CodingKey {
        case policy
        case samples
    }
}

private enum VoiceRegistrationError: LocalizedError {
    case recordingDidNotStart
    case sampleMissing
    case storeUnavailable
    case sampleRejected([String])

    var errorDescription: String? {
        switch self {
        case .recordingDidNotStart:
            return "Recording did not start."
        case .sampleMissing:
            return "Recorded sample is missing."
        case .storeUnavailable:
            return "Onboarding store is unavailable."
        case .sampleRejected(let reasons):
            return "Sample rejected: \(reasons.joined(separator: "; "))"
        }
    }
}

private extension Digest {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
