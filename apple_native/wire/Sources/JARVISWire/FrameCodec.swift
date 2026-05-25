import Foundation

public struct WireFrameHeader: Sendable, Equatable {
    public static let version: UInt8 = 1
    public var version: UInt8
    public var messageType: WireMessageType
    public var flags: UInt8
    public var sequence: UInt64
    public var timestampUnixMs: Int64
    public var nonce: Data

    public init(version: UInt8 = WireFrameHeader.version, messageType: WireMessageType, flags: UInt8 = 0, sequence: UInt64, timestampUnixMs: Int64 = ClockUnix.milliseconds(), nonce: Data? = nil) throws {
        self.version = version
        self.messageType = messageType
        self.flags = flags
        self.sequence = sequence
        self.timestampUnixMs = timestampUnixMs
        self.nonce = try nonce ?? Sodium.randomBytes(Sodium.aeadNonceBytes)
    }

    var aad: Data {
        var out = Data()
        out.append(version)
        out.append(messageType.rawValue)
        out.append(flags)
        out.appendUInt64BE(sequence)
        out.appendInt64BE(timestampUnixMs)
        out.append(nonce)
        return out
    }
}

public struct WireFrame: Sendable, Equatable {
    public var header: WireFrameHeader
    public var ciphertext: Data

    public init(header: WireFrameHeader, ciphertext: Data) {
        self.header = header
        self.ciphertext = ciphertext
    }
}

public struct WireSession: Sendable {
    public let role: WireRole
    public let keys: SessionKeys
    public private(set) var nextSequence: UInt64
    private var replayProtector: ReplayProtector

    public init(role: WireRole, keys: SessionKeys, initialSequence: UInt64 = 0, replayProtector: ReplayProtector = ReplayProtector()) {
        self.role = role
        self.keys = keys
        self.nextSequence = initialSequence
        self.replayProtector = replayProtector
    }

    public mutating func seal(_ payload: WirePayload, flags: UInt8 = 0) throws -> Data {
        let plaintext = try JSONEncoder.wireCanonical.encode(payload)
        nextSequence += 1
        let header = try WireFrameHeader(messageType: payload.type, flags: flags, sequence: nextSequence)
        let ciphertext = try Sodium.seal(plaintext: plaintext, aad: header.aad, nonce: header.nonce, key: keys.transmitKey)
        return try WireFrameCodec.encodeFrame(WireFrame(header: header, ciphertext: ciphertext))
    }

    public mutating func open(_ data: Data, nowUnixMs: Int64 = ClockUnix.milliseconds()) throws -> WirePayload {
        let frame = try WireFrameCodec.decodeFrame(data)
        guard abs(nowUnixMs - frame.header.timestampUnixMs) <= replayProtector.maximumClockSkewMs else { throw WireError.staleTimestamp }
        let plaintext = try Sodium.open(ciphertext: frame.ciphertext, aad: frame.header.aad, nonce: frame.header.nonce, key: keys.receiveKey)
        let payload = try JSONDecoder.wireCanonical.decode(WirePayload.self, from: plaintext)
        guard payload.type == frame.header.messageType else { throw WireError.invalidFrame }
        try replayProtector.validate(nonce: frame.header.nonce, timestampUnixMs: frame.header.timestampUnixMs, sequence: frame.header.sequence, nowUnixMs: nowUnixMs)
        return payload
    }
}

public enum WireFrameCodec {
    public static func encodeFrame(_ frame: WireFrame) throws -> Data {
        guard frame.header.version == WireFrameHeader.version else { throw WireError.invalidFrame }
        guard frame.header.nonce.count == Sodium.aeadNonceBytes else { throw WireError.invalidNonceSize(expected: Sodium.aeadNonceBytes, actual: frame.header.nonce.count) }
        var payload = Data()
        payload.append(frame.header.version)
        payload.append(frame.header.messageType.rawValue)
        payload.append(frame.header.flags)
        payload.appendUInt64BE(frame.header.sequence)
        payload.appendInt64BE(frame.header.timestampUnixMs)
        payload.append(frame.header.nonce)
        payload.appendUInt32BE(UInt32(frame.ciphertext.count))
        payload.append(frame.ciphertext)
        var framed = Data()
        framed.appendUInt32BE(UInt32(payload.count))
        framed.append(payload)
        return framed
    }

    public static func decodeFrame(_ data: Data) throws -> WireFrame {
        var reader = DataReader(data)
        let length = try Int(reader.readUInt32BE())
        guard length == reader.remainingCount else { throw WireError.invalidFrame }
        let version = try reader.readByte()
        guard version == WireFrameHeader.version else { throw WireError.invalidFrame }
        guard let type = WireMessageType(rawValue: try reader.readByte()) else { throw WireError.invalidFrame }
        let flags = try reader.readByte()
        let sequence = try reader.readUInt64BE()
        let timestamp = try reader.readInt64BE()
        let nonce = try reader.readData(count: Sodium.aeadNonceBytes)
        let cipherLength = try Int(reader.readUInt32BE())
        let ciphertext = try reader.readData(count: cipherLength)
        guard reader.remainingCount == 0 else { throw WireError.invalidFrame }
        return WireFrame(header: try WireFrameHeader(version: version, messageType: type, flags: flags, sequence: sequence, timestampUnixMs: timestamp, nonce: nonce), ciphertext: ciphertext)
    }
}

struct DataReader {
    private let data: Data
    private var offset: Int = 0

    init(_ data: Data) { self.data = data }
    var remainingCount: Int { data.count - offset }

    mutating func readByte() throws -> UInt8 {
        guard remainingCount >= 1 else { throw WireError.invalidFrame }
        defer { offset += 1 }
        return data[offset]
    }

    mutating func readData(count: Int) throws -> Data {
        guard count >= 0, remainingCount >= count else { throw WireError.invalidFrame }
        let range = offset..<(offset + count)
        offset += count
        return data.subdata(in: range)
    }

    mutating func readUInt32BE() throws -> UInt32 {
        let bytes = try readData(count: 4)
        return bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    mutating func readUInt64BE() throws -> UInt64 {
        let bytes = try readData(count: 8)
        return bytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    mutating func readInt64BE() throws -> Int64 {
        Int64(bitPattern: try readUInt64BE())
    }
}

extension Data {
    mutating func appendUInt32BE(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8(value & 0xff))
    }

    mutating func appendUInt64BE(_ value: UInt64) {
        for shift in stride(from: 56, through: 0, by: -8) {
            append(UInt8((value >> UInt64(shift)) & 0xff))
        }
    }

    mutating func appendInt64BE(_ value: Int64) {
        appendUInt64BE(UInt64(bitPattern: value))
    }
}
