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
        try nativeSpatialModelsDoNotRequireDOMSurface()
        try await onboardingSeparatesPeopleAndCreatesEvidence()
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
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("onboarding.json")
        let store = try OnboardingStore(fileURL: fileURL)

        let wife = try await store.authorizePerson(
            displayName: "Pepper",
            relationship: "wife",
            role: .spouse,
            consentedBy: "operator",
            consentScope: "voice, watch, phone, CarPlay companion evidence"
        )
        let dad = try await store.authorizePerson(
            displayName: "Dad",
            relationship: "father",
            role: .parent,
            consentedBy: "operator",
            consentScope: "watch and phone observational companion evidence"
        )
        let updatedDad = try await store.pairDevice(
            personID: dad.id,
            label: "Dad Apple Watch",
            source: .appleWatch,
            platform: "watchOS",
            pairingID: "watch-dad-001"
        )
        let state = await store.snapshot()

        try expect(wife.memoryScopeID != dad.memoryScopeID, "memory scopes must differ")
        try expect(updatedDad.devices.count == 1, "dad should have one device")
        try expect(state.persons.count == 2, "two people should be stored")
        try expect(state.evidence.map(\.kind).contains("person_authorized"), "authorization evidence should exist")
        try expect(state.evidence.map(\.kind).contains("device_paired"), "device evidence should exist")
        try expect(FileManager.default.fileExists(atPath: fileURL.path), "onboarding store should persist")
    }

    static func revocationClosesAccess() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("onboarding.json")
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
