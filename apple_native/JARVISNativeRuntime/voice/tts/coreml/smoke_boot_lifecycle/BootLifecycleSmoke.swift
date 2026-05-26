// BootLifecycleSmoke — V4R R10
//
// Exercises BootLifecycleTracker without paying CoreML compile cost.
// Verifies:
//   1. Snapshot transitions across the 6 BootPhase events
//   2. AsyncStream broadcast delivers every snapshot
//   3. /boot/status JSON shape is well-formed
//   4. ETA persistence via §7 atomic write (O_EXCL+fsync+rename, mode 0600)
//   5. ETA hint roundtrip: 2nd boot reads median from prior samples
//   6. markFailed records BLOCKER audit + leaves isReady false
//   7. Gate behaviour: snapshot.isReady=false → 503 caller, true → 200 caller
//
// Exit 0 = green. Non-zero = red.

import Foundation

// In-memory audit capture so we can assert audit emissions.
final class AuditCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [(String, [String: Any])] = []

    func record(_ event: String, _ fields: [String: Any]) {
        lock.lock()
        events.append((event, fields))
        lock.unlock()
    }

    func all() -> [(String, [String: Any])] {
        lock.lock(); defer { lock.unlock() }
        return events
    }

    func first(_ name: String) -> (String, [String: Any])? {
        all().first { $0.0 == name }
    }
}

var failures: [String] = []

func require(_ condition: Bool, _ msg: String, file: StaticString = #file, line: UInt = #line) {
    if !condition {
        let s = "FAIL [\(file):\(line)] \(msg)"
        fputs(s + "\n", stderr)
        failures.append(s)
    } else {
        print("OK   \(msg)")
    }
}

func tempTimingsPath(_ tag: String) -> String {
    let tmp = NSTemporaryDirectory()
    let dir = (tmp as NSString).appendingPathComponent("jarvis-boot-smoke-\(getpid())-\(tag)")
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: nil)
    return (dir as NSString).appendingPathComponent("boot_timings.json")
}

