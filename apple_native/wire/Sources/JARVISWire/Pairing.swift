#if canImport(CsodiumShim) && os(macOS)
import CsodiumShim
#endif
import Foundation

public struct PairingOffer: Codable, Sendable, Equatable {
    public var protocolVersion: UInt8
    public var hostID: String
    public var operatorID: String
    public var anchorPublicKey: Data
    public var offerNonce: Data
    public var createdAtUnixMs: Int64
    public var expiresAtUnixMs: Int64
    public var endpointHints: [String]
    public var signature: Data

    public init(protocolVersion: UInt8 = WireFrameHeader.version, hostID: String, operatorID: String = "Robert \"Grizzly\" Hanson, GMRI", anchorPublicKey: Data, offerNonce: Data? = nil, createdAtUnixMs: Int64 = ClockUnix.milliseconds(), expiresAtUnixMs: Int64? = nil, endpointHints: [String] = [], signature: Data = Data()) throws {
        self.protocolVersion = protocolVersion
        self.hostID = hostID
        self.operatorID = operatorID
        self.anchorPublicKey = anchorPublicKey
        self.offerNonce = try offerNonce ?? Sodium.randomBytes(24)
        self.createdAtUnixMs = createdAtUnixMs
        self.expiresAtUnixMs = expiresAtUnixMs ?? (createdAtUnixMs + 300_000)
        self.endpointHints = endpointHints
        self.signature = signature
    }

    public func signedPayload() throws -> Data {
        try JSONEncoder.wireCanonical.encode(UnsignedPairingOffer(offer: self))
    }
}

private struct UnsignedPairingOffer: Codable {
    var protocolVersion: UInt8
    var hostID: String
    var operatorID: String
    var anchorPublicKey: Data
    var offerNonce: Data
    var createdAtUnixMs: Int64
    var expiresAtUnixMs: Int64
    var endpointHints: [String]

    init(offer: PairingOffer) {
        protocolVersion = offer.protocolVersion
        hostID = offer.hostID
        operatorID = offer.operatorID
        anchorPublicKey = offer.anchorPublicKey
        offerNonce = offer.offerNonce
        createdAtUnixMs = offer.createdAtUnixMs
        expiresAtUnixMs = offer.expiresAtUnixMs
        endpointHints = offer.endpointHints
    }
}

public struct PairingResponse: Codable, Sendable, Equatable {
    public var companionID: String
    public var companionKind: String
    public var companionSigningPublicKey: Data
    public var offerNonce: Data
    public var responseNonce: Data
    public var createdAtUnixMs: Int64
    public var shortCode: String
    public var signature: Data

    public init(companionID: String, companionKind: String, companionSigningPublicKey: Data, offerNonce: Data, responseNonce: Data? = nil, createdAtUnixMs: Int64 = ClockUnix.milliseconds(), shortCode: String, signature: Data = Data()) throws {
        self.companionID = companionID
        self.companionKind = companionKind
        self.companionSigningPublicKey = companionSigningPublicKey
        self.offerNonce = offerNonce
        self.responseNonce = try responseNonce ?? Sodium.randomBytes(24)
        self.createdAtUnixMs = createdAtUnixMs
        self.shortCode = shortCode
        self.signature = signature
    }

    public func signedPayload() throws -> Data {
        try JSONEncoder.wireCanonical.encode(UnsignedPairingResponse(response: self))
    }
}

private struct UnsignedPairingResponse: Codable {
    var companionID: String
    var companionKind: String
    var companionSigningPublicKey: Data
    var offerNonce: Data
    var responseNonce: Data
    var createdAtUnixMs: Int64
    var shortCode: String

    init(response: PairingResponse) {
        companionID = response.companionID
        companionKind = response.companionKind
        companionSigningPublicKey = response.companionSigningPublicKey
        offerNonce = response.offerNonce
        responseNonce = response.responseNonce
        createdAtUnixMs = response.createdAtUnixMs
        shortCode = response.shortCode
    }
}

public struct PairingRecord: Codable, Sendable, Equatable {
    public var hostID: String
    public var companionID: String
    public var companionKind: String
    public var operatorID: String
    public var anchorPublicKey: Data
    public var companionSigningPublicKey: Data
    public var enrolledAtUnixMs: Int64
    public var enrollmentSignature: Data

    public init(hostID: String, companionID: String, companionKind: String, operatorID: String, anchorPublicKey: Data, companionSigningPublicKey: Data, enrolledAtUnixMs: Int64 = ClockUnix.milliseconds(), enrollmentSignature: Data = Data()) {
        self.hostID = hostID
        self.companionID = companionID
        self.companionKind = companionKind
        self.operatorID = operatorID
        self.anchorPublicKey = anchorPublicKey
        self.companionSigningPublicKey = companionSigningPublicKey
        self.enrolledAtUnixMs = enrolledAtUnixMs
        self.enrollmentSignature = enrollmentSignature
    }

