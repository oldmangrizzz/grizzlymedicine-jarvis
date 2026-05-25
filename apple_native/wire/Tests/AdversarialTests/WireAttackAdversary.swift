import Foundation
@testable import JARVISWire

final class MockWireAdversary {
    func replayPairing(offer: PairingOffer, response: PairingResponse, attestation: OperatorAttestation, against admission: inout PairingAdmissionController, anchor: SoulAnchorSigning, nowUnixMs: Int64) throws -> PairingRecord {
        try admission.completeEnrollment(offer: offer, response: response, operatorAttestation: attestation, anchor: anchor, nowUnixMs: nowUnixMs)
    }

    func swapPairingKeys(offer: PairingOffer, response: PairingResponse, attackerKey: SigningKeyPair, anchor: SoulAnchorSigning, nowUnixMs: Int64) throws -> PairingRecord {
        var swapped = response
        swapped.companionSigningPublicKey = attackerKey.publicKey
        let attestation = try PairingCeremony.createOperatorAttestation(offer: offer, response: response, anchor: anchor, approvedAtUnixMs: nowUnixMs)
        return try PairingCeremony.completeEnrollment(offer: offer, response: swapped, operatorAttestation: attestation, anchor: anchor, nowUnixMs: nowUnixMs)
    }

    func forgeSessionKeys(observedHostHello: SessionHello, role: WireRole = .companion) throws -> SessionKeys {
        try Sodium.derive(role: role, selfKeyPair: KeyExchangeKeyPair.generate(), peerPublicKey: observedHostHello.ephemeralPublicKey)
    }

    func forgeMessage(payload: WirePayload, visibleType: WireMessageType, sequence: UInt64, nowUnixMs: Int64) throws -> Data {
        let attackerKey = try Sodium.randomBytes(Sodium.aeadKeyBytes)
        let header = try WireFrameHeader(messageType: visibleType, sequence: sequence, timestampUnixMs: nowUnixMs)
        let plaintext = try JSONEncoder.wireCanonical.encode(payload)
        let ciphertext = try Sodium.seal(plaintext: plaintext, aad: header.aad, nonce: header.nonce, key: attackerKey)
        return try WireFrameCodec.encodeFrame(WireFrame(header: header, ciphertext: ciphertext))
    }

    func replayInSession(_ frame: Data, against session: inout WireSession, nowUnixMs: Int64) throws -> WirePayload {
        try session.open(frame, nowUnixMs: nowUnixMs)
    }

    func downgradeVersion(frame: Data, to version: UInt8) -> Data {
        var downgraded = frame
        if downgraded.count > 4 { downgraded[4] = version }
        return downgraded
    }

    func deliverOutOfOrder(payload: WirePayload, sequence: UInt64, sender: WireSession, receiver: inout WireSession, nowUnixMs: Int64) throws -> WirePayload {
        let header = try WireFrameHeader(messageType: payload.type, sequence: sequence, timestampUnixMs: nowUnixMs)
        let plaintext = try JSONEncoder.wireCanonical.encode(payload)
        let ciphertext = try Sodium.seal(plaintext: plaintext, aad: header.aad, nonce: header.nonce, key: sender.keys.transmitKey)
        let frame = try WireFrameCodec.encodeFrame(WireFrame(header: header, ciphertext: ciphertext))
        return try receiver.open(frame, nowUnixMs: nowUnixMs)
    }

    func spamPairingRequests(count: Int, sourceID: String, against admission: inout PairingAdmissionController) -> Int {
        var rejected = 0
        for _ in 0..<count {
            do { try admission.recordPairingRequest(from: sourceID) } catch { rejected += 1 }
        }
        return rejected
    }

    func spamSessionInit(count: Int, sourceID: String, against admission: inout PairingAdmissionController) -> Int {
        var rejected = 0
        for _ in 0..<count {
            do { try admission.recordSessionInit(from: sourceID) } catch { rejected += 1 }
        }
        return rejected
    }

    func forgeDistress(message: DistressMessage, companionID: String, attackerKey: SigningKeyPair, nowUnixMs: Int64) throws -> SignedDistressSignal {
        try DistressChannel.sign(message, companionID: companionID, companionSigningKey: attackerKey, nowUnixMs: nowUnixMs)
    }

    func forgeOperatorAttestation(offer: PairingOffer, response: PairingResponse, attackerAnchor: SoulAnchorSigning, approvedAtUnixMs: Int64) throws -> OperatorAttestation {
        try PairingCeremony.createOperatorAttestation(offer: offer, response: response, anchor: attackerAnchor, approvedAtUnixMs: approvedAtUnixMs)
    }
}
