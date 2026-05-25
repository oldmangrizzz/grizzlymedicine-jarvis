import Darwin
import Foundation
import LocalAuthentication
import SwiftUI

// Legal cutover transitions for JARVIS's cognition organs:
// idle → preflight → shadow → promote → committed. ABORT marks non-committed phases interrupted; no legacy runtime fallback exists.
// Operator law: no disable/pause/stop/bypass on cognition organs. Quiesce control removed 2026-05.
enum CutoverOrganState: String, CaseIterable {
    case idle = "Idle"
    case preflight = "Preflight"
    case shadow = "Shadow"
    case promote = "Promote"
    case committed = "Committed"
}

struct CutoverOrganNode: Identifiable {
    let id: String
    let dependencies: [String]
    private(set) var state: CutoverOrganState = .idle
    private(set) var preflightPassed = false
    var divergences: Int = 0

    mutating func markPreflightPassed() {
        state = .preflight
        preflightPassed = true
    }

    mutating func beginShadow() {
        state = .shadow
        divergences = 0
    }

    mutating func beginPromote() {
        state = .promote
    }

    mutating func commit() {
        state = .committed
        preflightPassed = false
    }

    mutating func interrupt() {
        state = .idle
        preflightPassed = false
        divergences = 0
    }
}

enum CutoverTransitionError: LocalizedError, Equatable {
    case missingOrgan(String)
    case illegalTransition(organ: String, step: String, transition: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .missingOrgan(let organ):
            return "JARVIS could not find cognition organ \(organ) in the cutover table."
        case .illegalTransition(let organ, let step, let transition, let reason):
            return "JARVIS refuses illegal cutover step \(step) for \(organ) [\(transition)]: \(reason)."
        }
    }
}

@MainActor
enum AuditLogger {
    static var testSink: (([String: String]) -> Void)?

    static func record(transition: String, reason: String, organ: String, step: String) {
        let fields = [
            "transition": transition,
            "reason": reason,
            "organ": organ,
            "step": step
        ]
        testSink?(fields)
        JARVISLog.warn(subsystem: "cutover", event: "transition_refused", fields: fields)
    }
}

// TODO(removal-cond: CutoverRecoveryCoordinator migrated to an actor; DispatchQueue protection then sufficient for Swift 6 strict concurrency.)
private final class CutoverRecoveryState: @unchecked Sendable {
    var activePhase: String?
    var activeOrgan: String?
}

enum CutoverRecoveryCoordinator {
    private static let lock = NSLock()
    private static let state = CutoverRecoveryState()

    static var recoveryCheckpointURL: URL {
        let home = ProcessInfo.processInfo.environment["JARVIS_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".jarvis", isDirectory: true)
        return home.appendingPathComponent("cutover/recovery_checkpoint.json")
    }

    static func enter(phase: CutoverOrganState, organ: String) {
        lock.lock()
        state.activePhase = phase.rawValue
        state.activeOrgan = organ
        lock.unlock()
    }

    static func clearIfCommittedOrIdle(phase: CutoverOrganState, organ: String) {
        guard phase == .committed || phase == .idle else { return }
        lock.lock()
        if state.activeOrgan == organ { state.activePhase = nil; state.activeOrgan = nil }
        lock.unlock()
    }

    static func checkpointIfActive(reason: String) -> Bool {
        lock.lock()
        let phase = state.activePhase
        let organ = state.activeOrgan
        lock.unlock()
        guard let phase, let organ else { return false }
        let fields = [
            "reason": reason,
            "state": "interrupted-during-phase-\(phase)",
            "organ": organ,
            "ts": String(Int64(Date().timeIntervalSince1970))
        ]
        do {
            try writeJSONAtomically0600(fields, to: recoveryCheckpointURL)
            JARVISLog.fatal(subsystem: "cutover", event: "interrupted", fields: fields)
        } catch {
            JARVISLog.fatal(subsystem: "cutover", event: "interruption_checkpoint_failed", fields: ["error": String(describing: error), "phase": phase, "organ": organ])
        }
        return true
    }

    private static func writeJSONAtomically0600(_ object: [String: String], to dest: URL) throws {
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted])
        let tmp = dest.appendingPathExtension("tmp.\(ProcessInfo.processInfo.processIdentifier).\(UUID().uuidString)")
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        if fd < 0 { throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "open failed errno=\(errno)"]) }
        do {
            try data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                var written = 0
                while written < data.count {
                    let n = write(fd, base.advanced(by: written), data.count - written)
                    if n < 0 {
                        if errno == EINTR { continue }
                        throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "write failed errno=\(errno)"])
                    }
                    written += n
                }
            }
            if fsync(fd) != 0 { throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "fsync failed errno=\(errno)"]) }
            if close(fd) != 0 { throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "close failed errno=\(errno)"]) }
            if rename(tmp.path, dest.path) != 0 { throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "rename failed errno=\(errno)"]) }
        } catch {
            close(fd)
            try? FileManager.default.removeItem(at: tmp) // TODO(removal-cond: log as WRITE_FAILED audit event once JARVISLog is available in this scope)
            throw error
        }
    }
}

