import Foundation

public struct SignedDistressSignal: Codable, Sendable, Equatable {
    public var companionID: String
    public var createdAtUnixMs: Int64
    public var nonce: Data
    public var message: DistressMessage
    public var companionSigningPublicKey: Data
    public var signature: Data

    public init(companionID: String, createdAtUnixMs: Int64 = ClockUnix.milliseconds(), nonce: Data? = nil, message: DistressMessage, companionSigningPublicKey: Data, signature: Data = Data()) throws {
        self.companionID = companionID
        self.createdAtUnixMs = createdAtUnixMs
        self.nonce = try nonce ?? Sodium.randomBytes(24)
        self.message = message
        self.companionSigningPublicKey = companionSigningPublicKey
        self.signature = signature
    }

    public func signedPayload() throws -> Data {
        try JSONEncoder.wireCanonical.encode(UnsignedSignedDistressSignal(signal: self))
    }
}

private struct UnsignedSignedDistressSignal: Codable {
    var companionID: String
    var createdAtUnixMs: Int64
    var nonce: Data
    var message: DistressMessage
    var companionSigningPublicKey: Data

    init(signal: SignedDistressSignal) {
        companionID = signal.companionID
        createdAtUnixMs = signal.createdAtUnixMs
        nonce = signal.nonce
        message = signal.message
        companionSigningPublicKey = signal.companionSigningPublicKey
    }
}

public enum DistressChannel {
    public static func sign(_ distress: DistressMessage, companionID: String, companionSigningKey: SigningKeyPair, nowUnixMs: Int64 = ClockUnix.milliseconds()) throws -> SignedDistressSignal {
        var signal = try SignedDistressSignal(companionID: companionID, createdAtUnixMs: nowUnixMs, message: distress, companionSigningPublicKey: companionSigningKey.publicKey)
        signal.signature = try Sodium.sign(signal.signedPayload(), secretKey: companionSigningKey.secretKey)
        return signal
    }

    public static func verify(_ signal: SignedDistressSignal, enrolledRecord: PairingRecord, replayProtector: inout ReplayProtector, nowUnixMs: Int64 = ClockUnix.milliseconds()) throws -> Bool {
        guard signal.companionID == enrolledRecord.companionID else { throw WireError.invalidSignature }
        guard signal.companionSigningPublicKey == enrolledRecord.companionSigningPublicKey else { throw WireError.invalidSignature }
        guard try Sodium.verify(signature: signal.signature, message: signal.signedPayload(), publicKey: signal.companionSigningPublicKey) else { return false }
        try replayProtector.validate(nonce: signal.nonce, timestampUnixMs: signal.createdAtUnixMs, sequence: UInt64(bitPattern: signal.createdAtUnixMs), nowUnixMs: nowUnixMs)
        return true
    }
}
