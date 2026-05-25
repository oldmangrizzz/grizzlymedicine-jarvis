import Foundation

public struct SessionHello: Codable, Sendable, Equatable {
    public var role: WireRole
    public var deviceID: String
    public var sessionID: UUID
    public var anchorPublicKey: Data
    public var ephemeralPublicKey: Data
    public var nonce: Data
    public var createdAtUnixMs: Int64
    public var signature: Data

    public init(role: WireRole, deviceID: String, sessionID: UUID = UUID(), anchorPublicKey: Data, ephemeralPublicKey: Data, nonce: Data? = nil, createdAtUnixMs: Int64 = ClockUnix.milliseconds(), signature: Data = Data()) throws {
        self.role = role
        self.deviceID = deviceID
        self.sessionID = sessionID
        self.anchorPublicKey = anchorPublicKey
        self.ephemeralPublicKey = ephemeralPublicKey
        self.nonce = try nonce ?? Sodium.randomBytes(24)
        self.createdAtUnixMs = createdAtUnixMs
        self.signature = signature
    }

    public func signedPayload() throws -> Data {
        try JSONEncoder.wireCanonical.encode(UnsignedSessionHello(hello: self))
    }
}

private struct UnsignedSessionHello: Codable {
    var role: WireRole
    var deviceID: String
    var sessionID: UUID
    var anchorPublicKey: Data
    var ephemeralPublicKey: Data
    var nonce: Data
    var createdAtUnixMs: Int64

    init(hello: SessionHello) {
        role = hello.role
        deviceID = hello.deviceID
        sessionID = hello.sessionID
        anchorPublicKey = hello.anchorPublicKey
        ephemeralPublicKey = hello.ephemeralPublicKey
        nonce = hello.nonce
        createdAtUnixMs = hello.createdAtUnixMs
    }
}

public struct SessionHandshake: Sendable {
    public let role: WireRole
    public let deviceID: String
    public let ephemeralKeyPair: KeyExchangeKeyPair
    public let hello: SessionHello

    public static func begin(role: WireRole, deviceID: String, anchor: SoulAnchorSigning, nowUnixMs: Int64 = ClockUnix.milliseconds()) throws -> SessionHandshake {
        let kx = try KeyExchangeKeyPair.generate()
        var hello = try SessionHello(role: role, deviceID: deviceID, anchorPublicKey: anchor.anchorPublicKey, ephemeralPublicKey: kx.publicKey, createdAtUnixMs: nowUnixMs)
        hello.signature = try anchor.sign(hello.signedPayload())
        return SessionHandshake(role: role, deviceID: deviceID, ephemeralKeyPair: kx, hello: hello)
    }

    public func finish(peerHello: SessionHello, expectedPeerRole: WireRole, trustedAnchorPublicKey: Data? = nil, nowUnixMs: Int64 = ClockUnix.milliseconds(), maximumClockSkewMs: Int64 = 300_000) throws -> WireSession {
        guard peerHello.role == expectedPeerRole else { throw WireError.roleMismatch }
        if let trustedAnchorPublicKey, peerHello.anchorPublicKey != trustedAnchorPublicKey { throw WireError.invalidSignature }
        guard abs(nowUnixMs - peerHello.createdAtUnixMs) <= maximumClockSkewMs else { throw WireError.staleTimestamp }
        let verifier = SodiumSoulAnchor(publicKey: peerHello.anchorPublicKey)
        guard try verifier.verify(signature: peerHello.signature, message: peerHello.signedPayload()) else { throw WireError.invalidSignature }
        let keys = try Sodium.derive(role: role, selfKeyPair: ephemeralKeyPair, peerPublicKey: peerHello.ephemeralPublicKey)
        return WireSession(role: role, keys: keys)
    }
}
