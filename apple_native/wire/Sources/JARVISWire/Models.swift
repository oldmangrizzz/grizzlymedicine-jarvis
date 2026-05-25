import Foundation

public enum WireRole: String, Codable, Sendable, Equatable {
    case host
    case companion
}

public enum WireMessageType: UInt8, Codable, Sendable, Equatable {
    case input = 1
    case output = 2
    case status = 3
    case distress = 4
    case pairing = 5
    case heartbeat = 6
}

public struct SigningKeyPair: Sendable, Equatable {
    public let publicKey: Data
    public let secretKey: Data

    public init(publicKey: Data, secretKey: Data) {
        self.publicKey = publicKey
        self.secretKey = secretKey
    }

    public static func generate() throws -> SigningKeyPair {
        try Sodium.signKeypair()
    }
}

public struct KeyExchangeKeyPair: Sendable, Equatable {
    public let publicKey: Data
    public let secretKey: Data

    public init(publicKey: Data, secretKey: Data) {
        self.publicKey = publicKey
        self.secretKey = secretKey
    }

    public static func generate() throws -> KeyExchangeKeyPair {
        try Sodium.kxKeypair()
    }
}

public struct SessionKeys: Sendable, Equatable {
    public let receiveKey: Data
    public let transmitKey: Data

    public init(receiveKey: Data, transmitKey: Data) {
        self.receiveKey = receiveKey
        self.transmitKey = transmitKey
    }
}

public protocol SoulAnchorSigning: Sendable {
    var anchorPublicKey: Data { get }
    func sign(_ message: Data) throws -> Data
}

public protocol SoulAnchorVerifying: Sendable {
    var anchorPublicKey: Data { get }
    func verify(signature: Data, message: Data) throws -> Bool
}

public struct SodiumSoulAnchor: SoulAnchorSigning, SoulAnchorVerifying {
    public let anchorPublicKey: Data
    private let secretKey: Data?

    public init(publicKey: Data, secretKey: Data? = nil) {
        self.anchorPublicKey = publicKey
        self.secretKey = secretKey
    }

    public init(keyPair: SigningKeyPair) {
        self.anchorPublicKey = keyPair.publicKey
        self.secretKey = keyPair.secretKey
    }

    public func sign(_ message: Data) throws -> Data {
        guard let secretKey else { throw WireError.invalidSignature }
        return try Sodium.sign(message, secretKey: secretKey)
    }

    public func verify(signature: Data, message: Data) throws -> Bool {
        try Sodium.verify(signature: signature, message: message, publicKey: anchorPublicKey)
    }
}

public struct WirePayload: Codable, Sendable, Equatable {
    public var id: UUID
    public var type: WireMessageType
    public var createdAtUnixMs: Int64
    public var body: Body

    public init(id: UUID = UUID(), type: WireMessageType, createdAtUnixMs: Int64 = ClockUnix.milliseconds(), body: Body) {
        self.id = id
        self.type = type
        self.createdAtUnixMs = createdAtUnixMs
        self.body = body
    }

    public enum Body: Codable, Sendable, Equatable {
        case input(InputMessage)
        case output(OutputMessage)
        case status(StatusMessage)
        case distress(DistressMessage)
        case pairing(PairingEvent)
        case heartbeat(HeartbeatMessage)

        private enum CodingKeys: String, CodingKey { case kind, value }
        private enum Kind: String, Codable { case input, output, status, distress, pairing, heartbeat }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(Kind.self, forKey: .kind) {
            case .input: self = .input(try container.decode(InputMessage.self, forKey: .value))
            case .output: self = .output(try container.decode(OutputMessage.self, forKey: .value))
            case .status: self = .status(try container.decode(StatusMessage.self, forKey: .value))
            case .distress: self = .distress(try container.decode(DistressMessage.self, forKey: .value))
            case .pairing: self = .pairing(try container.decode(PairingEvent.self, forKey: .value))
            case .heartbeat: self = .heartbeat(try container.decode(HeartbeatMessage.self, forKey: .value))
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .input(let value):
                try container.encode(Kind.input, forKey: .kind)
                try container.encode(value, forKey: .value)
            case .output(let value):
                try container.encode(Kind.output, forKey: .kind)
                try container.encode(value, forKey: .value)
            case .status(let value):
                try container.encode(Kind.status, forKey: .kind)
                try container.encode(value, forKey: .value)
            case .distress(let value):
                try container.encode(Kind.distress, forKey: .kind)
                try container.encode(value, forKey: .value)
            case .pairing(let value):
                try container.encode(Kind.pairing, forKey: .kind)
                try container.encode(value, forKey: .value)
            case .heartbeat(let value):
                try container.encode(Kind.heartbeat, forKey: .kind)
                try container.encode(value, forKey: .value)
            }
        }
    }
}

public struct InputMessage: Codable, Sendable, Equatable {
    public var modality: String
    public var text: String?
    public var binary: Data?
    public var metadata: [String: String]
    public init(modality: String, text: String? = nil, binary: Data? = nil, metadata: [String: String] = [:]) {
        self.modality = modality
        self.text = text
        self.binary = binary
        self.metadata = metadata
    }
}

public struct OutputMessage: Codable, Sendable, Equatable {
    public var surface: String
    public var text: String?
    public var binary: Data?
    public var metadata: [String: String]
    public init(surface: String, text: String? = nil, binary: Data? = nil, metadata: [String: String] = [:]) {
        self.surface = surface
        self.text = text
        self.binary = binary
        self.metadata = metadata
    }
}

public struct StatusMessage: Codable, Sendable, Equatable {
    public var state: String
    public var battery: Double?
    public var network: String?
    public var metadata: [String: String]
    public init(state: String, battery: Double? = nil, network: String? = nil, metadata: [String: String] = [:]) {
        self.state = state
        self.battery = battery
        self.network = network
        self.metadata = metadata
    }
}

public struct DistressMessage: Codable, Sendable, Equatable {
    public var severity: UInt8
    public var reason: String
    public var locationHint: String?
    public var needsImmediateAttention: Bool
    public init(severity: UInt8, reason: String, locationHint: String? = nil, needsImmediateAttention: Bool = true) {
        self.severity = severity
        self.reason = reason
        self.locationHint = locationHint
        self.needsImmediateAttention = needsImmediateAttention
    }
}

public struct PairingEvent: Codable, Sendable, Equatable {
    public var phase: String
    public var deviceID: String
    public init(phase: String, deviceID: String) {
        self.phase = phase
        self.deviceID = deviceID
    }
}

public struct HeartbeatMessage: Codable, Sendable, Equatable {
    public var deviceID: String
    public var monotonicCounter: UInt64
    public init(deviceID: String, monotonicCounter: UInt64) {
        self.deviceID = deviceID
        self.monotonicCounter = monotonicCounter
    }
}

public enum ClockUnix {
    public static func milliseconds(date: Date = Date()) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }
}

extension JSONEncoder {
    static var wireCanonical: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dataEncodingStrategy = .base64
        return encoder
    }
}

extension JSONDecoder {
    static var wireCanonical: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dataDecodingStrategy = .base64
        return decoder
    }
}
