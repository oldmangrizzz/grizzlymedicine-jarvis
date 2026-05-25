import Foundation

public struct TrustEnvelope: Codable, Equatable {
    public let payload: String
    public let payload_sha256: String
    public let signature_over_payload_sha256: String
    public let signed_at_unix: Int64
    public let key_fingerprint_hex: String

    public init(payloadData: Data, coldRoot: ColdRootKey, signedAtUnix: Int64 = Int64(Date().timeIntervalSince1970)) throws {
        let digestHex = sha256Hex(payloadData)
        guard let digest = unhex(digestHex) else { throw CeremonyError.crypto("payload SHA-256 encoding failed") }
        self.payload = payloadData.base64EncodedString()
        self.payload_sha256 = digestHex
        self.signature_over_payload_sha256 = hex(try coldRoot.sign(digest))
        self.signed_at_unix = signedAtUnix
        self.key_fingerprint_hex = sha256Hex(coldRoot.publicKey)
    }

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

public func canonicalAuditAnchorJSON(startSequenceID: UInt64, startPrevHashHex: String, keyFingerprintHex: String) throws -> Data {
    let anchor: [String: Any] = [
        "key_fingerprint_hex": keyFingerprintHex,
        "start_prev_hash_hex": startPrevHashHex,
        "start_sequence_id": startSequenceID,
    ]
    return try JSONSerialization.data(withJSONObject: anchor, options: [.sortedKeys])
}
