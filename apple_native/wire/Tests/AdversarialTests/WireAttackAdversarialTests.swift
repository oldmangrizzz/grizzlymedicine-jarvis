import XCTest
@testable import JARVISWire

final class WireAttackAdversarialTests: XCTestCase {
    private let baseTime: Int64 = 1_700_000_000_000
    private let adversary = MockWireAdversary()

    func test01PairingReplayRejected() throws {
        let fixture = try pairingFixture()
        var admission = PairingAdmissionController(maximumPairingRequestsPerSource: 4, maximumSessionInitRequestsPerSource: 4)
        let record = try admission.completeEnrollment(offer: fixture.offer, response: fixture.response, operatorAttestation: fixture.attestation, anchor: fixture.anchor, nowUnixMs: baseTime + 4_000)
        XCTAssertTrue(try PairingCeremony.verifyEnrollment(record))
        XCTAssertThrowsError(try adversary.replayPairing(offer: fixture.offer, response: fixture.response, attestation: fixture.attestation, against: &admission, anchor: fixture.anchor, nowUnixMs: baseTime + 5_000)) { error in
            XCTAssertEqual(error as? WireError, .replayDetected)
        }
    }

    func test02PairingMITMKeySwapRejected() throws {
        let fixture = try pairingFixture()
        let attackerKey = try SigningKeyPair.generate()
        XCTAssertThrowsError(try adversary.swapPairingKeys(offer: fixture.offer, response: fixture.response, attackerKey: attackerKey, anchor: fixture.anchor, nowUnixMs: baseTime + 4_000)) { error in
            XCTAssertEqual(error as? WireError, .invalidSignature)
        }
    }

    func test03SessionKeyForgeCannotOpenAuthenticatedTraffic() throws {
        let established = try establishedSessions()
        var hostSession = established.hostSession
        let forgedKeys = try adversary.forgeSessionKeys(observedHostHello: established.hostHello.hello)
        var forgedCompanion = WireSession(role: .companion, keys: forgedKeys)
        let payload = inputPayload("legitimate input")
        let forgedFrame = try forgedCompanion.seal(payload)
        XCTAssertThrowsError(try hostSession.open(forgedFrame)) { error in
            XCTAssertEqual(error as? WireError, .invalidCiphertext)
        }
    }

    func test04MessageForgeWithValidLookingHeaderRejected() throws {
        let established = try establishedSessions()
        var hostSession = established.hostSession
        let forged = try adversary.forgeMessage(payload: inputPayload("forged command"), visibleType: .input, sequence: 1, nowUnixMs: baseTime + 2_000)
        XCTAssertThrowsError(try hostSession.open(forged, nowUnixMs: baseTime + 2_000)) { error in
            XCTAssertEqual(error as? WireError, .invalidCiphertext)
        }
    }

    func test05ReplayInSessionRejected() throws {
        var established = try establishedSessions()
        let frame = try established.companionSession.seal(inputPayload("first delivery"))
        _ = try established.hostSession.open(frame)
        XCTAssertThrowsError(try adversary.replayInSession(frame, against: &established.hostSession, nowUnixMs: ClockUnix.milliseconds())) { error in
            XCTAssertEqual(error as? WireError, .replayDetected)
        }
    }

    func test06ReplayAcrossSessionsRejectedByFreshKeys() throws {
        var first = try establishedSessions()
        let oldFrame = try first.companionSession.seal(inputPayload("old session payload"))
        _ = try first.hostSession.open(oldFrame)
        var secondHostSession = try establishedSessions(nowUnixMs: baseTime + 10_000).hostSession
        XCTAssertThrowsError(try secondHostSession.open(oldFrame)) { error in
            XCTAssertEqual(error as? WireError, .invalidCiphertext)
        }
    }

