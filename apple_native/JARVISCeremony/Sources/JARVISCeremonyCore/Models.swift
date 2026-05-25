import Foundation
import IOKit

public let jarvisOperatorID = "Robert \"Grizzly\" Hanson, GMRI"
// NOTE: Test-only fallback. Production seal path MUST pass operator-attested operatorID via execute(operatorID:). DO NOT use as default at seal.
public let jarvisSubjectID = "JARVIS"

public enum BirthCertificateDecodeError: Error, CustomStringConvertible, Equatable {
    case hvAnchorTooLarge(Int)
    case hvAnchorNonHex
    case machineMismatch(expected: String, actual: String)
    case duplicateKey(String)
    case unknownField(String)
    case malformedJSON(String)
    case machineUUIDUnavailable

    public var description: String {
        switch self {
        case .hvAnchorTooLarge(let count): return "BirthCertificateHVAnchorTooLarge(\(count))"
        case .hvAnchorNonHex: return "BirthCertificateHVAnchorNonHex"
        case .machineMismatch(let expected, let actual): return "BirthCertificateMachineMismatch(expected: \(expected), actual: \(actual))"
        case .duplicateKey(let key): return "BirthCertificateDuplicateKey(\(key))"
        case .unknownField(let key): return "BirthCertificateUnknownField(\(key))"
        case .malformedJSON(let reason): return "BirthCertificateMalformedJSON(\(reason))"
        case .machineUUIDUnavailable: return "BirthCertificateMachineUUIDUnavailable"
        }
    }
}

public enum BirthCertificateError: Error, CustomStringConvertible, Equatable {
    case unsupportedHKDFDomainVersion(found: String, expected: String)
    case invalidOperatorID(reason: String)

    public var description: String {
        switch self {
        case .unsupportedHKDFDomainVersion(let found, let expected):
            return "BirthCertificateUnsupportedHKDFDomainVersion(found: \(found), expected: \(expected))"
        case .invalidOperatorID(let reason):
            return "BirthCertificateInvalidOperatorID(\(reason))"
        }
    }
}

public struct CharacterValuesAnchor: Codable, Equatable {
    public let bootIdentity: String
    public let valuesHash: String
    public let originHash: String
    public let identityHash: String
    public let hvAnchor: String
    public let hvKernel: String
    public let hvDimension: Int
}

public struct SecureEnclaveDescriptor: Codable, Equatable {
    public let mode: String
    public let hardwareBindingActive: Bool
    public let keyID: String
    public let publicKeyBase64: String
    public let publicKeySHA256Hex: String
    public let machineUUID: String
    public init(mode: String, hardwareBindingActive: Bool, keyID: String, publicKeyBase64: String, publicKeySHA256Hex: String, machineUUID: String) {
        self.mode = mode; self.hardwareBindingActive = hardwareBindingActive; self.keyID = keyID
        self.publicKeyBase64 = publicKeyBase64; self.publicKeySHA256Hex = publicKeySHA256Hex; self.machineUUID = machineUUID
    }
}

private struct AllKeysCodingKey: CodingKey, Hashable {
    let stringValue: String
    let intValue: Int?
    init?(stringValue: String) { self.stringValue = stringValue; self.intValue = nil }
    init?(intValue: Int) { self.stringValue = String(intValue); self.intValue = intValue }
}

