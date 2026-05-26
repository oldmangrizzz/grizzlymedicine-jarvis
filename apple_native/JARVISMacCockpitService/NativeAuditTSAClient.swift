// NativeAuditTSAClient — V4R R11h F-E13
//
// RFC 3161 Time-Stamp Protocol client. Submits the SHA-256 of each
// audit_chain_boot_anchor record to one or more external TSAs and
// stores the resulting timeStampTokens side-by-side with the audit log.
// This adds *external* timestamp evidence on top of the audit chain so
// that a uid=operator attacker who rewrites the entire chain (R11e
// class-A2) cannot also forge a TSA receipt — the TSA's private key
// lives outside this machine and the receipt cryptographically binds
// the anchor's SHA-256 to a specific wall-clock instant.
//
// Threat model addressed:
//   - Total-chain-rewrite (R11e A2): attacker recomputes the entire
//     audit chain with their preferred events. With F-D01 they need
//     the aux signing key; with F-E13 they additionally need to forge
//     a third-party TSA signature OR re-submit their forged anchors
//     to live TSAs (whose timestamps will be hours/days off the
//     original boot time, immediately visible to the verifier).
//   - Replay (R11e cross-cut): an attacker who can replay an old
//     valid anchor record into the chain will see the TSA receipt
//     reference the old `tsNow` — verifier flags the gap.
//
// Design constraints:
//   - Boot-path call site is SYNCHRONOUS. URLSession is async. We
//     bridge with DispatchSemaphore + a hard 3s wall-clock timeout
//     per TSA. Boot never blocks longer than (timeout × tsa_count).
//   - Audit chain records are bounded to 512 bytes (F-C03). TSA
//     receipts are 4-8 KB. They CANNOT live inline. They live at
//     ~/.jarvis/audit/tsa/<anchor_sha>-<tsa_name>.der and the
//     audit-chain record is unchanged from R11f. The verifier walks
//     both files and binds them by anchor_sha.
//   - Configuration is OPT-IN. If ~/.jarvis/identity/tsa_urls.json
//     is absent, TSA submission is a no-op. The ceremony writes the
//     config; running without it produces no pending files, no
//     receipts, and no audit-chain difference. This keeps unit tests
//     hermetic and makes the cockpit boot in fully air-gapped
//     environments. Operators who require TSA evidence MUST write the
//     config during the ceremony.
//   - Hand-rolled DER. RFC 3161 TimeStampReq is small enough (~70 B)
//     that bringing in a full ASN.1 dependency is excessive and would
//     widen the supply-chain surface (R11g F-E16).
//
// Configuration format (~/.jarvis/identity/tsa_urls.json, mode 0600):
//   {
//     "tsas": [
//       {"name": "freetsa", "url": "https://freetsa.org/tsr"},
//       {"name": "digicert", "url": "http://timestamp.digicert.com"}
//     ],
//     "timeout_seconds": 3
//   }
//
// Pending retry queue:
//   On per-TSA failure (network, timeout, malformed response, status
//   != granted), the client records ~/.jarvis/audit/pending_tsa/
//   <anchor_sha>.json listing which TSAs failed. NativeAuditTSAClient.
//   retryPending() walks the queue and retries; called explicitly by
//   the cockpit on next boot before sealBootAnchor emits a new anchor.

import CryptoKit
import Foundation
import os

enum NativeAuditTSAClientError: Error, LocalizedError {
    case configMalformed(path: String, reason: String)
    case configBadMode(path: String, mode: UInt16)
    case derEncodingFailed(reason: String)
    case responseParseFailed(reason: String)
    case responseStatusNotGranted(status: Int)
    case networkFailure(tsa: String, underlying: String)
    /// R11j F-F05 — TSA response's TSTInfo did not bind to the
    /// imprint/nonce we submitted. Indicates substitution or replay.
    case responseBindingMismatch(reason: String)