    public func signedPayload() throws -> Data {
        try JSONEncoder.wireCanonical.encode(UnsignedPairingRecord(record: self))
    }
}

private struct UnsignedPairingRecord: Codable {
    var hostID: String
    var companionID: String
    var companionKind: String
    var operatorID: String
    var anchorPublicKey: Data
    var companionSigningPublicKey: Data
    var enrolledAtUnixMs: Int64

    init(record: PairingRecord) {
        hostID = record.hostID
        companionID = record.companionID
        companionKind = record.companionKind
        operatorID = record.operatorID
        anchorPublicKey = record.anchorPublicKey
        companionSigningPublicKey = record.companionSigningPublicKey
        enrolledAtUnixMs = record.enrolledAtUnixMs
    }
}

public struct OperatorAttestation: Codable, Sendable, Equatable {
    public var operatorID: String
    public var offerNonce: Data
    public var companionSigningPublicKey: Data
    public var shortCode: String
    public var approvedAtUnixMs: Int64
    public var signature: Data

    public init(operatorID: String, offerNonce: Data, companionSigningPublicKey: Data, shortCode: String, approvedAtUnixMs: Int64 = ClockUnix.milliseconds(), signature: Data = Data()) {
        self.operatorID = operatorID
        self.offerNonce = offerNonce
        self.companionSigningPublicKey = companionSigningPublicKey
        self.shortCode = shortCode
        self.approvedAtUnixMs = approvedAtUnixMs
        self.signature = signature
    }

    public func signedPayload() throws -> Data {
        try JSONEncoder.wireCanonical.encode(UnsignedOperatorAttestation(attestation: self))
    }
}

private struct UnsignedOperatorAttestation: Codable {
    var operatorID: String
    var offerNonce: Data
    var companionSigningPublicKey: Data
    var shortCode: String
    var approvedAtUnixMs: Int64

    init(attestation: OperatorAttestation) {
        operatorID = attestation.operatorID
        offerNonce = attestation.offerNonce
        companionSigningPublicKey = attestation.companionSigningPublicKey
        shortCode = attestation.shortCode
        approvedAtUnixMs = attestation.approvedAtUnixMs
    }
}

public enum PairingCeremony {
    public static func createOffer(hostID: String, endpointHints: [String], anchor: SoulAnchorSigning, nowUnixMs: Int64 = ClockUnix.milliseconds()) throws -> PairingOffer {
        var offer = try PairingOffer(hostID: hostID, anchorPublicKey: anchor.anchorPublicKey, createdAtUnixMs: nowUnixMs, endpointHints: endpointHints)
        offer.signature = try anchor.sign(offer.signedPayload())
        return offer
    }

    public static func encodeQRCodePayload(_ offer: PairingOffer) throws -> String {
        let data = try JSONEncoder.wireCanonical.encode(offer)
        return "jarvis-wire://pair?offer=" + data.base64URLEncodedString()
    }

    public static func decodeQRCodePayload(_ payload: String) throws -> PairingOffer {
        guard let marker = payload.range(of: "offer=") else { throw WireError.malformedPairingPayload }
        let encoded = String(payload[marker.upperBound...])
        guard let data = Data(base64URLEncoded: encoded) else { throw WireError.malformedPairingPayload }
        return try JSONDecoder.wireCanonical.decode(PairingOffer.self, from: data)
    }

    public static func verifyOffer(_ offer: PairingOffer, nowUnixMs: Int64 = ClockUnix.milliseconds()) throws -> Bool {
        guard offer.protocolVersion == WireFrameHeader.version else { throw WireError.invalidFrame }
        guard nowUnixMs <= offer.expiresAtUnixMs else { throw WireError.pairingExpired }
        let verifier = SodiumSoulAnchor(publicKey: offer.anchorPublicKey)
        return try verifier.verify(signature: offer.signature, message: offer.signedPayload())
    }

