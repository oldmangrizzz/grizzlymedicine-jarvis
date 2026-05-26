// HashParitySmoke.swift — CLI tool for hash parity verification.
// Used by test_manifest_hash_parity.swift to obtain Swift side hash for comparison.
// Usage: HashParitySmoke <directory_path>
// Output: 64-char lowercase hex to stdout.

import Foundation
@_spi(Testing) import JARVISCoreMLTTS

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: HashParitySmoke <directory_path>\n", stderr)
    exit(1)
}

let dirURL = URL(fileURLWithPath: CommandLine.arguments[1])
do {
    let hash = try XTTSCoreMLPipeline.hashDirectoryManifestForTesting(dirURL)
    print(hash)
} catch {
    fputs("Error: \(error)\n", stderr)
    exit(1)
}