    var errorDescription: String? {
        switch self {
        case .configMalformed(let p, let r): return "TSA config at \(p) malformed: \(r)"
        case .configBadMode(let p, let m): return "TSA config at \(p) has insecure mode \(String(format: "%o", m)); require 0600"
        case .derEncodingFailed(let r): return "TSA DER encoding failed: \(r)"
        case .responseParseFailed(let r): return "TSA response parse failed: \(r)"
        case .responseStatusNotGranted(let s): return "TSA PKIStatus \(s) (not granted)"
        case .networkFailure(let t, let u): return "TSA \(t) network: \(u)"
        case .responseBindingMismatch(let r): return "TSA response binding mismatch: \(r)"
        }
    }
}

enum NativeAuditTSAClient {
    static let canonicalConfigPath = "~/.jarvis/identity/tsa_urls.json"
    static let canonicalReceiptDir = "~/.jarvis/audit/tsa"
    static let canonicalPendingDir = "~/.jarvis/audit/pending_tsa"
    static let defaultTimeoutSeconds: TimeInterval = 3.0

    struct TSAEndpoint: Codable, Equatable {
        let name: String
        let url: String
    }

    struct Config: Codable {
        let tsas: [TSAEndpoint]
        let timeoutSeconds: TimeInterval?
        enum CodingKeys: String, CodingKey {
            case tsas
            case timeoutSeconds = "timeout_seconds"
        }
    }

    // MARK: - Public entry points

    /// Submit `anchorShaHex` to every configured TSA and persist any
    /// returned timeStampTokens to ~/.jarvis/audit/tsa/. Failures are
    /// recorded to ~/.jarvis/audit/pending_tsa/ for later retry. No
    /// throws — boot must not abort on TSA failure.
    static func submit(
        anchorShaHex: String,
        env: [String: String] = ProcessInfo.processInfo.environment,
        urlSession: URLSession = .shared
    ) {
        let cfg: Config
        do {
            guard let loaded = try loadConfig(env: env) else { return }
            cfg = loaded
        } catch {
            NativeSecurityAudit.tryRecord("tsa_config_invalid", fields: ["reason": "\(error)"])
            return
        }
        let timeout = cfg.timeoutSeconds ?? defaultTimeoutSeconds
        guard let imprint = hexToBytes(anchorShaHex), imprint.count == 32 else {
            NativeSecurityAudit.tryRecord("tsa_submit_bad_anchor_sha", fields: ["anchor_sha": anchorShaHex])
            return
        }
        var failures: [String] = []
        for tsa in cfg.tsas {
            do {
                let token = try submitOne(
                    imprint: imprint,
                    tsa: tsa,
                    timeout: timeout,
                    urlSession: urlSession
                )
                try writeReceipt(anchorShaHex: anchorShaHex, tsaName: tsa.name, token: token, env: env)
                NativeSecurityAudit.tryRecord("tsa_receipt_stored", fields: [
                    "tsa": tsa.name,
                    "anchor_sha": anchorShaHex,
                    "bytes": String(token.count)
                ])
            } catch {
                failures.append(tsa.name)
                NativeSecurityAudit.tryRecord("tsa_submit_failed", fields: [
                    "tsa": tsa.name,
                    "anchor_sha": anchorShaHex,
                    "reason": "\(error)"
                ])
            }
        }
        if !failures.isEmpty {
            recordPending(anchorShaHex: anchorShaHex, failingTSAs: failures, env: env)
        }
    }

