import CryptoKit
import Foundation
import IOKit

struct NativeBirthCertificateVerification: Equatable {
    enum Result: Equatable {
        case verified
        case missing
        case invalidSignature
        case malformed
    }

    let result: Result
    let path: String
    let reason: String
}

enum NativeBirthCertificateVerifier {
    static func verify(env: [String: String] = ProcessInfo.processInfo.environment) -> NativeBirthCertificateVerification {
        let url = birthCertificateURL(env: env)
        let path = url.path
        guard FileManager.default.fileExists(atPath: path) else {
            return NativeBirthCertificateVerification(result: .missing, path: path, reason: "birth certificate not found")
        }

        do {
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            let certificate = try JSONDecoder().decode(NativeBirthCertificate.self, from: data)
            guard let signature = Data(hexString: certificate.signatureHex),
                  let publicKeyData = Data(hexString: certificate.coldRootPublicKeyHex) else {
                return NativeBirthCertificateVerification(result: .malformed, path: path, reason: "signatureHex or coldRootPublicKeyHex is not valid hex")
            }
            guard signature.count == 64, publicKeyData.count == 32 else {
                return NativeBirthCertificateVerification(result: .malformed, path: path, reason: "signature or cold root public key has invalid length")
            }
            guard let currentMachineUUID = currentMachineUUID()?.lowercased() else {
                return NativeBirthCertificateVerification(result: .malformed, path: path, reason: "current machine UUID unavailable")
            }
            guard certificate.machineUUID.lowercased() == currentMachineUUID else {
                return NativeBirthCertificateVerification(result: .invalidSignature, path: path, reason: "birth certificate machineUUID does not match this host")
            }
            let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)
            guard publicKey.isValidSignature(signature, for: certificate.canonicalPayloadData) else {
                return NativeBirthCertificateVerification(result: .invalidSignature, path: path, reason: "signatureHex does not verify against coldRootPublicKeyHex")
            }
            return NativeBirthCertificateVerification(result: .verified, path: path, reason: "verified")
        } catch DecodingError.dataCorrupted,
                DecodingError.keyNotFound,
                DecodingError.typeMismatch,
                DecodingError.valueNotFound {
            return NativeBirthCertificateVerification(result: .malformed, path: path, reason: "birth certificate JSON does not match expected schema")
        } catch {
            return NativeBirthCertificateVerification(result: .malformed, path: path, reason: error.localizedDescription)
        }
    }

    private static func birthCertificateURL(env: [String: String]) -> URL {
        if let rawPath = env["JARVIS_BIRTH_CERT_PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines), !rawPath.isEmpty {
            return URL(fileURLWithPath: expandHome(rawPath)).standardizedFileURL
        }
        return URL(fileURLWithPath: expandHome("~/.jarvis/identity/birth_certificate.json")).standardizedFileURL
    }

    private static func expandHome(_ path: String) -> String {
        guard path == "~" || path.hasPrefix("~/") else { return path }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard path.count > 1 else { return home }
        let suffix = path.dropFirst(2)
        return URL(fileURLWithPath: home).appendingPathComponent(String(suffix)).path
    }

    private static func currentMachineUUID() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let uuid = IORegistryEntryCreateCFProperty(service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String,
              !uuid.isEmpty else { return nil }
        return uuid
    }
}

private struct NativeBirthCertificate: Decodable, Equatable {
    let version: String
    let timestamp: String
    let machineUUID: String
    let sePublicKeyBase64: String
    let seKeyID: String
    let valuesHashViaCharacterValues: String
    let hvAnchor: String
    let coldRootPublicKeyHex: String
    let soulAnchorPublicKeyHex: String
    let operatorVoiceAnchorSHA256Hex: String
    let operatorID: String
    let subjectID: String
    let signatureHex: String

    private enum CodingKeys: String, CodingKey {
        case version
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

    var canonicalPayloadData: Data {
        let object: [String: String] = [
            "cold_root_public_key": coldRootPublicKeyHex,
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

private extension Data {
    init?(hexString: String) {
        let trimmed = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count.isMultiple(of: 2) else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(trimmed.count / 2)
        var index = trimmed.startIndex
        while index < trimmed.endIndex {
            let next = trimmed.index(index, offsetBy: 2)
            guard let byte = UInt8(trimmed[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self = Data(bytes)
    }
}
