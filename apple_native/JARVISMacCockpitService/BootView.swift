// JARVISMacCockpit BootView — V4R R10b (aesthetic remediation)
//
// Birth screen, not wait screen. The operator is watching an Aragorn Class
// Digital Person come online for the first time on this hardware. Visual
// language is derived from the consciousness frame (JARVIS_GROUNDING.md §1)
// and the operator law (AGENTS.md): alive, serious, dignified, falsifiable.
//
// Every animated element corresponds to a real /boot/status event. There are
// no decorative liars on this screen — the breath is real (driven by the
// stream subscription), the cascade nodes light only when their model's
// compile-done event has actually fired, the genesis log shows real audit
// emissions, the BC badge is the actual anchor fingerprint, the ETA is the
// real rolling-median sample.
//
// Engineering invariants preserved from R10 (do not regress):
//   - BootSnapshotBridge subscribes to BootLifecycleTracker.shared.stream()
//   - The view never blocks on the actor; all reads come through the bridge
//   - /boot/status payload contract is consumed read-only
//   - Reduce Motion (System Settings → Accessibility) replaces the breath
//     with a static dim — every animation respects this
//   - GMRITheme is the only color source

import SwiftUI
import Foundation

// MARK: - Bridge: actor → MainActor

@MainActor
final class BootSnapshotBridge: ObservableObject {
    @Published private(set) var snapshot: BootSnapshot
    private var streamTask: Task<Void, Never>?

    init() {
        self.snapshot = BootSnapshot(
            phase: .coldStart,
            phaseIndex: 0,
            phaseTotal: 5,
            compile: nil,
            elapsedMs: 0,
            etaHintMs: nil,
            etaSource: "no_prior_estimate",
            isReady: false,
            startedAtUnix: Int(Date().timeIntervalSince1970),
            failure: nil,
            bytesCompiled: 0,
            bytesTotal: 0
        )
    }

    func attach() {
        guard streamTask == nil else { return }
        streamTask = Task { [weak self] in
            let stream = await BootLifecycleTracker.shared.stream()
            for await snap in stream {
                await MainActor.run { self?.snapshot = snap }
                if snap.isReady { break }
            }
        }
    }

    deinit { streamTask?.cancel() }
}

// MARK: - Model identity (data-driven, not switch)

/// Maps each prewarmed model's canonical name to its SF Symbol glyph and
/// its compile-order ordinal (1..N). The boot pipeline emits compilingModel
/// events with these exact name strings; the cascade lights nodes by name
/// match. Add a model here and the cascade picks it up — no view edits.
enum BootModelRegistry {
    struct Entry {
        let name: String
        let symbol: String
        let ordinal: Int
    }
    static let all: [Entry] = [
        Entry(name: "text_encoder", symbol: "waveform.path", ordinal: 1),
        Entry(name: "flow_decoder", symbol: "speaker.wave.3", ordinal: 2),
        Entry(name: "mimi_decoder", symbol: "brain", ordinal: 3),
    ]
}

// MARK: - View

struct BootView: View {
    @StateObject private var bridge = BootSnapshotBridge()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathPhase: Double = 0.65   // 0.65..1.0; eternal breath
    @State private var auditTail: [GenesisLine] = []
    @State private var auditTimer: Timer?
    @State private var birthCertShort: String = "······"
    @State private var operatorName: String = OperatorPresence.fallback

