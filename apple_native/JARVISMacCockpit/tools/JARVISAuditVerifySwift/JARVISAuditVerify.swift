// JARVISAuditVerifySwift — V4R R11d F-C03 + R11f F-D01
//
// Offline verifier for the tamper-evident audit hash chain written by
// NativeSecurityAudit. Reads an audit jsonl file line-by-line and asserts:
//   1. Every record parses as a JSON object.
//   2. seq starts at 1 and increments by exactly 1.
//   3. prev_sha of each record == sha of the prior record (or
//      "00…0" × 64 for the genesis record).
//   4. sha of each record == SHA-256(canonical-sorted JSON of the record
//      with the `sha` field removed).
//
// R11f F-D01: when `--cold-root-pubkey-hex <hex>` and `--aux-cert-path
// <path>` are supplied, the verifier additionally:
//   5. Loads and verifies the aux certificate against the cold root pubkey.
//      The cert's cold_root_sig must cover canonical-sorted JSON of
//      {aux_pubkey_hex, valid_from, valid_until}.
//   6. For every audit_chain_boot_anchor record encountered, verifies
//      anchor_signature_hex against the aux pubkey over canonical-sorted
//      JSON of {boot_id, event, prev_chain_tail_sha, ts}. Mismatch → exit 1.
//   7. If the file is non-empty AND the scan saw ZERO anchor records, exit 1
//      with "chain contains no boot anchors — possible total rewrite".
//
// Exits 0 on chain-valid, 1 on any mismatch. Prints the first offending
// record's seq + reason on failure. No external dependencies beyond
// Foundation + CryptoKit.

import CryptoKit
import Foundation

private struct VerifierArgs {
    var path: String
    var coldRootPublicKeyHex: String?
    var auxCertPath: String?
}

private func parseArgs(_ argv: [String]) -> VerifierArgs? {
    var path: String?
    var coldRootHex: String?
    var auxCert: String?
    var i = 0
    while i < argv.count {
        let a = argv[i]
        switch a {
        case "--cold-root-pubkey-hex":
            guard i + 1 < argv.count else { return nil }
            coldRootHex = argv[i + 1]
            i += 2
        case "--aux-cert-path":
            guard i + 1 < argv.count else { return nil }
            auxCert = argv[i + 1]
            i += 2
        default:
            if path == nil { path = a; i += 1 } else { return nil }
        }
    }
    guard let p = path else { return nil }
    return VerifierArgs(path: p, coldRootPublicKeyHex: coldRootHex, auxCertPath: auxCert)
}

private func decodeHex(_ s: String) -> Data? {
    let cleaned = s.trimmingCharacters(in: .whitespacesAndNewlines)
    guard cleaned.count % 2 == 0 else { return nil }
    var bytes: [UInt8] = []
    bytes.reserveCapacity(cleaned.count / 2)
    var idx = cleaned.startIndex
    while idx < cleaned.endIndex {
        let next = cleaned.index(idx, offsetBy: 2)
        guard let b = UInt8(cleaned[idx..<next], radix: 16) else { return nil }
        bytes.append(b)
        idx = next
    }
    return Data(bytes)
}

/// Parses + verifies an aux certificate against the cold root pubkey.
/// Returns the aux public key on success.
private func verifyAuxCertificate(
    certData: Data,
    coldRootPublicKey: Curve25519.Signing.PublicKey
) -> Curve25519.Signing.PublicKey? {
    guard let parsed = try? JSONSerialization.jsonObject(with: certData) as? [String: Any] else { return nil }
    guard let auxHex = parsed["aux_pubkey_hex"] as? String,
          let validFrom = parsed["valid_from"] as? Int,
          let validUntil = parsed["valid_until"] as? Int,
          let sigHex = parsed["cold_root_sig"] as? String
    else { return nil }
    guard let auxBytes = decodeHex(auxHex),
          let sigBytes = decodeHex(sigHex),
          let auxPub = try? Curve25519.Signing.PublicKey(rawRepresentation: auxBytes)
    else { return nil }
    let signedFields: [String: Any] = [
        "aux_pubkey_hex": auxHex,
        "valid_from": validFrom,
        "valid_until": validUntil
    ]
    guard let signedData = try? JSONSerialization.data(withJSONObject: signedFields, options: [.sortedKeys]),
          coldRootPublicKey.isValidSignature(sigBytes, for: signedData)
    else { return nil }
    return auxPub
}

private func verifyAnchorSignature(
    record: [String: Any],
    auxPublicKey: Curve25519.Signing.PublicKey
) -> Bool {
    guard let bootId = record["boot_id"] as? String,
          let prevChainTailSha = record["prev_chain_tail_sha"] as? String,
          let ts = record["ts"] as? Int,
          let sigHex = record["anchor_signature_hex"] as? String,
          let sigBytes = decodeHex(sigHex)
    else { return false }
    let signedFields: [String: Any] = [
        "boot_id": bootId,
        "event": "audit_chain_boot_anchor",
        "prev_chain_tail_sha": prevChainTailSha,
        "ts": ts
    ]
    guard let signedData = try? JSONSerialization.data(withJSONObject: signedFields, options: [.sortedKeys]) else {
        return false
    }
    return auxPublicKey.isValidSignature(sigBytes, for: signedData)
}

