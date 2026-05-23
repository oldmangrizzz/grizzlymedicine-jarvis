import JARVISCompanionCore
import SwiftUI

struct PeopleView: View {
    @EnvironmentObject private var accent: CompanionAccentTheme
    @StateObject private var model = PeopleViewModel.make()

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [.black, accent.color.opacity(0.14), accent.color.opacity(0.07)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        header
                        addPersonCard
                        trustedPeopleCard
                        if !model.message.isEmpty {
                            statusCard(model.message, tint: accent.color)
                        }
                        if !model.errorText.isEmpty {
                            statusCard(model.errorText, tint: .orange)
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
            Text("TRUSTED PEOPLE")
                .font(.caption.weight(.bold))
                .tracking(1.4)
                .foregroundStyle(accent.color)
            Text("Tell JARVIS who matters.")
                .font(.largeTitle.weight(.semibold))
                .foregroundStyle(.white)
            Text("Add someone once. Their voice training stays under My Voice.")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.72))
        }
    }

    private var addPersonCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add a person")
                .font(.headline)
                .foregroundStyle(.white)

            TextField("Name", text: $model.newPersonName)
                .textContentType(.name)
                .textFieldStyle(.roundedBorder)

            TextField("How you know them", text: $model.newRelationship)
                .textFieldStyle(.roundedBorder)

            Picker("Role", selection: $model.selectedRole) {
                ForEach(PersonRole.allCases, id: \.self) { role in
                    Text(PeopleViewModel.label(for: role)).tag(role)
                }
            }
            .pickerStyle(.menu)
            .tint(accent.color)

            Button {
                Task { await model.addPerson() }
            } label: {
                Label(model.isSaving ? "Saving" : "Save person", systemImage: "person.badge.plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isSaving || model.newPersonName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(16)
        .background(.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(accent.color.opacity(0.20), lineWidth: 1)
        )
    }

    private var trustedPeopleCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("People JARVIS knows")
                    .font(.headline)
                    .foregroundStyle(.white)
                Spacer()
                Button("Refresh") {
                    Task { await model.refresh() }
                }
                .font(.caption.weight(.semibold))
                .tint(accent.color)
            }

            if model.people.isEmpty {
                Text("No trusted people yet.")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.66))
            } else {
                ForEach(model.people) { person in
                    personRow(person)
                }
            }
        }
        .padding(16)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func personRow(_ person: AuthorizedPerson) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(person.displayName)
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text("\(person.relationship.isEmpty ? "Trusted person" : person.relationship) - \(PeopleViewModel.label(for: person.role))")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.66))
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
        }
        .padding(12)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func statusCard(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(tint)
            .textSelection(.enabled)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

@MainActor
final class PeopleViewModel: ObservableObject {
    @Published private(set) var people: [AuthorizedPerson] = []
    @Published var newPersonName: String = ""
    @Published var newRelationship: String = ""
    @Published var selectedRole: PersonRole = .caregiver
    @Published private(set) var isSaving = false
    @Published private(set) var message = ""
    @Published private(set) var errorText = ""

    private let store: OnboardingStore?

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
                consentedBy: "operator",
                consentScope: "voice enrollment status, companion context events, emergency context, and evidence export"
            )
            newPersonName = ""
            newRelationship = ""
            message = "\(person.displayName) is saved."
            errorText = ""
            await refresh()
        } catch {
            errorText = "Could not save person: \(error)"
        }
    }

    func remove(_ person: AuthorizedPerson) async {
        guard let store else {
            errorText = "People list is unavailable."
            return
        }
        do {
            let removed = try await store.revokePerson(personID: person.id, revokedBy: "operator")
            message = "\(removed.displayName) was removed."
            errorText = ""
            await refresh()
        } catch {
            errorText = "Could not remove \(person.displayName): \(error)"
        }
    }

    static func label(for role: PersonRole) -> String {
        switch role {
        case .operatorPrimary:
            return "Primary user"
        case .spouse:
            return "Spouse"
        case .childAdult:
            return "Adult child"
        case .parent:
            return "Parent"
        case .caregiver:
            return "Caregiver"
        case .emsTester:
            return "EMS tester"
        case .collaborator:
            return "Collaborator"
        }
    }

    static func voiceLabel(for status: VoiceEnrollmentStatus) -> String {
        switch status {
        case .notStarted, .consentedPendingSamples:
            return "Voice not trained yet"
        case .samplesCapturedPendingModel(let sampleCount):
            return "\(sampleCount) voice sample\(sampleCount == 1 ? "" : "s") saved"
        case .enrolled:
            return "Voice trained"
        case .revoked:
            return "Removed"
        }
    }
}