    public static func shortCode(for offer: PairingOffer, digits: Int = 6) -> String {
        let material = offer.anchorPublicKey + offer.offerNonce + Data(offer.hostID.utf8)
#if canImport(CsodiumShim) && os(macOS)
        var hash = Data(count: Int(crypto_generichash_bytes_min()))
        let hashCount = hash.count
        hash.withUnsafeMutableBytes { outPtr in
            material.withUnsafeBytes { inPtr in
                guard let outBase = outPtr.bindMemory(to: UInt8.self).baseAddress,
                      let inBase = inPtr.bindMemory(to: UInt8.self).baseAddress else { return }
                crypto_generichash(outBase, hashCount, inBase, UInt64(material.count), nil, 0)
            }
        }
#else
        let hash = Sodium.genericHashPrefix(material, byteCount: 16)
#endif
        let value = hash.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } % UInt32(pow(10.0, Double(digits)))
        return String(format: "%0*u", digits, value)
    }

    public static func createResponse(offer: PairingOffer, companionID: String, companionKind: String, companionSigningKey: SigningKeyPair, displayedShortCode: String, nowUnixMs: Int64 = ClockUnix.milliseconds()) throws -> PairingResponse {
        guard try verifyOffer(offer, nowUnixMs: nowUnixMs) else { throw WireError.invalidSignature }
        guard displayedShortCode == shortCode(for: offer) else { throw WireError.shortCodeMismatch }
        var response = try PairingResponse(companionID: companionID, companionKind: companionKind, companionSigningPublicKey: companionSigningKey.publicKey, offerNonce: offer.offerNonce, createdAtUnixMs: nowUnixMs, shortCode: displayedShortCode)
        response.signature = try Sodium.sign(response.signedPayload(), secretKey: companionSigningKey.secretKey)
        return response
    }

    public static func createOperatorAttestation(offer: PairingOffer, response: PairingResponse, anchor: SoulAnchorSigning, approvedAtUnixMs: Int64 = ClockUnix.milliseconds()) throws -> OperatorAttestation {
        guard offer.anchorPublicKey == anchor.anchorPublicKey else { throw WireError.invalidSignature }
        guard try verifyOffer(offer, nowUnixMs: approvedAtUnixMs) else { throw WireError.invalidSignature }
        guard response.offerNonce == offer.offerNonce else { throw WireError.malformedPairingPayload }
        guard response.shortCode == shortCode(for: offer) else { throw WireError.shortCodeMismatch }
        guard try Sodium.verify(signature: response.signature, message: response.signedPayload(), publicKey: response.companionSigningPublicKey) else { throw WireError.invalidSignature }
        var attestation = OperatorAttestation(operatorID: offer.operatorID, offerNonce: offer.offerNonce, companionSigningPublicKey: response.companionSigningPublicKey, shortCode: response.shortCode, approvedAtUnixMs: approvedAtUnixMs)
        attestation.signature = try anchor.sign(attestation.signedPayload())
        return attestation
    }

    public static func verifyOperatorAttestation(_ attestation: OperatorAttestation, offer: PairingOffer, response: PairingResponse, nowUnixMs: Int64 = ClockUnix.milliseconds(), maximumClockSkewMs: Int64 = 300_000) throws -> Bool {
        guard attestation.operatorID == offer.operatorID else { throw WireError.operatorAttestationRequired }
        guard attestation.offerNonce == offer.offerNonce else { throw WireError.operatorAttestationRequired }
        guard attestation.companionSigningPublicKey == response.companionSigningPublicKey else { throw WireError.operatorAttestationRequired }
        guard attestation.shortCode == response.shortCode else { throw WireError.operatorAttestationRequired }
        guard abs(nowUnixMs - attestation.approvedAtUnixMs) <= maximumClockSkewMs else { throw WireError.staleTimestamp }
        let verifier = SodiumSoulAnchor(publicKey: offer.anchorPublicKey)
        return try verifier.verify(signature: attestation.signature, message: attestation.signedPayload())
    }

    public static func completeEnrollment(offer: PairingOffer, response: PairingResponse, operatorAttestation: OperatorAttestation, anchor: SoulAnchorSigning, nowUnixMs: Int64 = ClockUnix.milliseconds()) throws -> PairingRecord {
        guard offer.anchorPublicKey == anchor.anchorPublicKey else { throw WireError.invalidSignature }
        guard try verifyOffer(offer, nowUnixMs: nowUnixMs) else { throw WireError.invalidSignature }
        guard response.offerNonce == offer.offerNonce else { throw WireError.malformedPairingPayload }
        guard response.shortCode == shortCode(for: offer) else { throw WireError.shortCodeMismatch }
        guard try Sodium.verify(signature: response.signature, message: response.signedPayload(), publicKey: response.companionSigningPublicKey) else { throw WireError.invalidSignature }
        guard try verifyOperatorAttestation(operatorAttestation, offer: offer, response: response, nowUnixMs: nowUnixMs) else { throw WireError.operatorAttestationRequired }
        var record = PairingRecord(hostID: offer.hostID, companionID: response.companionID, companionKind: response.companionKind, operatorID: offer.operatorID, anchorPublicKey: offer.anchorPublicKey, companionSigningPublicKey: response.companionSigningPublicKey, enrolledAtUnixMs: nowUnixMs)
        record.enrollmentSignature = try anchor.sign(record.signedPayload())
        return record
    }

    public static func verifyEnrollment(_ record: PairingRecord) throws -> Bool {
        let verifier = SodiumSoulAnchor(publicKey: record.anchorPublicKey)
        return try verifier.verify(signature: record.enrollmentSignature, message: record.signedPayload())
    }
}

public extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLEncoded string: String) {
        var base64 = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let padding = (4 - base64.count % 4) % 4
        base64 += String(repeating: "=", count: padding)
        self.init(base64Encoded: base64)
    }
}
