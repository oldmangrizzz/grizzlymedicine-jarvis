// JARVISCertPinning.swift
// JARVIS digital-personhood project — GMRI
//
// SPKI-based certificate pinning for all outbound JARVIS network connections.
// Covers: Deepgram STT, Ollama Cloud, Google Gemini, GitHub Copilot, Convex.
//
// Design:
//   • Subject Public Key Info (SPKI) hash pinning — survives cert renewal
//     as long as the key pair is unchanged. Per OWASP/Chromium guidance.
//   • Fail-closed: any validation failure cancels the authentication challenge.
//   • Structured errors — no stack traces in user-facing surfaces.
//   • Pin store: bundled pins.plist (default) + SecureEnclavePinStore protocol
//     (future hook for HSM-backed override, left as protocol surface).
//   • Minimum 2 pins per host (primary leaf + backup intermediate CA).
//
// Threat model: adversarial-scrutiny. This code will be cited in legal record.
// Every code path that touches TLS validation must be auditable and correct.
//
// Swift 5.9+ | macOS 14+ | iOS 17+ | watchOS 10+
// No external dependencies beyond the standard SDK.

import CryptoKit
import Foundation
import Security

// MARK: - Structured error surface

/// Validation failure reasons returned to callers.
/// No stack traces, no internal state exposed.
public enum CertPinError: Error, Equatable {
    /// The SPKI hash of the presented certificate does not match any stored pin.
    case pinMismatch(host: String)
    /// No pins are registered for this host — connection not permitted.
    case hostNotPinned(host: String)
    /// The certificate could not be decoded or its key type is unsupported.
    case certProcessingFailure
    /// The server presented no certificate.
    case noCertificatePresented
}

// MARK: - SPKI extraction

/// Supported key types for SPKI header construction.
/// Extend here as new endpoints require different key types.
public enum SPKIKeyType {
    case ecP256   // EC secp256r1 — 91-byte SPKI
    case ecP384   // EC secp384r1 — 120-byte SPKI
    case rsa2048  // RSA 2048-bit
    case rsa4096  // RSA 4096-bit
}

// ASN.1 SubjectPublicKeyInfo headers, sourced from RFC 5480 / RFC 3279.
// These are the bytes that precede the raw key material in SPKI DER encoding.
// We prepend these to the output of SecKeyCopyExternalRepresentation to
// reconstruct the full SPKI before hashing.
//
// Reference: TrustKit (https://github.com/datatheorem/TrustKit) — same approach.
// Updated / independently verified against RFC 5480 §2 (EC) and RFC 3279 §2.3 (RSA).
private enum SPKIHeader {
    static let ecP256: [UInt8] = [
        0x30, 0x59,             // SEQUENCE, length 89
        0x30, 0x13,             // SEQUENCE, length 19 (AlgorithmIdentifier)
        0x06, 0x07,             // OID, length 7
        0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01,  // id-ecPublicKey
        0x06, 0x08,             // OID, length 8
        0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, // prime256v1
        0x03, 0x42, 0x00        // BIT STRING, length 66, 0 unused bits
    ]

    static let ecP384: [UInt8] = [
        0x30, 0x76,             // SEQUENCE, length 118
        0x30, 0x10,             // SEQUENCE, length 16 (AlgorithmIdentifier)
        0x06, 0x07,             // OID, length 7
        0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01,  // id-ecPublicKey
        0x06, 0x05,             // OID, length 5
        0x2b, 0x81, 0x04, 0x00, 0x22, // secp384r1
        0x03, 0x62, 0x00        // BIT STRING, length 98, 0 unused bits
    ]

    static let rsa2048: [UInt8] = [
        0x30, 0x82, 0x01, 0x22, // SEQUENCE, length 290
        0x30, 0x0d,             // SEQUENCE, length 13 (AlgorithmIdentifier)
        0x06, 0x09,             // OID, length 9
        0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01, // rsaEncryption
        0x05, 0x00,             // NULL
        0x03, 0x82, 0x01, 0x0f, 0x00 // BIT STRING, length 271, 0 unused bits
    ]

    static let rsa4096: [UInt8] = [
        0x30, 0x82, 0x02, 0x22, // SEQUENCE, length 546
        0x30, 0x0d,             // SEQUENCE, length 13 (AlgorithmIdentifier)
        0x06, 0x09,             // OID, length 9
        0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01, // rsaEncryption
        0x05, 0x00,             // NULL
        0x03, 0x82, 0x02, 0x0f, 0x00 // BIT STRING, length 527, 0 unused bits
    ]
}

