import CCeremonyLibsodium
import Foundation

public final class ColdRootKey {
    public let seed: SecureBytes
    public let publicKey: Data
    private let privateKey: UnsafeMutablePointer<UInt8>
    private let privateKeyCount = 64

    public init(seed seedData: Data? = nil) throws {
        guard sodium_init() >= 0 else { throw CeremonyError.crypto("libsodium initialization failed") }
        if let seedData {
            guard seedData.count == 32 else { throw CeremonyError.crypto("Ed25519 seed must be 32 bytes") }
            self.seed = try SecureBytes(copying: seedData)
        } else {
            self.seed = try SecureBytes.random(count: 32)
        }
        guard let raw = sodium_malloc(privateKeyCount) else { throw CeremonyError.crypto("sodium_malloc failed for cold private key") }
        let keyPtr = raw.bindMemory(to: UInt8.self, capacity: privateKeyCount)
        self.privateKey = keyPtr
        guard sodium_mlock(keyPtr, privateKeyCount) == 0 else { sodium_free(raw); throw CeremonyError.crypto("sodium_mlock failed for cold private key") }
        var pub = Data(count: 32)
        let rc = try self.seed.withUnsafeBytes { seedRaw in
            try pub.withUnsafeMutableBytes { pubRaw in
                guard let pubBase = pubRaw.bindMemory(to: UInt8.self).baseAddress,
                      let seedBase = seedRaw.baseAddress else { throw CeremonyError.crypto("Ed25519 seed/public key buffer unavailable") }
                return crypto_sign_seed_keypair(pubBase, keyPtr, seedBase)
            }
        }
        guard rc == 0 else { throw CeremonyError.crypto("libsodium Ed25519 keypair generation failed") }
        self.publicKey = pub
    }

    deinit {
        sodium_memzero(privateKey, privateKeyCount)
        sodium_munlock(privateKey, privateKeyCount)
        sodium_free(privateKey)
    }

    public func withColdVaultBytes(_ body: (UnsafeBufferPointer<UInt8>) throws -> Void) throws {
        try body(UnsafeBufferPointer(start: privateKey, count: privateKeyCount))
    }

    public func sign(_ message: Data) throws -> Data {
        var signature = Data(count: 64)
        var sigLen: UInt64 = 0
        let rc = try signature.withUnsafeMutableBytes { sigRaw in
            try message.withUnsafeBytes { msgRaw in
                guard let sigBase = sigRaw.bindMemory(to: UInt8.self).baseAddress,
                      let msgBase = msgRaw.bindMemory(to: UInt8.self).baseAddress else { throw CeremonyError.crypto("Ed25519 signing buffer unavailable") }
                return crypto_sign_detached(sigBase, &sigLen, msgBase, UInt64(message.count), privateKey)
            }
        }
        guard rc == 0, sigLen == 64 else { throw CeremonyError.crypto("Ed25519 signature failed") }
        return signature
    }

    public static func verify(signature: Data, message: Data, publicKey: Data) -> Bool {
        guard sodium_init() >= 0, signature.count == 64, publicKey.count == 32 else { return false }
        let rc = signature.withUnsafeBytes { sigRaw in
            message.withUnsafeBytes { msgRaw in
                publicKey.withUnsafeBytes { pubRaw in
                    guard let sigBase = sigRaw.bindMemory(to: UInt8.self).baseAddress,
                          let msgBase = msgRaw.bindMemory(to: UInt8.self).baseAddress,
                          let pubBase = pubRaw.bindMemory(to: UInt8.self).baseAddress else { return Int32(-1) }
                    return crypto_sign_verify_detached(sigBase, msgBase, UInt64(message.count), pubBase)
                }
            }
        }
        return rc == 0
    }
}
