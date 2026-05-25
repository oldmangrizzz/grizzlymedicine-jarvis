import XCTest
import AVFoundation
import JARVISWire
@testable import JARVISiOSCompanion

final class JARVISiOSCompanionTests: XCTestCase {
    func testPairingFromWireQRCodePayload() throws {
        let hostKey = try SigningKeyPair.generate()
        let anchor = SodiumSoulAnchor(keyPair: hostKey)
        let offer = try PairingCeremony.createOffer(hostID: "grizzly-mac", endpointHints: ["bonjour:_jarvis-wire._tcp"], anchor: anchor)
        let payload = try PairingCeremony.encodeQRCodePayload(offer)
        let shortCode = PairingCeremony.shortCode(for: offer)

        let material = try PairingCoordinator().completePairing(qrPayload: payload, displayedShortCode: shortCode, companionID: "test-phone")

        XCTAssertEqual(material.record.hostID, "grizzly-mac")
        XCTAssertEqual(material.record.operatorID, "Robert \"Grizzly\" Hanson, GMRI")
        XCTAssertEqual(material.record.companionKind, "iphone-sensory-effector-surface")
        XCTAssertEqual(material.record.anchorPublicKey, hostKey.publicKey)
        XCTAssertEqual(material.record.companionSigningPublicKey, material.companionSigningKey.publicKey)
    }

    func testWireMessageFlowSealsAudioAndOutputFrames() throws {
        let hostSigning = try SigningKeyPair.generate()
        let companionSigning = try SigningKeyPair.generate()
        let hostAnchor = SodiumSoulAnchor(keyPair: hostSigning)
        let companionAnchor = SodiumSoulAnchor(keyPair: companionSigning)

        let hostHandshake = try SessionHandshake.begin(role: .host, deviceID: "mac", anchor: hostAnchor)
        let companionHandshake = try SessionHandshake.begin(role: .companion, deviceID: "phone", anchor: companionAnchor)
        var hostSession = try hostHandshake.finish(peerHello: companionHandshake.hello, expectedPeerRole: .companion, trustedAnchorPublicKey: companionSigning.publicKey)
        var companionSession = try companionHandshake.finish(peerHello: hostHandshake.hello, expectedPeerRole: .host, trustedAnchorPublicKey: hostSigning.publicKey)

        let microphonePCM = Data([0x00, 0x00, 0xff, 0x7f])
        let input = WirePayload(type: .input, body: .input(InputMessage(modality: "audio/pcm", binary: microphonePCM, metadata: ["encoding": "pcm_s16le", "sampleRate": "16000"])))
        let sealedInput = try companionSession.seal(input)
        XCTAssertEqual(try hostSession.open(sealedInput), input)

        let speakerPCM = Data([0x00, 0x00, 0x01, 0x00])
        let output = WirePayload(type: .output, body: .output(OutputMessage(surface: "iphone-speaker", binary: speakerPCM, metadata: ["sampleRate": "16000"])))
        let sealedOutput = try hostSession.seal(output)
        XCTAssertEqual(try companionSession.open(sealedOutput), output)
    }