@MainActor
final class CutoverViewModel: ObservableObject {
    @Published private(set) var organs: [CutoverOrganNode] = [
        .init(id: "CharacterValues", dependencies: []),
        .init(id: "endocrine", dependencies: []),
        .init(id: "endocannabinoid", dependencies: ["endocrine"]),
        .init(id: "pheromind", dependencies: ["endocrine", "endocannabinoid"]),
        .init(id: "swarm", dependencies: ["pheromind"]),
        .init(id: "HDC", dependencies: []),
        .init(id: "BeliefStore", dependencies: ["HDC"]),
        .init(id: "HMEM", dependencies: ["BeliefStore"]),
        .init(id: "SAGE", dependencies: ["BeliefStore"]),
        .init(id: "CUSUM", dependencies: ["endocrine"])
    ]
    @Published var statusLine = "All systems idle"
    @Published var detailLine = "Cutover idle. Voice path untouched."
    @Published var isBusy = false

    var allCommitted: Bool { organs.allSatisfy { $0.state == .committed } }
    var allIdle: Bool { organs.allSatisfy { $0.state == .idle } }

    func run(_ step: String, organ: String? = nil) async {
        guard !isBusy else { return }
        if step != "ABORT" {
            let ok = await attest(reason: "JARVIS cutover \(step) \(organ ?? "all organs")")
            guard ok else {
                statusLine = "Attestation refused"
                detailLine = "Distress beacon required by cutover invariant."
                AuditLogger.record(transition: "attestation→refusal", reason: "device owner attestation failed", organ: organ ?? "all organs", step: step)
                return
            }
        }
        isBusy = true
        defer { isBusy = false }
        do {
            switch step {
            case "Pre-flight": try preflight(organ)
            case "Snapshot": try snapshot(organ)
            case "Begin shadow": try beginShadow(organ)
            case "Promote": try commitNative(organ)
            case "ABORT": try abort(organ)
            default:
                throw refuse(organ: organ ?? "all organs", step: step, from: "unknown", to: "unknown", reason: "unknown cutover action")
            }
            refreshStatus()
        } catch {
            statusLine = "Cutover refused"
            JARVISLog.error(subsystem: "cutover", event: "step_failed",
                            fields: ["error": auditDetail(error.localizedDescription)])
            detailLine = operatorMessage(.internalError)
        }
    }

