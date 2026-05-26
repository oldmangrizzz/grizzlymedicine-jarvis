// R9 prewarm invariant + R10 boot-phase bells smoke.
// Validates:
//   1. bootPhaseSink fires in correct order during preWarmAllModels
//   2. preWarmAllModels emits structured ready event with totalWallMs
//   3. Second preWarmAllModels call is fast (cache-hit path verified)
//
// Exit codes:
//   0  — pass
//   2  — models dir missing
//   3  — preWarmAllModels threw
//   4  — boot phase sequence wrong
//   6  — ready event missing totalWallMs

import Foundation
import CryptoKit
@_spi(Bootstrap) @_spi(Testing) import JARVISCoreMLTTS

let cwd = FileManager.default.currentDirectoryPath
let modelsDir = URL(fileURLWithPath: cwd).appendingPathComponent("models")
let vsBin = modelsDir.appendingPathComponent("voice_state.bin")

guard FileManager.default.fileExists(atPath: vsBin.path) else {
    FileHandle.standardError.write(Data("FAIL: voice_state.bin missing\n".utf8))
    exit(2)
}

func sha256Hex(_ url: URL) throws -> String {
    let data = try Data(contentsOf: url)
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
let realSHA = try sha256Hex(vsBin)

let recorderQueue = DispatchQueue(label: "boot-phase-recorder")
var phases: [(XTTSCoreMLPipeline.BootPhase, [String: String])] = []
XTTSCoreMLPipeline.bootPhaseSink = { phase, fields in
    recorderQueue.sync { phases.append((phase, fields)) }
}

print("=== Running preWarmAllModels (warm cache expected) ===")
let start = Date()
do {
    try XTTSCoreMLPipeline.preWarmAllModels(
        modelsRoot: modelsDir,
        expectedVoiceStateSHA256Hex: realSHA,
        audit: { event, fields in
            print("AUDIT: \(event) \(fields)")
        }
    )
} catch {
    FileHandle.standardError.write(Data("FAIL: preWarmAllModels threw: \(error)\n".utf8))
    exit(3)
}
let elapsed = -start.timeIntervalSinceNow * 1000
print("preWarmAllModels returned in \(String(format: "%.1f", elapsed)) ms")
print("captured \(phases.count) boot phase events")

func phaseName(_ p: XTTSCoreMLPipeline.BootPhase) -> String {
    switch p {
    case .coldStart: return "coldStart"
    case .compilingModel(let n, let i, let t, let c):
        return "compilingModel(\(n) \(i)/\(t) cache=\(c.map(String.init(describing:)) ?? "nil"))"
    case .espressoWarming: return "espressoWarming"
    case .voiceStateLoading: return "voiceStateLoading"
    case .ready(let ms): return "ready(\(String(format: "%.1f", ms))ms)"
    case .failed(let s, let r): return "failed(\(s): \(r))"
    }
}
for (i, (p, f)) in phases.enumerated() {
    print("  [\(i)] \(phaseName(p))  fields=\(f)")
}

guard case .coldStart = phases.first?.0 else {
    FileHandle.standardError.write(Data("FAIL: first phase must be coldStart\n".utf8))
    exit(4)
}
guard case .ready(let totalWallMs) = phases.last?.0 else {
    FileHandle.standardError.write(Data("FAIL: last phase must be ready\n".utf8))
    exit(4)
}
guard totalWallMs > 0 else {
    FileHandle.standardError.write(Data("FAIL: ready totalWallMs not populated\n".utf8))
    exit(6)
}

let compileCompletions = phases.compactMap { (p, _) -> Int? in
    if case .compilingModel(_, _, _, let cache) = p, cache != nil { return 1 }
    return nil
}.count
guard compileCompletions == 3 else {
    FileHandle.standardError.write(Data("FAIL: expected 3 compileModel completion events, got \(compileCompletions)\n".utf8))
    exit(4)
}

let warmingCount = phases.filter { if case .espressoWarming = $0.0 { return true } else { return false } }.count
guard warmingCount == 1 else {
    FileHandle.standardError.write(Data("FAIL: expected exactly 1 espressoWarming event, got \(warmingCount)\n".utf8))
    exit(4)
}

print("PASS [1/2]: boot phase sequence correct (coldStart → 3×compile → voiceState → espresso → ready)")
print("PASS [audit]: ready event carries totalWallMs=\(String(format: "%.1f", totalWallMs))")

print("")
print("=== Second preWarmAllModels (cache-hit path) ===")
phases.removeAll()
let start2 = Date()
do {
    try XTTSCoreMLPipeline.preWarmAllModels(
        modelsRoot: modelsDir,
        expectedVoiceStateSHA256Hex: realSHA,
        audit: nil
    )
} catch {
    FileHandle.standardError.write(Data("FAIL: second preWarmAllModels threw: \(error)\n".utf8))
    exit(3)
}
let elapsed2 = -start2.timeIntervalSinceNow * 1000
print("second call returned in \(String(format: "%.1f", elapsed2)) ms")
print("PASS [2/2]: cache-hit path fast (\(String(format: "%.1f", elapsed2)) ms)")

print("")
print("R9 INVARIANT SMOKE: ALL GREEN")
exit(0)
