import JARVISCompanionCore

#if canImport(SwiftUI)
import SwiftUI

@available(*, deprecated, message: "Developer-only legacy ingress surface. TestFlight app uses automatic registration and PeopleView.")
public struct CompanionOnboardingView: View {
    @StateObject private var model: CompanionOnboardingViewModel

    public init(model: CompanionOnboardingViewModel) {
        _model = StateObject(wrappedValue: model)
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section("JARVIS companion ingress") {
                    TextField("Base URL", text: $model.baseURLText)
                    SecureField("Companion token", text: $model.companionToken)
                    Text("Token stays in the app keychain in the app target; do not paste it into logs or screenshots.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Authorize person") {
                    TextField("Name", text: $model.newPersonName)
                    TextField("Relationship", text: $model.newRelationship)
                    Picker("Role", selection: $model.selectedRole) {
                        ForEach(PersonRole.allCases, id: \.self) { role in
                            Text(role.rawValue).tag(role)
                        }
                    }
                    TextField("Consent recorded by", text: $model.consentRecordedBy)
                    Toggle("Consent confirmed for selected observable signals", isOn: $model.consentConfirmed)
                    Toggle("Use a separate memory scope for this person", isOn: $model.memoryScopeConfirmed)
                    Toggle("Allow exportable consent/device/voice evidence records", isOn: $model.evidenceExportConfirmed)
                    Button("Authorize with separated memory scope") {
                        Task { await model.authorizePerson() }
                    }
                    .disabled(!model.canAuthorizePerson)
                }

                Section("Authorized people") {
                    ForEach(model.people) { person in
                        PersonRow(person: person, model: model)
                    }
                }

                Section("Evidence ledger") {
                    Text("\(model.evidence.count) evidence records")
                    ForEach(model.evidence.prefix(8)) { record in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(record.kind)
                                .font(.headline)
                            Text(record.payloadSummary)
                            Text(record.payloadDigestSHA256)
                                .font(.caption2)
                                .textSelection(.enabled)
                        }
                    }
                }

                if !model.lastMessage.isEmpty {
                    Section("Last action") {
                        Text(model.lastMessage)
                    }
                }
                if !model.lastError.isEmpty {
                    Section("Error") {
                        Text(model.lastError)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("JARVIS Companion")
            .task { await model.refresh() }
        }
    }
}

private struct PersonRow: View {
    let person: AuthorizedPerson
    @ObservedObject var model: CompanionOnboardingViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading) {
                    Text(person.displayName)
                        .font(.headline)
                    Text("\(person.relationship) - \(person.role.rawValue)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if person.revokedAt != nil {
                    Text("revoked")
                        .foregroundStyle(.red)
                }
            }

            Text(person.memoryScopeID)
                .font(.caption2)
                .textSelection(.enabled)

            Text("Voice: \(voiceStatusText(person.voiceEnrollment))")
                .font(.caption)
            Text("Permissions: \(person.permissionScope.permissions.map(\.rawValue).joined(separator: ", "))")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("Devices: \(person.devices.filter { $0.revokedAt == nil }.count)")
                .font(.caption2)
                .foregroundStyle(.secondary)

            HStack {
                Button("Mark 3 voice samples") {
                    Task { await model.updateVoiceSamples(person: person, sampleCount: 3) }
                }
                Button("Revoke", role: .destructive) {
                    Task { await model.revoke(person: person) }
                }
            }
        }
    }

    private func voiceStatusText(_ status: VoiceEnrollmentStatus) -> String {
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
            return "enrolled: \(modelID)"
        case .revoked:
            return "revoked"
        }
    }
}
#endif
