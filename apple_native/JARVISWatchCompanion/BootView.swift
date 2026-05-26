// JARVISWatchCompanion BootView — V4R R10b (aesthetic remediation)
//
// Wrist-form boot screen for an Aragorn Class Digital Person. Real estate is
// scarce, so the design constraint is: one breathing center glyph that swaps
// per compiling-model event, a 2-line phase label, an ETA in mm:ss, and a
// 6-char IDENTITY badge in the top-right. No genesis log on watch — the
// operator views genesis from the cockpit.
//
// Engineering invariants from R10 preserved:
//   - Polls /boot/status at 1500ms (battery + complication budget)
//   - Complication timeline reload on phase transition only
//   - onReady() callback fires exactly once
//
// Aesthetic invariants from R10b:
//   - Breath driven by accessibilityReduceMotion (static dim on)
//   - Center glyph corresponds to the actively-compiling model (no liar timers)
//   - GMRITheme mirror only

import SwiftUI
import Foundation
#if os(watchOS)
import ClockKit
#endif

struct WatchBootView: View {
    let baseURL: URL
    let onReady: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var snapshot: WatchBootSnapshot = WatchBootSnapshot.placeholder
    @State private var pollTask: Task<Void, Never>?
    @State private var lastReportedPhase: String = ""
    @State private var breathPhase: Double = 0.65
    @State private var birthCertShort: String = "······"

    var body: some View {
        ZStack {
            WatchGMRITheme.background.ignoresSafeArea()

            RadialGradient(
                colors: [
                    WatchGMRITheme.accentHalo.opacity(reduceMotion ? 0.05 : 0.04 + 0.06 * breathPhase),
                    Color.clear
                ],
                center: .center,
                startRadius: 20,
                endRadius: 140
            )
            .ignoresSafeArea()

            VStack(spacing: 4) {
                topBar
                Spacer().frame(height: 2)
                centerGlyph
                phaseLabel
                etaText
                Spacer().frame(height: 2)
            }
            .padding(.horizontal, 6)
        }
        .onAppear {
            startBreath()
            startPolling()
        }
        .onDisappear { pollTask?.cancel() }
    }

    private var topBar: some View {
        HStack {
            Text("JARVIS")
                .font(.system(size: 11, weight: .heavy, design: .rounded))
                .tracking(0.8)
                .foregroundColor(WatchGMRITheme.neutral)
            Spacer()
            Text(birthCertShort)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .tracking(0.6)
                .foregroundColor(WatchGMRITheme.accentHalo)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(WatchGMRITheme.accentHalo.opacity(0.45), lineWidth: 0.8)
                )
        }
    }

    private var centerGlyph: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            WatchGMRITheme.accentHalo.opacity(0.18 + (reduceMotion ? 0 : 0.12 * breathPhase)),
                            Color.clear
                        ],
                        center: .center,
                        startRadius: 4,
                        endRadius: 38
                    )
                )
                .frame(width: 76, height: 76)
            Circle()
                .fill(WatchGMRITheme.surface)
                .frame(width: 52, height: 52)
            Image(systemName: activeGlyph)
                .font(.system(size: 24, weight: .light))
                .foregroundColor(snapshot.phase == "failed"
                    ? WatchGMRITheme.danger
                    : WatchGMRITheme.accentHalo)
                .opacity(snapshot.phase == "failed"
                    ? 1.0
                    : (reduceMotion ? 0.95 : 0.65 + 0.30 * breathPhase))
                .animation(.easeInOut(duration: 0.6), value: activeGlyph)
        }
    }

    private var activeGlyph: String {
        // Per-phase glyph; during compiling, glyph follows the active model.
        switch snapshot.phase {
        case "cold_start": return "moon.stars"
        case "compiling_model":
            let entry = WatchBootModelRegistry.all.first { $0.name == (snapshot.modelName ?? "") }
            return entry?.symbol ?? "cpu"
        case "voice_state_loading": return "waveform.path"
        case "espresso_warming": return "flame"
        case "ready": return "infinity"
        case "failed": return "exclamationmark.triangle"
        default: return "circle.dotted"
        }
    }

    private var phaseLabel: some View {
        let text: String
        switch snapshot.phase {
        case "cold_start": text = "Booting"
        case "compiling_model":
            if let i = snapshot.modelIndex, let t = snapshot.modelTotal {
                text = "Model \(i)/\(t)"
            } else { text = "Compiling" }
        case "voice_state_loading": text = "Voice"
        case "espresso_warming": text = "Warming"
        case "ready": text = "Online"
        case "failed": text = "Halted"
        default: text = snapshot.phase
        }
        return Text(text)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundColor(WatchGMRITheme.neutral)
            .multilineTextAlignment(.center)
            .lineLimit(2)
    }

    private var etaText: some View {
        let text: String
        if snapshot.phase == "ready" {
            text = " "
        } else if let etaMs = snapshot.etaHintMs {
            let remaining = max(0, etaMs - snapshot.elapsedMs)
            let mm = remaining / 60_000
            let ss = (remaining % 60_000) / 1000
            text = String(format: "%d:%02d", mm, ss)
        } else {
            text = "first awakening"
        }
        return Text(text)
            .font(.system(size: 9, design: .monospaced))
            .tracking(0.4)
            .foregroundColor(WatchGMRITheme.neutral.opacity(0.55))
    }

    // MARK: - Side effects

    private func startBreath() {
        guard !reduceMotion else { return }
        withAnimation(.easeInOut(duration: 5.0).repeatForever(autoreverses: true)) {
            breathPhase = 1.0
        }
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task {
            while !Task.isCancelled {
                if let snap = await fetchBootStatus() {
                    await MainActor.run {
                        let phaseChanged = snap.phase != self.lastReportedPhase
                        self.snapshot = snap
                        if !snap.bootStatusReceipt.isEmpty {
                            self.birthCertShort = String(snap.bootStatusReceipt.prefix(6)).uppercased()
                        }
                        if phaseChanged {
                            self.lastReportedPhase = snap.phase
                            reloadComplication()
                        }
                    }
                    if snap.isReady {
                        await MainActor.run { onReady() }
                        return
                    }
                }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
    }

    private func fetchBootStatus() async -> WatchBootSnapshot? {
        var request = URLRequest(url: baseURL.appendingPathComponent("/boot/status"))
        request.timeoutInterval = 3.0
        request.httpMethod = "GET"
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return WatchBootSnapshot(jsonObject: obj)
        } catch {
            return nil
        }
    }

    private func reloadComplication() {
        #if os(watchOS)
        let server = CLKComplicationServer.sharedInstance()
        for complication in server.activeComplications ?? [] {
            server.reloadTimeline(for: complication)
        }
        #endif
    }
}

