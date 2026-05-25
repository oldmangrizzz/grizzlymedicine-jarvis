import CryptoKit
import Foundation

public enum BIP39Error: Error, CustomStringConvertible, Equatable {
    case wordlistMissing
    case fileTooLarge(actual: UInt64, limit: UInt64)
    case nonASCII(line: Int)
    case bomPresent
    case invalidLineEnding(line: Int)
    case invalidByte(line: Int, byte: UInt8)
    case whitespace(line: Int)
    case wrongWordCount(Int)
    case duplicateWord(String)
    case invalidEntropyLength(Int)
    case invalidMnemonicCount(Int)
    case wordNotInList(String)
    case checksumMismatch

    public var description: String {
        switch self {
        case .wordlistMissing: return "BIP39WordlistMissing"
        case .fileTooLarge(let actual, let limit): return "BIP39FileTooLarge(actual: \(actual), limit: \(limit))"
        case .nonASCII(let line): return "BIP39NonASCII(line: \(line))"
        case .bomPresent: return "BIP39BOMPresent"
        case .invalidLineEnding(let line): return "BIP39InvalidLineEnding(line: \(line))"
        case .invalidByte(let line, let byte): return "BIP39InvalidByte(line: \(line), byte: \(byte))"
        case .whitespace(let line): return "BIP39Whitespace(line: \(line))"
        case .wrongWordCount(let count): return "BIP39WrongWordCount(\(count))"
        case .duplicateWord(let word): return "BIP39DuplicateWord(\(word))"
        case .invalidEntropyLength(let count): return "BIP39InvalidEntropyLength(\(count))"
        case .invalidMnemonicCount(let count): return "BIP39InvalidMnemonicCount(\(count))"
        case .wordNotInList(let word): return "BIP39WordNotInList(\(word))"
        case .checksumMismatch: return "BIP39ChecksumMismatch"
        }
    }
}

public struct BIP39 {
    public static let maxWordlistBytes: UInt64 = 64 * 1024
    public let words: [String]

    public init(words: [String]? = nil) throws {
        if let words {
            self.words = try Self.validate(words: words)
        } else {
            guard let url = Bundle.module.url(forResource: "bip39_english", withExtension: "txt") else {
                throw BIP39Error.wordlistMissing
            }
            self.words = try Self.loadStrictWordlist(from: url)
        }
    }

    public init(wordlistURL: URL) throws {
        self.words = try Self.loadStrictWordlist(from: wordlistURL)
    }

    public static func loadStrictWordlist(from url: URL) throws -> [String] {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        guard size <= maxWordlistBytes else { throw BIP39Error.fileTooLarge(actual: size, limit: maxWordlistBytes) }
        let data = try Data(contentsOf: url)
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { throw BIP39Error.bomPresent }
        var entries: [String] = []
        var line = Data()
        var lineNo = 1
        var index = data.startIndex
        while index < data.endIndex {
            let byte = data[index]
            if byte == 0x0A {
                entries.append(try parseLine(line, lineNo: lineNo))
                line.removeAll(keepingCapacity: true)
                lineNo += 1
            } else if byte == 0x0D {
                let next = data.index(after: index)
                guard next < data.endIndex, data[next] == 0x0A else { throw BIP39Error.invalidLineEnding(line: lineNo) }
                entries.append(try parseLine(line, lineNo: lineNo))
                line.removeAll(keepingCapacity: true)
                lineNo += 1
                index = next
            } else {
                line.append(byte)
            }
            index = data.index(after: index)
        }
        if !line.isEmpty { entries.append(try parseLine(line, lineNo: lineNo)) }
        return try validate(words: entries)
    }

    private static func parseLine(_ data: Data, lineNo: Int) throws -> String {
        for byte in data {
            if byte < 0x20 || byte > 0x7E { throw byte > 0x7E ? BIP39Error.nonASCII(line: lineNo) : BIP39Error.invalidByte(line: lineNo, byte: byte) }
            if byte == 0x20 || byte == 0x09 { throw BIP39Error.whitespace(line: lineNo) }
        }
        guard let word = String(data: data, encoding: .ascii) else { throw BIP39Error.nonASCII(line: lineNo) }
        return word
    }

    private static func validate(words: [String]) throws -> [String] {
        guard words.count == 2048 else { throw BIP39Error.wrongWordCount(words.count) }
        var seen = Set<String>()
        for word in words {
            guard !word.isEmpty else { throw BIP39Error.invalidByte(line: 0, byte: 0) }
            for byte in word.utf8 {
                if byte < 0x20 || byte > 0x7E { throw byte > 0x7E ? BIP39Error.nonASCII(line: 0) : BIP39Error.invalidByte(line: 0, byte: byte) }
                if byte == 0x20 || byte == 0x09 { throw BIP39Error.whitespace(line: 0) }
            }
            guard seen.insert(word).inserted else { throw BIP39Error.duplicateWord(word) }
        }
        return words
    }

    public func mnemonic(from entropy: Data) throws -> [String] {
        guard entropy.count == 32 else { throw BIP39Error.invalidEntropyLength(entropy.count) }
        let checksum = Array(SHA256.hash(data: entropy))[0]
        var bits = [Bool](); bits.reserveCapacity(264)
        for b in entropy { appendBits(byte: b, count: 8, into: &bits) }
        appendBits(byte: checksum, count: 8, into: &bits)
        return stride(from: 0, to: 264, by: 11).map { offset in
            var idx = 0
            for bit in bits[offset..<offset+11] { idx = (idx << 1) | (bit ? 1 : 0) }
            return words[idx]
        }
    }

    public func entropy(from mnemonic: [String]) throws -> Data {
        guard mnemonic.count == 24 else { throw BIP39Error.invalidMnemonicCount(mnemonic.count) }
        var bits = [Bool](); bits.reserveCapacity(264)
        for word in mnemonic {
            guard let idx = words.firstIndex(of: word) else { throw BIP39Error.wordNotInList(word) }
            for shift in stride(from: 10, through: 0, by: -1) { bits.append(((idx >> shift) & 1) == 1) }
        }
        var entropy = Data(count: 32)
        for byteIndex in 0..<32 {
            var value: UInt8 = 0
            for bitIndex in 0..<8 { value = (value << 1) | (bits[byteIndex * 8 + bitIndex] ? 1 : 0) }
            entropy[byteIndex] = value
        }
        let checksum = Array(SHA256.hash(data: entropy))[0]
        for i in 0..<8 {
            let expected = ((checksum >> (7 - i)) & 1) == 1
            guard bits[256 + i] == expected else { throw BIP39Error.checksumMismatch }
        }
        return entropy
    }

    private func appendBits(byte: UInt8, count: Int, into bits: inout [Bool]) {
        for shift in stride(from: 7, through: 8 - count, by: -1) { bits.append(((byte >> shift) & 1) == 1) }
    }
}
