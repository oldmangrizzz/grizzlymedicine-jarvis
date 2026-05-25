import Foundation
import JARVISSecureEnclave

func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw SecureEnclaveIdentityError.crypto("smoke validation failed: \(message)") }
}

let root = try generateColdRootForTestsOnly()
// JARVIS_HOME makes smoke artifacts hermetic; when set it replaces the default .build-backed home root.
let smokeHome = ProcessInfo.processInfo.environment["JARVIS_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        .appendingPathComponent(".build/smoke-artifacts", isDirectory: true)
let base = smokeHome.appendingPathComponent("jarvis-se-smoke-\(UUID().uuidString)", isDirectory: true)
try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
func cleanupSmokeBase() {
    guard FileManager.default.fileExists(atPath: base.path) else { return }
    do { try FileManager.default.removeItem(at: base) }
    catch { fputs("JARVISSecureEnclaveSmoke cleanup failed: \(error)\n", stderr) }
}
defer { cleanupSmokeBase() }

if ProcessInfo.processInfo.environment["JARVIS_SE_REQUIRE_HARDWARE"] == "1" {
    let hardware = SecureEnclaveIdentityManager(
        keyTag: "org.gmri.jarvis.soul-anchor.smoke.hardware.\(UUID().uuidString)",
        auditLogPath: base.appendingPathComponent("hardware-audit.jsonl"),
        keysRoot: base.appendingPathComponent("keys", isDirectory: true)
    )
    // Phase I (fail-closed): the manager no longer silently autogenerates artifacts on
    // first load. Smoke acts as its own ceremony tool, explicitly issuing the audit seal
    // master blob and the hot-key blob before exercising the load path.
    try hardware.issueAuditSealMasterBlob()
    _ = try hardware.issueCryptoKitSecureEnclaveKey()
    let descriptor = try hardware.descriptor()
    try require(descriptor.mode == .secureEnclave, "Secure Enclave mode expected on this Mac")
    try require(descriptor.hardwareBindingActive, "hardware binding must be active")
    let signature = try hardware.signChallenge(Data("JARVIS Soul Anchor SE smoke challenge".utf8))
    try require(signature.mode == .secureEnclave, "challenge signature must use Secure Enclave")
    try require(signature.publicKeySHA256Hex == descriptor.publicKeySHA256Hex, "challenge signer must match hot key")
    let certificate = try hardware.createCertificate(valuesHash: String(repeating: "e", count: 64),
                                                     coldRootPublicKey: root.publicKey,
                                                     coldRootPrivateKey: root.privateKey,
                                                     createdAtUnix: "1716508800")
    let verification = SecureEnclaveIdentityManager.verifyCertificate(certificate, coldRootPublicKey: root.publicKey)
    try require(verification.ok, verification.reason ?? "certificate verification failed")
}

let fallback = SecureEnclaveIdentityManager(
    keyTag: "org.gmri.jarvis.soul-anchor.smoke.fallback.\(UUID().uuidString)",
    auditLogPath: base.appendingPathComponent("fallback-audit.jsonl"),
    forceSoftwareFallback: true
)
// Phase I (fail-closed): explicitly issue the audit seal master blob and the libsodium
// fallback keypair before invoking descriptor()/signChallenge(). The manager will not
// silently regenerate these artifacts on first call.
try fallback.issueAuditSealMasterBlob()
_ = try fallback.issueFallbackKeypair()
let fallbackDescriptor = try fallback.descriptor()
try require(fallbackDescriptor.mode == .libsodiumFallback, "forced fallback mode expected")
try require(!fallbackDescriptor.hardwareBindingActive, "fallback must not claim hardware binding")
try require(fallbackDescriptor.warning == SecureEnclaveIdentityManager.fallbackWarning, "fallback warning must be explicit")
let fallbackAudit = try String(contentsOf: base.appendingPathComponent("fallback-audit.jsonl"), encoding: .utf8)
try require(fallbackAudit.contains("hardware_binding_not_active"), "fallback audit event missing")

print("SecureEnclave smoke passed: certificate/fallback paths OK; set JARVIS_SE_REQUIRE_HARDWARE=1 to force hardware SE validation")
