// test_manifest_hash_parity.swift — v4r-r6-hash-algo-reconcile
//
// Proves that Swift recursiveDirectoryManifestHex and the C++ sha256PackageManifestHexSodium
// algorithm (represented by ManifestHashHarness) produce identical hashes on the same directory.
//
// Run: swift test --filter ManifestHashParityTests

import XCTest
import Foundation
@_spi(Testing) import JARVISCoreMLTTS

final class ManifestHashParityTests: XCTestCase {

    // MARK: - Harness lookup

    /// Locate the ManifestHashHarness binary built alongside the test suite.
    /// swift test builds all targets into .build/<platform>/<config>/; the test binary's
    /// directory sibling is where executables land.
    private static func harnessURL() throws -> URL {
        let testBinaryDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        let harness = testBinaryDir.appendingPathComponent("ManifestHashHarness")
        guard FileManager.default.fileExists(atPath: harness.path) else {
            throw XCTestError(.failureWhileWaiting,
                              userInfo: [NSLocalizedDescriptionKey:
                                "ManifestHashHarness not found at \(harness.path). " +
                                "Build the ManifestHashHarness target before running tests."])
        }
        return harness
    }

    /// Run the C++ harness on dirPath; returns the 64-char hex string or throws.
    private func cppManifestHash(for dirPath: String) throws -> String {
        let harness = try Self.harnessURL()
        let proc = Process()
        proc.executableURL = harness
        proc.arguments = [dirPath]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            if let errData = (proc.standardError as? Pipe).map({ $0.fileHandleForReading.readDataToEndOfFile() }),
               let errStr = String(data: errData, encoding: .utf8) {
                throw XCTestError(.failureWhileWaiting,
                                  userInfo: [NSLocalizedDescriptionKey:
                                    "ManifestHashHarness exited \(proc.terminationStatus): \(errStr)"])
            }
            throw XCTestError(.failureWhileWaiting,
                              userInfo: [NSLocalizedDescriptionKey:
                                "ManifestHashHarness exited \(proc.terminationStatus)"])
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let raw = String(data: data, encoding: .utf8) else {
            throw XCTestError(.failureWhileWaiting,
                              userInfo: [NSLocalizedDescriptionKey: "ManifestHashHarness produced non-UTF8 output"])
        }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Test fixture setup

    /// Create a controlled directory tree for deterministic hashing.
    /// Returns the root URL. The caller is responsible for cleanup.
    private func makeFixtureDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jarvis_hash_parity_\(ProcessInfo.processInfo.processIdentifier)_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        // Normal file
        try "hello world\n".write(to: root.appendingPathComponent("normal.txt"), atomically: true, encoding: .utf8)

        // Zero-byte (empty) file
        try Data().write(to: root.appendingPathComponent("empty.dat"))

        // Deeply nested file
        let nested = root.appendingPathComponent("a/b/c", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try "deep content\n".write(to: nested.appendingPathComponent("deep.txt"), atomically: true, encoding: .utf8)

        // Hidden file — must be HASHED by both sides (not allowlisted)
        try "hidden content\n".write(to: root.appendingPathComponent(".hidden_file"), atomically: true, encoding: .utf8)

        // Allowlisted file — must be SKIPPED by both sides
        try "ds store noise\n".write(to: root.appendingPathComponent(".DS_Store"), atomically: true, encoding: .utf8)

        // Another file to ensure sort order is exercised
        try "zebra\n".write(to: root.appendingPathComponent("z_last.bin"), atomically: true, encoding: .utf8)
        try "alpha\n".write(to: root.appendingPathComponent("a_first.bin"), atomically: true, encoding: .utf8)

        return root
    }

    // MARK: - Parity test

    func testSwiftAndCppHashIdentical() throws {
        guard (try? Self.harnessURL()) != nil else {
            throw XCTSkip("ManifestHashHarness binary not built; run: swift build --target ManifestHashHarness")
        }

        let root = try makeFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        // Swift side
        let swiftHash = try XTTSCoreMLPipeline.hashDirectoryManifestForTesting(root)
        XCTAssertEqual(swiftHash.count, 64, "Swift hash must be 64-char lowercase hex")

        // C++ side
        let cppHash = try cppManifestHash(for: root.path)
        XCTAssertEqual(cppHash.count, 64, "C++ harness hash must be 64-char lowercase hex")

        // THE PARITY ASSERTION
        XCTAssertEqual(swiftHash, cppHash,
                       "Swift and C++ manifest hash algorithms must produce identical output.\n" +
                       "Swift: \(swiftHash)\n" +
                       "C++:   \(cppHash)")

        // Confirm .DS_Store was ignored: compute hash with .DS_Store deleted and verify
        // same result — proving the allowlist fires on both sides.
        let dsStoreURL = root.appendingPathComponent(".DS_Store")
        try FileManager.default.removeItem(at: dsStoreURL)
        let swiftHashNoDSStore = try XTTSCoreMLPipeline.hashDirectoryManifestForTesting(root)
        let cppHashNoDSStore = try cppManifestHash(for: root.path)
        XCTAssertEqual(swiftHash, swiftHashNoDSStore,
                       "Swift: removing .DS_Store must not change hash (allowlisted)")
        XCTAssertEqual(cppHash, cppHashNoDSStore,
                       "C++: removing .DS_Store must not change hash (allowlisted)")
        XCTAssertEqual(swiftHashNoDSStore, cppHashNoDSStore,
                       "Swift and C++ must still agree after .DS_Store removal")

        // Confirm hidden file IS hashed: removing .hidden_file must change the hash.
        let hiddenURL = root.appendingPathComponent(".hidden_file")
        try FileManager.default.removeItem(at: hiddenURL)
        let swiftHashNoHidden = try XTTSCoreMLPipeline.hashDirectoryManifestForTesting(root)
        let cppHashNoHidden = try cppManifestHash(for: root.path)
        XCTAssertNotEqual(swiftHashNoDSStore, swiftHashNoHidden,
                          "Swift: removing a non-allowlisted hidden file must change hash")
        XCTAssertNotEqual(cppHashNoDSStore, cppHashNoHidden,
                          "C++: removing a non-allowlisted hidden file must change hash")
        XCTAssertEqual(swiftHashNoHidden, cppHashNoHidden,
                       "Swift and C++ must agree after hidden file removal")
    }

    // MARK: - Determinism test

    func testSwiftHashIsDeterministic() throws {
        let root = try makeFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let hash1 = try XTTSCoreMLPipeline.hashDirectoryManifestForTesting(root)
        let hash2 = try XTTSCoreMLPipeline.hashDirectoryManifestForTesting(root)
        XCTAssertEqual(hash1, hash2, "Same directory must produce same hash on two calls")
    }
}