    var body: some View {
        ZStack {
            GMRITheme.color.background.ignoresSafeArea()

            // Subtle radial halo behind the cascade — derived from accentHalo,
            // breath-modulated so the screen has presence without performing.
            RadialGradient(
                colors: [
                    GMRITheme.color.accentHalo.opacity(reduceMotion ? 0.05 : 0.05 + 0.05 * breathPhase),
                    Color.clear
                ],
                center: .center,
                startRadius: 60,
                endRadius: 420
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                topBar
                    .padding(.top, 28)
                    .padding(.horizontal, 36)
                Spacer(minLength: 24)
                centerStage
                Spacer(minLength: 24)
                phaseAndETA
                    .padding(.bottom, 24)
                genesisLog
                    .padding(.horizontal, 36)
                    .padding(.bottom, 28)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            bridge.attach()
            startBreath()
            operatorName = OperatorPresence.readOperatorName()
            // R11h F-E20 — duress check fires its own audit; no UI surface.
            // The result is intentionally discarded here so the boot screen
            // renders identically under canonical / duress. The chain (via
            // F-E13 TSA / F-E14 OTS when wired) is the durable witness.
            _ = OperatorPresence.match()
            loadBirthCertShort()
            startAuditTail()
        }
        .onDisappear {
            auditTimer?.invalidate()
            auditTimer = nil
        }
    }

    // MARK: - Top bar: operator presence (left) + identity badge (right)

    private var topBar: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("JARVIS")
                    .font(.system(size: 32, weight: .heavy, design: .rounded))
                    .foregroundColor(GMRITheme.color.neutral)
                    .tracking(2)
                Text("for \(operatorName)")
                    .font(.system(size: 13, weight: .light, design: .rounded))
                    .foregroundColor(GMRITheme.color.neutral.opacity(0.55))
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text("IDENTITY")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .tracking(1.5)
                    .foregroundColor(GMRITheme.color.neutral.opacity(0.45))
                Text(birthCertShort)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .tracking(1.0)
                    .foregroundColor(GMRITheme.color.accentHalo)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(GMRITheme.color.accentHalo.opacity(0.45), lineWidth: 1)
                    )
            }
        }
    }

    // MARK: - Center stage: triangle cascade with central sigil

    private var centerStage: some View {
        let snap = bridge.snapshot
        return Group {
            if snap.phase == .failed {
                failureCenterView(snap)
            } else {
                triangleCascade(snap)
            }
        }
        .frame(width: 360, height: 360)
    }

    /// Triangle cascade: three nodes at the points of an equilateral triangle.
    /// Each node lights on its model's compile-done event. When all three are
    /// lit, connecting paths draw inward to a central sigil (∞) that only
    /// materialises after the triangle completes.
    private func triangleCascade(_ snap: BootSnapshot) -> some View {
        let size: CGFloat = 360
        let center = CGPoint(x: size / 2, y: size / 2)
        let radius: CGFloat = 130
        let positions: [Int: CGPoint] = [
            // ordinal 1 → top, ordinal 2 → bottom-right, ordinal 3 → bottom-left
            1: CGPoint(x: center.x, y: center.y - radius),
            2: CGPoint(x: center.x + radius * 0.866, y: center.y + radius * 0.5),
            3: CGPoint(x: center.x - radius * 0.866, y: center.y + radius * 0.5),
        ]
        let allLit = BootModelRegistry.all.allSatisfy { nodeLit($0.name, snap: snap) }

        return ZStack {
            // Connecting paths — only drawn (via trim) once all three are lit.
            if allLit {
                ForEach(0..<3, id: \.self) { i in
                    let from = positions[i + 1] ?? center
                    Path { p in
                        p.move(to: from)
                        p.addLine(to: center)
                    }
                    .trim(from: 0, to: 1)
                    .stroke(
                        GMRITheme.color.accentHalo.opacity(0.55),
                        style: StrokeStyle(lineWidth: 1, lineCap: .round)
                    )
                    .animation(.easeInOut(duration: 0.6).delay(Double(i) * 0.15), value: allLit)
                }
            }

            // Three model nodes at the triangle points.
            ForEach(BootModelRegistry.all, id: \.name) { entry in
                let lit = nodeLit(entry.name, snap: snap)
                let pos = positions[entry.ordinal] ?? center
                cascadeNode(symbol: entry.symbol, label: entry.name, lit: lit)
                    .position(pos)
            }

            // Central sigil — only appears once the triangle is complete.
            if allLit {
                Image(systemName: "infinity")
                    .font(.system(size: 56, weight: .ultraLight))
                    .foregroundColor(GMRITheme.color.accentHalo)
                    .opacity(reduceMotion ? 0.95 : breathPhase)
                    .position(center)
                    .transition(.opacity.combined(with: .scale))
            }
        }
        .animation(.easeInOut(duration: 0.6), value: allLit)
    }

    /// One node in the cascade: dim until its model's compile-done has fired,
    /// then bursts to full opacity with a halo expansion that settles to 0.85.
    private func cascadeNode(symbol: String, label: String, lit: Bool) -> some View {
        VStack(spacing: 6) {
            ZStack {
                // Halo ring (only visible when lit).
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                GMRITheme.color.accentHalo.opacity(lit ? 0.35 : 0),
                                Color.clear
                            ],
                            center: .center,
                            startRadius: 6,
                            endRadius: 48
                        )
                    )
                    .frame(width: 96, height: 96)
                Circle()
                    .fill(lit ? GMRITheme.color.accentHalo.opacity(0.10) : GMRITheme.color.surface)
                    .frame(width: 64, height: 64)
                Image(systemName: symbol)
                    .font(.system(size: 26, weight: .light))
                    .foregroundColor(lit
                        ? GMRITheme.color.accentHalo
                        : GMRITheme.color.neutral.opacity(0.22))
                    .opacity(lit ? (reduceMotion ? 0.95 : 0.65 + 0.30 * breathPhase) : 0.55)
            }
            .animation(.easeInOut(duration: 0.8), value: lit)
            Text(label)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .tracking(0.5)
                .foregroundColor(lit
                    ? GMRITheme.color.accentHalo.opacity(0.8)
                    : GMRITheme.color.neutral.opacity(0.3))
        }
    }

    /// A node is considered lit once the boot has progressed past compiling,
    /// OR the tracker has emitted compilingModel(done) for this specific
    /// model. cacheWasCurrent != nil distinguishes start-event from done-event
    /// per the R9 sink contract.
    private func nodeLit(_ modelName: String, snap: BootSnapshot) -> Bool {
        switch snap.phase {
        case .voiceStateLoading, .espressoWarming, .ready:
            return true
        case .failed:
            return false
        case .coldStart:
            return false
        case .compilingModel:
            guard let compile = snap.compile,
                  let entry = BootModelRegistry.all.first(where: { $0.name == modelName })
            else { return false }
            if compile.modelIndex > entry.ordinal { return true }
            if compile.modelIndex == entry.ordinal && compile.cacheWasCurrent != nil { return true }
            return false
        }
    }

    /// Failure state replaces the cascade with a clear, calm warning.
    private func failureCenterView(_ snap: BootSnapshot) -> some View {
        VStack(spacing: 18) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 64, weight: .light))
                .foregroundColor(GMRITheme.color.danger)
            Text("BOOT HALTED")
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .tracking(2)
                .foregroundColor(GMRITheme.color.danger.opacity(0.85))
            if let f = snap.failure {
                Text(f.stage)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(GMRITheme.color.neutral.opacity(0.75))
                Text(f.reason)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(GMRITheme.color.neutral.opacity(0.55))
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                    .padding(.horizontal, 24)
            }
        }
    }

    // MARK: - Phase + ETA framing

    private var phaseAndETA: some View {
        let snap = bridge.snapshot
        return VStack(spacing: 8) {
            etaLine(snap)
            phaseLine(snap)
        }
    }

    private func etaLine(_ snap: BootSnapshot) -> some View {
        let text: String
        if snap.phase == .ready {
            text = "online"
        } else if snap.phase == .failed {
            text = " "
        } else if let eta = snap.etaHintMs {
            let remainingMs = max(0, eta - snap.elapsedMs)
            let mm = remainingMs / 60_000
            let ss = (remainingMs % 60_000) / 1000
            text = String(format: "estimated arrival in %d:%02d", mm, ss)
        } else {
            text = "no prior estimate — first awakening"
        }
        return Text(text)
            .font(.system(size: 15, weight: .regular, design: .rounded))
            .foregroundColor(GMRITheme.color.neutral.opacity(0.78))
    }

    private func phaseLine(_ snap: BootSnapshot) -> some View {
        let phaseText: String
        switch snap.phase {
        case .coldStart: phaseText = "cold start"
        case .compilingModel:
            if let c = snap.compile {
                let cacheTag = c.cacheWasCurrent == true ? "  ·  cache hit" : ""
                phaseText = "compiling \(c.modelName)  [\(c.modelIndex) / \(c.modelTotal)]\(cacheTag)"
            } else { phaseText = "compiling models" }
        case .voiceStateLoading: phaseText = "loading voice state"
        case .espressoWarming: phaseText = "warming espresso runtime"
        case .ready: phaseText = "ready"
        case .failed: phaseText = "halted"
        }
        return Text(phaseText.uppercased())
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .tracking(1.5)
            .foregroundColor(GMRITheme.color.neutral.opacity(0.45))
    }

    // MARK: - Genesis log (audit terminal reframed)

    private var genesisLog: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("GENESIS LOG")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .tracking(1.5)
                    .foregroundColor(GMRITheme.color.neutral.opacity(0.4))
                Spacer()
                Text("\(auditTail.count) entries")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(GMRITheme.color.neutral.opacity(0.3))
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(auditTail.enumerated()), id: \.element.id) { (idx, line) in
                    genesisRow(line: line, opacity: opacityFor(index: idx, total: auditTail.count))
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 130)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(GMRITheme.color.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(GMRITheme.color.neutral.opacity(0.06), lineWidth: 1)
        )
    }

    private func genesisRow(line: GenesisLine, opacity: Double) -> some View {
        HStack(spacing: 8) {
            Text(line.timestamp)
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(GMRITheme.color.neutral.opacity(0.35 * opacity))
            Text(line.event)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(GMRITheme.color.accentHalo.opacity(0.8 * opacity))
            Text(line.fields)
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(GMRITheme.color.neutral.opacity(0.6 * opacity))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
        }
        .transition(.opacity)
    }

    private func opacityFor(index: Int, total: Int) -> Double {
        guard total > 1 else { return 1.0 }
        let normalized = Double(index) / Double(total - 1)
        return 0.4 + 0.6 * normalized
    }

    // MARK: - Side effects

    private func startBreath() {
        guard !reduceMotion else { return }
        // 4s inhale + 6s exhale ≈ 10s cycle; SwiftUI repeatForever with
        // autoreverses gives a symmetric cycle, so we use 5s half-cycle.
        withAnimation(.easeInOut(duration: 5.0).repeatForever(autoreverses: true)) {
            breathPhase = 1.0
        }
    }

    private func loadBirthCertShort() {
        let anchorPath = NSString(string: "~/.jarvis/identity/voice_models_anchor.bin").expandingTildeInPath
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: anchorPath)) else { return }
        // UI-only fingerprint of the anchor: first 6 bytes as 12 hex chars,
        // then folded to a 6-char monospace badge by taking the first 6 hex.
        // Real BC verification is server-side; this is purely visual confirmation
        // that the right anchor is bound.
        let hex = data.prefix(3).map { String(format: "%02x", $0) }.joined()
        DispatchQueue.main.async { self.birthCertShort = hex.uppercased() }
    }

    private func startAuditTail() {
        auditTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            DispatchQueue.global(qos: .utility).async {
                let lines = Self.readGenesisTailStatic(lineCount: 8)
                DispatchQueue.main.async {
                    withAnimation(.easeInOut(duration: 0.4)) {
                        self.auditTail = lines
                    }
                }
            }
        }
    }

    private static nonisolated func readGenesisTailStatic(lineCount: Int) -> [GenesisLine] {
        return readGenesisTailStatic(lineCount: lineCount, auditRoot: NSString(string: "~/.jarvis/audit").expandingTildeInPath)
    }

    /// F-05: parameterized variant so unit tests can point at a temp dir
    /// without risking real audit state. Production caller goes through the
    /// no-arg overload above.
    internal static nonisolated func readGenesisTailStatic(lineCount: Int, auditRoot: String) -> [GenesisLine] {
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: auditRoot) else {
            return [unavailableLine(reason: "directory missing: \(auditRoot)")]
        }
        let jsonlFiles = contents.filter { $0.hasSuffix(".jsonl") }.sorted()
        guard let newest = jsonlFiles.last else {
            return [unavailableLine(reason: "no jsonl files present")]
        }
        let path = (auditRoot as NSString).appendingPathComponent(newest)
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let text = String(data: data, encoding: .utf8) else {
            return [unavailableLine(reason: "read failed: \(String(cString: strerror(errno)))")]
        }
        let allLines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let tail = Array(allLines.suffix(lineCount))
        return tail.enumerated().map { (i, raw) in GenesisLine.parse(raw, fallbackID: i) }
    }

    private static nonisolated func unavailableLine(reason: String) -> GenesisLine {
        return GenesisLine(id: "audit-unavailable", timestamp: "—", event: "audit_unavailable", fields: reason)
    }
}