public struct BirthCertificate: Codable, Equatable {
    public let version: String
    public let hkdfDomainVersion: String
    public let timestamp: String
    public let machineUUID: String
    public let sePublicKeyBase64: String
    public let seKeyID: String
    public let valuesHashViaCharacterValues: String
    public let hvAnchor: String
    public let coldRootPublicKeyHex: String
    public let soulAnchorPublicKeyHex: String
    public let operatorVoiceAnchorSHA256Hex: String
    public let operatorID: String
    public let subjectID: String
    public var signatureHex: String

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case version
        case hkdfDomainVersion
        case timestamp
        case machineUUID
        case sePublicKeyBase64
        case seKeyID
        case valuesHashViaCharacterValues
        case hvAnchor
        case coldRootPublicKeyHex
        case soulAnchorPublicKeyHex = "soul_anchor_pub"
        case operatorVoiceAnchorSHA256Hex
        case operatorID
        case subjectID
        case signatureHex
    }

    public init(version: String = "jarvis-soul-anchor-birth-1",
                hkdfDomainVersion: String,
                timestamp: String,
                machineUUID: String,
                sePublicKeyBase64: String,
                seKeyID: String,
                valuesHashViaCharacterValues: String,
                hvAnchor: String,
                coldRootPublicKeyHex: String,
                soulAnchorPublicKeyHex: String,
                operatorVoiceAnchorSHA256Hex: String = "",
                operatorID: String,
                subjectID: String = jarvisSubjectID,
                signatureHex: String = "") throws {
        self.version = version
        self.hkdfDomainVersion = hkdfDomainVersion
        self.timestamp = timestamp
        self.machineUUID = machineUUID
        self.sePublicKeyBase64 = sePublicKeyBase64
        self.seKeyID = seKeyID
        self.valuesHashViaCharacterValues = valuesHashViaCharacterValues
        self.hvAnchor = hvAnchor
        self.coldRootPublicKeyHex = coldRootPublicKeyHex
        self.soulAnchorPublicKeyHex = soulAnchorPublicKeyHex
        self.operatorVoiceAnchorSHA256Hex = operatorVoiceAnchorSHA256Hex
        self.operatorID = try Self.validateOperatorID(operatorID)
        self.subjectID = subjectID
        self.signatureHex = signatureHex
    }

    public init(from decoder: Decoder) throws {
        let all = try decoder.container(keyedBy: AllKeysCodingKey.self)
        let known = Set(CodingKeys.allCases.map(\.rawValue))
        for key in all.allKeys where !known.contains(key.stringValue) {
            throw BirthCertificateDecodeError.unknownField(key.stringValue)
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(String.self, forKey: .version)
        guard c.contains(.hkdfDomainVersion) else {
            throw BirthCertificateError.unsupportedHKDFDomainVersion(found: "<missing>", expected: HKDFDomain.currentSchemaVersion)
        }
        hkdfDomainVersion = try c.decode(String.self, forKey: .hkdfDomainVersion)
        try Self.validateHKDFDomainVersion(hkdfDomainVersion)
        timestamp = try c.decode(String.self, forKey: .timestamp)
        machineUUID = try c.decode(String.self, forKey: .machineUUID)
        sePublicKeyBase64 = try c.decode(String.self, forKey: .sePublicKeyBase64)
        seKeyID = try c.decode(String.self, forKey: .seKeyID)
        valuesHashViaCharacterValues = try c.decode(String.self, forKey: .valuesHashViaCharacterValues)
        hvAnchor = try c.decode(String.self, forKey: .hvAnchor)
        coldRootPublicKeyHex = try c.decode(String.self, forKey: .coldRootPublicKeyHex)
        soulAnchorPublicKeyHex = try c.decode(String.self, forKey: .soulAnchorPublicKeyHex)
        operatorVoiceAnchorSHA256Hex = try c.decode(String.self, forKey: .operatorVoiceAnchorSHA256Hex)
        operatorID = try Self.validateOperatorID(try c.decode(String.self, forKey: .operatorID))
        subjectID = try c.decode(String.self, forKey: .subjectID)
        signatureHex = try c.decode(String.self, forKey: .signatureHex)
        try Self.validateSecurityFields(hvAnchor: hvAnchor, machineUUID: machineUUID)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(hkdfDomainVersion, forKey: .hkdfDomainVersion)
        try c.encode(timestamp, forKey: .timestamp)
        try c.encode(machineUUID, forKey: .machineUUID)
        try c.encode(sePublicKeyBase64, forKey: .sePublicKeyBase64)
        try c.encode(seKeyID, forKey: .seKeyID)
        try c.encode(valuesHashViaCharacterValues, forKey: .valuesHashViaCharacterValues)
        try c.encode(hvAnchor, forKey: .hvAnchor)
        try c.encode(coldRootPublicKeyHex, forKey: .coldRootPublicKeyHex)
        try c.encode(soulAnchorPublicKeyHex, forKey: .soulAnchorPublicKeyHex)
        try c.encode(operatorVoiceAnchorSHA256Hex, forKey: .operatorVoiceAnchorSHA256Hex)
        try c.encode(operatorID, forKey: .operatorID)
        try c.encode(subjectID, forKey: .subjectID)
        try c.encode(signatureHex, forKey: .signatureHex)
    }

    public static func strictDecode(from data: Data) throws -> BirthCertificate {
        try rejectDuplicateTopLevelKeys(in: data)
        _ = try JSONSerialization.jsonObject(with: data, options: [])
        return try JSONDecoder().decode(BirthCertificate.self, from: data)
    }

    public func verifyHKDFDomainVersion() throws {
        try Self.validateHKDFDomainVersion(hkdfDomainVersion)
    }

    public static func validateOperatorID(_ operatorID: String) throws -> String {
        let trimmed = operatorID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw BirthCertificateError.invalidOperatorID(reason: "empty_after_trim")
        }
        guard trimmed.utf8.count <= 192 else {
            throw BirthCertificateError.invalidOperatorID(reason: "utf8_length_exceeds_192")
        }
        if trimmed.unicodeScalars.contains(where: { ($0.value <= 0x1F) || $0.value == 0x7F }) {
            throw BirthCertificateError.invalidOperatorID(reason: "contains_control_chars")
        }
        return trimmed
    }

    private static func validateHKDFDomainVersion(_ found: String) throws {
        guard found == HKDFDomain.currentSchemaVersion else {
            throw BirthCertificateError.unsupportedHKDFDomainVersion(found: found, expected: HKDFDomain.currentSchemaVersion)
        }
    }

    private static func validateSecurityFields(hvAnchor: String, machineUUID: String) throws {
        guard hvAnchor.count <= 256 else { throw BirthCertificateDecodeError.hvAnchorTooLarge(hvAnchor.count) }
        guard !hvAnchor.isEmpty, hvAnchor.utf8.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }) else {
            throw BirthCertificateDecodeError.hvAnchorNonHex
        }
        let current = try currentMachineUUID()
        guard machineUUID.lowercased() == current.lowercased() else {
            throw BirthCertificateDecodeError.machineMismatch(expected: current, actual: machineUUID)
        }
    }

    private static func rejectDuplicateTopLevelKeys(in data: Data) throws {
        guard let s = String(data: data, encoding: .utf8) else { throw BirthCertificateDecodeError.malformedJSON("utf8") }
        var i = s.startIndex

        func skipWS() {
            while i < s.endIndex, s[i].isWhitespace { i = s.index(after: i) }
        }

        func hexValue(_ ch: Character) throws -> UInt32 {
            guard let scalar = ch.unicodeScalars.first, ch.unicodeScalars.count == 1 else {
                throw BirthCertificateDecodeError.malformedJSON("bad unicode escape")
            }
            switch scalar.value {
            case 48...57: return scalar.value - 48
            case 65...70: return scalar.value - 55
            case 97...102: return scalar.value - 87
            default: throw BirthCertificateDecodeError.malformedJSON("bad unicode escape")
            }
        }

        func parseUnicodeUnit() throws -> UInt32 {
            var value: UInt32 = 0
            for _ in 0..<4 {
                guard i < s.endIndex else { throw BirthCertificateDecodeError.malformedJSON("bad unicode escape") }
                value = (value << 4) | (try hexValue(s[i]))
                i = s.index(after: i)
            }
            return value
        }

        func appendScalar(_ value: UInt32, to out: inout String) throws {
            guard let scalar = UnicodeScalar(value) else { throw BirthCertificateDecodeError.malformedJSON("bad unicode scalar") }
            out.unicodeScalars.append(scalar)
        }

        func parseUnicodeEscape(into out: inout String) throws {
            let first = try parseUnicodeUnit()
            var scalar = first
            if (0xD800...0xDBFF).contains(first) {
                guard i < s.endIndex, s[i] == "\\" else { throw BirthCertificateDecodeError.malformedJSON("missing surrogate pair") }
                i = s.index(after: i)
                guard i < s.endIndex, s[i] == "u" else { throw BirthCertificateDecodeError.malformedJSON("missing surrogate pair") }
                i = s.index(after: i)
                let second = try parseUnicodeUnit()
                guard (0xDC00...0xDFFF).contains(second) else { throw BirthCertificateDecodeError.malformedJSON("bad surrogate pair") }
                scalar = 0x10000 + (((first - 0xD800) << 10) | (second - 0xDC00))
            } else if (0xDC00...0xDFFF).contains(first) {
                throw BirthCertificateDecodeError.malformedJSON("bad surrogate pair")
            }
            try appendScalar(scalar, to: &out)
        }

        func canonicalKey(_ key: String) -> String {
            let scalars = Array(key.unicodeScalars)
            guard !scalars.isEmpty, scalars.allSatisfy({ $0.value <= 0xFF }) else { return key }
            let bytes = scalars.map { UInt8($0.value) }
            guard let redecoded = String(data: Data(bytes), encoding: .utf8) else { return key }
            return redecoded
        }

        func parseString() throws -> String {
            guard i < s.endIndex, s[i] == "\"" else { throw BirthCertificateDecodeError.malformedJSON("expected string") }
            i = s.index(after: i)
            var out = ""
            while i < s.endIndex {
                let ch = s[i]
                i = s.index(after: i)
                if ch == "\"" { return out }
                if ch == "\\" {
                    guard i < s.endIndex else { throw BirthCertificateDecodeError.malformedJSON("bad escape") }
                    let esc = s[i]
                    i = s.index(after: i)
                    switch esc {
                    case "\"": out.append("\"")
                    case "\\": out.append("\\")
                    case "/": out.append("/")
                    case "b": out.append("\u{08}")
                    case "f": out.append("\u{0c}")
                    case "n": out.append("\n")
                    case "r": out.append("\r")
                    case "t": out.append("\t")
                    case "u": try parseUnicodeEscape(into: &out)
                    default: throw BirthCertificateDecodeError.malformedJSON("bad escape")
                    }
                } else {
                    if ch.unicodeScalars.contains(where: { $0.value < 0x20 }) {
                        throw BirthCertificateDecodeError.malformedJSON("raw control")
                    }
                    out.append(ch)
                }
            }
            throw BirthCertificateDecodeError.malformedJSON("unterminated string")
        }

        func skipObject() throws {
            i = s.index(after: i)
            skipWS()
            if i < s.endIndex, s[i] == "}" { i = s.index(after: i); return }
            while i < s.endIndex {
                _ = try parseString()
                skipWS()
                guard i < s.endIndex, s[i] == ":" else { throw BirthCertificateDecodeError.malformedJSON("expected colon") }
                i = s.index(after: i)
                try skipValue()
                skipWS()
                if i < s.endIndex, s[i] == "," { i = s.index(after: i); skipWS(); continue }
                if i < s.endIndex, s[i] == "}" { i = s.index(after: i); return }
                throw BirthCertificateDecodeError.malformedJSON("expected object delimiter")
            }
            throw BirthCertificateDecodeError.malformedJSON("unterminated object")
        }

        func skipArray() throws {
            i = s.index(after: i)
            skipWS()
            if i < s.endIndex, s[i] == "]" { i = s.index(after: i); return }
            while i < s.endIndex {
                try skipValue()
                skipWS()
                if i < s.endIndex, s[i] == "," { i = s.index(after: i); skipWS(); continue }
                if i < s.endIndex, s[i] == "]" { i = s.index(after: i); return }
                throw BirthCertificateDecodeError.malformedJSON("expected array delimiter")
            }
            throw BirthCertificateDecodeError.malformedJSON("unterminated array")
        }

        func skipValue() throws {
            skipWS()
            guard i < s.endIndex else { throw BirthCertificateDecodeError.malformedJSON("missing value") }
            if s[i] == "\"" { _ = try parseString(); return }
            if s[i] == "{" { try skipObject(); return }
            if s[i] == "[" { try skipArray(); return }
            let start = i
            while i < s.endIndex, s[i] != ",", s[i] != "}", s[i] != "]", !s[i].isWhitespace {
                i = s.index(after: i)
            }
            guard i > start else { throw BirthCertificateDecodeError.malformedJSON("bad value") }
        }

        skipWS()
        guard i < s.endIndex, s[i] == "{" else { throw BirthCertificateDecodeError.malformedJSON("expected object") }
        i = s.index(after: i)
        var seen = Set<String>()
        skipWS()
        while i < s.endIndex, s[i] != "}" {
            let key = canonicalKey(try parseString())
            guard seen.insert(key).inserted else { throw BirthCertificateDecodeError.duplicateKey(key) }
            skipWS()
            guard i < s.endIndex, s[i] == ":" else { throw BirthCertificateDecodeError.malformedJSON("expected colon") }
            i = s.index(after: i)
            try skipValue()
            skipWS()
            if i < s.endIndex, s[i] == "," { i = s.index(after: i); skipWS(); continue }
            if i < s.endIndex, s[i] == "}" { break }
            throw BirthCertificateDecodeError.malformedJSON("expected object delimiter")
        }
        guard i < s.endIndex, s[i] == "}" else { throw BirthCertificateDecodeError.malformedJSON("unterminated object") }
        i = s.index(after: i)
        skipWS()
        guard i == s.endIndex else { throw BirthCertificateDecodeError.malformedJSON("trailing data") }
    }

    public var canonicalPayloadData: Data {
        let object: [String: String] = [
            "cold_root_public_key": coldRootPublicKeyHex,
            "hkdf_domain_version": hkdfDomainVersion,
            "hv_anchor": hvAnchor,
            "machine_uuid": machineUUID,
            "operator_id": operatorID,
            "operator_voice_anchor_sha256": operatorVoiceAnchorSHA256Hex,
            "se_key_id": seKeyID,
            "se_pubkey": sePublicKeyBase64,
            "soul_anchor_pub": soulAnchorPublicKeyHex,
            "subject_id": subjectID,
            "timestamp": timestamp,
            "v": version,
            "values_hash_via_CharacterValues": valuesHashViaCharacterValues,
        ]
        let fields = object.keys.sorted().map { key in
            "\"\(Self.escape(key))\":\"\(Self.escape(object[key] ?? ""))\""
        }.joined(separator: ",")
        return Data(("{" + fields + "}").utf8)
    }

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    private static func escape(_ value: String) -> String {
        var out = ""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }
}

