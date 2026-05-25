import CCeremonyLibsodium
import Foundation

public struct SecureBytes {
    private final class Storage {
        let pointer: UnsafeMutablePointer<UInt8>
        let length: Int
        init(length: Int) throws {
            guard sodium_init() >= 0 else { throw CeremonyError.crypto("libsodium initialization failed") }
            guard length >= 0 else { throw CeremonyError.crypto("SecureBytes length cannot be negative") }
            guard let raw = sodium_malloc(length == 0 ? 1 : length) else { throw CeremonyError.crypto("sodium_malloc failed for SecureBytes") }
            let ptr = raw.bindMemory(to: UInt8.self, capacity: length == 0 ? 1 : length)
            if sodium_mlock(ptr, length == 0 ? 1 : length) != 0 {
                sodium_free(raw)
                throw CeremonyError.crypto("sodium_mlock failed for SecureBytes")
            }
            self.pointer = ptr
            self.length = length
        }
        deinit {
            sodium_memzero(pointer, length == 0 ? 1 : length)
            sodium_munlock(pointer, length == 0 ? 1 : length)
            sodium_free(pointer)
        }
    }

    private let storage: Storage
    public var count: Int { storage.length }

    public init(copying bytes: UnsafeBufferPointer<UInt8>) throws {
        self.storage = try Storage(length: bytes.count)
        if bytes.count > 0, let src = bytes.baseAddress {
            storage.pointer.initialize(from: src, count: bytes.count)
        }
    }

    public init(copying data: Data) throws {
        self.storage = try Storage(length: data.count)
        try data.withUnsafeBytes { raw in
            guard data.count == 0 || raw.baseAddress != nil else { throw CeremonyError.crypto("SecureBytes source had no base address") }
            if let base = raw.bindMemory(to: UInt8.self).baseAddress, data.count > 0 {
                storage.pointer.initialize(from: base, count: data.count)
            }
        }
    }

    public static func random(count: Int) throws -> SecureBytes {
        let secure = try SecureBytes(uninitializedCount: count)
        secure.withUnsafeMutableBytes { ptr in
            if let base = ptr.baseAddress, count > 0 { randombytes_buf(base, count) }
        }
        return secure
    }

    private init(uninitializedCount count: Int) throws { self.storage = try Storage(length: count) }

    public func withUnsafeBytes<R>(_ body: (UnsafeBufferPointer<UInt8>) throws -> R) rethrows -> R {
        try body(UnsafeBufferPointer(start: storage.pointer, count: storage.length))
    }

    fileprivate func withUnsafeMutableBytes<R>(_ body: (UnsafeMutableBufferPointer<UInt8>) throws -> R) rethrows -> R {
        try body(UnsafeMutableBufferPointer(start: storage.pointer, count: storage.length))
    }

    public func zero() {
        sodium_memzero(storage.pointer, storage.length == 0 ? 1 : storage.length)
    }
}

public struct SecureMnemonic {
    private let bytes: SecureBytes

    public init(words: [String]) throws {
        let encoded = Data(words.joined(separator: "\n").utf8)
        self.bytes = try SecureBytes(copying: encoded)
    }

    public func withMnemonicWords<R>(_ body: ([String]) throws -> R) rethrows -> R {
        try bytes.withUnsafeBytes { buffer in
            var data = Data(buffer: buffer)
            defer { data.resetBytes(in: 0..<data.count) }
            let text = String(decoding: data, as: UTF8.self)
            let words = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            return try body(words)
        }
    }

    public func withPaperBackupBytes(ceremonyHash: String, _ body: (UnsafeBufferPointer<UInt8>) throws -> Void) throws {
        try withMnemonicWords { words in
            for (index, word) in words.enumerated() {
                var line = Data("\(index + 1). \(word)\n".utf8)
                defer { line.resetBytes(in: 0..<line.count) }
                try line.withUnsafeBytes { raw in
                    guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { throw CeremonyError.crypto("paper backup line buffer unavailable") }
                    try body(UnsafeBufferPointer(start: base, count: line.count))
                }
            }
            var footer = Data("ceremony_hash: \(ceremonyHash)\n".utf8)
            defer { footer.resetBytes(in: 0..<footer.count) }
            try footer.withUnsafeBytes { raw in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { throw CeremonyError.crypto("paper backup footer buffer unavailable") }
                try body(UnsafeBufferPointer(start: base, count: footer.count))
            }
        }
    }

    public func acknowledgeRecorded() { bytes.zero() }

}