    func test07ForwardSecrecyDecryptPastWithCompromisedCurrentKeyFails() throws {
        var past = try establishedSessions(nowUnixMs: baseTime)
        let pastPayload = inputPayload("past session secret")
        let pastFrameData = try past.companionSession.seal(pastPayload)
        let pastFrame = try WireFrameCodec.decodeFrame(pastFrameData)
        let current = try establishedSessions(nowUnixMs: baseTime + 20_000)
        let compromisedCurrentReceiveKey = current.hostSession.keys.receiveKey
        XCTAssertNotEqual(past.hostSession.keys.receiveKey, compromisedCurrentReceiveKey)
        XCTAssertThrowsError(try Sodium.open(ciphertext: pastFrame.ciphertext, aad: pastFrame.header.aad, nonce: pastFrame.header.nonce, key: compromisedCurrentReceiveKey)) { error in
            XCTAssertEqual(error as? WireError, .invalidCiphertext)
        }
    }

    func test08DowngradeRejectedForFrameAndPairingOffer() throws {
        var established = try establishedSessions()
        let frame = try established.companionSession.seal(inputPayload("version downgrade attempt"))
        let downgradedFrame = adversary.downgradeVersion(frame: frame, to: 0)
        XCTAssertThrowsError(try established.hostSession.open(downgradedFrame, nowUnixMs: baseTime + 2_000)) { error in
            XCTAssertEqual(error as? WireError, .invalidFrame)
        }

        let anchor = SodiumSoulAnchor(keyPair: try SigningKeyPair.generate())
        var downgradedOffer = try PairingOffer(protocolVersion: 0, hostID: "mac", anchorPublicKey: anchor.anchorPublicKey, createdAtUnixMs: baseTime)
        downgradedOffer.signature = try anchor.sign(downgradedOffer.signedPayload())
        XCTAssertThrowsError(try PairingCeremony.verifyOffer(downgradedOffer, nowUnixMs: baseTime + 1_000)) { error in
            XCTAssertEqual(error as? WireError, .invalidFrame)
        }
    }

    func test09OutOfOrderDeliveryRejected() throws {
        var established = try establishedSessions()
        _ = try adversary.deliverOutOfOrder(payload: inputPayload("sequence one"), sequence: 1, sender: established.companionSession, receiver: &established.hostSession, nowUnixMs: baseTime + 2_000)
        _ = try adversary.deliverOutOfOrder(payload: inputPayload("sequence three"), sequence: 3, sender: established.companionSession, receiver: &established.hostSession, nowUnixMs: baseTime + 3_000)
        XCTAssertThrowsError(try adversary.deliverOutOfOrder(payload: inputPayload("stale sequence two"), sequence: 2, sender: established.companionSession, receiver: &established.hostSession, nowUnixMs: baseTime + 4_000)) { error in
            XCTAssertEqual(error as? WireError, .sequenceRollback)
        }
    }

    func test10ResourceExhaustionBoundedWithoutCrash() {
        var admission = PairingAdmissionController(maximumPairingRequestsPerSource: 8, maximumSessionInitRequestsPerSource: 8)
        let pairingRejected = adversary.spamPairingRequests(count: 256, sourceID: "attacker-netblock", against: &admission)
        let sessionRejected = adversary.spamSessionInit(count: 256, sourceID: "attacker-netblock", against: &admission)
        XCTAssertEqual(pairingRejected, 248)
        XCTAssertEqual(sessionRejected, 248)
    }

    func test11DistressForgeRejectedAndRealDistressRemainsAccepted() throws {
        let fixture = try pairingFixture(companionID: "watch", companionKind: "watchOS")
        let record = try PairingCeremony.completeEnrollment(offer: fixture.offer, response: fixture.response, operatorAttestation: fixture.attestation, anchor: fixture.anchor, nowUnixMs: baseTime + 4_000)
        let attackerKey = try SigningKeyPair.generate()
        let distress = DistressMessage(severity: 5, reason: "fall detected")
        let forged = try adversary.forgeDistress(message: distress, companionID: "watch", attackerKey: attackerKey, nowUnixMs: baseTime + 5_000)
        var replay = ReplayProtector()
        XCTAssertThrowsError(try DistressChannel.verify(forged, enrolledRecord: record, replayProtector: &replay, nowUnixMs: baseTime + 5_100)) { error in
            XCTAssertEqual(error as? WireError, .invalidSignature)
        }
        let real = try DistressChannel.sign(distress, companionID: "watch", companionSigningKey: fixture.companionKey, nowUnixMs: baseTime + 5_200)
        XCTAssertTrue(try DistressChannel.verify(real, enrolledRecord: record, replayProtector: &replay, nowUnixMs: baseTime + 5_300))
    }