public func currentMachineUUID() throws -> String {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
    guard service != 0 else { throw BirthCertificateDecodeError.machineUUIDUnavailable }
    defer { IOObjectRelease(service) }
    guard let uuid = IORegistryEntryCreateCFProperty(service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String,
          !uuid.isEmpty else { throw BirthCertificateDecodeError.machineUUIDUnavailable }
    return uuid.lowercased()
}

public struct USBDeviceCertificate: Codable, Equatable {
    public let version: String
    public let volumeUUID: String
    public let bsdName: String
    public let vendorString: String
    public let modelString: String
    public let ceremonyID: String
    public let writeProtectState: String
    public let createdAtUnix: Int64
    public let signatureHex: String

    public init(version: String = "jarvis-usb-device-certificate-1",
                volumeUUID: String,
                bsdName: String,
                vendorString: String,
                modelString: String,
                ceremonyID: String,
                writeProtectState: String,
                createdAtUnix: Int64 = Int64(Date().timeIntervalSince1970),
                signatureHex: String = "") {
        self.version = version
        self.volumeUUID = volumeUUID
        self.bsdName = bsdName
        self.vendorString = vendorString
        self.modelString = modelString
        self.ceremonyID = ceremonyID
        self.writeProtectState = writeProtectState
        self.createdAtUnix = createdAtUnix
        self.signatureHex = signatureHex
    }

    public var canonicalPayloadData: Data {
        let object: [String: String] = [
            "bsd_name": bsdName,
            "ceremony_id": ceremonyID,
            "created_at_unix": String(createdAtUnix),
            "model_string": modelString,
            "v": version,
            "vendor_string": vendorString,
            "volume_uuid": volumeUUID,
            "write_protect_state": writeProtectState,
        ]
        let fields = object.keys.sorted().map { key in
            "\"\(key)\":\"\(object[key]?.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") ?? "")\""
        }.joined(separator: ",")
        return Data(("{" + fields + "}").utf8)
    }

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

