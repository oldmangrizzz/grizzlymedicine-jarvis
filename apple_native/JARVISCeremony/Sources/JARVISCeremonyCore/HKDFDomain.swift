/// Centralised HKDF `sharedInfo` domain strings for the JARVISCeremony package.
///
/// Rule: same cryptographic purpose → same domain string; different purpose → must differ.
/// Using an enum makes typos impossible and makes exhaustive audits trivial.
///
/// **Versioning:** bump the version suffix (e.g. `.v2`) and run a migration if the
/// derived key semantic changes.  Never reuse an old string for a new purpose.
enum HKDFDomain: String {
    static let currentSchemaVersion = "v1"

    /// SE-anchored local-backup seal: ECDH-derived key used to seal the soul-anchor blob.
    case localSeal    = "jarvis.soulanchor.localSeal.v1"

    /// Key used for the SE-anchored audit-chain HMAC (one key per audit log file,
    /// derived from the SE-sealed master blob via ECDH self-agreement).
    case auditHmacKey = "jarvis.audit.hmacKey.v1"
}
