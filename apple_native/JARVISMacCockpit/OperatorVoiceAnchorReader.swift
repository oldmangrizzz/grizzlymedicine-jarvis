// OperatorVoiceAnchorReader.swift
//
// Reads the operator-attested voice anchor SHA-256 from the birth certificate
// JSON for use as the loadtime integrity baseline of `voice_state.bin`
// (V4R R8 — closes the tamper window between the C++ mount tripwire and the
// Swift Float projection).
//
// Signature verification is NOT performed here — by the time
// `NativeVoiceCapture.synthesize` calls this, the C++ runtime has already
// verified the BC signature at startup (`verifyVoiceTripwireOrThrow`) and
// the Swift HTTP listener has done the same
// (`NativeRuntimeHTTPService.verifyBirthCertOrThrow`). This reader only
// extracts the already-trusted anchor value. AGENTS.md §1: no silent
// fallback — every error path throws.

import Foundation

enum OperatorVoiceAnchorReaderError: Error, LocalizedError {
    case birthCertMissing(path: String)
    case birthCertUnreadable(path: String, reason: String)
    case birthCertMalformed(path: String, reason: String)
    case anchorEmpty(path: String)
    case anchorMalformed(path: String, value: String)

    var errorDescription: String? {
        switch self {
        case .birthCertMissing(let p): return "Birth certificate not found at \(p)"
        case .birthCertUnreadable(let p, let r): return "Birth certificate at \(p) unreadable: \(r)"
        case .birthCertMalformed(let p, let r): return "Birth certificate at \(p) malformed: \(r)"
        case .anchorEmpty(let p): return "operatorVoiceAnchorSHA256Hex empty in \(p) — operator must complete voice anchor ceremony before runtime can load voice_state"
        case .anchorMalformed(let p, let v): return "operatorVoiceAnchorSHA256Hex in \(p) is not a 64-char lowercase hex SHA-256: \(v.prefix(16))…"
        }
    }
}

enum OperatorVoiceAnchorReader {
    /// Reads the BC at `JARVIS_BIRTH_CERT_PATH` (env override) or
    /// `~/.jarvis/identity/birth_certificate.json` and returns the
    /// `operatorVoiceAnchorSHA256Hex` field, lowercased. Throws on any
    /// missing/empty/malformed condition — never returns a default.
    static func read(env: [String: String] = ProcessInfo.processInfo.environment) throws -> String {
        let url = birthCertificateURL(env: env)
        let path = url.path
        guard FileManager.default.fileExists(atPath: path) else {
            throw OperatorVoiceAnchorReaderError.birthCertMissing(path: path)
        }
        let data: Data
        do {
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw OperatorVoiceAnchorReaderError.birthCertUnreadable(path: path, reason: error.localizedDescription)
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw OperatorVoiceAnchorReaderError.birthCertMalformed(path: path, reason: error.localizedDescription)
        }
        guard let dict = object as? [String: Any] else {
            throw OperatorVoiceAnchorReaderError.birthCertMalformed(path: path, reason: "top-level value is not a JSON object")
        }
        guard let rawAnchor = dict["operatorVoiceAnchorSHA256Hex"] as? String else {
            throw OperatorVoiceAnchorReaderError.birthCertMalformed(path: path, reason: "operatorVoiceAnchorSHA256Hex field absent or non-string")
        }
        let anchor = rawAnchor.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if anchor.isEmpty {
            throw OperatorVoiceAnchorReaderError.anchorEmpty(path: path)
        }
        guard anchor.count == 64, anchor.allSatisfy({ ("0"..."9").contains($0) || ("a"..."f").contains($0) }) else {
            throw OperatorVoiceAnchorReaderError.anchorMalformed(path: path, value: anchor)
        }
        return anchor
    }

    private static func birthCertificateURL(env: [String: String]) -> URL {
        // R11d F-C02: env override gated behind compile flag via the shared
        // NativeInsecurePathOverride helper. JARVIS_BIRTH_CERTIFICATE_PATH
        // (the alternate spelling) is preserved through the same gate for
        // backward-compat with existing test harnesses.
        #if DEBUG && JARVIS_INSECURE_PATHS
        if let rawPath = env["JARVIS_BIRTH_CERT_PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines), !rawPath.isEmpty {
            return URL(fileURLWithPath: expandHome(rawPath)).standardizedFileURL
        }
        if let rawPath = env["JARVIS_BIRTH_CERTIFICATE_PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines), !rawPath.isEmpty {
            return URL(fileURLWithPath: expandHome(rawPath)).standardizedFileURL
        }
        #endif
        return URL(fileURLWithPath: expandHome("~/.jarvis/identity/birth_certificate.json")).standardizedFileURL
    }

    private static func expandHome(_ path: String) -> String {
        guard path == "~" || path.hasPrefix("~/") else { return path }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard path.count > 1 else { return home }
        let suffix = path.dropFirst(2)
        return URL(fileURLWithPath: home).appendingPathComponent(String(suffix)).path
    }
}