public struct CeremonyCommitRecord: Codable, Equatable {
    public let version: Int
    public let ceremonyHash: String
    public let voiceAnchorSHA256: String
    public let voiceAnchorNonceHex: String?
    public let sealedCertSHA256: String
    public let anchorRootSHA256: String
    public let auditAnchorSHA256: String
    public let consumedChallengesInitialSHA256: String
    public let sealedCertPath: String
    public let writtenAtUnix: Int64
    public let ceremonyID: String

    public init(version: Int = 2, ceremonyHash: String, voiceAnchorSHA256: String, voiceAnchorNonceHex: String? = nil, sealedCertSHA256: String, anchorRootSHA256: String, auditAnchorSHA256: String, consumedChallengesInitialSHA256: String, sealedCertPath: String, writtenAtUnix: Int64 = Int64(Date().timeIntervalSince1970), ceremonyID: String) {
        self.version = version
        self.ceremonyHash = ceremonyHash
        self.voiceAnchorSHA256 = voiceAnchorSHA256
        self.voiceAnchorNonceHex = voiceAnchorNonceHex
        self.sealedCertSHA256 = sealedCertSHA256
        self.anchorRootSHA256 = anchorRootSHA256
        self.auditAnchorSHA256 = auditAnchorSHA256
        self.consumedChallengesInitialSHA256 = consumedChallengesInitialSHA256
        self.sealedCertPath = sealedCertPath
        self.writtenAtUnix = writtenAtUnix
        self.ceremonyID = ceremonyID
    }

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

public struct CeremonyArtifacts {
    public let certificate: BirthCertificate
    public let mnemonic: SecureMnemonic
    public let ceremonyHash: String
    public let usbCertificateURL: URL
    public let localSealedBackupURL: URL
    public let localPlainJsonURL: URL
}

public enum CeremonyIntegrityError: Error, CustomStringConvertible, Equatable {
    case sealedCertWithoutCommit(String)
    case commitWithoutSealedCert(String)
    case commitHashMismatch(expected: String, actual: String)
    case commitRecordObsolete(Int)
    case unsupportedCommitVersion(Int)
    case interruptedCeremonyRecovery(String)