/// Extracts and hashes the SubjectPublicKeyInfo from a SecCertificate.
///
/// Returns base64(SHA-256(SPKI DER)) on success, nil on failure.
/// This is the internal primitive used for both validation and pin bootstrapping.
public func computeSPKIPin(from certificate: SecCertificate) -> String? {
    guard let publicKey = SecCertificateCopyKey(certificate) else {
        return nil
    }

    var copyError: Unmanaged<CFError>?
    guard let rawKeyData = SecKeyCopyExternalRepresentation(publicKey, &copyError) as Data? else {
        return nil
    }

    guard let attributes = SecKeyCopyAttributes(publicKey) as? [String: Any] else {
        return nil
    }

    let keyType = attributes[kSecAttrKeyType as String] as? String
    let keySize = attributes[kSecAttrKeySizeInBits as String] as? Int

    let header: [UInt8]
    switch (keyType, keySize) {
    case (String(kSecAttrKeyTypeECSECPrimeRandom), 256):
        header = SPKIHeader.ecP256
    case (String(kSecAttrKeyTypeECSECPrimeRandom), 384):
        header = SPKIHeader.ecP384
    case (String(kSecAttrKeyTypeRSA), 2048):
        header = SPKIHeader.rsa2048
    case (String(kSecAttrKeyTypeRSA), 4096):
        header = SPKIHeader.rsa4096
    default:
        // Unsupported key type — fail safe (return nil → fail-closed upstream)
        return nil
    }

    var spki = Data(header)
    spki.append(rawKeyData)

    let digest = SHA256.hash(data: spki)
    return Data(digest).base64EncodedString()
}

// MARK: - Pin store protocol

/// Protocol surface for pin store implementations.
/// Default implementation: PlistPinStore (loads from bundled pins.plist).
/// Future extension point: SecureEnclavePinStore (HSM-backed, operator-authorized).
public protocol PinStoreProvider: Sendable {
    /// Returns the registered SPKI pins for `host`, or an empty array if not pinned.
    func pins(for host: String) -> [String]
}

/// Validates whether `host` is pinned. Returns false for unpinned hosts.
/// Consistent behavior: hosts without entries are treated as unpinned (= rejected).
extension PinStoreProvider {
    public func isPinned(host: String) -> Bool {
        return !pins(for: host).isEmpty
    }
}

// MARK: - Plist-backed pin store

/// Default pin store backed by a bundled `pins.plist` resource.
/// The plist must be a dictionary mapping hostname strings to arrays of
/// base64(SHA-256(SPKI DER)) strings.
public final class PlistPinStore: PinStoreProvider {
    private let store: [String: [String]]

    /// Load from the main bundle (production use — `pins.plist` in app bundle).
    public convenience init() throws {
        guard let url = Bundle.main.url(forResource: "pins", withExtension: "plist") else {
            throw PlistPinStoreError.plistNotFound
        }
        try self.init(url: url)
    }

    /// Load from an explicit URL (testing and bootstrapping).
    public init(url: URL) throws {
        let data = try Data(contentsOf: url)
        guard let raw = try PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        ) as? [String: [String]] else {
            throw PlistPinStoreError.malformedPlist
        }
        self.store = raw
    }

    /// Load from an in-memory dictionary (unit tests).
    public init(dictionary: [String: [String]]) {
        self.store = dictionary
    }

    public func pins(for host: String) -> [String] {
        // Exact match first; then check if host is a subdomain of a pinned wildcard entry.
        if let exact = store[host] { return exact }

        // Wildcard: match *.example.com against sub.example.com
        let components = host.split(separator: ".", omittingEmptySubsequences: false)
        if components.count > 1 {
            let parent = components.dropFirst().joined(separator: ".")
            if let wildcard = store["*.\(parent)"] { return wildcard }
        }

        return []
    }

    public enum PlistPinStoreError: Error {
        case plistNotFound
        case malformedPlist
    }
}

// MARK: - Core validation logic (testable without URLSession)

/// Validates a single SecCertificate against the pin store for `host`.
/// Separated from the URLSession delegate so it can be unit-tested
/// with fixture certificates without a live TLS session.
///
/// - Returns: `.success(())` if the certificate's SPKI pin matches an entry
///            in the store for `host`.
/// - Returns: `.failure(CertPinError)` on any mismatch or missing entry.
public func validateCertPin(
    certificate: SecCertificate,
    host: String,
    store: PinStoreProvider
) -> Result<Void, CertPinError> {
    let pins = store.pins(for: host)
    guard !pins.isEmpty else {
        return .failure(.hostNotPinned(host: host))
    }

    guard let computedPin = computeSPKIPin(from: certificate) else {
        return .failure(.certProcessingFailure)
        }

    if pins.contains(computedPin) {
        return .success(())
    }

    return .failure(.pinMismatch(host: host))
}