    func test12CompanionEnrollmentRequiresOperatorAttestation() throws {
        let fixture = try pairingFixture()
        let attackerAnchor = SodiumSoulAnchor(keyPair: try SigningKeyPair.generate())
        XCTAssertThrowsError(try adversary.forgeOperatorAttestation(offer: fixture.offer, response: fixture.response, attackerAnchor: attackerAnchor, approvedAtUnixMs: baseTime + 3_000)) { error in
            XCTAssertEqual(error as? WireError, .invalidSignature)
        }
        var tamperedAttestation = fixture.attestation
        tamperedAttestation.companionSigningPublicKey = try SigningKeyPair.generate().publicKey
        XCTAssertThrowsError(try PairingCeremony.completeEnrollment(offer: fixture.offer, response: fixture.response, operatorAttestation: tamperedAttestation, anchor: fixture.anchor, nowUnixMs: baseTime + 4_000)) { error in
            XCTAssertEqual(error as? WireError, .operatorAttestationRequired)
        }
        let record = try PairingCeremony.completeEnrollment(offer: fixture.offer, response: fixture.response, operatorAttestation: fixture.attestation, anchor: fixture.anchor, nowUnixMs: baseTime + 4_000)
        XCTAssertTrue(try PairingCeremony.verifyEnrollment(record))
    }

    private func pairingFixture(companionID: String = "iphone", companionKind: String = "iOS") throws -> (anchor: SodiumSoulAnchor, offer: PairingOffer, companionKey: SigningKeyPair, response: PairingResponse, attestation: OperatorAttestation) {
        let anchor = SodiumSoulAnchor(keyPair: try SigningKeyPair.generate())
        let offer = try PairingCeremony.createOffer(hostID: "mac-host", endpointHints: ["bonjour:_jarvis-wire._tcp"], anchor: anchor, nowUnixMs: baseTime)
        let companionKey = try SigningKeyPair.generate()
        let response = try PairingCeremony.createResponse(offer: offer, companionID: companionID, companionKind: companionKind, companionSigningKey: companionKey, displayedShortCode: PairingCeremony.shortCode(for: offer), nowUnixMs: baseTime + 1_000)
        let attestation = try PairingCeremony.createOperatorAttestation(offer: offer, response: response, anchor: anchor, approvedAtUnixMs: baseTime + 2_000)
        return (anchor, offer, companionKey, response, attestation)
    }

    private func establishedSessions(nowUnixMs: Int64? = nil) throws -> (anchor: SodiumSoulAnchor, hostHello: SessionHandshake, companionHello: SessionHandshake, hostSession: WireSession, companionSession: WireSession) {
        let t = nowUnixMs ?? baseTime
        let anchor = SodiumSoulAnchor(keyPair: try SigningKeyPair.generate())
        let hostHello = try SessionHandshake.begin(role: .host, deviceID: "mac", anchor: anchor, nowUnixMs: t)
        let companionHello = try SessionHandshake.begin(role: .companion, deviceID: "phone", anchor: anchor, nowUnixMs: t + 500)
        let hostSession = try hostHello.finish(peerHello: companionHello.hello, expectedPeerRole: .companion, trustedAnchorPublicKey: anchor.anchorPublicKey, nowUnixMs: t + 1_000)
        let companionSession = try companionHello.finish(peerHello: hostHello.hello, expectedPeerRole: .host, trustedAnchorPublicKey: anchor.anchorPublicKey, nowUnixMs: t + 1_000)
        return (anchor, hostHello, companionHello, hostSession, companionSession)
    }

    private func inputPayload(_ text: String) -> WirePayload {
        WirePayload(type: .input, createdAtUnixMs: baseTime + 1_000, body: .input(InputMessage(modality: "text", text: text)))
    }
}