    public var description: String {
        switch self {
        case .sealedCertWithoutCommit(let path): return "JARVIS found a sealed birth certificate without a commit record at \(path). Operator recovery authorization is required."
        case .commitWithoutSealedCert(let path): return "JARVIS found a commit record without its sealed birth certificate at \(path). Operator recovery authorization is required."
        case .commitHashMismatch(let expected, let actual): return "JARVIS refused launch: commit record hash mismatch. expected=\(expected) actual=\(actual). Operator recovery authorization is required."
        case .commitRecordObsolete(let version): return "JARVIS refused launch: obsolete ceremony commit record version \(version). Re-run the ceremony to bind all trust files."
        case .unsupportedCommitVersion(let version): return "JARVIS refused launch: unsupported ceremony commit record version \(version). Operator recovery authorization is required."
        case .interruptedCeremonyRecovery(let path): return "JARVIS found an interrupted ceremony lock at \(path). Clear partial state only with explicit operator authorization."
        }
    }
}

public enum CeremonyAbortReason: Equatable, CustomStringConvertible, Sendable {
    case soulAnchorIssuanceFailed(reason: String)
    case soulAnchorAlreadyPresent

    public var description: String {
        switch self {
        case .soulAnchorIssuanceFailed(let reason): return "Soul Anchor key issuance failed: \(reason)"
        case .soulAnchorAlreadyPresent: return "Soul Anchor key already exists; refusing overwrite"
        }
    }
}

public struct CeremonyAbortedError: Error, Equatable, CustomStringConvertible {
    public let reason: CeremonyAbortReason
    public init(_ reason: CeremonyAbortReason) { self.reason = reason }
    public var description: String { "JARVIS ceremony aborted: \(reason.description)" }
}

public enum CeremonyError: Error, CustomStringConvertible, Equatable {
    case aborted(CeremonyAbortedError)
    case alreadyAnchored(String)
    case alreadyInProgress(String)
    case missingVoiceAnchor(String)
    case integrity(CeremonyIntegrityError)
    case usbIdentityChanged(expected: String, actual: String)
    case secureEnclaveUnavailable(String)
    case noUSBSelected
    case usbNotConfirmed
    case paperBackupNotConfirmed
    case operatorIDMissing
    case writeRefused(String)
    case crypto(String)
    case characterValues(String)
    case verificationFailed
    case transactionFailed(String)