@main
struct JARVISAuditVerify {
    static func main() {
        let argv = Array(CommandLine.arguments.dropFirst())
        guard let args = parseArgs(argv) else {
            FileHandle.standardError.write(Data(
                "usage: jarvis-audit-verify-swift <path> [--cold-root-pubkey-hex <hex>] [--aux-cert-path <path>]\n".utf8
            ))
            exit(2)
        }

        // R11f F-D01: aux verification gated by both args. If either is
        // supplied alone, refuse — anchor-aware mode requires both pieces.
        var auxPublicKey: Curve25519.Signing.PublicKey?
        switch (args.coldRootPublicKeyHex, args.auxCertPath) {
        case (.some(let hex), .some(let certPath)):
            guard let rootBytes = decodeHex(hex),
                  let rootPub = try? Curve25519.Signing.PublicKey(rawRepresentation: rootBytes)
            else {
                FileHandle.standardError.write(Data("invalid --cold-root-pubkey-hex\n".utf8))
                exit(2)
            }
            let certData: Data
            do { certData = try Data(contentsOf: URL(fileURLWithPath: certPath)) }
            catch {
                FileHandle.standardError.write(Data("aux cert read failed: \(error)\n".utf8))
                exit(1)
            }
            guard let aux = verifyAuxCertificate(certData: certData, coldRootPublicKey: rootPub) else {
                FileHandle.standardError.write(Data("aux certificate verification failed against cold root\n".utf8))
                exit(1)
            }
            auxPublicKey = aux
        case (.none, .none):
            auxPublicKey = nil
        default:
            FileHandle.standardError.write(Data(
                "anchor-aware mode requires both --cold-root-pubkey-hex and --aux-cert-path\n".utf8
            ))
            exit(2)
        }

        let url = URL(fileURLWithPath: args.path)
        let raw: Data
        do { raw = try Data(contentsOf: url) }
        catch {
            FileHandle.standardError.write(Data("read failed: \(error)\n".utf8))
            exit(2)
        }

        guard let text = String(data: raw, encoding: .utf8) else {
            FileHandle.standardError.write(Data("file is not valid UTF-8\n".utf8))
            exit(1)
        }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        let genesisPrev = String(repeating: "0", count: 64)
        var expectedSeq = 1
        var expectedPrev = genesisPrev
        var anchorCount = 0

        for (idx, line) in lines.enumerated() {
            guard let lineData = line.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else {
                FileHandle.standardError.write(Data("line \(idx + 1): not a JSON object\n".utf8))
                exit(1)
            }

            guard let recordedSha = parsed["sha"] as? String,
                  let recordedPrev = parsed["prev_sha"] as? String,
                  let recordedSeq = parsed["seq"] as? Int
            else {
                FileHandle.standardError.write(Data("line \(idx + 1): missing chain fields (need sha, prev_sha, seq)\n".utf8))
                exit(1)
            }

            if recordedSeq != expectedSeq {
                FileHandle.standardError.write(Data("line \(idx + 1): seq=\(recordedSeq), expected \(expectedSeq)\n".utf8))
                exit(1)
            }
            if recordedPrev != expectedPrev {
                FileHandle.standardError.write(
                    Data("line \(idx + 1): prev_sha=\(recordedPrev), expected \(expectedPrev)\n".utf8)
                )
                exit(1)
            }

            var withoutSha = parsed
            withoutSha.removeValue(forKey: "sha")
            guard let recomputeInput = try? JSONSerialization.data(
                withJSONObject: withoutSha, options: [.sortedKeys]
            ) else {
                FileHandle.standardError.write(Data("line \(idx + 1): canonical reserialize failed\n".utf8))
                exit(1)
            }
            let recomputed = SHA256.hash(data: recomputeInput)
                .map { String(format: "%02x", $0) }.joined()
            if recomputed != recordedSha {
                FileHandle.standardError.write(
                    Data("line \(idx + 1): sha mismatch — recorded=\(recordedSha) recomputed=\(recomputed)\n".utf8)
                )
                exit(1)
            }

            // R11f F-D01: per-anchor signature verification (when in
            // anchor-aware mode) AND prev_chain_tail_sha binding check.
            if (parsed["event"] as? String) == "audit_chain_boot_anchor" {
                anchorCount += 1
                if let aux = auxPublicKey {
                    guard verifyAnchorSignature(record: parsed, auxPublicKey: aux) else {
                        FileHandle.standardError.write(
                            Data("line \(idx + 1): anchor_signature_hex verification failed\n".utf8)
                        )
                        exit(1)
                    }
                    // The signed prev_chain_tail_sha must match the actual
                    // prev_sha of THIS record (it binds the anchor to its
                    // position in the chain).
                    if let signedPrev = parsed["prev_chain_tail_sha"] as? String,
                       signedPrev != recordedPrev {
                        FileHandle.standardError.write(
                            Data("line \(idx + 1): anchor prev_chain_tail_sha=\(signedPrev) does not match prev_sha=\(recordedPrev) (chain position binding)\n".utf8)
                        )
                        exit(1)
                    }
                }
            }

            expectedSeq += 1
            expectedPrev = recordedSha
        }

        // R11f F-D01: in anchor-aware mode, a non-empty chain that contains
        // NO anchors is the signature of a total rewrite by an attacker who
        // doesn't possess the aux key. Fail.
        if auxPublicKey != nil, !lines.isEmpty, anchorCount == 0 {
            FileHandle.standardError.write(Data(
                "chain contains no boot anchors — possible total rewrite (anchor-aware mode)\n".utf8
            ))
            exit(1)
        }

        if auxPublicKey != nil {
            print("audit chain valid: \(lines.count) record(s) verified, \(anchorCount) anchor(s) verified against aux cert")
        } else {
            print("audit chain valid: \(lines.count) record(s) verified")
        }
        exit(0)
    }
}