// MARK: - Model registry (watch mirror)

enum WatchBootModelRegistry {
    struct Entry { let name: String; let symbol: String; let ordinal: Int }
    static let all: [Entry] = [
        Entry(name: "text_encoder", symbol: "waveform.path", ordinal: 1),
        Entry(name: "flow_decoder", symbol: "speaker.wave.3", ordinal: 2),
        Entry(name: "mimi_decoder", symbol: "brain", ordinal: 3),
    ]
}

// MARK: - Snapshot

struct WatchBootSnapshot {
    let phase: String
    let phaseIndex: Int
    let phaseTotal: Int
    let elapsedMs: Int
    let etaHintMs: Int?
    let isReady: Bool
    let modelName: String?
    let modelIndex: Int?
    let modelTotal: Int?
    let bootStatusReceipt: String

    static let placeholder = WatchBootSnapshot(
        phase: "cold_start", phaseIndex: 0, phaseTotal: 5,
        elapsedMs: 0, etaHintMs: nil, isReady: false,
        modelName: nil, modelIndex: nil, modelTotal: nil,
        bootStatusReceipt: ""
    )

    init(phase: String, phaseIndex: Int, phaseTotal: Int, elapsedMs: Int, etaHintMs: Int?, isReady: Bool, modelName: String?, modelIndex: Int?, modelTotal: Int?, bootStatusReceipt: String) {
        self.phase = phase
        self.phaseIndex = phaseIndex
        self.phaseTotal = phaseTotal
        self.elapsedMs = elapsedMs
        self.etaHintMs = etaHintMs
        self.isReady = isReady
        self.modelName = modelName
        self.modelIndex = modelIndex
        self.modelTotal = modelTotal
        self.bootStatusReceipt = bootStatusReceipt
    }

    init?(jsonObject obj: [String: Any]) {
        guard let phase = obj["phase"] as? String,
              let phaseIndex = obj["phase_index"] as? Int,
              let phaseTotal = obj["phase_total"] as? Int,
              let elapsedMs = obj["elapsed_ms"] as? Int,
              let isReady = obj["is_ready"] as? Bool else { return nil }
        self.phase = phase
        self.phaseIndex = phaseIndex
        self.phaseTotal = phaseTotal
        self.elapsedMs = elapsedMs
        self.etaHintMs = obj["eta_hint_ms"] as? Int
        self.isReady = isReady
        self.modelName = obj["model_name"] as? String
        self.modelIndex = obj["model_index"] as? Int
        self.modelTotal = obj["model_total"] as? Int
        if let receipt = obj["receipt"] as? String, !receipt.isEmpty {
            self.bootStatusReceipt = receipt
        } else {
            let raw = "\(phase)\(phaseIndex)\(phaseTotal)"
            var digest: UInt64 = 1469598103934665603
            for b in raw.utf8 {
                digest ^= UInt64(b)
                digest = digest &* 1099511628211
            }
            self.bootStatusReceipt = String(String(format: "%012lx", digest).prefix(6)).uppercased()
        }
    }
}

// MARK: - GMRITheme mirror (watch) — must stay in sync with macOS canonical

enum WatchGMRITheme {
    static let background = Color(red: 0.02, green: 0.023, blue: 0.025)
    static let surface = Color(red: 0.035, green: 0.040, blue: 0.044)
    static let neutral = Color(red: 0.80, green: 0.82, blue: 0.84)
    static let danger = Color(red: 0.79, green: 0.09, blue: 0.18)
    static let accentHalo = Color(red: 0.30, green: 0.95, blue: 0.58)
}