    public var description: String {
        switch self {
        case .aborted(let e): return e.description
        case .alreadyAnchored(let p): return "JARVIS is already anchored at \(p). Re-anchor requires operator-attestation through cockpit."
        case .alreadyInProgress(let p): return "JARVIS ceremony already in progress; lock held at \(p)."
        case .missingVoiceAnchor(let m): return "JARVIS requires the operator voice anchor before binding identity: \(m)"
        case .integrity(let e): return e.description
        case .usbIdentityChanged(let expected, let actual): return "USB identity changed during ceremony. expected=\(expected) actual=\(actual). Staging left for forensic review."
        case .secureEnclaveUnavailable(let m): return "Secure Enclave unavailable: \(m)"
        case .noUSBSelected: return "No operator-confirmed USB cold vault selected."
        case .usbNotConfirmed: return "USB wipe/use checkbox is not confirmed."
        case .paperBackupNotConfirmed: return "Paper backup was not confirmed; ceremony cannot complete."
        case .operatorIDMissing: return "Operator ID is required before the birth ceremony can fire."
        case .writeRefused(let p): return "Refusing write outside ceremony allow-list: \(p)"
        case .crypto(let m): return m
        case .characterValues(let m): return m
        case .verificationFailed: return "Birth certificate signature verification failed."
        case .transactionFailed(let m): return m
        }
    }
}
