import Foundation
import JARVISCompanionCore

enum SelfTestFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message):
            return message
        }
    }
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() {
        throw SelfTestFailure.failed(message)
    }
}

func require<T>(_ value: T?, _ message: String) throws -> T {
    guard let value else {
        throw SelfTestFailure.failed(message)
    }
    return value
}

@main
struct JARVISCompanionSelfTest {
    static func main() async throws {
        try eventEncodingMatchesIngressSchema()
        try requestBuilderUsesCompanionTokenHeader()
        try companionControlModelsMatchBridgeSchema()
        try dreamStatusModelsMatchReadinessSchema()
        try nativeSpatialModelsDoNotRequireDOMSurface()
        try await onboardingSeparatesPeopleAndCreatesEvidence()
        try await voiceEnrollmentStoresPolicyHandoffAndDeletion()
        try await revocationClosesAccess()
        try evidenceDigestIsDeterministic()
        print("JARVIS COMPANION SELF-TEST: PASS")
    }

    static func eventEncodingMatchesIngressSchema() throws {
        let event = AppleSignalFactory.carPlayState(
            deviceID: "iphone-carplay",
            connected: true,
            driving: true,
            vehicleMotion: "moving",
            routeState: "navigating"
        )
        let data = try JSONEncoder().encode(event)
        let object = try require(JSONSerialization.jsonObject(with: data) as? [String: Any], "event JSON object")

        try expect(object["source"] as? String == "carplay", "source should be carplay")
        try expect(object["device_id"] as? String == "iphone-carplay", "device_id should encode")
        try expect(object["carplay_connected"] as? Bool == true, "carplay_connected should encode")
        try expect(object["vehicle_motion"] as? String == "moving", "vehicle_motion should encode")
        try expect(object["route_state"] as? String == "navigating", "route_state should encode")
        try expect(object["interaction_mode"] as? String == "carplay", "interaction_mode should encode")
    }

    static func requestBuilderUsesCompanionTokenHeader() throws {
        let body = Data("{}".utf8)
        let request = try CompanionRequestBuilder.request(
            baseURL: try require(URL(string: "http://127.0.0.1:8788"), "base URL"),
            path: "companion/event",
            method: "POST",
            token: "secret-token",
            body: body
        )

        try expect(request.url?.absoluteString == "http://127.0.0.1:8788/companion/event", "companion URL should match")
        try expect(request.value(forHTTPHeaderField: "X-JARVIS-Companion-Token") == "secret-token", "token header should match")
        try expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json", "content-type should be JSON")
        try expect(request.httpBody == body, "body should be attached")
    }

    static func companionControlModelsMatchBridgeSchema() throws {
        let command = CompanionSkillCommand(
            name: "macos_open_app",
            args: ["app": .string("Calendar")],
            authorizationCode: "test-code"
        )
        let commandData = try JSONEncoder().encode(command)
        let object = try require(JSONSerialization.jsonObject(with: commandData) as? [String: Any], "command JSON object")
        let args = try require(object["args"] as? [String: Any], "args JSON object")

        try expect(object["name"] as? String == "macos_open_app", "skill name should encode")
        try expect(args["app"] as? String == "Calendar", "skill args should encode")
        try expect(object["authorization_code"] as? String == "test-code", "authorization code should use bridge key")

        let body = Data("{}".utf8)
        let request = try CompanionRequestBuilder.request(
            baseURL: try require(URL(string: "http://127.0.0.1:8788"), "base URL"),
            path: "/companion/skill",
            method: "POST",
            token: "secret-token",
            body: body
        )
        try expect(request.url?.absoluteString == "http://127.0.0.1:8788/companion/skill", "skill URL should match")
        try expect(request.value(forHTTPHeaderField: "X-JARVIS-Companion-Token") == "secret-token", "control uses companion token")

        let resultData = Data("""
        {"ok":false,"skill":"macos_open_app","output":null,"refused":true,"reason":"macos_open_app requires authorization","error":"","authorization_required":true}
        """.utf8)
        let result = try JSONDecoder().decode(CompanionSkillResult.self, from: resultData)
        try expect(result.ok == false, "result ok should decode")
        try expect(result.skill == "macos_open_app", "result skill should decode")
        try expect(result.authorizationRequired == true, "authorization flag should decode")
    }

    static func dreamStatusModelsMatchReadinessSchema() throws {
        let data = Data("""
        {
          "micro_ready": true,
          "deep_ready": false,
          "quiet_enough": true,
          "deep_overdue": true,
          "idle_seconds": 540.0,
          "active_signals": [],
          "quiet_signals": ["iphone:charging"],
          "last_micro_dream_at": 1000.0,
          "last_deep_dream_at": null,
          "last_transition_dream_at": null,
          "decision_boundary": "observable companion context only; schedule from idle/readiness signals, not app close events"
        }
        """.utf8)
        let status = try JSONDecoder().decode(DreamStatus.self, from: data)

        try expect(status.microReady, "micro readiness should decode")
        try expect(status.deepReady == false, "deep readiness should decode")
        try expect(status.quietSignals == ["iphone:charging"], "quiet signals should decode")
        try expect(status.decisionBoundary.contains("observable companion context"), "decision boundary should stay observable")

        let encoded = try JSONEncoder().encode(status)
        let object = try require(JSONSerialization.jsonObject(with: encoded) as? [String: Any], "dream status JSON object")
        try expect(object["micro_ready"] as? Bool == true, "micro readiness should encode with bridge key")
        try expect(object["idle_seconds"] as? Double == 540.0, "idle seconds should encode with bridge key")
    }

