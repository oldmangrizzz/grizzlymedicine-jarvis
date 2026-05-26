// ============================================================
// BOOT LIFECYCLE TRACKER (V4R R10)
//
// Single source of truth for JARVIS native runtime boot progress.
// Consumes the R9 bootPhaseSink fan-out from XTTSCoreMLPipeline, exposes:
//   - synchronous snapshot() for /boot/status HTTP handler
//   - AsyncStream<BootSnapshot> for UI surfaces (cockpit, iOS, watchOS)
//   - markReady() / markFailed() lifecycle transitions
//   - rolling-median ETA hint persisted to ~/.jarvis/identity/boot_timings.json
//     via §7 atomic write (O_EXCL + O_NOFOLLOW + 0600 + fsync + rename)
//
// The tracker is Foundation-only (no Network, no SwiftUI, no CoreML imports)
// so it builds standalone in the smoke executable target.
// ============================================================

import Foundation

// Snake-case BootPhase identifiers for JSON wire shape. The pipeline's R9
// enum cases map to these strings; kept in this module so the HTTP/UI layer
// never reaches into the TTS module's enum representation.
public enum BootPhaseKind: String, Sendable, Codable {
    case coldStart = "cold_start"
    case compilingModel = "compiling_model"
    case voiceStateLoading = "voice_state_loading"
    case espressoWarming = "espresso_warming"
    case ready = "ready"
    case failed = "failed"
}

public struct BootCompileDetail: Sendable, Codable, Equatable {
    public let modelIndex: Int
    public let modelTotal: Int
    public let modelName: String
    public let cacheWasCurrent: Bool?
}

public struct BootFailure: Sendable, Codable, Equatable {
    public let stage: String
    public let reason: String
}

public struct BootSnapshot: Sendable, Codable, Equatable {
    public let phase: BootPhaseKind
    public let phaseIndex: Int
    public let phaseTotal: Int
    public let compile: BootCompileDetail?
    public let elapsedMs: Int
    public let etaHintMs: Int?
    public let etaSource: String
    public let isReady: Bool
    public let startedAtUnix: Int
    public let failure: BootFailure?
    public let bytesCompiled: Int64
    public let bytesTotal: Int64

    public func jsonObject() -> [String: Any] {
        var obj: [String: Any] = [
            "phase": phase.rawValue,
            "phase_index": phaseIndex,
            "phase_total": phaseTotal,
            "elapsed_ms": elapsedMs,
            "eta_source": etaSource,
            "is_ready": isReady,
            "started_at_unix": startedAtUnix,
            "bytes_compiled": bytesCompiled,
            "bytes_total": bytesTotal,
        ]
        if let etaHintMs { obj["eta_hint_ms"] = etaHintMs } else { obj["eta_hint_ms"] = NSNull() }
        if let compile {
            obj["model_index"] = compile.modelIndex
            obj["model_total"] = compile.modelTotal
            obj["model_name"] = compile.modelName
            obj["cache_was_current"] = compile.cacheWasCurrent.map { $0 as Any } ?? NSNull()
        } else {
            obj["model_index"] = NSNull()
            obj["model_total"] = NSNull()
            obj["model_name"] = NSNull()
            obj["cache_was_current"] = NSNull()
        }
        if let failure {
            obj["failure"] = ["stage": failure.stage, "reason": failure.reason]
        } else {
            obj["failure"] = NSNull()
        }
        return obj
    }
}

// Phase index mapping. Six phases total in the non-failed lane.
private let phaseOrdinals: [BootPhaseKind: Int] = [
    .coldStart: 0,
    .compilingModel: 1,
    .voiceStateLoading: 2,
    .espressoWarming: 3,
    .ready: 4,
    .failed: 5,
]
private let phaseTotalForSnapshot = 5  // 0..4 in the happy path

