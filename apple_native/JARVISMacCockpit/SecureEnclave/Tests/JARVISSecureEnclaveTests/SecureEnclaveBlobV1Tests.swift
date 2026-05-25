import XCTest
@testable import JARVISSecureEnclave

final class SecureEnclaveBlobV1Tests: XCTestCase {
    func testRoundTripWorks() throws {
        let plaintext = Data((0..<64).map(UInt8.init))
        let blob = try SecureEnclaveBlobV1.serialize(plaintext: plaintext, keyTag: "tag-a")
        XCTAssertEqual(try SecureEnclaveBlobV1.open(blob, keyTag: "tag-a"), plaintext)
    }

    func testByteFlipAtEveryOffsetRejects() throws {
        let blob = try SecureEnclaveBlobV1.serialize(plaintext: Data((0..<64).map(UInt8.init)), keyTag: "tag-a")
        for offset in blob.indices {
            var tampered = blob
            tampered[offset] ^= 0xff
            XCTAssertThrowsError(try SecureEnclaveBlobV1.open(tampered, keyTag: "tag-a"), "offset \(offset) accepted")
        }
    }

    func testCrossKeytagCopyRejects() throws {
        let blob = try SecureEnclaveBlobV1.serialize(plaintext: Data("secret".utf8), keyTag: "tag-a")
        XCTAssertThrowsError(try SecureEnclaveBlobV1.open(blob, keyTag: "tag-b")) { error in
            XCTAssertEqual(error as? BlobIntegrityError, .keytagMismatch)
        }
    }

    func testMagicMismatchRejects() throws {
        var blob = try SecureEnclaveBlobV1.serialize(plaintext: Data("secret".utf8), keyTag: "tag-a")
        blob[0] = 0
        XCTAssertThrowsError(try SecureEnclaveBlobV1.open(blob, keyTag: "tag-a")) { error in
            XCTAssertEqual(error as? BlobIntegrityError, .magicMismatch)
        }
    }

    func testMigrationSerializesOldPlaintextOnce() throws {
        let old = Data("old-cryptokit-blob".utf8)
        XCTAssertFalse(SecureEnclaveBlobV1.isVersioned(old))
        let migrated = try SecureEnclaveBlobV1.serialize(plaintext: old, keyTag: "tag-a")
        XCTAssertTrue(SecureEnclaveBlobV1.isVersioned(migrated))
        XCTAssertEqual(try SecureEnclaveBlobV1.open(migrated, keyTag: "tag-a"), old)
        let reopened = try SecureEnclaveBlobV1.open(migrated, keyTag: "tag-a")
        XCTAssertEqual(reopened, old)
    }
}

extension SecureEnclaveBlobV1Tests {
    func testBlobV1UsesXChaChaTwentyFourByteNonce() throws {
        XCTAssertTrue(SecureEnclaveBlobV1.cipherNameForTest.contains("XChaCha20-Poly1305"))
        XCTAssertEqual(SecureEnclaveBlobV1.nonceLengthForTest, 24)
        let blob = try SecureEnclaveBlobV1.serialize(plaintext: Data("nonce-check".utf8), keyTag: "tag-a")
        XCTAssertGreaterThanOrEqual(blob.count, SecureEnclaveBlobV1.magic.count + 32 + 24 + 16)
    }

    func testChaChaTwentyPoly1305TwelveByteNonceBlobIsRefusedByV1Parser() throws {
        let keyTag = "tag-a"
        var forged = Data()
        forged.append(SecureEnclaveBlobV1.magic)
        forged.append(try XCTUnwrap(unhex(SecureEnclaveBlobV1.keytagSHA256Hex(keyTag))))
        forged.append(Data(repeating: 7, count: 12))
        forged.append(Data(repeating: 8, count: 32))
        XCTAssertThrowsError(try SecureEnclaveBlobV1.open(forged, keyTag: keyTag))
    }
}