    /// Walk the pending_tsa directory and re-submit each entry. Removes
    /// the entry on full success. Safe to call at boot before
    /// sealBootAnchor.
    static func retryPending(
        env: [String: String] = ProcessInfo.processInfo.environment,
        urlSession: URLSession = .shared
    ) {
        let pendingDir = resolvePath(canonicalPendingDir, env: env)
        guard FileManager.default.fileExists(atPath: pendingDir),
              let entries = try? FileManager.default.contentsOfDirectory(atPath: pendingDir) else {
            return
        }
        for fname in entries where fname.hasSuffix(".json") {
            let full = pendingDir + "/" + fname
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: full)),
                  let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let anchorSha = parsed["anchor_sha"] as? String else { continue }
            submit(anchorShaHex: anchorSha, env: env, urlSession: urlSession)
            // submit() will rewrite the pending file if any TSA still
            // fails. If submit() wrote no new pending file (full
            // success), our caller can delete this one. Race-safe via
            // re-read.
            let stillPending = (try? FileManager.default.attributesOfItem(atPath: full)) != nil
            if stillPending {
                // submit() wrote a fresh pending — but our original
                // entry might list different failing tsas; the fresh
                // one supersedes. Nothing to do.
                continue
            }
        }
    }

    // MARK: - DER encoding (RFC 3161 TimeStampReq)

    /// Returns the DER-encoded TimeStampReq for the given SHA-256 imprint
    /// and 8-byte nonce. Exposed `internal` for byte-exact unit tests.
    static func encodeTimeStampReq(sha256Imprint: Data, nonce: Data) throws -> Data {
        guard sha256Imprint.count == 32 else {
            throw NativeAuditTSAClientError.derEncodingFailed(reason: "imprint must be 32 bytes, got \(sha256Imprint.count)")
        }
        guard !nonce.isEmpty, nonce.count <= 20 else {
            throw NativeAuditTSAClientError.derEncodingFailed(reason: "nonce must be 1..20 bytes, got \(nonce.count)")
        }
        // SHA-256 OID 2.16.840.1.101.3.4.2.1 pre-encoded (TLV).
        let sha256OID: [UInt8] = [0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01]
        let algId = derSequence(Data(sha256OID) + derNull())
        let imprint = derSequence(algId + derOctetString(sha256Imprint))
        let version = derInteger(1)
        let nonceTLV = derIntegerFromBytes(nonce)
        let certReq = derBoolean(true)
        return derSequence(version + imprint + nonceTLV + certReq)
    }

    // MARK: - DER parsing (RFC 3161 TimeStampResp)

    /// Parses a TimeStampResp DER blob, validates the PKIStatus, and
    /// returns the raw DER bytes of the timeStampToken (preserving the
    /// full ContentInfo SEQUENCE for later verification). Throws on
    /// malformed responses or non-granted status.
    static func parseTimeStampResp(_ data: Data) throws -> Data {
        var cursor = 0
        let outerTag = try derPeekTag(data, at: &cursor)
        guard outerTag == 0x30 else {
            throw NativeAuditTSAClientError.responseParseFailed(reason: "outer tag != SEQUENCE")
        }
        let outerLen = try derReadLength(data, at: &cursor)
        let outerEnd = cursor + outerLen
        guard outerEnd <= data.count else {
            throw NativeAuditTSAClientError.responseParseFailed(reason: "outer length exceeds buffer")
        }

        let statusTag = try derPeekTag(data, at: &cursor)
        guard statusTag == 0x30 else {
            throw NativeAuditTSAClientError.responseParseFailed(reason: "PKIStatusInfo != SEQUENCE")
        }
        let statusLen = try derReadLength(data, at: &cursor)
        let statusEnd = cursor + statusLen
        guard statusEnd <= outerEnd else {
            throw NativeAuditTSAClientError.responseParseFailed(reason: "PKIStatusInfo length escapes outer")
        }
        // First child of PKIStatusInfo is PKIStatus (INTEGER).
        let intTag = try derPeekTag(data, at: &cursor)
        guard intTag == 0x02 else {
            throw NativeAuditTSAClientError.responseParseFailed(reason: "PKIStatus != INTEGER")
        }
        let intLen = try derReadLength(data, at: &cursor)
        guard cursor + intLen <= statusEnd else {
            throw NativeAuditTSAClientError.responseParseFailed(reason: "PKIStatus length escapes parent")
        }
        var statusVal = 0
        for i in 0..<intLen {
            statusVal = (statusVal << 8) | Int(data[cursor + i])
        }
        guard statusVal == 0 || statusVal == 1 else {
            throw NativeAuditTSAClientError.responseStatusNotGranted(status: statusVal)
        }
        // Skip past PKIStatusInfo entirely.
        cursor = statusEnd
        guard cursor < outerEnd else {
            throw NativeAuditTSAClientError.responseParseFailed(reason: "timeStampToken missing despite status granted")
        }
        // Next sibling: timeStampToken (ContentInfo, SEQUENCE).
        let tokenStart = cursor
        let tokenTag = try derPeekTag(data, at: &cursor)
        guard tokenTag == 0x30 else {
            throw NativeAuditTSAClientError.responseParseFailed(reason: "timeStampToken tag != SEQUENCE")
        }
        let tokenLen = try derReadLength(data, at: &cursor)
        let tokenEnd = cursor + tokenLen
        guard tokenEnd <= outerEnd else {
            throw NativeAuditTSAClientError.responseParseFailed(reason: "timeStampToken length escapes outer")
        }
        return data.subdata(in: tokenStart..<tokenEnd)
    }

    /// R11j F-F05 — parse + bind. Returns the timeStampToken bytes
    /// after verifying that the embedded TSTInfo's messageImprint
    /// matches `expectedImprint` AND its nonce matches `expectedNonce`.
    /// Without this check, an attacker who can MITM the TSA can swap
    /// a fresh well-signed TSA token in place of one for a different
    /// (attacker-chosen) imprint/nonce — the cockpit would archive a
    /// valid-looking RFC3161 token that doesn't actually bind to the
    /// audit chain it claims to anchor.
    static func parseTimeStampResp(
        _ data: Data,
        expectedImprint: Data,
        expectedNonce: Data
    ) throws -> Data {
        let token = try parseTimeStampResp(data)
        let (imprint, nonce) = try parseTSTInfo(timeStampToken: token)
        guard imprint == expectedImprint else {
            throw NativeAuditTSAClientError.responseBindingMismatch(
                reason: "TSTInfo.messageImprint != submitted imprint (expected \(expectedImprint.count) bytes, got \(imprint.count); expected sha=\(expectedImprint.prefix(8).map { String(format: "%02x", $0) }.joined()), got=\(imprint.prefix(8).map { String(format: "%02x", $0) }.joined()))"
            )
        }
        guard nonce == expectedNonce else {
            throw NativeAuditTSAClientError.responseBindingMismatch(
                reason: "TSTInfo.nonce != submitted nonce (expected=\(expectedNonce.map { String(format: "%02x", $0) }.joined()), got=\(nonce.map { String(format: "%02x", $0) }.joined()))"
            )
        }
        return token
    }

    /// R11j F-F05 — parse a CMS SignedData wrapping TSTInfo to extract
    /// (messageImprint.hashedMessage, nonce). Throws on any structural
    /// anomaly or missing nonce (since `submitOne` always sends one).
    ///
    /// timeStampToken DER structure (RFC 3161 §2.4.2 + RFC 5652):
    ///   ContentInfo ::= SEQUENCE {
    ///     contentType  OBJECT IDENTIFIER (1.2.840.113549.1.7.2),
    ///     content [0] EXPLICIT SignedData
    ///   }
    ///   SignedData ::= SEQUENCE {
    ///     version, digestAlgorithms (SET), encapContentInfo,
    ///     certificates [0] OPTIONAL, crls [1] OPTIONAL,
    ///     signerInfos (SET)
    ///   }
    ///   encapContentInfo ::= SEQUENCE {
    ///     eContentType OID (1.2.840.113549.1.9.16.1.4 tstInfo),
    ///     eContent [0] EXPLICIT OCTET STRING containing TSTInfo DER
    ///   }
    ///   TSTInfo ::= SEQUENCE {
    ///     version INTEGER, policy OID,
    ///     messageImprint SEQUENCE { algoId, OCTET STRING hashedMessage },
    ///     serialNumber INTEGER, genTime GeneralizedTime,
    ///     accuracy SEQUENCE OPTIONAL,
    ///     ordering BOOLEAN OPTIONAL,
    ///     nonce INTEGER OPTIONAL,
    ///     tsa [0] OPTIONAL, extensions [1] OPTIONAL
    ///   }
    static func parseTSTInfo(timeStampToken token: Data) throws -> (imprint: Data, nonce: Data) {
        // Outer ContentInfo SEQUENCE.
        var c = 0
        try expectTag(token, &c, 0x30, "ContentInfo")
        let ciLen = try derReadLength(token, at: &c)
        let ciEnd = c + ciLen
        guard ciEnd <= token.count else {
            throw NativeAuditTSAClientError.responseParseFailed(reason: "ContentInfo overruns buffer")
        }
        // contentType OID — skip.
        try skipTLV(token, &c, ciEnd, expectedTag: 0x06, context: "ContentInfo.contentType")
        // content [0] EXPLICIT — tag 0xA0.
        try expectTag(token, &c, 0xA0, "ContentInfo.content [0]")
        let contentLen = try derReadLength(token, at: &c)
        let contentEnd = c + contentLen
        guard contentEnd <= ciEnd else {
            throw NativeAuditTSAClientError.responseParseFailed(reason: "content [0] overruns ContentInfo")
        }
        // SignedData SEQUENCE.
        try expectTag(token, &c, 0x30, "SignedData")
        let sdLen = try derReadLength(token, at: &c)
        let sdEnd = c + sdLen
        guard sdEnd <= contentEnd else {
            throw NativeAuditTSAClientError.responseParseFailed(reason: "SignedData overruns content")
        }
        // version (INTEGER) — skip.
        try skipTLV(token, &c, sdEnd, expectedTag: 0x02, context: "SignedData.version")
        // digestAlgorithms (SET, tag 0x31) — skip.
        try skipTLV(token, &c, sdEnd, expectedTag: 0x31, context: "SignedData.digestAlgorithms")
        // encapContentInfo SEQUENCE.
        try expectTag(token, &c, 0x30, "EncapsulatedContentInfo")
        let eciLen = try derReadLength(token, at: &c)
        let eciEnd = c + eciLen
        guard eciEnd <= sdEnd else {
            throw NativeAuditTSAClientError.responseParseFailed(reason: "EncapsulatedContentInfo overruns SignedData")
        }
        // eContentType OID — skip.
        try skipTLV(token, &c, eciEnd, expectedTag: 0x06, context: "EncapsulatedContentInfo.eContentType")
        // [0] EXPLICIT.
        try expectTag(token, &c, 0xA0, "EncapsulatedContentInfo.eContent [0]")
        let econtentLen = try derReadLength(token, at: &c)
        let econtentEnd = c + econtentLen
        guard econtentEnd <= eciEnd else {
            throw NativeAuditTSAClientError.responseParseFailed(reason: "eContent [0] overruns EncapsulatedContentInfo")
        }
        // OCTET STRING wrapping TSTInfo.
        try expectTag(token, &c, 0x04, "TSTInfo OCTET STRING")
        let octetLen = try derReadLength(token, at: &c)
        let octetEnd = c + octetLen
        guard octetEnd <= econtentEnd else {
            throw NativeAuditTSAClientError.responseParseFailed(reason: "TSTInfo OCTET STRING overruns eContent")
        }
        // TSTInfo SEQUENCE.
        try expectTag(token, &c, 0x30, "TSTInfo")
        let tiLen = try derReadLength(token, at: &c)
        let tiEnd = c + tiLen
        guard tiEnd <= octetEnd else {
            throw NativeAuditTSAClientError.responseParseFailed(reason: "TSTInfo overruns OCTET STRING")
        }
        // version (INTEGER) — skip.
        try skipTLV(token, &c, tiEnd, expectedTag: 0x02, context: "TSTInfo.version")
        // policy OID — skip.
        try skipTLV(token, &c, tiEnd, expectedTag: 0x06, context: "TSTInfo.policy")
        // messageImprint SEQUENCE.
        try expectTag(token, &c, 0x30, "TSTInfo.messageImprint")
        let miLen = try derReadLength(token, at: &c)
        let miEnd = c + miLen
        guard miEnd <= tiEnd else {
            throw NativeAuditTSAClientError.responseParseFailed(reason: "messageImprint overruns TSTInfo")
        }
        // messageImprint.algoId SEQUENCE — skip.
        try skipTLV(token, &c, miEnd, expectedTag: 0x30, context: "messageImprint.algoId")
        // messageImprint.hashedMessage OCTET STRING — capture.
        try expectTag(token, &c, 0x04, "messageImprint.hashedMessage")
        let hmLen = try derReadLength(token, at: &c)
        guard c + hmLen <= miEnd else {
            throw NativeAuditTSAClientError.responseParseFailed(reason: "hashedMessage overruns messageImprint")
        }
        let imprint = token.subdata(in: c..<(c + hmLen))
        c = miEnd  // skip rest of messageImprint
        // serialNumber INTEGER — skip.
        try skipTLV(token, &c, tiEnd, expectedTag: 0x02, context: "TSTInfo.serialNumber")
        // genTime (GeneralizedTime, tag 0x18) — skip.
        try skipTLV(token, &c, tiEnd, expectedTag: 0x18, context: "TSTInfo.genTime")
        // Optional fields. Scan by tag to find INTEGER (nonce).
        var nonce: Data? = nil
        while c < tiEnd {
            let tag = try derPeekTag(token, at: &c)
            let len = try derReadLength(token, at: &c)
            guard c + len <= tiEnd else {
                throw NativeAuditTSAClientError.responseParseFailed(reason: "TSTInfo trailing field overruns")
            }
            if tag == 0x02 {  // INTEGER = nonce
                nonce = token.subdata(in: c..<(c + len))
                // Strip leading 0x00 padding byte that DER adds when
                // high bit is set (RFC 5280 — INTEGER is signed).
                if let n = nonce, n.count > 1, n.first == 0x00, (n[1] & 0x80) == 0x80 {
                    nonce = n.dropFirst()
                }
                c += len
                break
            }
            // accuracy (0x30), ordering (0x01), tsa [0] (0xA0), extensions [1] (0xA1) → skip.
            c += len
        }
        guard let foundNonce = nonce else {
            throw NativeAuditTSAClientError.responseBindingMismatch(
                reason: "TSTInfo.nonce missing — submitOne always sends a nonce; absent nonce in response is a substitution oracle"
            )
        }
        return (imprint, foundNonce)
    }

    // R11j F-F05 helpers.

    private static func expectTag(_ data: Data, _ c: inout Int, _ tag: UInt8, _ ctx: String) throws {
        let actual = try derPeekTag(data, at: &c)
        guard actual == tag else {
            throw NativeAuditTSAClientError.responseParseFailed(reason: "\(ctx): expected tag 0x\(String(format: "%02x", tag)), got 0x\(String(format: "%02x", actual))")
        }
    }

    private static func skipTLV(_ data: Data, _ c: inout Int, _ end: Int, expectedTag: UInt8, context: String) throws {
        try expectTag(data, &c, expectedTag, context)
        let len = try derReadLength(data, at: &c)
        guard c + len <= end else {
            throw NativeAuditTSAClientError.responseParseFailed(reason: "\(context): length \(len) overruns parent")
        }
        c += len
    }

    // MARK: - DER primitives (internal for tests)

    static func derLength(_ n: Int) -> Data {
        if n < 0x80 { return Data([UInt8(n)]) }
        var bytes: [UInt8] = []
        var v = n
        while v > 0 { bytes.insert(UInt8(v & 0xff), at: 0); v >>= 8 }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }

    static func derSequence(_ inner: Data) -> Data {
        return Data([0x30]) + derLength(inner.count) + inner
    }

    static func derInteger(_ n: Int) -> Data {
        precondition(n >= 0, "derInteger expects non-negative")
        if n == 0 { return Data([0x02, 0x01, 0x00]) }
        var bytes: [UInt8] = []
        var v = n
        while v > 0 { bytes.insert(UInt8(v & 0xff), at: 0); v >>= 8 }
        // High-bit set = prepend 0x00 to keep INTEGER positive.
        if (bytes[0] & 0x80) != 0 { bytes.insert(0x00, at: 0) }
        return Data([0x02]) + derLength(bytes.count) + Data(bytes)
    }

    static func derIntegerFromBytes(_ raw: Data) -> Data {
        var bytes = Array(raw)
        // Strip leading zeros (but keep at least one byte).
        while bytes.count > 1 && bytes[0] == 0 { bytes.removeFirst() }
        // High-bit set = prepend 0x00 to encode as positive.
        if (bytes[0] & 0x80) != 0 { bytes.insert(0x00, at: 0) }
        return Data([0x02]) + derLength(bytes.count) + Data(bytes)
    }

    static func derOctetString(_ d: Data) -> Data {
        return Data([0x04]) + derLength(d.count) + d
    }

    static func derNull() -> Data { return Data([0x05, 0x00]) }
    static func derBoolean(_ b: Bool) -> Data { return Data([0x01, 0x01, b ? 0xFF : 0x00]) }

    private static func derPeekTag(_ data: Data, at cursor: inout Int) throws -> UInt8 {
        guard cursor < data.count else {
            throw NativeAuditTSAClientError.responseParseFailed(reason: "tag read past end")
        }
        let t = data[cursor]
        cursor += 1
        return t
    }

    private static func derReadLength(_ data: Data, at cursor: inout Int) throws -> Int {
        guard cursor < data.count else {
            throw NativeAuditTSAClientError.responseParseFailed(reason: "length read past end")
        }
        let first = data[cursor]; cursor += 1
        if first < 0x80 { return Int(first) }
        let n = Int(first & 0x7F)
        guard n > 0, n <= 4, cursor + n <= data.count else {
            throw NativeAuditTSAClientError.responseParseFailed(reason: "bad long-form length")
        }
        var v = 0
        for _ in 0..<n {
            v = (v << 8) | Int(data[cursor]); cursor += 1
        }
        return v
    }

    // MARK: - Network submission

    private static func submitOne(
        imprint: Data,
        tsa: TSAEndpoint,
        timeout: TimeInterval,
        urlSession: URLSession
    ) throws -> Data {
        guard let url = URL(string: tsa.url) else {
            throw NativeAuditTSAClientError.networkFailure(tsa: tsa.name, underlying: "invalid URL: \(tsa.url)")
        }
        var nonce = Data(count: 8)
        _ = nonce.withUnsafeMutableBytes { buf in
            SecRandomCopyBytes(kSecRandomDefault, 8, buf.baseAddress!)
        }
        let reqBody = try encodeTimeStampReq(sha256Imprint: imprint, nonce: nonce)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/timestamp-query", forHTTPHeaderField: "Content-Type")
        req.setValue("application/timestamp-reply", forHTTPHeaderField: "Accept")
        req.httpBody = reqBody
        req.timeoutInterval = timeout

        // Cross-thread state hand-off from URLSession completion handler
        // back to this sync call site. OSAllocatedUnfairLock wraps the
        // mutable state in a Sendable-safe container — no
        // @unchecked Sendable or nonisolated(unsafe) needed
        // (AGENTS.md §3 prohibits safety-invariant suppression).
        struct ResultState {
            var data: Data?
            var err: (any Error)?
            var status: Int
        }
        let sem = DispatchSemaphore(value: 0)
        let state = OSAllocatedUnfairLock<ResultState>(
            initialState: ResultState(data: nil, err: nil, status: 0)
        )
        let task = urlSession.dataTask(with: req) { d, resp, err in
            state.withLock { s in
                s.data = d
                s.err = err
                if let http = resp as? HTTPURLResponse { s.status = http.statusCode }
            }
            sem.signal()
        }
        task.resume()
        let wait = sem.wait(timeout: .now() + timeout + 0.5)
        guard wait == .success else {
            task.cancel()
            throw NativeAuditTSAClientError.networkFailure(tsa: tsa.name, underlying: "timeout after \(timeout)s")
        }
        let final = state.withLock { $0 }
        if let err = final.err {
            throw NativeAuditTSAClientError.networkFailure(tsa: tsa.name, underlying: err.localizedDescription)
        }
        guard let body = final.data, !body.isEmpty else {
            throw NativeAuditTSAClientError.networkFailure(tsa: tsa.name, underlying: "empty body (HTTP \(final.status))")
        }
        guard (200...299).contains(final.status) else {
            throw NativeAuditTSAClientError.networkFailure(tsa: tsa.name, underlying: "HTTP \(final.status)")
        }
        return try parseTimeStampResp(body, expectedImprint: imprint, expectedNonce: nonce)
    }

    // MARK: - Persistence

    private static func writeReceipt(
        anchorShaHex: String,
        tsaName: String,
        token: Data,
        env: [String: String]
    ) throws {
        let dir = resolvePath(canonicalReceiptDir, env: env)
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: dir),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let safeName = tsaName.replacingOccurrences(of: "/", with: "_")
        let full = "\(dir)/\(anchorShaHex)-\(safeName).der"
        try token.write(to: URL(fileURLWithPath: full), options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: full)
    }

    private static func recordPending(anchorShaHex: String, failingTSAs: [String], env: [String: String]) {
        let dir = resolvePath(canonicalPendingDir, env: env)
        try? FileManager.default.createDirectory(
            at: URL(fileURLWithPath: dir),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let payload: [String: Any] = [
            "anchor_sha": anchorShaHex,
            "ts_first_attempt": Int(Date().timeIntervalSince1970),
            "tsas_pending": failingTSAs
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            return
        }
        let full = "\(dir)/\(anchorShaHex).json"
        try? data.write(to: URL(fileURLWithPath: full), options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: full)
    }

    // MARK: - Config load

    static func loadConfig(env: [String: String]) throws -> Config? {
        let path = resolvePath(canonicalConfigPath, env: env)
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        // F-C05-symmetric: refuse world/group-readable config files.
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let mode = attrs[.posixPermissions] as? NSNumber {
            let m = mode.uint16Value
            if (m & 0o077) != 0 {
                throw NativeAuditTSAClientError.configBadMode(path: path, mode: m)
            }
        }
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            throw NativeAuditTSAClientError.configMalformed(path: path, reason: "unreadable: \(error.localizedDescription)")
        }
        do {
            return try JSONDecoder().decode(Config.self, from: data)
        } catch {
            throw NativeAuditTSAClientError.configMalformed(path: path, reason: "JSON decode: \(error.localizedDescription)")
        }
    }

    // MARK: - Path resolution

    private static func resolvePath(_ canonical: String, env: [String: String]) -> String {
        #if DEBUG && JARVIS_INSECURE_PATHS
        let envKey: String?
        switch canonical {
        case canonicalConfigPath: envKey = "JARVIS_TSA_CONFIG_PATH"
        case canonicalReceiptDir: envKey = "JARVIS_TSA_RECEIPT_DIR"
        case canonicalPendingDir: envKey = "JARVIS_TSA_PENDING_DIR"
        default: envKey = nil
        }
        if let key = envKey,
           let override = env[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return NSString(string: override).expandingTildeInPath
        }
        #endif
        return NSString(string: canonical).expandingTildeInPath
    }

    private static func hexToBytes(_ hex: String) -> Data? {
        let s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(s.count / 2)
        var idx = s.startIndex
        while idx < s.endIndex {
            let next = s.index(idx, offsetBy: 2)
            guard let b = UInt8(s[idx..<next], radix: 16) else { return nil }
            bytes.append(b)
            idx = next
        }
        return Data(bytes)
    }
}

// Non-throwing audit emit for use inside TSA failure paths — we can't
// fail boot because the audit emit itself failed.
extension NativeSecurityAudit {
    static func tryRecord(_ event: String, fields: [String: Any] = [:]) {
        do { try NativeSecurityAudit.record(event, fields: fields) } catch { /* swallowed */ }
    }
}
