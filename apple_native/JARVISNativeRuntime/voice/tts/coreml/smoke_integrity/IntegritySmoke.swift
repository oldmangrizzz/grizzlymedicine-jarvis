// R8 voice_state loadtime SHA verification smoke.
// XCTest is unavailable under `swift test` in this env; this executable
// exercises the same code paths the unit tests would, without XCTest.
//
// Exit codes:
//   0  — all assertions passed
//   2  — voice_state.bin missing
//   3  — honest SHA load failed unexpectedly
//   4  — tampered SHA load did NOT throw (security failure)
//   5  — tampered SHA threw wrong error kind
//   6  — audit record was not emitted on mismatch
//   7  — audit record missing required fields
//   8  — empty/malformed anchor not rejected

import Foundation
import CryptoKit
@_spi(Testing) import JARVISCoreMLTTS

func sha256Hex(_ url: URL) throws -> String {
    let data = try Data(contentsOf: url)
    let digest = SHA256.hash(data: data)
    return digest.map { String(format: "%02x", $0) }.joined()
}

let cwd = FileManager.default.currentDirectoryPath
let modelsDir = URL(fileURLWithPath: cwd).appendingPathComponent("models")
let vsBin = modelsDir.appendingPathComponent("voice_state.bin")
let vsJSON = modelsDir.appendingPathComponent("voice_state.json")

guard FileManager.default.fileExists(atPath: vsBin.path),
      FileManager.default.fileExists(atPath: vsJSON.path) else {
    FileHandle.standardError.write(Data("FAIL: voice_state.bin or .json missing under \(modelsDir.path)\n".utf8))
    exit(2)
}

let realSHA: String
do {
    realSHA = try sha256Hex(vsBin)
} catch {
    FileHandle.standardError.write(Data("FAIL: cannot read voice_state.bin: \(error)\n".utf8))
    exit(2)
}
print("voice_state.bin SHA = \(realSHA)")

// --- Test 1: honest SHA loads cleanly, no audit emitted ---
do {
    var auditCalls: [(String, [String: String])] = []
    let audit: (String, [String: String]) -> Void = { event, fields in
        auditCalls.append((event, fields))
    }
    _ = try XTTSCoreMLPipeline.loadVoiceState(
        binURL: vsBin,
        jsonURL: vsJSON,
        expectedSHA256Hex: realSHA,
        audit: audit
    )
    if !auditCalls.isEmpty {
        FileHandle.standardError.write(Data("FAIL: audit emitted on success path: \(auditCalls)\n".utf8))
        exit(3)
    }
    print("PASS [1/4]: honest SHA accepted, no audit emitted")
} catch {
    FileHandle.standardError.write(Data("FAIL: honest SHA load threw: \(error)\n".utf8))
    exit(3)
}

// --- Test 2: empty anchor rejected (voiceStateAnchorMissing) ---
do {
    _ = try XTTSCoreMLPipeline.loadVoiceState(
        binURL: vsBin, jsonURL: vsJSON,
        expectedSHA256Hex: "", audit: nil
    )
    FileHandle.standardError.write(Data("FAIL: empty anchor accepted\n".utf8))
    exit(8)
} catch CoreMLLoaderError.voiceStateAnchorMissing {
    print("PASS [2/4]: empty anchor rejected (voiceStateAnchorMissing)")
} catch {
    FileHandle.standardError.write(Data("FAIL: empty anchor wrong error: \(error)\n".utf8))
    exit(8)
}

// --- Test 3: malformed anchor rejected (voiceStateAnchorMalformed) ---
do {
    _ = try XTTSCoreMLPipeline.loadVoiceState(
        binURL: vsBin, jsonURL: vsJSON,
        expectedSHA256Hex: "not-a-real-sha", audit: nil
    )
    FileHandle.standardError.write(Data("FAIL: malformed anchor accepted\n".utf8))
    exit(8)
} catch CoreMLLoaderError.voiceStateAnchorMalformed {
    print("PASS [3/4]: malformed anchor rejected (voiceStateAnchorMalformed)")
} catch {
    FileHandle.standardError.write(Data("FAIL: malformed anchor wrong error: \(error)\n".utf8))
    exit(8)
}

// --- Test 4: tampered SHA throws + emits audit BLOCKER ---
let tamperedSHA = String(repeating: "0", count: 64)
var capturedAudits: [(String, [String: String])] = []
let auditCapture: (String, [String: String]) -> Void = { event, fields in
    capturedAudits.append((event, fields))
}

var threw = false
var wrongKind = false
do {
    _ = try XTTSCoreMLPipeline.loadVoiceState(
        binURL: vsBin, jsonURL: vsJSON,
        expectedSHA256Hex: tamperedSHA, audit: auditCapture
    )
} catch let e as CoreMLLoaderError {
    threw = true
    switch e {
    case .voiceStateIntegrityMismatch(let expected, let actual, _):
        print("PASS [4/4]: tampered SHA rejected (voiceStateIntegrityMismatch)")
        print("  expected_prefix12=\(expected)  actual_prefix12=\(actual)")
    default:
        wrongKind = true
        FileHandle.standardError.write(Data("FAIL: expected voiceStateIntegrityMismatch, got \(e)\n".utf8))
    }
} catch {
    wrongKind = true
    FileHandle.standardError.write(Data("FAIL: unexpected error type: \(error)\n".utf8))
}

if !threw {
    FileHandle.standardError.write(Data("FAIL: tampered SHA did not throw — SECURITY REGRESSION\n".utf8))
    exit(4)
}
if wrongKind { exit(5) }

if capturedAudits.isEmpty {
    FileHandle.standardError.write(Data("FAIL: no audit emitted on mismatch\n".utf8))
    exit(6)
}

let (event, fields) = capturedAudits[0]
let requiredFields = ["expected_prefix12", "actual_prefix12", "path", "severity", "size_bytes"]
for k in requiredFields {
    guard fields[k] != nil else {
        FileHandle.standardError.write(Data("FAIL: audit missing field '\(k)'. Fields: \(fields)\n".utf8))
        exit(7)
    }
}
guard fields["severity"] == "BLOCKER" else {
    FileHandle.standardError.write(Data("FAIL: audit severity not BLOCKER: \(fields["severity"] ?? "nil")\n".utf8))
    exit(7)
}
guard event == "voice_state_loadtime_integrity_mismatch" else {
    FileHandle.standardError.write(Data("FAIL: audit event name wrong: '\(event)'\n".utf8))
    exit(7)
}
print("PASS [audit]: event='\(event)' severity=BLOCKER fields=\(fields.keys.sorted())")

print("")
print("R8 INTEGRITY SMOKE: ALL GREEN")
exit(0)