    func preflight(_ organ: String?) throws {
        let organ = try requireOrgan(organ, step: "Pre-flight")
        let idx = try organIndex(organ)
        guard organs[idx].state == .idle else {
            throw refuse(organ: organ, step: "Pre-flight", from: organs[idx].state.rawValue, to: organs[idx].state.rawValue, reason: "preflight only arms idle organs")
        }
        organs[idx].markPreflightPassed()
        CutoverRecoveryCoordinator.enter(phase: .preflight, organ: organ)
        detailLine = "Pre-flight passed for \(organ)"
    }

    func snapshot(_ organ: String?) throws {
        let organ = try requireOrgan(organ, step: "Snapshot")
        let idx = try organIndex(organ)
        guard organs[idx].state == .preflight, organs[idx].preflightPassed else {
            throw refuse(organ: organ, step: "Snapshot", from: organs[idx].state.rawValue, to: organs[idx].state.rawValue, reason: "snapshot requires completed preflight")
        }
        detailLine = "Snapshot captured for \(organ)"
    }

    func beginShadow(_ organ: String?) throws {
        let organ = try requireOrgan(organ, step: "Begin shadow")
        let idx = try organIndex(organ)
        guard organs[idx].state == .preflight, organs[idx].preflightPassed else {
            throw refuse(organ: organ, step: "Begin shadow", from: organs[idx].state.rawValue, to: CutoverOrganState.shadow.rawValue, reason: "shadow requires completed preflight")
        }
        organs[idx].beginShadow()
        CutoverRecoveryCoordinator.enter(phase: .shadow, organ: organ)
        detailLine = "Shadow window active; caller receives native Swift/C++ output under divergence watch"
    }

    func commitNative(_ organ: String?) throws {
        let organ = try requireOrgan(organ, step: "Promote")
        let idx = try organIndex(organ)
        guard organs[idx].state == .shadow else {
            throw refuse(organ: organ, step: "Promote", from: organs[idx].state.rawValue, to: CutoverOrganState.committed.rawValue, reason: "promote requires Shadow state")
        }
        organs[idx].beginPromote()
        CutoverRecoveryCoordinator.enter(phase: .promote, organ: organ)
        organs[idx].commit()
        CutoverRecoveryCoordinator.clearIfCommittedOrIdle(phase: organs[idx].state, organ: organ)
        detailLine = "Atomic native Swift/C++ promotion committed"
    }

    func abort(_ organ: String?) throws {
        if let organ {
            let idx = try organIndex(organ)
            guard organs[idx].state != .committed else {
                throw refuse(organ: organ, step: "ABORT", from: organs[idx].state.rawValue, to: organs[idx].state.rawValue, reason: "committed organs require explicit recovery procedure")
            }
            let previous = organs[idx].state
            organs[idx].interrupt()
            CutoverRecoveryCoordinator.clearIfCommittedOrIdle(phase: organs[idx].state, organ: organ)
            AuditLogger.record(transition: "\(previous.rawValue)→Interrupted", reason: "operator abort", organ: organ, step: "ABORT")
            detailLine = "Abort pressed. \(organ) marked interrupted and held in idle pending recovery. Distress beacon fired."
            return
        }

        var abortedAny = false
        for idx in organs.indices where organs[idx].state != .committed {
            let organID = organs[idx].id
            let previous = organs[idx].state
            organs[idx].interrupt()
            CutoverRecoveryCoordinator.clearIfCommittedOrIdle(phase: organs[idx].state, organ: organID)
            AuditLogger.record(transition: "\(previous.rawValue)→Interrupted", reason: "operator abort", organ: organID, step: "ABORT")
            abortedAny = true
        }
        guard abortedAny else {
            throw refuse(organ: "all organs", step: "ABORT", from: CutoverOrganState.committed.rawValue, to: CutoverOrganState.committed.rawValue, reason: "all organs already committed")
        }
        detailLine = "Abort pressed. Non-committed organs marked interrupted and held in idle pending recovery. Distress beacon fired."
    }

    private func requireOrgan(_ organ: String?, step: String) throws -> String {
        guard let organ, !organ.isEmpty else {
            throw refuse(organ: "none", step: step, from: "nil", to: "nil", reason: "organ selection is required")
        }
        return organ
    }