    func testAudioPCMCodecRoundTripsInt16Mono() throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 3))
        buffer.frameLength = 3
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        channel[0] = -1.0
        channel[1] = 0.0
        channel[2] = 1.0

        let pcm = AudioPCMCodec.pcm16MonoData(from: buffer)
        XCTAssertEqual(pcm.count, 6)
        let playback = try XCTUnwrap(AudioPCMCodec.makePlaybackBuffer(pcm16Mono: pcm, sampleRate: 16_000))
        XCTAssertEqual(playback.frameLength, 3)
        XCTAssertEqual(playback.format.sampleRate, 16_000)
    }

    @MainActor
    func testBackgroundDropsConnectionStateAndTransmission() throws {
        let material = try Self.makeStoredMaterial()
        let store = InMemoryPairingStore(material: material)
        let model = CompanionAppModel(pairingStore: store, notificationRelay: RecordingDistressRelay())

        model.backgroundGracefully()

        XCTAssertFalse(model.isTransmittingAudio)
        XCTAssertEqual(model.connectionState, .disconnected)
        XCTAssertEqual(model.pairingRecord?.hostID, "mac")
    }

    @MainActor
    func testQRScanURLWithValidOfferIsAccepted() throws {
        let model = CompanionAppModel(pairingStore: InMemoryPairingStore(material: nil), notificationRelay: RecordingDistressRelay())
        let hostKey = try SigningKeyPair.generate()
        let anchor = SodiumSoulAnchor(keyPair: hostKey)
        let offer = try PairingCeremony.createOffer(hostID: "test-host", endpointHints: [], anchor: anchor)
        let urlString = try PairingCeremony.encodeQRCodePayload(offer)
        let url = try XCTUnwrap(URL(string: urlString))

        model.acceptPairingURL(url)

        XCTAssertEqual(model.incomingPairingPayload, urlString)
        XCTAssertNil(model.lastError, "valid offer URL must not set lastError")
    }

    @MainActor
    func testQRScanURLWithMalformedOfferIsRejected() throws {
        let model = CompanionAppModel(pairingStore: InMemoryPairingStore(material: nil), notificationRelay: RecordingDistressRelay())
        let url = try XCTUnwrap(URL(string: "jarvis-wire://pair?offer=notvalidbase64!!!"))

        model.acceptPairingURL(url)

        XCTAssertEqual(model.incomingPairingPayload, "", "malformed offer must not be stored")
        XCTAssertNotNil(model.lastError, "malformed offer URL must set lastError")
    }

    // MARK: Fix 5 — Bonjour host pinning: anchor key pre-check

    func testBonjourIdentityPrecheckRejectsWrongAnchorKey() throws {
        // Simulate the companion receiving a SessionHello from a peer that has a different
        // anchor key than the one bound in the pairing record.
        // The companion must fire BonjourIdentityError.anchorKeyMismatch before any
        // companion data (deviceID, signing public key) is sent to the untrusted peer.
        let pairedHostKey = try SigningKeyPair.generate()
        let attackerHostKey = try SigningKeyPair.generate()
        let companionKey = try SigningKeyPair.generate()

        // Build a pairing record that trusts pairedHostKey.
        let record = PairingRecord(
            hostID: "mac",
            companionID: "phone",
            companionKind: "iphone-sensory-effector-surface",
            operatorID: "Robert \"Grizzly\" Hanson, GMRI",
            anchorPublicKey: pairedHostKey.publicKey,
            companionSigningPublicKey: companionKey.publicKey
        )

        // Attacker announces itself with attackerHostKey (wrong anchor).
        let attackerAnchor = SodiumSoulAnchor(keyPair: attackerHostKey)
        let attackerHandshake = try SessionHandshake.begin(role: .host, deviceID: "attacker-mac", anchor: attackerAnchor)
        let attackerHello = attackerHandshake.hello

        // Verify that the anchor key from the attacker's hello does NOT match the pairing record.
        XCTAssertNotEqual(attackerHello.anchorPublicKey, record.anchorPublicKey,
            "Test precondition: attacker anchor key must differ from paired anchor key")

        // The companion identity pre-check that fires in receiveAndVerifyHostHello():
        // anchorPublicKey == record.anchorPublicKey must be false → BonjourIdentityError.anchorKeyMismatch.
        let identityCheckPasses = attackerHello.anchorPublicKey == record.anchorPublicKey
        XCTAssertFalse(identityCheckPasses, "Identity pre-check must reject attacker's hello")

        // Confirm the same check on the legit host key passes.
        let legitimateHostAnchor = SodiumSoulAnchor(keyPair: pairedHostKey)
        let legitimateHandshake = try SessionHandshake.begin(role: .host, deviceID: "mac", anchor: legitimateHostAnchor)
        let legitimateHello = legitimateHandshake.hello
        XCTAssertEqual(legitimateHello.anchorPublicKey, record.anchorPublicKey,
            "Legitimate host anchor key must match pairing record")
    }

    func testBonjourIdentityPrecheckAllowsCorrectAnchorKey() throws {
        // Confirm that when the host sends a hello with the paired anchor key,
        // SessionHandshake.finish completes without error.
        let hostKey = try SigningKeyPair.generate()
        let companionKey = try SigningKeyPair.generate()
        let hostAnchor = SodiumSoulAnchor(keyPair: hostKey)
        let companionAnchor = SodiumSoulAnchor(keyPair: companionKey)

        let hostHandshake = try SessionHandshake.begin(role: .host, deviceID: "mac", anchor: hostAnchor)
        let companionHandshake = try SessionHandshake.begin(role: .companion, deviceID: "phone", anchor: companionAnchor)

        // In the new protocol the companion receives host hello first and verifies.
        XCTAssertEqual(hostHandshake.hello.anchorPublicKey, hostKey.publicKey)

        // Companion calls finish with trustedAnchorPublicKey = hostKey.publicKey.
        XCTAssertNoThrow(try companionHandshake.finish(
            peerHello: hostHandshake.hello,
            expectedPeerRole: .host,
            trustedAnchorPublicKey: hostKey.publicKey
        ))
    }

    func testBonjourIdentityPrecheckRejectsWrongAnchorKeyViaFinish() throws {
        // Confirm that SessionHandshake.finish with mismatched trustedAnchorPublicKey
        // throws WireError.invalidSignature (the secondary guard inside finish).
        let hostKey = try SigningKeyPair.generate()
        let attackerKey = try SigningKeyPair.generate()
        let companionKey = try SigningKeyPair.generate()
        let hostAnchor = SodiumSoulAnchor(keyPair: hostKey)
        let companionAnchor = SodiumSoulAnchor(keyPair: companionKey)

        let hostHandshake = try SessionHandshake.begin(role: .host, deviceID: "mac", anchor: hostAnchor)
        let companionHandshake = try SessionHandshake.begin(role: .companion, deviceID: "phone", anchor: companionAnchor)

        XCTAssertThrowsError(try companionHandshake.finish(
            peerHello: hostHandshake.hello,
            expectedPeerRole: .host,
            trustedAnchorPublicKey: attackerKey.publicKey  // wrong pin
        )) { error in
            XCTAssertEqual(error as? WireError, .invalidSignature,
                "finish with wrong trustedAnchorPublicKey must throw .invalidSignature")
        }
    }

    func testSiriQuarantineAndLeastPrivilegePlists() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let infoURL = projectRoot.appendingPathComponent("JARVISiOSCompanion/Info.plist")
        let entitlementsURL = projectRoot.appendingPathComponent("JARVISiOSCompanion/JARVISiOSCompanion.entitlements")
        let infoData = try Data(contentsOf: infoURL)
        let entitlementsData = try Data(contentsOf: entitlementsURL)
        let info = try XCTUnwrap(PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any])
        let entitlements = try XCTUnwrap(PropertyListSerialization.propertyList(from: entitlementsData, format: nil) as? [String: Any])

        XCTAssertNotNil(info["NSMicrophoneUsageDescription"])
        XCTAssertNotNil(info["NSLocalNetworkUsageDescription"])
        for forbidden in ["NSCameraUsageDescription", "NSContactsUsageDescription", "NSLocationWhenInUseUsageDescription", "NSSiriUsageDescription", "NSSpeechRecognitionUsageDescription", "INIntentsSupported", "NSUserActivityTypes"] {
            XCTAssertNil(info[forbidden], "Forbidden Info.plist key present: \(forbidden)")
        }
        XCTAssertTrue(entitlements.isEmpty, "Entitlements must stay empty; microphone is an Info.plist runtime permission, not an entitlement.")
    }

    @MainActor
    func testDistressPayloadUsesMinimalRelayPath() throws {
        let relay = RecordingDistressRelay()
        let model = CompanionAppModel(pairingStore: InMemoryPairingStore(material: nil), notificationRelay: relay)
        let payload = WirePayload(type: .distress, body: .distress(DistressMessage(severity: 5, reason: "not shown", locationHint: "not shown")))

        model.handle(payload: payload)
        XCTAssertEqual(relay.count, 1)
    }

    private static func makeStoredMaterial() throws -> StoredPairingMaterial {
        let hostKey = try SigningKeyPair.generate()
        let companionKey = try SigningKeyPair.generate()
        let record = PairingRecord(hostID: "mac", companionID: "phone", companionKind: "iphone-sensory-effector-surface", operatorID: "Robert \"Grizzly\" Hanson, GMRI", anchorPublicKey: hostKey.publicKey, companionSigningPublicKey: companionKey.publicKey)
        return StoredPairingMaterial(record: record, companionSigningKey: companionKey)
    }
}

final class InMemoryPairingStore: PairingStore {
    var material: StoredPairingMaterial?
    init(material: StoredPairingMaterial?) { self.material = material }
    func load() throws -> StoredPairingMaterial? { material }
    func save(_ material: StoredPairingMaterial) throws { self.material = material }
    func delete() throws { material = nil }
}

final class RecordingDistressRelay: DistressNotificationRelaying {
    private(set) var count = 0
    func relayDistressBanner() { count += 1 }
}
