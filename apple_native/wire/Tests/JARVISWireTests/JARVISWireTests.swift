import XCTest
@testable import JARVISWire

final class JARVISWireTests: XCTestCase {
    func testPairingCeremonyCreatesVerifiableEnrollment() throws {
        let hostAnchor = SodiumSoulAnchor(keyPair: try SigningKeyPair.generate())
        let offer = try PairingCeremony.createOffer(hostID: "mac-host", endpointHints: ["bonjour:_jarvis-wire._tcp"], anchor: hostAnchor, nowUnixMs: 1_700_000_000_000)
        XCTAssertTrue(try PairingCeremony.verifyOffer(offer, nowUnixMs: 1_700_000_001_000))
        let qr = try PairingCeremony.encodeQRCodePayload(offer)
        let decoded = try PairingCeremony.decodeQRCodePayload(qr)
        XCTAssertEqual(decoded, offer)
        let companionKey = try SigningKeyPair.generate()
        let code = PairingCeremony.shortCode(for: offer)
        let response = try PairingCeremony.createResponse(offer: decoded, companionID: "iphone", companionKind: "iOS", companionSigningKey: companionKey, displayedShortCode: code, nowUnixMs: 1_700_000_002_000)
        let attestation = try PairingCeremony.createOperatorAttestation(offer: offer, response: response, anchor: hostAnchor, approvedAtUnixMs: 1_700_000_002_500)
        let record = try PairingCeremony.completeEnrollment(offer: offer, response: response, operatorAttestation: attestation, anchor: hostAnchor, nowUnixMs: 1_700_000_003_000)
        XCTAssertTrue(try PairingCeremony.verifyEnrollment(record))
        XCTAssertEqual(record.companionSigningPublicKey, companionKey.publicKey)
    }

    func testNormalMessageFlow() throws {
        let anchor = SodiumSoulAnchor(keyPair: try SigningKeyPair.generate())
        let hostHandshake = try SessionHandshake.begin(role: .host, deviceID: "mac", anchor: anchor, nowUnixMs: 1_700_000_000_000)
        let companionHandshake = try SessionHandshake.begin(role: .companion, deviceID: "phone", anchor: anchor, nowUnixMs: 1_700_000_000_500)
        var hostSession = try hostHandshake.finish(peerHello: companionHandshake.hello, expectedPeerRole: .companion, nowUnixMs: 1_700_000_001_000)
        var companionSession = try companionHandshake.finish(peerHello: hostHandshake.hello, expectedPeerRole: .host, nowUnixMs: 1_700_000_001_000)
        let payload = WirePayload(type: .input, createdAtUnixMs: 1_700_000_001_100, body: .input(InputMessage(modality: "voice", text: "JARVIS, status.")))
        let frame = try companionSession.seal(payload)
        let opened = try hostSession.open(frame, nowUnixMs: ClockUnix.milliseconds())
        XCTAssertEqual(opened, payload)
    }

    func testReplayRejection() throws {
        let anchor = SodiumSoulAnchor(keyPair: try SigningKeyPair.generate())
        let hostHandshake = try SessionHandshake.begin(role: .host, deviceID: "mac", anchor: anchor)
        let companionHandshake = try SessionHandshake.begin(role: .companion, deviceID: "watch", anchor: anchor)
        var hostSession = try hostHandshake.finish(peerHello: companionHandshake.hello, expectedPeerRole: .companion)
        var companionSession = try companionHandshake.finish(peerHello: hostHandshake.hello, expectedPeerRole: .host)
        let distress = WirePayload(type: .distress, body: .distress(DistressMessage(severity: 5, reason: "fall detected")))
        let frame = try companionSession.seal(distress)
        _ = try hostSession.open(frame)
        XCTAssertThrowsError(try hostSession.open(frame)) { error in XCTAssertEqual(error as? WireError, .replayDetected) }
    }

