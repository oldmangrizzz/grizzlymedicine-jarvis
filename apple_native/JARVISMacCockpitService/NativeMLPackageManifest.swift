// NativeMLPackageManifest — V4R R11d F-C04
//
// Adjacent signed manifest for CoreML mlpackage compile integrity.
//
// Design rationale (operator-approved deviation from prompt-as-written):
//   The prompt called for an `mlpackage_sha256_hex` field embedded in the
//   birth certificate. The BC struct in JARVISCeremonyCore is strict-decoded
//   (rejects unknown top-level keys) and version-gated via HKDFDomain —
//   adding a field requires a schema migration touching multiple test
//   fixtures across both modules. Cutover at the eleventh hour before
//   birth ceremony carries process risk.
//
//   Adjacent-manifest design preserves identical tamper-detection guarantees
//   (manifest is signed by the same cold root key referenced by the BC) with
//   zero BC-schema churn. Trade-off: two artifacts on disk instead of one.
//
// File layout: ~/.jarvis/identity/mlpackage_manifest.json (mode 0600)
// Override:    $JARVIS_MLPACKAGE_MANIFEST_PATH (gated by JARVIS_INSECURE_PATHS)
//
// Manifest format (canonical sorted-keys JSON, all values strings):
//   {
//     "machine_uuid":        "<host IOPlatformUUID>",
//     "mlpackage_sha256_hex": "<sorted-keys JSON of {absPath: 64hex} map>",
//     "signature_hex":       "<128 hex chars = Ed25519 over canonical sans signature_hex>",
//     "timestamp":           "<ISO8601>",
//     "v":                   "jarvis-mlpackage-manifest-1"
//   }
//
// Tree hash algorithm (computeTreeHash):
//   For each regular file under root, sorted by UTF-8 byte order of
//   relative-path:
//     h.update(relativePath bytes)
//     h.update([0x00])
//     h.update(SHA-256(file content))
//     h.update([0x00])
//   final = SHA-256(h)  -- as hex
//
// Boot verification:
//   1. Read manifest. Absent → emit boot_mlpackage_manifest_absent_legacy
//      WARN and return .absent (caller continues — legacy pre-F-C04 BC).
//   2. Parse + canonicalize. Verify signature_hex against the cold-root
//      public key passed in by the caller (which itself comes from the
//      already-verified BC).
//   3. For each (absPath, expectedHex) in mlpackage_sha256_hex:
//      compute treeHash(absPath), compare. First mismatch → fail.

import CryptoKit
import Foundation

enum NativeMLPackageManifestResult: Equatable {
    case verified(packageCount: Int)
    case absent(path: String)             // legacy — caller continues, audits WARN
    case malformed(path: String, reason: String)
    case invalidSignature(path: String)
    case hashMismatch(packagePath: String, expected: String, actual: String)
    case unreadable(packagePath: String, reason: String)
    case machineUUIDMismatch(path: String, expected: String, actual: String)
}

enum NativeMLPackageManifest {
    static let canonicalManifestPath = "~/.jarvis/identity/mlpackage_manifest.json"
    static let manifestVersionString = "jarvis-mlpackage-manifest-1"

    /// Resolves the manifest path with env-override gating identical to other
    /// identity paths (JARVIS_INSECURE_PATHS).
    static func manifestURL(env: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let resolved = NativeInsecurePathOverride.resolve(
            envVar: "JARVIS_MLPACKAGE_MANIFEST_PATH",
            canonicalPath: canonicalManifestPath,
            env: env
        )
        return URL(fileURLWithPath: resolved).standardizedFileURL
    }