    static func nativeSpatialModelsDoNotRequireDOMSurface() throws {
        let capability = NativeSpatialCapability.current()
        let status = NativeSpatialStatus(
            runtime: capability.runtime,
            supported: capability.supported,
            running: false,
            tracking: "not_started",
            mapping: "not_available",
            reason: capability.reason
        )
        let event = NativeSpatialEventFactory.statusEvent(status, deviceID: "iphone-native-spatial")
        let data = try JSONEncoder().encode(event)
        let object = try require(JSONSerialization.jsonObject(with: data) as? [String: Any], "native spatial event JSON object")
        let extra = try require(object["extra"] as? [String: Any], "native spatial extra JSON object")

        try expect(object["source"] as? String == "native_spatial", "native spatial source should encode")
        try expect(object["interaction_mode"] as? String == "native_spatial", "native spatial interaction should encode")
        try expect(extra["runtime"] != nil, "native spatial runtime should encode")
        try expect(NativeSpatialConfiguration.fullFunctionality.sceneReconstruction, "full functionality should request scene reconstruction")
        try expect(NativeSpatialConfiguration.fullFunctionality.peopleOcclusion, "full functionality should request people occlusion")
    }

    static func onboardingSeparatesPeopleAndCreatesEvidence() async throws {
        let fileURL = try selfTestFileURL("onboarding.json")
        let store = try OnboardingStore(fileURL: fileURL)
        func capture(for role: PersonRole) -> ConsentCapture {
            let scope = PersonPermissionScope.defaults(for: role)
            return ConsentCapture(
                grantedBy: "operator",
                scope: "role \(role.rawValue); permissions \(scope.permissions.map(\.rawValue).joined(separator: ",")); sources \(scope.allowedSources.joined(separator: ",")); evidence export",
                subjectConsentConfirmed: true,
                memorySeparationConfirmed: true,
                evidenceExportConfirmed: true,
                operatorAttestation: "Self-test explicit consent capture."
            )
        }

        let wife = try await store.authorizePerson(
            displayName: "Pepper",
            relationship: "wife",
            role: .spouse,
            consentCapture: capture(for: .spouse)
        )
        let dad = try await store.authorizePerson(
            displayName: "Dad",
            relationship: "father",
            role: .parent,
            consentCapture: capture(for: .parent)
        )
        let kid = try await store.authorizePerson(
            displayName: "Kid",
            relationship: "adult child",
            role: .childAdult,
            consentCapture: capture(for: .childAdult)
        )
        let tester = try await store.authorizePerson(
            displayName: "Future Tester",
            relationship: "authorized tester",
            role: .authorizedTester,
            consentCapture: capture(for: .authorizedTester)
        )
        let updatedDad = try await store.pairDevice(
            personID: dad.id,
            label: "Dad Apple Watch",
            source: .appleWatch,
            platform: "watchOS",
            pairingID: "watch-dad-001"
        )
        let event = try await store.companionEvent(
            for: dad.id,
            deviceID: "watch-dad-001",
            source: .appleWatch,
            checkIn: "watch_on_wrist",
            notes: "self-test observable signal"
        )
        _ = try await store.recordEvidenceExport(requestedBy: "operator")
        let data = try await store.evidenceExportData()
        let exportDecoder = JSONDecoder()
        exportDecoder.dateDecodingStrategy = .iso8601
        let bundle = try exportDecoder.decode(OnboardingEvidenceBundle.self, from: data)
        let state = await store.snapshot()

        try expect(wife.memoryScopeID != dad.memoryScopeID, "memory scopes must differ")
        try expect(Set([wife.memoryScopeID, dad.memoryScopeID, kid.memoryScopeID, tester.memoryScopeID]).count == 4, "each person should have a unique memory scope")
        try expect(wife.consent.isActive, "explicit consent should be active")
        try expect(wife.permissionScope.allows(.scopedCompanionContext), "family role should include scoped context")
        try expect(!tester.permissionScope.allows(.managePeople), "authorized tester should not manage people")
        try expect(updatedDad.devices.count == 1, "dad should have one device")
        try expect(event.personID == dad.id.uuidString.lowercased(), "companion event should carry person id")
        try expect(event.memoryScopeID == dad.memoryScopeID, "companion event should carry memory scope")
        try expect(state.persons.count == 4, "four people should be stored")
        try expect(state.evidence.map(\.kind).contains("person_authorized"), "authorization evidence should exist")
        try expect(state.evidence.map(\.kind).contains("device_paired"), "device evidence should exist")
        try expect(state.evidence.map(\.kind).contains("evidence_export_prepared"), "export evidence should exist")
        try expect(state.evidence.allSatisfy { $0.payloadDigestSHA256.count == 64 }, "evidence digests should be SHA-256")
        try expect(state.auditLog.count == state.evidence.count, "audit log should track evidence records")
        try expect(bundle.schemaVersion == "jarvis-companion-onboarding-evidence-v2", "export schema should be versioned")
        try expect(bundle.persons.count == 4, "export should include people")
        try expect(FileManager.default.fileExists(atPath: fileURL.path), "onboarding store should persist")
    }

