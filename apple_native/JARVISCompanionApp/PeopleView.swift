import JARVISCompanionCore
import SwiftUI

struct PeopleView: View {
    @EnvironmentObject private var accent: CompanionAccentTheme
    @EnvironmentObject private var appState: CompanionAppState
    @StateObject private var model = PeopleViewModel.make()

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [GMRITheme.color.background, accent.color.opacity(0.14), accent.color.opacity(0.07)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        header
                        addPersonCard
                        devicePairingCard
                        trustedPeopleCard
                        evidenceExportCard
                        if !model.message.isEmpty {
                            statusCard(model.message, tint: accent.color)
                        }
                        if !model.errorText.isEmpty {
                            statusCard(model.errorText, tint: GMRITheme.color.warning)
                        }
                    }
                    .padding(20)
                }
            }
            .navigationTitle("People")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .task { await model.refresh() }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("AUTHORIZED PEOPLE")
                .font(.caption.weight(.bold))
                .tracking(1.4)
                .foregroundStyle(accent.color)
            Text("Separate people. Separate scopes.")
                .font(.largeTitle.weight(.semibold))
                .foregroundStyle(GMRITheme.color.neutral)
            Text("Add wife, adult kid, dad, or authorized testers only after consent. JARVIS stores selected observable signals under that person's memory scope.")
                .font(.callout)
                .foregroundStyle(GMRITheme.color.neutral.opacity(0.72))
        }
    }

    private var addPersonCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add a person")
                .font(.headline)
                .foregroundStyle(GMRITheme.color.neutral)

            TextField("Name", text: $model.newPersonName)
                .textContentType(.name)
                .textFieldStyle(.roundedBorder)

            TextField("Relationship", text: $model.newRelationship)
                .textFieldStyle(.roundedBorder)

            Picker("Role", selection: $model.selectedRole) {
                ForEach(PersonRole.allCases, id: \.self) { role in
                    Text(PeopleViewModel.label(for: role)).tag(role)
                }
            }
            .pickerStyle(.menu)
            .tint(accent.color)

            Text(model.permissionSummary(for: model.selectedRole))
                .font(.caption)
                .foregroundStyle(GMRITheme.color.neutral.opacity(0.66))
                .textSelection(.enabled)

            TextField("Consent recorded by", text: $model.consentRecordedBy)
                .textFieldStyle(.roundedBorder)

            VStack(alignment: .leading, spacing: 8) {
                Toggle("Consent confirmed for selected observable signals", isOn: $model.consentConfirmed)
                Toggle("Create a separate memory scope for this person", isOn: $model.memoryScopeConfirmed)
                Toggle("Create exportable consent/device/voice evidence", isOn: $model.evidenceExportConfirmed)
            }
            .font(.callout)
            .foregroundStyle(GMRITheme.color.neutral.opacity(0.86))

            Button {
                Task { await model.addPerson() }
            } label: {
                Label(model.isSaving ? "Saving" : "Save person with consent", systemImage: "person.badge.plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isSaving || !model.canAddPerson)
        }
        .padding(16)
        .background(GMRITheme.color.neutral.opacity(0.09), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(accent.color.opacity(0.20), lineWidth: 1)
        )
    }

    private var devicePairingCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pair a device")
                .font(.headline)
                .foregroundStyle(GMRITheme.color.neutral)
            Text("Pairing binds a phone, watch, CarPlay, HomeKit, or tester device to one memory scope.")
                .font(.caption)
                .foregroundStyle(GMRITheme.color.neutral.opacity(0.66))

            if model.people.isEmpty {
                Text("Add a person before pairing a device.")
                    .font(.callout)
                    .foregroundStyle(GMRITheme.color.neutral.opacity(0.66))
            } else {
                Picker("Person", selection: $model.selectedDevicePersonID) {
                    ForEach(model.people) { person in
                        Text(person.displayName).tag(Optional(person.id))
                    }
                }
                .pickerStyle(.menu)
                .tint(accent.color)

                TextField("Device label", text: $model.deviceLabel)
                    .textFieldStyle(.roundedBorder)

                Picker("Signal source", selection: $model.selectedDeviceSource) {
                    ForEach(PeopleViewModel.deviceSources, id: \.rawValue) { source in
                        Text(PeopleViewModel.label(for: source)).tag(source)
                    }
                }
                .pickerStyle(.menu)
                .tint(accent.color)

                TextField("Platform", text: $model.devicePlatform)
                    .textFieldStyle(.roundedBorder)

                TextField("Pairing ID", text: $model.devicePairingID)
                    .textInputAutocapitalization(.never)
                    .textFieldStyle(.roundedBorder)

                Button {
                    Task { await model.pairDevice() }
                } label: {
                    Label(model.isPairing ? "Pairing" : "Pair device", systemImage: "link.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(model.isPairing || !model.canPairDevice)
            }
        }
        .padding(16)
        .background(GMRITheme.color.neutral.opacity(0.07), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(accent.color.opacity(0.16), lineWidth: 1)
        )
    }

    private var trustedPeopleCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Authorized people")
                    .font(.headline)
                    .foregroundStyle(GMRITheme.color.neutral)
                Spacer()
                Button("Refresh") {
                    Task { await model.refresh() }
                }
                .font(.caption.weight(.semibold))
                .tint(accent.color)
            }

            if model.people.isEmpty {
                Text("No authorized people yet.")
                    .font(.callout)
                    .foregroundStyle(GMRITheme.color.neutral.opacity(0.66))
            } else {
                ForEach(model.people) { person in
                    personRow(person)
                }
            }
        }
        .padding(16)
        .background(GMRITheme.color.neutral.opacity(0.07), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func personRow(_ person: AuthorizedPerson) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(person.displayName)
                        .font(.headline)
                        .foregroundStyle(GMRITheme.color.neutral)
                    Text("\(person.relationship.isEmpty ? "Authorized person" : person.relationship) - \(PeopleViewModel.label(for: person.role))")
                        .font(.caption)
                        .foregroundStyle(GMRITheme.color.neutral.opacity(0.66))
                    Text(PeopleViewModel.consentLabel(for: person.consent))
                        .font(.caption2)
                        .foregroundStyle(person.consent.isActive ? accent.color.opacity(0.90) : GMRITheme.color.warning)
                    Text(PeopleViewModel.voiceLabel(for: person.voiceEnrollment))
                        .font(.caption2)
                        .foregroundStyle(accent.color.opacity(0.90))
                }
                Spacer()
                Button(role: .destructive) {
                    Task { await model.remove(person) }
                } label: {
                    Image(systemName: "person.crop.circle.badge.minus")
                }
                .buttonStyle(.borderless)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Memory: \(person.memoryScopeID)")
                    .textSelection(.enabled)
                Text("Permissions: \(PeopleViewModel.permissionLabels(for: person.permissionScope.permissions).joined(separator: ", "))")
                Text("Sources: \(person.permissionScope.allowedSources.map(PeopleViewModel.labelForSourceRawValue).joined(separator: ", "))")
                Text("Devices: \(person.devices.filter { $0.revokedAt == nil }.count)")
                ForEach(person.devices.filter { $0.revokedAt == nil }) { device in
                    Text("• \(device.label) — \(PeopleViewModel.labelForSourceRawValue(device.source)) — \(device.platform)")
                }
            }
            .font(.caption2)
            .foregroundStyle(GMRITheme.color.neutral.opacity(0.62))
        }
        .padding(12)
        .background(GMRITheme.color.neutral.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var evidenceExportCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Evidence and audit")
                .font(.headline)
                .foregroundStyle(GMRITheme.color.neutral)
            Text("\(model.evidenceCount) evidence records • \(model.auditCount) audit log entries")
                .font(.caption)
                .foregroundStyle(GMRITheme.color.neutral.opacity(0.66))

            Button {
                Task { await model.prepareEvidenceExport() }
            } label: {
                Label(model.isPreparingExport ? "Preparing" : "Prepare evidence JSON", systemImage: "doc.badge.gearshape")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(model.isPreparingExport)

            if let url = model.exportURL {
                ShareLink(item: url) {
                    Label("Share evidence JSON", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }

            Button {
                Task { await model.syncEvidence(appState: appState) }
            } label: {
                Label(model.isSyncingEvidence ? "Syncing" : "Sync evidence to JARVIS Cloud", systemImage: "cloud.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(model.isSyncingEvidence || model.evidenceCount == 0)
        }
        .padding(16)
        .background(GMRITheme.color.neutral.opacity(0.07), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(accent.color.opacity(0.16), lineWidth: 1)
        )
    }

    private func statusCard(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(tint)
            .textSelection(.enabled)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(GMRITheme.color.neutral.opacity(0.07), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

@MainActor
final class PeopleViewModel: ObservableObject {
    @Published private(set) var people: [AuthorizedPerson] = []
    @Published var newPersonName: String = ""
    @Published var newRelationship: String = ""
    @Published var selectedRole: PersonRole = .spouse
    @Published var consentRecordedBy: String = "operator"
    @Published var consentConfirmed: Bool = false
    @Published var memoryScopeConfirmed: Bool = false
    @Published var evidenceExportConfirmed: Bool = false
    @Published var selectedDevicePersonID: UUID?
    @Published var deviceLabel: String = ""
    @Published var selectedDeviceSource: CompanionEvent.Source = .iPhone
    @Published var devicePlatform: String = "iOS"
    @Published var devicePairingID: String = ""
    @Published private(set) var evidenceCount: Int = 0
    @Published private(set) var auditCount: Int = 0
    @Published private(set) var exportURL: URL?
    @Published private(set) var isSaving = false
    @Published private(set) var isPairing = false
    @Published private(set) var isPreparingExport = false
    @Published private(set) var isSyncingEvidence = false
    @Published private(set) var message = ""
    @Published private(set) var errorText = ""

    private let store: OnboardingStore?

    static let deviceSources: [CompanionEvent.Source] = [
        .iPhone,
        .appleWatch,
        .carPlay,
        .homeKit,
        .nativeSpatial,
        .blink,
        .esp32Future,
    ]

    var canAddPerson: Bool {
        !newPersonName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            consentConfirmed &&
            memoryScopeConfirmed &&
            evidenceExportConfirmed
    }

    var canPairDevice: Bool {
        selectedDevicePersonID != nil &&
            !deviceLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !devicePairingID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func make() -> PeopleViewModel {
        do {
            return try PeopleViewModel()
        } catch {
            return PeopleViewModel(errorText: "Could not open people list: \(error)")
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
        let state = await store.snapshot()
        people = state.persons.filter { $0.revokedAt == nil }
        evidenceCount = state.evidence.count
        auditCount = state.auditLog.count
        if selectedDevicePersonID == nil || !people.contains(where: { $0.id == selectedDevicePersonID }) {
            selectedDevicePersonID = people.first?.id
        }
        await writeEvidenceExport(recordExport: false)
    }

    func addPerson() async {
        guard let store else {
            errorText = "People list is unavailable."
            return
        }
        let name = newPersonName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            errorText = "Type a name first."
            return
        }

        isSaving = true
        defer { isSaving = false }
        do {
            let person = try await store.authorizePerson(
                displayName: name,
                relationship: newRelationship,
                role: selectedRole,
                consentCapture: ConsentCapture(
                    grantedBy: consentRecordedBy,
                    scope: consentScopeSummary(for: selectedRole),
                    subjectConsentConfirmed: consentConfirmed,
                    memorySeparationConfirmed: memoryScopeConfirmed,
                    evidenceExportConfirmed: evidenceExportConfirmed,
                    operatorAttestation: "Operator recorded explicit consent for selected observable companion signals."
                )
            )
            newPersonName = ""
            newRelationship = ""
            consentConfirmed = false
            memoryScopeConfirmed = false
            evidenceExportConfirmed = false
            selectedDevicePersonID = person.id
            message = "\(person.displayName) is saved under \(person.memoryScopeID)."
            errorText = ""
            await refresh()
        } catch {
            errorText = "Could not save person: \(error)"
        }
    }

    func pairDevice() async {
        guard let store else {
            errorText = "People list is unavailable."
            return
        }
        guard let personID = selectedDevicePersonID else {
            errorText = "Choose a person first."
            return
        }

        isPairing = true
        defer { isPairing = false }
        do {
            let updated = try await store.pairDevice(
                personID: personID,
                label: deviceLabel,
                source: selectedDeviceSource,
                platform: devicePlatform,
                pairingID: devicePairingID
            )
            deviceLabel = ""
            devicePairingID = ""
            message = "Paired device to \(updated.displayName) under \(updated.memoryScopeID)."
            errorText = ""
            await refresh()
        } catch {
            errorText = "Could not pair device: \(error)"
        }
    }

    func prepareEvidenceExport() async {
        await writeEvidenceExport(recordExport: true)
    }

    func syncEvidence(appState: CompanionAppState) async {
        guard let store else {
            errorText = "People list is unavailable."
            return
        }
        isSyncingEvidence = true
        defer { isSyncingEvidence = false }
        do {
            await appState.ensureRegistered()
            guard appState.isPaired else {
                errorText = "Connect this device to JARVIS Cloud before syncing evidence."
                return
            }
            let client = try appState.makeCloudClient()
            let records = await store.snapshot().evidence
            guard !records.isEmpty else {
                errorText = "No evidence records to sync."
                return
            }
            for record in records {
                _ = try await client.publishOnboardingEvidence(record)
            }
            message = "Synced \(records.count) evidence record\(records.count == 1 ? "" : "s") to JARVIS Cloud."
            errorText = ""
        } catch {
            errorText = "Evidence sync failed: \(error.localizedDescription)"
        }
    }

    func remove(_ person: AuthorizedPerson) async {
        guard let store else {
            errorText = "People list is unavailable."
            return
        }
        do {
            let removed = try await store.revokePerson(personID: person.id, revokedBy: "operator")
            message = "\(removed.displayName) was removed; devices and voice status closed."
            errorText = ""
            await refresh()
        } catch {
            errorText = "Could not remove \(person.displayName): \(error)"
        }
    }

    func permissionSummary(for role: PersonRole) -> String {
        let scope = PersonPermissionScope.defaults(for: role)
        let permissions = Self.permissionLabels(for: scope.permissions).joined(separator: ", ")
        let sources = scope.allowedSources.map(Self.labelForSourceRawValue).joined(separator: ", ")
        return "Permissions: \(permissions). Sources: \(sources)."
    }

    private func writeEvidenceExport(recordExport: Bool) async {
        guard let store else {
            return
        }
        if recordExport {
            isPreparingExport = true
        }
        defer {
            if recordExport {
                isPreparingExport = false
            }
        }
        do {
            if recordExport {
                _ = try await store.recordEvidenceExport(requestedBy: consentRecordedBy)
            }
            let data = try await store.evidenceExportData()
            let url = try OnboardingStore.defaultEvidenceExportURL()
            try writeBlobAtomically0600(data, to: url, context: "companion onboarding evidence export")
            exportURL = url
            let state = await store.snapshot()
            evidenceCount = state.evidence.count
            auditCount = state.auditLog.count
            if recordExport {
                message = "Evidence export prepared at \(url.path)."
                errorText = ""
            }
        } catch {
            if recordExport {
                errorText = "Could not prepare evidence export: \(error)"
            }
        }
    }

    private func consentScopeSummary(for role: PersonRole) -> String {
        let scope = PersonPermissionScope.defaults(for: role)
        return "Role \(role.rawValue); permissions \(scope.permissions.map(\.rawValue).joined(separator: ",")); sources \(scope.allowedSources.joined(separator: ",")); separate memory scope; exportable onboarding evidence."
    }

    static func label(for role: PersonRole) -> String {
        switch role {
        case .operatorPrimary:
            return "Primary operator"
        case .spouse:
            return "Spouse"
        case .childAdult:
            return "Adult child"
        case .parent:
            return "Parent"
        case .caregiver:
            return "Support person"
        case .emsTester:
            return "Field signal tester"
        case .authorizedTester:
            return "Authorized tester"
        case .collaborator:
            return "Collaborator"
        }
    }

    static func label(for source: CompanionEvent.Source) -> String {
        labelForSourceRawValue(source.rawValue)
    }

    static func labelForSourceRawValue(_ rawValue: String) -> String {
        switch rawValue {
        case CompanionEvent.Source.iPhone.rawValue:
            return "iPhone"
        case CompanionEvent.Source.appleWatch.rawValue:
            return "Apple Watch"
        case CompanionEvent.Source.nativeSpatial.rawValue:
            return "Native Spatial"
        case CompanionEvent.Source.carPlay.rawValue:
            return "CarPlay"
        case CompanionEvent.Source.homeKit.rawValue:
            return "HomeKit"
        case CompanionEvent.Source.blink.rawValue:
            return "Blink"
        case CompanionEvent.Source.esp32Future.rawValue:
            return "ESP32 tester"
        default:
            return rawValue
        }
    }

    static func permissionLabels(for permissions: [PersonPermission]) -> [String] {
        permissions.map { permission in
            switch permission {
            case .observeSelectedSignals:
                return "selected signals"
            case .pairApprovedDevices:
                return "device pairing"
            case .voiceEnrollmentStatus:
                return "voice status"
            case .scopedCompanionContext:
                return "scoped context"
            case .evidenceExport:
                return "evidence export"
            case .managePeople:
                return "manage people"
            }
        }
    }

    static func consentLabel(for consent: ConsentRecord) -> String {
        consent.isActive ? "Consent active: \(consent.acknowledgements.count) statements" : "Consent revoked"
    }

    static func voiceLabel(for status: VoiceEnrollmentStatus) -> String {
        switch status {
        case .notStarted:
            return "Voice not started"
        case .consentedPendingSamples:
            return "Voice consent recorded; samples pending"
        case .samplesCapturedPendingModel(let sampleCount):
            return "\(sampleCount) voice sample\(sampleCount == 1 ? "" : "s") saved"
        case .modelEnrollmentBlocked(let sampleCount, let reason):
            return "\(sampleCount) voice samples ready; model enrollment blocked: \(reason)"
        case .enrolled:
            return "Voice enrolled"
        case .revoked:
            return "Voice status closed"
        }
    }
}