    func testSignatureForgeryRejection() throws {
        let anchor = SodiumSoulAnchor(keyPair: try SigningKeyPair.generate())
        let attacker = SodiumSoulAnchor(keyPair: try SigningKeyPair.generate())
        var offer = try PairingCeremony.createOffer(hostID: "mac", endpointHints: [], anchor: anchor, nowUnixMs: 1_700_000_000_000)
        offer.hostID = "evil-mac"
        XCTAssertFalse(try PairingCeremony.verifyOffer(offer, nowUnixMs: 1_700_000_001_000))
        let hostHello = try SessionHandshake.begin(role: .host, deviceID: "mac", anchor: anchor)
        let forgedCompanion = try SessionHandshake.begin(role: .companion, deviceID: "phone", anchor: attacker)
        XCTAssertThrowsError(try hostHello.finish(peerHello: forgedCompanion.hello, expectedPeerRole: .companion, trustedAnchorPublicKey: anchor.anchorPublicKey))
    }

    func testEphemeralKeyRotationChangesSessionKeys() throws {
        let anchor = SodiumSoulAnchor(keyPair: try SigningKeyPair.generate())
        let firstHost = try SessionHandshake.begin(role: .host, deviceID: "mac", anchor: anchor)
        let firstCompanion = try SessionHandshake.begin(role: .companion, deviceID: "phone", anchor: anchor)
        let firstHostSession = try firstHost.finish(peerHello: firstCompanion.hello, expectedPeerRole: .companion)
        let firstCompanionSession = try firstCompanion.finish(peerHello: firstHost.hello, expectedPeerRole: .host)
        let secondHost = try SessionHandshake.begin(role: .host, deviceID: "mac", anchor: anchor)
        let secondCompanion = try SessionHandshake.begin(role: .companion, deviceID: "phone", anchor: anchor)
        let secondHostSession = try secondHost.finish(peerHello: secondCompanion.hello, expectedPeerRole: .companion)
        let secondCompanionSession = try secondCompanion.finish(peerHello: secondHost.hello, expectedPeerRole: .host)
        XCTAssertEqual(firstHostSession.keys.receiveKey, firstCompanionSession.keys.transmitKey)
        XCTAssertEqual(firstHostSession.keys.transmitKey, firstCompanionSession.keys.receiveKey)
        XCTAssertEqual(secondHostSession.keys.receiveKey, secondCompanionSession.keys.transmitKey)
        XCTAssertNotEqual(firstHostSession.keys.receiveKey, secondHostSession.keys.receiveKey)
        XCTAssertNotEqual(firstHost.hello.ephemeralPublicKey, secondHost.hello.ephemeralPublicKey)
    }

    func testDistressFallbackSignatureAndReplay() throws {
        let anchor = SodiumSoulAnchor(keyPair: try SigningKeyPair.generate())
        let companionKey = try SigningKeyPair.generate()
        var record = PairingRecord(hostID: "mac", companionID: "watch", companionKind: "watchOS", operatorID: "Robert \"Grizzly\" Hanson, GMRI", anchorPublicKey: anchor.anchorPublicKey, companionSigningPublicKey: companionKey.publicKey, enrolledAtUnixMs: 1_700_000_000_000)
        record.enrollmentSignature = try anchor.sign(record.signedPayload())
        XCTAssertTrue(try PairingCeremony.verifyEnrollment(record))
        let signal = try DistressChannel.sign(DistressMessage(severity: 5, reason: "degraded link distress"), companionID: "watch", companionSigningKey: companionKey, nowUnixMs: 1_700_000_001_000)
        var replay = ReplayProtector()
        XCTAssertTrue(try DistressChannel.verify(signal, enrolledRecord: record, replayProtector: &replay, nowUnixMs: 1_700_000_001_500))
        XCTAssertThrowsError(try DistressChannel.verify(signal, enrolledRecord: record, replayProtector: &replay, nowUnixMs: 1_700_000_001_600))
    }
}