func runSmoke() async {
    print("=== R10 Boot Lifecycle Smoke ===")
    print("")

    // Test 1: snapshot transitions across the 6 BootPhase events.
    let path1 = tempTimingsPath("t1")
    let audit1 = AuditCapture()
    let tracker1 = BootLifecycleTracker(timingsPath: path1, auditSink: { e, f in audit1.record(e, f) })

    let initial = await tracker1.snapshot()
    require(initial.phase == .coldStart, "T1 initial phase is cold_start")
    require(!initial.isReady, "T1 initial isReady is false")
    require(initial.etaHintMs == nil, "T1 first-boot ETA hint is nil")
    require(initial.etaSource == "no_prior_estimate", "T1 first-boot ETA source is no_prior_estimate")

    await tracker1.recordColdStart(modelsRoot: "/tmp/fake", totalBytes: 100_000_000)
    let s1 = await tracker1.snapshot()
    require(s1.bytesTotal == 100_000_000, "T1 bytesTotal set")
    require(s1.bytesCompiled == 0, "T1 bytesCompiled starts at 0")

    // Compile model 1: start, then done.
    await tracker1.recordCompileStart(name: "text_encoder", index: 1, total: 3, cacheWasCurrent: nil)
    let s2 = await tracker1.snapshot()
    require(s2.phase == .compilingModel, "T1 phase is compiling_model after compile start")
    require(s2.compile?.modelName == "text_encoder", "T1 compile detail names text_encoder")
    require(s2.compile?.cacheWasCurrent == nil, "T1 compile-start has cacheWasCurrent=nil")

    await tracker1.recordCompileDone(name: "text_encoder", index: 1, total: 3, cacheWasCurrent: true, modelBytes: 30_000_000)
    let s3 = await tracker1.snapshot()
    require(s3.compile?.cacheWasCurrent == true, "T1 compile-done has cacheWasCurrent=true")
    require(s3.bytesCompiled == 30_000_000, "T1 bytesCompiled advanced to 30M")

    // Compile remaining models.
    await tracker1.recordCompileStart(name: "flow_decoder", index: 2, total: 3, cacheWasCurrent: nil)
    await tracker1.recordCompileDone(name: "flow_decoder", index: 2, total: 3, cacheWasCurrent: false, modelBytes: 50_000_000)
    await tracker1.recordCompileStart(name: "mimi_decoder", index: 3, total: 3, cacheWasCurrent: nil)
    await tracker1.recordCompileDone(name: "mimi_decoder", index: 3, total: 3, cacheWasCurrent: true, modelBytes: 20_000_000)
    let s4 = await tracker1.snapshot()
    require(s4.bytesCompiled == 100_000_000, "T1 bytesCompiled at 100M after all 3 models")

    await tracker1.recordVoiceStateLoading()
    let s5 = await tracker1.snapshot()
    require(s5.phase == .voiceStateLoading, "T1 phase advances to voice_state_loading")
    require(s5.compile == nil, "T1 compile detail cleared after voice_state_loading")

    await tracker1.recordEspressoWarming()
    let s6 = await tracker1.snapshot()
    require(s6.phase == .espressoWarming, "T1 phase advances to espresso_warming")

    await tracker1.markReady(totalWallMs: 336_000.0)
    let s7 = await tracker1.snapshot()
    require(s7.phase == .ready, "T1 phase advances to ready")
    require(s7.isReady == true, "T1 isReady flips true on markReady")
    require(s7.bytesCompiled == s7.bytesTotal, "T1 bytesCompiled saturates to bytesTotal on ready")

    // Test 4: ETA persistence file exists, mode 0600, parseable.
    require(FileManager.default.fileExists(atPath: path1), "T4 boot_timings.json written")
    if let attrs = try? FileManager.default.attributesOfItem(atPath: path1),
       let perms = attrs[.posixPermissions] as? NSNumber {
        require(perms.intValue == 0o600, "T4 boot_timings.json mode is 0600 (got \(String(perms.intValue, radix: 8)))")
    } else {
        require(false, "T4 could not read boot_timings.json attrs")
    }
    if let data = try? Data(contentsOf: URL(fileURLWithPath: path1)),
       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        require(json["version"] as? Int == 1, "T4 timings file version=1")
        let samples = json["samples"] as? [[String: Any]] ?? []
        require(samples.count == 1, "T4 timings file has 1 sample (got \(samples.count))")
        if let first = samples.first {
            require(first["wall_ms"] as? Int == 336_000, "T4 sample wall_ms=336000")
            require(first["cache_was_current_count"] as? Int == 2, "T4 cache_was_current_count=2 (text+mimi)")
        }
    } else {
        require(false, "T4 timings file not parseable")
    }

    // Test 6: audit emission for ready event.
    if let (_, fields) = audit1.first("boot_lifecycle_ready") {
        require(fields["wall_ms"] as? Int == 336_000, "T6 audit boot_lifecycle_ready has wall_ms=336000")
        require(fields["models_total"] as? Int == 3, "T6 audit boot_lifecycle_ready has models_total=3")
        require(fields["cache_was_current_count"] as? Int == 2, "T6 audit cache_was_current_count=2")
    } else {
        require(false, "T6 boot_lifecycle_ready audit event missing")
    }

    // Test 5: ETA hint roundtrip. Construct second tracker on same path,
    // confirm it reads the sample as the hint.
    let tracker2 = BootLifecycleTracker(timingsPath: path1, auditSink: { _, _ in })
    let snap2 = await tracker2.snapshot()
    require(snap2.etaHintMs == 336_000, "T5 second tracker reads 336000 from prior sample (got \(String(describing: snap2.etaHintMs)))")
    require(snap2.etaSource == "rolling_median_1", "T5 second tracker eta_source is rolling_median_1 (got \(snap2.etaSource))")

    // Test 7: markFailed leaves isReady false + BLOCKER audit + failure populated.
    let path7 = tempTimingsPath("t7")
    let audit7 = AuditCapture()
    let tracker7 = BootLifecycleTracker(timingsPath: path7, auditSink: { e, f in audit7.record(e, f) })
    await tracker7.recordColdStart(modelsRoot: "/tmp/fake", totalBytes: 100_000_000)
    await tracker7.markFailed(stage: "espresso_warmup", reason: "ENEEDOMEM (mocked)")
    let snap7 = await tracker7.snapshot()
    require(snap7.phase == .failed, "T7 phase is failed after markFailed")
    require(!snap7.isReady, "T7 isReady remains false after markFailed")
    require(snap7.failure?.stage == "espresso_warmup", "T7 failure.stage populated")
    if let (_, fields) = audit7.first("boot_lifecycle_failed") {
        require((fields["severity"] as? String) == "BLOCKER", "T7 failed audit severity=BLOCKER")
        require((fields["stage"] as? String) == "espresso_warmup", "T7 failed audit stage=espresso_warmup")
    } else {
        require(false, "T7 boot_lifecycle_failed audit event missing")
    }

    // Test 3: JSON shape sanity.
    let json = snap7.jsonObject()
    let mandatoryKeys = [
        "phase", "phase_index", "phase_total", "elapsed_ms", "eta_source",
        "is_ready", "started_at_unix", "bytes_compiled", "bytes_total",
        "eta_hint_ms", "model_index", "model_total", "model_name",
        "cache_was_current", "failure",
    ]
    for k in mandatoryKeys {
        require(json[k] != nil, "T3 JSON has mandatory key '\(k)'")
    }

    // Test 8: gate semantics (caller side simulation).
    let readySnap = s7
    let notReadySnap = snap7
    require(!notReadySnap.isReady, "T8 not-ready snapshot.isReady is false (caller should 503)")
    require(readySnap.isReady, "T8 ready snapshot.isReady is true (caller should 200)")

    // Test 2: AsyncStream broadcast delivers updates.
    let path9 = tempTimingsPath("t9")
    let tracker9 = BootLifecycleTracker(timingsPath: path9, auditSink: { _, _ in })
    var streamedPhases: [BootPhaseKind] = []
    let stream = await tracker9.stream()
    let collector = Task {
        var collected: [BootPhaseKind] = []
        for await snap in stream {
            collected.append(snap.phase)
            if snap.phase == .ready { break }
        }
        return collected
    }
    try? await Task.sleep(nanoseconds: 50_000_000)
    await tracker9.recordColdStart(modelsRoot: "/tmp/fake", totalBytes: 1000)
    await tracker9.recordCompileStart(name: "text_encoder", index: 1, total: 1, cacheWasCurrent: nil)
    await tracker9.recordCompileDone(name: "text_encoder", index: 1, total: 1, cacheWasCurrent: true, modelBytes: 1000)
    await tracker9.recordVoiceStateLoading()
    await tracker9.recordEspressoWarming()
    await tracker9.markReady(totalWallMs: 100.0)
    streamedPhases = await collector.value
    require(streamedPhases.contains(.coldStart), "T2 stream delivered coldStart")
    require(streamedPhases.contains(.compilingModel), "T2 stream delivered compilingModel")
    require(streamedPhases.contains(.voiceStateLoading), "T2 stream delivered voiceStateLoading")
    require(streamedPhases.contains(.espressoWarming), "T2 stream delivered espressoWarming")
    require(streamedPhases.contains(.ready), "T2 stream delivered ready")

    print("")
    print("=== Results ===")
    if failures.isEmpty {
        print("ALL TESTS GREEN")
        // Show one ready-state JSON for operator's eye.
        if let data = try? JSONSerialization.data(withJSONObject: s7.jsonObject(), options: [.prettyPrinted, .sortedKeys]),
           let s = String(data: data, encoding: .utf8) {
            print("--- sample /boot/status payload (ready) ---")
            print(s)
        }
        if let data = try? Data(contentsOf: URL(fileURLWithPath: path1)),
           let s = String(data: data, encoding: .utf8) {
            print("--- boot_timings.json after 1 boot ---")
            print(s)
        }
        exit(0)
    } else {
        print("FAILURES (\(failures.count)):")
        for f in failures { print("  \(f)") }
        exit(1)
    }
}

@main
struct BootLifecycleSmokeMain {
    static func main() async {
        await runSmoke()
    }
}