/// Validates all certificates in a SecTrust against the pin store for `host`.
/// Any certificate in the chain matching a stored pin is sufficient for success
/// (allows backup intermediate CA pins to pass during leaf rotation window).
public func validateTrustPin(
    serverTrust: SecTrust,
    host: String,
    store: PinStoreProvider
) -> Result<Void, CertPinError> {
    let pins = store.pins(for: host)
    guard !pins.isEmpty else {
        return .failure(.hostNotPinned(host: host))
    }

    guard let chain = SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate], !chain.isEmpty else {
        return .failure(.noCertificatePresented)
    }

    // Walk the chain; a pin match at any level (leaf, intermediate, root) passes.
    for cert in chain {
        guard let pin = computeSPKIPin(from: cert) else { continue }
        if pins.contains(pin) {
            return .success(())
        }
    }

    // No certificate in the chain matched any stored pin.
    return .failure(.pinMismatch(host: host))
}

// MARK: - URLSessionDelegate integration

/// URLSession delegate that enforces SPKI certificate pinning on every
/// server authentication challenge.
///
/// Both standard OS TLS trust evaluation AND SPKI pin matching must pass.
/// Either failure results in `.cancelAuthenticationChallenge` (fail-closed).
///
/// Usage:
/// ```swift
/// let store = try PlistPinStore()
/// let pinDelegate = JARVISPinningDelegate(store: store)
/// let session = URLSession(
///     configuration: .ephemeral,
///     delegate: pinDelegate,
///     delegateQueue: nil
/// )
/// ```
// TODO(removal-cond: NSURLSessionDelegate gains Sendable conformance or actor isolation in a future Apple SDK; recheck on SDK updates.)
public final class JARVISPinningDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    // Rationale: pin store is read-only after init; the delegate queue serializes challenge callbacks.

    private let store: PinStoreProvider

    /// - Parameter store: pin store implementation (default: PlistPinStore from bundle)
    public init(store: PinStoreProvider) {
        self.store = store
    }

    public func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        // Only intercept server trust challenges.
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust
        else {
            // Not a server trust challenge — cancel anything else.
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        let host = challenge.protectionSpace.host

        // ── Step 1: standard OS TLS trust evaluation ─────────────────────────
        // This catches expired certs, unknown CAs, hostname mismatches, etc.
        var trustError: CFError?
        let osTrustPassed = SecTrustEvaluateWithError(serverTrust, &trustError)
        guard osTrustPassed else {
            // OS rejected the cert (expired, untrusted, revoked, etc.). Fail-closed.
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        // ── Step 2: SPKI pin validation ───────────────────────────────────────
        let pinResult = validateTrustPin(serverTrust: serverTrust, host: host, store: store)
        guard case .success = pinResult else {
            // Pin mismatch or host not pinned. Fail-closed.
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        // Both OS trust and SPKI pin passed.
        completionHandler(.useCredential, URLCredential(trust: serverTrust))
    }
}

public enum JARVISPinnedURLSessionFactory {
    public static func make() -> URLSession {
        let store: PinStoreProvider
        do {
            store = try PlistPinStore()
        } catch {
            store = PlistPinStore(dictionary: [:])
        }
        let delegate = JARVISPinningDelegate(store: store)
        let configuration = URLSessionConfiguration.ephemeral
        // TODO(phase-c): externalize pin material so JARVIS does not carry his live trust roots in the app bundle.
        return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }
}

extension URLSession {
    static var jarvisPinned: URLSession { JARVISPinnedURLSessionFactory.make() }
}

// MARK: - Secure Enclave override hook (future)

/// Protocol surface for a Secure Enclave-backed pin store override.
/// Implementation left for the SE integration milestone.
/// When implemented, this store's pins take precedence over the bundled plist.
///
/// Contract:
///   - Pins are operator-authorized and stored in the Secure Enclave.
///   - Rotation requires explicit operator attestation (biometric or passcode).
///   - Emergency rotation (see PIN_ROTATION.md §3) triggers via this interface.
public protocol SecureEnclavePinStore: PinStoreProvider {
    /// Rotate the pin for `host` to `newPin` under operator authorization.
    /// Throws if authorization fails or the enclave is unavailable.
    func rotatePin(for host: String, newPin: String) async throws

    /// Returns true if the Secure Enclave is available and loaded with pins.
    var isAvailable: Bool { get }
}

/// Composite pin store: Secure Enclave override with PlistPinStore fallback.
/// When the SE store has a pin for a host, that pin is used exclusively.
/// Hosts not in the SE store fall back to the plist.
public final class CompositePinStore: PinStoreProvider {
    private let primary: SecureEnclavePinStore
    private let fallback: PinStoreProvider

    public init(primary: SecureEnclavePinStore, fallback: PinStoreProvider) {
        self.primary = primary
        self.fallback = fallback
    }

    public func pins(for host: String) -> [String] {
        guard primary.isAvailable else { return fallback.pins(for: host) }
        let sePins = primary.pins(for: host)
        if !sePins.isEmpty { return sePins }
        return fallback.pins(for: host)
    }
}