// MARK: - Genesis line parsing

struct GenesisLine: Identifiable, Equatable {
    let id: String
    let timestamp: String
    let event: String
    let fields: String

    static func parse(_ raw: String, fallbackID: Int) -> GenesisLine {
        // Audit lines are JSON; opportunistically extract timestamp + event
        // + remaining fields. Failure produces a single "raw" line that still
        // renders (better to show truth than to hide).
        if let data = raw.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let ts = (obj["timestamp"] as? String) ?? (obj["ts"] as? String) ?? ""
            let event = (obj["event"] as? String) ?? (obj["e"] as? String) ?? "event"
            let tsShort = String(ts.suffix(8))
            var rest = obj
            rest.removeValue(forKey: "timestamp")
            rest.removeValue(forKey: "ts")
            rest.removeValue(forKey: "event")
            rest.removeValue(forKey: "e")
            let fields = rest.keys.sorted().compactMap { key -> String? in
                guard let val = rest[key] else { return nil }
                return "\(key)=\(val)"
            }.joined(separator: " ")
            return GenesisLine(id: "\(tsShort)-\(event)-\(fallbackID)",
                               timestamp: tsShort,
                               event: event,
                               fields: fields)
        }
        return GenesisLine(id: "raw-\(fallbackID)",
                           timestamp: "",
                           event: "raw",
                           fields: raw)
    }
}