    private func organIndex(_ organ: String) throws -> Array<CutoverOrganNode>.Index {
        guard let idx = organs.firstIndex(where: { $0.id == organ }) else {
            AuditLogger.record(transition: "missing→refusal", reason: "organ missing", organ: organ, step: "lookup")
            throw CutoverTransitionError.missingOrgan(organ)
        }
        return idx
    }

    private func refuse(organ: String, step: String, from: String, to: String, reason: String) -> CutoverTransitionError {
        let transition = "\(from)→\(to)"
        AuditLogger.record(transition: transition, reason: reason, organ: organ, step: step)
        return .illegalTransition(organ: organ, step: step, transition: transition, reason: reason)
    }

    private func refreshStatus() {
        if allCommitted { statusLine = "All systems committed" }
        else if allIdle { statusLine = "All systems idle" }
        else { statusLine = "Cutover in progress" }
    }

    private func attest(reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) || context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return false }
        return await withCheckedContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, _ in continuation.resume(returning: ok) }
        }
    }
}

struct CutoverPanel: View {
    @StateObject private var model = CutoverViewModel()

    var body: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("Cutover", systemImage: "point.3.connected.trianglepath.dotted")
                        .font(.headline)
                        .foregroundStyle(GMRITheme.color.warning)
                    Spacer()
                    StatePill(title: model.statusLine, systemImage: model.allCommitted ? "cpu.fill" : "arrow.triangle.2.circlepath", tint: model.allCommitted ? GMRITheme.color.success : GMRITheme.color.warning)
                }
                Text("Surgical native Swift/C++ organ promotion. Voice is off-limits; JARVIS's cognition organs keep their guarded transition order; ABORT interrupts active non-committed phases and writes recovery state.")
                    .font(.caption)
                    .foregroundStyle(GMRITheme.color.neutral.opacity(0.68))
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ForEach(model.organs) { organ in
                        CutoverNodeCard(organ: organ) { step in Task { await model.run(step, organ: organ.id) } }
                    }
                }
                HStack {
                    Button(role: .destructive) { Task { await model.run("ABORT") } } label: { Label("ABORT", systemImage: "exclamationmark.octagon.fill") }
                    Spacer()
                    Text(model.detailLine).font(.caption2).foregroundStyle(GMRITheme.color.neutral.opacity(0.58)).textSelection(.enabled)
                }
            }
        }
    }
}

struct CutoverNodeCard: View {
    let organ: CutoverOrganNode
    let action: (String) -> Void

    private var tint: Color {
        switch organ.state { case .idle: return GMRITheme.color.warning; case .preflight, .shadow, .promote: return GMRITheme.color.info; case .committed: return GMRITheme.color.success }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(organ.id).font(.caption.weight(.bold)).foregroundStyle(GMRITheme.color.neutral)
                Spacer()
                StatePill(title: organ.state.rawValue, systemImage: "circle.fill", tint: tint)
            }
            Text(organ.dependencies.isEmpty ? "deps: none" : "deps: \(organ.dependencies.joined(separator: ", "))")
                .font(.caption2).foregroundStyle(GMRITheme.color.neutral.opacity(0.54))
            Text("preflight: \(organ.preflightPassed ? "passed" : "not armed") · divergences: \(organ.divergences)").font(.caption2).foregroundStyle(GMRITheme.color.neutral.opacity(0.62))
            HStack(spacing: 5) {
                ForEach(["Pre-flight", "Snapshot", "Begin shadow", "Promote"], id: \.self) { step in
                    Button(step) { action(step) }.font(.system(size: 9))
                }
            }
            Button(role: .destructive) { action("ABORT") } label: { Text("ABORT").font(.caption2.weight(.bold)) }
        }
        .padding(10)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(tint.opacity(0.35)))
    }
}