public actor BootLifecycleTracker {
    public static let shared = BootLifecycleTracker()

    // F-02 ETA sanity envelope. Anything outside this window in a persisted
    // sample is treated as poison and dropped before median computation.
    // Tunable in one place; revisit only with operator authorization.
    private static let etaMinSanityMs: Int = 1_000          // 1 sec
    private static let etaMaxSanityMs: Int = 30 * 60 * 1_000 // 30 min

    private var phase: BootPhaseKind = .coldStart
    private var compile: BootCompileDetail?
    private var startedAt: Date
    private var bytesCompiled: Int64 = 0
    private var bytesTotal: Int64 = 0
    private var etaHintMs: Int?
    private var etaSource: String
    private var isReady: Bool = false
    private var failure: BootFailure?
    private var cacheWasCurrentCount: Int = 0
    private var modelsTotalCounted: Int = 0
    private var timingsPath: String
    private var continuations: [UUID: AsyncStream<BootSnapshot>.Continuation] = [:]
    private let auditSink: @Sendable (String, [String: Any]) -> Void

    public init(
        timingsPath: String? = nil,
        auditSink: (@Sendable (String, [String: Any]) -> Void)? = nil
    ) {
        let path = timingsPath ?? NSString(string: "~/.jarvis/identity/boot_timings.json").expandingTildeInPath
        self.timingsPath = path
        self.startedAt = Date()
        self.auditSink = auditSink ?? BootLifecycleTracker.defaultAudit
        // Seed ETA from prior samples (sync read on init is fine — it's a tiny
        // JSON file; we own this thread of execution at construction time).
        let (hint, source) = Self.loadEtaHint(path: path)
        self.etaHintMs = hint
        self.etaSource = source
    }

    public func snapshot() -> BootSnapshot {
        return BootSnapshot(
            phase: phase,
            phaseIndex: phaseOrdinals[phase] ?? 0,
            phaseTotal: phaseTotalForSnapshot,
            compile: compile,
            elapsedMs: Int(Date().timeIntervalSince(startedAt) * 1000.0),
            etaHintMs: etaHintMs,
            etaSource: etaSource,
            isReady: isReady,
            startedAtUnix: Int(startedAt.timeIntervalSince1970),
            failure: failure,
            bytesCompiled: bytesCompiled,
            bytesTotal: bytesTotal
        )
    }

    public func stream() -> AsyncStream<BootSnapshot> {
        let id = UUID()
        let current = snapshot()
        return AsyncStream { continuation in
            continuation.yield(current)
            self.registerContinuation(id: id, continuation: continuation)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.unregisterContinuation(id: id) }
            }
        }
    }

    private func registerContinuation(id: UUID, continuation: AsyncStream<BootSnapshot>.Continuation) {
        continuations[id] = continuation
    }

    private func unregisterContinuation(id: UUID) {
        continuations.removeValue(forKey: id)
    }

    // ---- Sink intake (called from XTTSCoreMLPipeline.bootPhaseSink via a
    //      synchronous Task-hopping shim installed by the HTTP service).

    public func recordColdStart(modelsRoot: String?, totalBytes: Int64) {
        self.phase = .coldStart
        self.startedAt = Date()
        self.bytesCompiled = 0
        self.bytesTotal = totalBytes
        self.isReady = false
        self.failure = nil
        self.compile = nil
        self.cacheWasCurrentCount = 0
        self.modelsTotalCounted = 0
        broadcast()
    }

    public func recordCompileStart(name: String, index: Int, total: Int, cacheWasCurrent: Bool?) {
        self.phase = .compilingModel
        self.compile = BootCompileDetail(
            modelIndex: index,
            modelTotal: total,
            modelName: name,
            cacheWasCurrent: cacheWasCurrent
        )
        self.modelsTotalCounted = max(modelsTotalCounted, total)
        broadcast()
    }

    public func recordCompileDone(name: String, index: Int, total: Int, cacheWasCurrent: Bool?, modelBytes: Int64) {
        self.compile = BootCompileDetail(
            modelIndex: index,
            modelTotal: total,
            modelName: name,
            cacheWasCurrent: cacheWasCurrent
        )
        self.bytesCompiled = min(bytesTotal, bytesCompiled + max(0, modelBytes))
        if cacheWasCurrent == true { self.cacheWasCurrentCount += 1 }
        broadcast()
    }

    public func recordVoiceStateLoading() {
        self.phase = .voiceStateLoading
        self.compile = nil
        broadcast()
    }

    public func recordEspressoWarming() {
        self.phase = .espressoWarming
        broadcast()
    }

    public func markReady(totalWallMs: Double) {
        let wallMs = Int(totalWallMs)
        let hintAtBoot = self.etaHintMs
        self.phase = .ready
        self.isReady = true
        self.compile = nil
        self.bytesCompiled = bytesTotal
        // Persist sample for next boot's ETA hint.
        let sample = BootTimingSample(
            unix: Int(Date().timeIntervalSince1970),
            wallMs: wallMs,
            cacheWasCurrentCount: cacheWasCurrentCount,
            modelsTotal: max(modelsTotalCounted, 0)
        )
        do {
            try Self.persistSample(path: timingsPath, sample: sample)
        } catch {
            // Persistence failure is not fatal to readiness, but DO audit it —
            // §1 no silent fallback.
            auditSink("boot_lifecycle_timings_write_failed", [
                "path": timingsPath,
                "reason": String(describing: error),
                "severity": "WARN",
            ])
        }
        auditSink("boot_lifecycle_ready", [
            "wall_ms": wallMs,
            "models_total": modelsTotalCounted,
            "cache_was_current_count": cacheWasCurrentCount,
            "eta_hint_ms_used": hintAtBoot.map { $0 as Any } ?? NSNull(),
            "eta_hint_ms_actual": wallMs,
            "eta_error_ms": hintAtBoot.map { wallMs - $0 } as Any? ?? NSNull(),
        ])
        broadcast()
    }

    public func markFailed(stage: String, reason: String) {
        // F-01 monotonicity guard: ready is a one-way latch. Failures that
        // arrive after the being is already online belong to runtime, not
        // boot. Refuse to corrupt the lifecycle state machine, but preserve
        // the event in the audit log so it remains diagnosable.
        if self.phase == .ready {
            auditSink("boot_lifecycle_post_ready_failure_rejected", [
                "stage": stage,
                "reason": reason,
                "severity": "WARN",
                "rationale": "monotonicity guard — being is already online",
            ])
            return
        }
        let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000.0)
        self.phase = .failed
        self.isReady = false
        self.failure = BootFailure(stage: stage, reason: reason)
        auditSink("boot_lifecycle_failed", [
            "stage": stage,
            "reason": reason,
            "elapsed_ms": elapsedMs,
            "severity": "BLOCKER",
        ])
        broadcast()
    }

    private func broadcast() {
        let snap = snapshot()
        for (_, continuation) in continuations {
            continuation.yield(snap)
        }
    }

    // ---- ETA persistence (§7 atomic write) ----

    private struct BootTimingSample: Codable {
        let unix: Int
        let wallMs: Int
        let cacheWasCurrentCount: Int
        let modelsTotal: Int

        enum CodingKeys: String, CodingKey {
            case unix
            case wallMs = "wall_ms"
            case cacheWasCurrentCount = "cache_was_current_count"
            case modelsTotal = "models_total"
        }
    }

    private struct BootTimingsFile: Codable {
        var version: Int
        var samples: [BootTimingSample]
        var maxSamples: Int

        enum CodingKeys: String, CodingKey {
            case version
            case samples
            case maxSamples = "max_samples"
        }
    }

    private static func loadEtaHint(path: String) -> (Int?, String) {
        guard FileManager.default.fileExists(atPath: path) else {
            return (nil, "no_prior_estimate")
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              !data.isEmpty,
              let file = try? JSONDecoder().decode(BootTimingsFile.self, from: data),
              !file.samples.isEmpty else {
            return (nil, "no_prior_estimate")
        }
        // Use up to last 5 samples. Median.
        let recent = Array(file.samples.suffix(5))
        // F-02: drop samples outside sanity envelope before computing median.
        // A poisoned timings file (hand-edited, test residue, partial write
        // with bogus value) must not surface as "-83 min" or "24 day" ETA on
        // the boot screen.
        let survivors = recent.filter {
            $0.wallMs >= etaMinSanityMs && $0.wallMs <= etaMaxSanityMs
        }
        guard !survivors.isEmpty else {
            return (nil, "no_prior_estimate")
        }
        let sorted = survivors.map { $0.wallMs }.sorted()
        let median: Int
        if sorted.count % 2 == 1 {
            median = sorted[sorted.count / 2]
        } else {
            median = (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
        }
        return (median, "rolling_median_\(sorted.count)")
    }

    private static func persistSample(path: String, sample: BootTimingSample) throws {
        var file: BootTimingsFile
        if FileManager.default.fileExists(atPath: path),
           let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let decoded = try? JSONDecoder().decode(BootTimingsFile.self, from: data) {
            file = decoded
            file.samples.append(sample)
            if file.samples.count > file.maxSamples {
                file.samples = Array(file.samples.suffix(file.maxSamples))
            }
        } else {
            file = BootTimingsFile(version: 1, samples: [sample], maxSamples: 5)
        }
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let payload = try encoder.encode(file)
        try atomicWriteSecure(path: path, data: payload)
    }

    private static func atomicWriteSecure(path: String, data: Data) throws {
        // §7: O_EXCL + O_NOFOLLOW + 0600 + fsync + rename. Temp lives next to
        // the target so the rename is atomic on the same filesystem.
        let dir = (path as NSString).deletingLastPathComponent
        let base = (path as NSString).lastPathComponent
        let tmp = "\(dir)/.\(base).tmp.\(getpid()).\(UUID().uuidString)"
        let flags: Int32 = O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC
        let fd = open(tmp, flags, 0o600)
        if fd < 0 {
            throw NSError(domain: "BootLifecycleTracker", code: Int(errno), userInfo: [
                NSLocalizedDescriptionKey: "open(O_EXCL|O_NOFOLLOW) failed: \(String(cString: strerror(errno)))",
                "path": tmp,
            ])
        }
        defer { close(fd) }
        var bytesRemaining = data.count
        var offset = 0
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            while bytesRemaining > 0 {
                let n = write(fd, base.advanced(by: offset), bytesRemaining)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw NSError(domain: "BootLifecycleTracker", code: Int(errno), userInfo: [
                        NSLocalizedDescriptionKey: "write failed: \(String(cString: strerror(errno)))",
                    ])
                }
                bytesRemaining -= n
                offset += n
            }
        }
        if fsync(fd) != 0 {
            throw NSError(domain: "BootLifecycleTracker", code: Int(errno), userInfo: [
                NSLocalizedDescriptionKey: "fsync failed: \(String(cString: strerror(errno)))",
            ])
        }
        if rename(tmp, path) != 0 {
            let renameErr = errno
            unlink(tmp)
            throw NSError(domain: "BootLifecycleTracker", code: Int(renameErr), userInfo: [
                NSLocalizedDescriptionKey: "rename failed: \(String(cString: strerror(renameErr)))",
            ])
        }
    }

    // ---- Default audit sink (writes via NativeSecurityAudit when present).
    //      The smoke target replaces this with an in-memory capture sink.

    public static let defaultAudit: @Sendable (String, [String: Any]) -> Void = { event, fields in
        // We cannot reference NativeSecurityAudit directly here because this
        // file is also pulled into the smoke executable target which doesn't
        // have the audit module. The HTTP service installs a real sink at
        // BootLifecycleTracker.shared construction time via dependency
        // injection in production. This default is a stderr breadcrumb so a
        // miswired tracker still leaves a trail.
        var pairs: [String] = []
        for (k, v) in fields { pairs.append("\(k)=\(v)") }
        fputs("[boot_lifecycle] event=\(event) \(pairs.joined(separator: " "))\n", stderr)
    }
}

// MARK: - Models-root byte total helper

public enum BootModelsBytes {
    /// Sum of .mlpackage directory sizes for the three prewarmed models. The
    /// .mlpackage is the compile source (what Espresso ingests). .mlmodelc
    /// caches are derived, so we report the source bytes as "compile cost".
    public static func computeTotalBytes(modelsRoot: URL) -> Int64 {
        let packages = ["text_encoder.mlpackage", "flow_decoder.mlpackage", "mimi_decoder.mlpackage"]
        var total: Int64 = 0
        for pkg in packages {
            let url = modelsRoot.appendingPathComponent(pkg)
            total += directoryBytes(url)
        }
        return total
    }

    public static func bytesForModel(modelsRoot: URL, modelName: String) -> Int64 {
        // R9 BootPhase names match the model basename (e.g. "text_encoder").
        let pkg = modelsRoot.appendingPathComponent("\(modelName).mlpackage")
        return directoryBytes(pkg)
    }

    private static func directoryBytes(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true, let size = values?.fileSize {
                total += Int64(size)
            }
        }
        return total
    }
}