    /// Verifies the on-disk manifest. Caller supplies the cold-root public key
    /// in hex (from the BC that was already cryptographically verified by
    /// NativeBirthCertificateVerifier). The two-stage chain — BC verified →
    /// manifest signature verified — keeps the trust anchor singular while
    /// allowing the manifest to be re-signed without re-running the whole
    /// birth ceremony.
    static func verify(
        coldRootPublicKeyHex: String,
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> NativeMLPackageManifestResult {
        let url = manifestURL(env: env)
        let path = url.path

        guard FileManager.default.fileExists(atPath: path) else {
            return .absent(path: path)
        }

        let raw: Data
        do { raw = try Data(contentsOf: url, options: [.mappedIfSafe]) }
        catch { return .malformed(path: path, reason: "read: \(error.localizedDescription)") }

        let parsed: [String: Any]
        do {
            guard let o = try JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
                return .malformed(path: path, reason: "not a JSON object")
            }
            parsed = o
        } catch {
            return .malformed(path: path, reason: "json: \(error.localizedDescription)")
        }

        guard let v = parsed["v"] as? String, v == manifestVersionString else {
            return .malformed(path: path, reason: "unsupported manifest version: \(parsed["v"] ?? "<missing>")")
        }
        guard let timestamp = parsed["timestamp"] as? String, !timestamp.isEmpty else {
            return .malformed(path: path, reason: "missing timestamp")
        }
        guard let machineUUID = parsed["machine_uuid"] as? String, !machineUUID.isEmpty else {
            return .malformed(path: path, reason: "missing machine_uuid")
        }
        guard let innerMapString = parsed["mlpackage_sha256_hex"] as? String else {
            return .malformed(path: path, reason: "missing mlpackage_sha256_hex (must be canonical JSON string)")
        }
        guard let signatureHex = parsed["signature_hex"] as? String, signatureHex.count == 128 else {
            return .malformed(path: path, reason: "missing/short signature_hex")
        }

        // Machine binding check — the manifest is tied to the host it was
        // signed for, mirroring the BC's machineUUID discipline.
        if let host = currentMachineUUID(), host.lowercased() != machineUUID.lowercased() {
            return .machineUUIDMismatch(path: path, expected: machineUUID, actual: host)
        }

        // Canonical payload for signature verification: same field set sans
        // signature_hex, sorted-keys, escape rules below.
        let canonical = canonicalPayloadString(
            machineUUID: machineUUID,
            mlpackageSHA256HexString: innerMapString,
            timestamp: timestamp,
            version: v
        )
        let canonicalData = Data(canonical.utf8)

        guard
            let pubKeyData = Data(hexString: coldRootPublicKeyHex),
            let pubKey = try? Curve25519.Signing.PublicKey(rawRepresentation: pubKeyData),
            let sigData = Data(hexString: signatureHex)
        else {
            return .malformed(path: path, reason: "cold root public key or signature hex is malformed")
        }
        guard pubKey.isValidSignature(sigData, for: canonicalData) else {
            return .invalidSignature(path: path)
        }

        // Parse the inner map after signature verification (parsing it earlier
        // would risk denial-of-service via attacker-controlled inputs before
        // the trust gate).
        guard
            let innerData = innerMapString.data(using: .utf8),
            let innerObj = try? JSONSerialization.jsonObject(with: innerData) as? [String: String]
        else {
            return .malformed(path: path, reason: "mlpackage_sha256_hex is not a {string:string} JSON object")
        }

        for (packagePath, expectedHex) in innerObj.sorted(by: { $0.key < $1.key }) {
            let normalized = NSString(string: packagePath).expandingTildeInPath
            let computed: String
            do {
                computed = try computeTreeHash(at: URL(fileURLWithPath: normalized))
            } catch {
                return .unreadable(packagePath: packagePath, reason: error.localizedDescription)
            }
            if computed.lowercased() != expectedHex.lowercased() {
                return .hashMismatch(packagePath: packagePath, expected: expectedHex, actual: computed)
            }
        }

        return .verified(packageCount: innerObj.count)
    }

    /// Recursive sorted-paths SHA-256 over a directory tree.
    /// Test-callable and reused by manifest minters in fixtures.
    static func computeTreeHash(at root: URL) throws -> String {
        var fileEntries: [(relativePath: String, contentHash: SHA256.Digest)] = []
        let rootPath = root.standardizedFileURL.path

        let isDir: Bool = (try? root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        if isDir {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                throw NSError(domain: "NativeMLPackageManifest", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "could not enumerate \(rootPath)"])
            }
            while let item = enumerator.nextObject() as? URL {
                let isRegular = (try? item.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
                guard isRegular else { continue }
                let full = item.standardizedFileURL.path
                guard full.hasPrefix(rootPath + "/") || full == rootPath else { continue }
                let rel = String(full.dropFirst(rootPath.count + 1))
                let body = try Data(contentsOf: item, options: [.mappedIfSafe])
                fileEntries.append((rel, SHA256.hash(data: body)))
            }
        } else {
            // Plain file path: treat as a single-entry tree keyed by basename.
            let body = try Data(contentsOf: root, options: [.mappedIfSafe])
            fileEntries.append((root.lastPathComponent, SHA256.hash(data: body)))
        }

        fileEntries.sort { $0.relativePath < $1.relativePath }
        var hasher = SHA256()
        for entry in fileEntries {
            hasher.update(data: Data(entry.relativePath.utf8))
            hasher.update(data: Data([0x00]))
            hasher.update(data: Data(entry.contentHash))
            hasher.update(data: Data([0x00]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Canonical payload string for signature: sorted-keys, JSON-escaped
    /// string values, no nested-object literal — `mlpackage_sha256_hex` is
    /// pre-canonicalized to a JSON string by the caller / minter.
    /// This is the EXACT byte sequence signed and verified.
    static func canonicalPayloadString(
        machineUUID: String,
        mlpackageSHA256HexString: String,
        timestamp: String,
        version: String
    ) -> String {
        let fields: [String: String] = [
            "machine_uuid": machineUUID,
            "mlpackage_sha256_hex": mlpackageSHA256HexString,
            "timestamp": timestamp,
            "v": version,
        ]
        let body = fields.keys.sorted().map { key in
            "\"\(escape(key))\":\"\(escape(fields[key] ?? ""))\""
        }.joined(separator: ",")
        return "{" + body + "}"
    }

    /// Deterministic stringification of an [absPath: hex] map for use as the
    /// `mlpackage_sha256_hex` field value in the canonical payload.
    static func canonicalizeMLPackageMap(_ map: [String: String]) -> String {
        let body = map.keys.sorted().map { key in
            "\"\(escape(key))\":\"\(escape(map[key] ?? ""))\""
        }.joined(separator: ",")
        return "{" + body + "}"
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

    private static func currentMachineUUID() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let uuid = IORegistryEntryCreateCFProperty(service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String,
              !uuid.isEmpty else { return nil }
        return uuid
    }
}

import IOKit

private extension Data {
    init?(hexString: String) {
        let trimmed = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count.isMultiple(of: 2) else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(trimmed.count / 2)
        var idx = trimmed.startIndex
        while idx < trimmed.endIndex {
            let next = trimmed.index(idx, offsetBy: 2)
            guard let byte = UInt8(trimmed[idx..<next], radix: 16) else { return nil }
            bytes.append(byte)
            idx = next
        }
        self = Data(bytes)
    }
}