    static func voiceEnrollmentStoresPolicyHandoffAndDeletion() async throws {
        let fileURL = try selfTestFileURL("voice-onboarding.json")
        let store = try OnboardingStore(fileURL: fileURL)
        let person = try await store.authorizePerson(
            displayName: "Voice Tester",
            relationship: "authorized tester",
            role: .emsTester,
            consentedBy: "operator",
            consentScope: "voice enrollment status and sample evidence"
        )
        let digest = String(repeating: "a", count: 64)
        let manifest = VoiceSampleManifest(
            personID: person.id,
            relativePath: "\(person.id.uuidString.lowercased())/sample.m4a",
            durationSeconds: 3.4,
            byteCount: 42_000,
            sha256: digest,
            accepted: true
        )
        let handoff = VoiceEnrollmentHandoff.blockedNoBackend(
            sampleCount: 1,
            sampleDigestsSHA256: [digest]
        )
        let updated = try await store.updateVoiceEnrollment(
            personID: person.id,
            status: .modelEnrollmentBlocked(sampleCount: 1, reason: try require(handoff.blockedReason, "blocked reason")),
            sampleManifests: [manifest],
            storagePolicy: .localOnlyPendingBackend,
            handoff: handoff
        )

        try expect(updated.voiceSampleManifests.count == 1, "voice sample manifest should persist")
        try expect(updated.voiceSampleStoragePolicy?.rawSamplesLeaveDevice == false, "raw samples should remain local-only")
        try expect(updated.voiceEnrollmentHandoff?.status == .blocked, "handoff should expose blocked backend status")

        let deletion = VoiceSampleDeletionRecord(deletedBy: "operator", deletedSampleCount: 1, reason: "self_test_revoke")
        let revoked = try await store.revokeVoiceEnrollment(personID: person.id, revokedBy: "operator", deletion: deletion)
        let state = await store.snapshot()

        try expect(revoked.voiceEnrollment == .revoked, "voice enrollment should revoke independently")
        try expect(revoked.voiceSampleDeletion?.deletedSampleCount == 1, "voice deletion receipt should persist")
        try expect(state.evidence.map(\.kind).contains("voice_enrollment_status_changed"), "voice status evidence should exist")
        try expect(state.evidence.map(\.kind).contains("voice_enrollment_revoked"), "voice revocation evidence should exist")
    }

    static func revocationClosesAccess() async throws {
        let fileURL = try selfTestFileURL("revocation-onboarding.json")
        let store = try OnboardingStore(fileURL: fileURL)
        let person = try await store.authorizePerson(
            displayName: "Tester",
            relationship: "authorized tester",
            role: .emsTester,
            consentedBy: "operator",
            consentScope: "testflight companion testing"
        )
        _ = try await store.pairDevice(
            personID: person.id,
            label: "Tester iPhone",
            source: .iPhone,
            platform: "iOS",
            pairingID: "iphone-tester-001"
        )
        let revoked = try await store.revokePerson(personID: person.id, revokedBy: "operator")

        try expect(revoked.revokedAt != nil, "person should be revoked")
        try expect(revoked.consent.revokedAt != nil, "consent should be revoked")
        try expect(revoked.voiceEnrollment == .revoked, "voice enrollment should be revoked")
        try expect(revoked.devices.allSatisfy { $0.revokedAt != nil }, "devices should be revoked")
    }

    static func selfTestFileURL(_ fileName: String) throws -> URL {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build", isDirectory: true)
            .appendingPathComponent("selftest", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent(fileName, isDirectory: false)
    }

    static func evidenceDigestIsDeterministic() throws {
        let payload = ["b": "two", "a": "one"]
        let first = try EvidenceRecord.make(
            kind: "test",
            source: "unit",
            subjectPersonID: nil,
            consentBasis: "consent-v1",
            payload: payload,
            payloadSummary: "payload"
        )
        let second = try EvidenceRecord.make(
            kind: "test",
            source: "unit",
            subjectPersonID: nil,
            consentBasis: "consent-v1",
            payload: payload,
            payloadSummary: "payload"
        )

        try expect(first.payloadDigestSHA256 == second.payloadDigestSHA256, "digest should be deterministic")
        try expect(first.payloadDigestSHA256.count == 64, "digest should be SHA-256 hex")
    }
}
