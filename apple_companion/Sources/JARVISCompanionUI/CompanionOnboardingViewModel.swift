import Foundation
import JARVISCompanionCore

#if canImport(SwiftUI)
import SwiftUI

@MainActor
public final class CompanionOnboardingViewModel: ObservableObject {
    @Published public private(set) var people: [AuthorizedPerson] = []
    @Published public private(set) var evidence: [EvidenceRecord] = []
    @Published public var baseURLText: String = "http://127.0.0.1:8788"
    @Published public var companionToken: String = ""
    @Published public var newPersonName: String = ""
    @Published public var newRelationship: String = ""
    @Published public var selectedRole: PersonRole = .spouse
    @Published public private(set) var lastMessage: String = ""
    @Published public private(set) var lastError: String = ""

    private let store: OnboardingStore

    public init(fileURL: URL? = nil) throws {
        self.store = try OnboardingStore(fileURL: fileURL ?? OnboardingStore.defaultFileURL())
        Task { await refresh() }
    }

    public func refresh() async {
        let state = await store.snapshot()
        people = state.persons
        evidence = state.evidence
    }

    public func authorizePerson(consentedBy: String = "operator") async {
        lastError = ""
        do {
            let person = try await store.authorizePerson(
                displayName: newPersonName,
                relationship: newRelationship,
                role: selectedRole,
                consentedBy: consentedBy,
                consentScope: "voice enrollment status, paired Apple devices, companion context events, and evidence export"
            )
            newPersonName = ""
            newRelationship = ""
            lastMessage = "Authorized \(person.displayName) with memory scope \(person.memoryScopeID)."
            await refresh()
        } catch {
            lastError = String(describing: error)
        }
    }

    public func pairDevice(person: AuthorizedPerson, source: CompanionEvent.Source, label: String, platform: String, pairingID: String) async {
        lastError = ""
        do {
            let updated = try await store.pairDevice(
                personID: person.id,
                label: label,
                source: source,
                platform: platform,
                pairingID: pairingID
            )
            lastMessage = "Paired \(label) to \(updated.displayName)."
            await refresh()
        } catch {
            lastError = String(describing: error)
        }
    }

    public func updateVoiceSamples(person: AuthorizedPerson, sampleCount: Int) async {
        lastError = ""
        do {
            let updated = try await store.updateVoiceEnrollment(
                personID: person.id,
                status: .samplesCapturedPendingModel(sampleCount: sampleCount)
            )
            lastMessage = "Voice samples recorded for \(updated.displayName); model enrollment still pending."
            await refresh()
        } catch {
            lastError = String(describing: error)
        }
    }

    public func revoke(person: AuthorizedPerson) async {
        lastError = ""
        do {
            let revoked = try await store.revokePerson(personID: person.id, revokedBy: "operator")
            lastMessage = "Revoked \(revoked.displayName)."
            await refresh()
        } catch {
            lastError = String(describing: error)
        }
    }

    public func buildClient() throws -> CompanionClient {
        guard let url = URL(string: baseURLText) else {
            throw CompanionClientError.invalidBaseURL
        }
        return CompanionClient(configuration: CompanionConfiguration(baseURL: url, token: companionToken))
    }
}
#endif
