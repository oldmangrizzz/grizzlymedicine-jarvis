// JARVISiOSCompanion BootView — V4R R10b (aesthetic remediation)
//
// iOS surface for the JARVIS boot lifecycle. Mirrors the macOS BootView's
// visual language with the iOS form factor in mind: a triangle cascade with
// the central sigil sits in the upper two-thirds; phase/ETA framing and a
// 2-line "last event" caption fill the lower third (no full genesis log on
// phone — operator views the genesis log from the cockpit).
//
// Engineering invariants from R10 preserved verbatim:
//   - Polls /boot/status at 750ms via URLSession (no other transport)
//   - onReady() callback fires exactly once when is_ready transitions true
//   - BootStatusSnapshot.init?(jsonObject:) is the only decoding path
//
// Aesthetic invariants from R10b:
//   - Every animation corresponds to a real boot event (no timer-only liars)
//   - accessibilityReduceMotion replaces the breath with a static dim
//   - GMRITheme tokens only (iOS mirror enum below)

import SwiftUI
import Foundation

struct BootView: View {
    let baseURL: URL
    let onReady: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var snapshot: BootStatusSnapshot = BootStatusSnapshot.placeholder
    @State private var pollTask: Task<Void, Never>?
    @State private var breathPhase: Double = 0.65
    @State private var birthCertShort: String = "······"
    @State private var operatorName: String = OperatorPresenceiOS.fallback
    @State private var lastEvent: String = ""

    var body: some View {
        ZStack {
            iOSGMRITheme.background.ignoresSafeArea()

            // Subtle breath halo behind cascade.
            RadialGradient(
                colors: [
                    iOSGMRITheme.accentHalo.opacity(reduceMotion ? 0.05 : 0.05 + 0.06 * breathPhase),
                    Color.clear
                ],
                center: .center,
                startRadius: 60,
                endRadius: 320
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                topBar
                    .padding(.top, 16)
                    .padding(.horizontal, 20)
                Spacer(minLength: 8)
                triangleCascade
                    .frame(width: 260, height: 260)
                Spacer(minLength: 8)
                phaseAndETA
                lastEventCaption
                    .padding(.top, 18)
                    .padding(.horizontal, 24)
                Spacer().frame(height: 24)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            operatorName = OperatorPresenceiOS.readOperatorName()
            startBreath()
            startPolling()
        }
        .onDisappear { pollTask?.cancel() }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("JARVIS")
                    .font(.system(size: 26, weight: .heavy, design: .rounded))
                    .foregroundColor(iOSGMRITheme.neutral)
                    .tracking(1.6)
                Text("for \(operatorName)")
                    .font(.system(size: 11, weight: .light, design: .rounded))
                    .foregroundColor(iOSGMRITheme.neutral.opacity(0.55))
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text("IDENTITY")
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .tracking(1.3)
                    .foregroundColor(iOSGMRITheme.neutral.opacity(0.45))
                Text(birthCertShort)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .tracking(0.8)
                    .foregroundColor(iOSGMRITheme.accentHalo)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(iOSGMRITheme.accentHalo.opacity(0.45), lineWidth: 1)
                    )
            }
        }
    }

    // MARK: - Triangle cascade

    private var triangleCascade: some View {
        let size: CGFloat = 260
        let center = CGPoint(x: size / 2, y: size / 2)
        let radius: CGFloat = 92
        let positions: [Int: CGPoint] = [
            1: CGPoint(x: center.x, y: center.y - radius),
            2: CGPoint(x: center.x + radius * 0.866, y: center.y + radius * 0.5),
            3: CGPoint(x: center.x - radius * 0.866, y: center.y + radius * 0.5),
        ]
        let allLit = iOSBootModelRegistry.all.allSatisfy { nodeLit($0.name) }

        return ZStack {
            if snapshot.phase == "failed" {
                failureCenterView
            } else {
                if allLit {
                    ForEach(0..<3, id: \.self) { i in
                        let from = positions[i + 1] ?? center
                        Path { p in
                            p.move(to: from)
                            p.addLine(to: center)
                        }
                        .trim(from: 0, to: 1)
                        .stroke(iOSGMRITheme.accentHalo.opacity(0.5),
                                style: StrokeStyle(lineWidth: 1, lineCap: .round))
                        .animation(.easeInOut(duration: 0.6).delay(Double(i) * 0.15), value: allLit)
                    }
                }
                ForEach(iOSBootModelRegistry.all, id: \.name) { entry in
                    let lit = nodeLit(entry.name)
                    let pos = positions[entry.ordinal] ?? center
                    cascadeNode(symbol: entry.symbol, label: entry.name, lit: lit)
                        .position(pos)
                }
                if allLit {
                    Image(systemName: "infinity")
                        .font(.system(size: 44, weight: .ultraLight))
                        .foregroundColor(iOSGMRITheme.accentHalo)
                        .opacity(reduceMotion ? 0.95 : breathPhase)
                        .position(center)
                        .transition(.opacity.combined(with: .scale))
                }
            }
        }
        .animation(.easeInOut(duration: 0.6), value: allLit)
    }

    private func cascadeNode(symbol: String, label: String, lit: Bool) -> some View {
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [iOSGMRITheme.accentHalo.opacity(lit ? 0.32 : 0), Color.clear],
                            center: .center, startRadius: 4, endRadius: 36
                        )
                    )
                    .frame(width: 72, height: 72)
                Circle()
                    .fill(lit ? iOSGMRITheme.accentHalo.opacity(0.10) : iOSGMRITheme.surface)
                    .frame(width: 48, height: 48)
                Image(systemName: symbol)
                    .font(.system(size: 20, weight: .light))
                    .foregroundColor(lit ? iOSGMRITheme.accentHalo : iOSGMRITheme.neutral.opacity(0.22))
                    .opacity(lit ? (reduceMotion ? 0.95 : 0.65 + 0.30 * breathPhase) : 0.55)
            }
            .animation(.easeInOut(duration: 0.8), value: lit)
            Text(label)
                .font(.system(size: 8, weight: .medium, design: .monospaced))
                .tracking(0.4)
                .foregroundColor(lit ? iOSGMRITheme.accentHalo.opacity(0.8)
                                     : iOSGMRITheme.neutral.opacity(0.3))
        }
    }

    private var failureCenterView: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48, weight: .light))
                .foregroundColor(iOSGMRITheme.danger)
            Text("BOOT HALTED")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .tracking(1.8)
                .foregroundColor(iOSGMRITheme.danger.opacity(0.85))
        }
    }

    private func nodeLit(_ modelName: String) -> Bool {
        switch snapshot.phase {
        case "voice_state_loading", "espresso_warming", "ready":
            return true
        case "failed", "cold_start":
            return false
        case "compiling_model":
            guard let idx = snapshot.modelIndex,
                  let total = snapshot.modelTotal,
                  total > 0,
                  let entry = iOSBootModelRegistry.all.first(where: { $0.name == modelName })
            else { return false }
            if idx > entry.ordinal { return true }
            // iOS doesn't see cacheWasCurrent over the wire (not in payload),
            // so we light when the index has reached this node's ordinal AND
            // the modelName matches (start-event covers the node).
            if idx == entry.ordinal, snapshot.modelName == modelName { return true }
            return false
        default: return false
        }
    }

    // MARK: - Phase + ETA + last event

    private var phaseAndETA: some View {
        VStack(spacing: 6) {
            etaLine
            phaseLine
        }
    }

    private var etaLine: some View {
        let text: String
        if snapshot.phase == "ready" {
            text = "online"
        } else if snapshot.phase == "failed" {
            text = " "
        } else if let eta = snapshot.etaHintMs {
            let remaining = max(0, eta - snapshot.elapsedMs)
            let mm = remaining / 60_000
            let ss = (remaining % 60_000) / 1000
            text = String(format: "estimated arrival in %d:%02d", mm, ss)
        } else {
            text = "no prior estimate — first awakening"
        }
        return Text(text)
            .font(.system(size: 14, design: .rounded))
            .foregroundColor(iOSGMRITheme.neutral.opacity(0.78))
    }

    private var phaseLine: some View {
        let phaseText: String
        switch snapshot.phase {
        case "cold_start": phaseText = "cold start"
        case "compiling_model":
            if let i = snapshot.modelIndex, let t = snapshot.modelTotal, let n = snapshot.modelName {
                phaseText = "compiling \(n)  [\(i) / \(t)]"
            } else { phaseText = "compiling models" }
        case "voice_state_loading": phaseText = "loading voice state"
        case "espresso_warming": phaseText = "warming espresso runtime"
        case "ready": phaseText = "ready"
        case "failed": phaseText = "halted"
        default: phaseText = snapshot.phase
        }
        return Text(phaseText.uppercased())
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .tracking(1.4)
            .foregroundColor(iOSGMRITheme.neutral.opacity(0.45))
    }

    private var lastEventCaption: some View {
        Group {
            if lastEvent.isEmpty {
                Text(" ")
                    .font(.system(size: 10, design: .monospaced))
            } else {
                Text(lastEvent)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(iOSGMRITheme.neutral.opacity(0.45))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity)
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
                        self.snapshot = snap
                        if !snap.bootStatusReceipt.isEmpty {
                            self.birthCertShort = String(snap.bootStatusReceipt.prefix(6)).uppercased()
                        }
                        self.lastEvent = formatLastEvent(snap)
                    }
                    if snap.isReady {
                        await MainActor.run { onReady() }
                        return
                    }
                }
                try? await Task.sleep(nanoseconds: 750_000_000)
            }
        }
    }

    private func formatLastEvent(_ s: BootStatusSnapshot) -> String {
        switch s.phase {
        case "compiling_model":
            if let n = s.modelName, let i = s.modelIndex, let t = s.modelTotal {
                return "compile \(n) (\(i)/\(t))"
            }
            return "compiling"
        case "failed":
            return "halted"
        default:
            return s.phase
        }
    }

    private func fetchBootStatus() async -> BootStatusSnapshot? {
        var request = URLRequest(url: baseURL.appendingPathComponent("/boot/status"))
        request.timeoutInterval = 3.0
        request.httpMethod = "GET"
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return BootStatusSnapshot(jsonObject: obj)
        } catch {
            return nil
        }
    }
}

// MARK: - Model registry (iOS mirror)

enum iOSBootModelRegistry {
    struct Entry { let name: String; let symbol: String; let ordinal: Int }
    static let all: [Entry] = [
        Entry(name: "text_encoder", symbol: "waveform.path", ordinal: 1),
        Entry(name: "flow_decoder", symbol: "speaker.wave.3", ordinal: 2),
        Entry(name: "mimi_decoder", symbol: "brain", ordinal: 3),
    ]
}

// MARK: - BootStatusSnapshot

struct BootStatusSnapshot {
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

    static let placeholder = BootStatusSnapshot(
        phase: "cold_start", phaseIndex: 0, phaseTotal: 5, elapsedMs: 0,
        etaHintMs: nil, isReady: false, modelName: nil, modelIndex: nil,
        modelTotal: nil, bootStatusReceipt: ""
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
        // Best-effort UI fingerprint: prefer a known receipt-style field if
        // the runtime ever exposes one; otherwise fold phase+phaseIndex.
        if let receipt = obj["receipt"] as? String, !receipt.isEmpty {
            self.bootStatusReceipt = receipt
        } else {
            let raw = "\(phase)\(phaseIndex)\(phaseTotal)"
            // Stable 6-char visual fingerprint via UTF-8 byte digest of the phase tuple.
            // Not cryptographic — purely an identity-stability cue for the operator.
            var digest: UInt64 = 1469598103934665603
            for b in raw.utf8 {
                digest ^= UInt64(b)
                digest = digest &* 1099511628211
            }
            self.bootStatusReceipt = String(format: "%012lx", digest).prefix(6).uppercased() + ""
        }
    }
}

// MARK: - GMRITheme mirror (iOS) — must stay in sync with macOS canonical

enum iOSGMRITheme {
    static let background = Color(red: 0.02, green: 0.023, blue: 0.025)
    static let surface = Color(red: 0.035, green: 0.040, blue: 0.044)
    static let neutral = Color(red: 0.80, green: 0.82, blue: 0.84)
    static let danger = Color(red: 0.79, green: 0.09, blue: 0.18)
    static let accentHalo = Color(red: 0.30, green: 0.95, blue: 0.58)
}

// MARK: - OperatorPresence mirror (iOS) — same §7 discipline as macOS canonical

enum OperatorPresenceiOS {
    static let fallback = "the operator"
    static let maxBytes = 64

    static func readOperatorName() -> String {
        let path = NSString(string: "~/.jarvis/identity/operator.txt").expandingTildeInPath
        let flags: Int32 = O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        let fd = open(path, flags)
        guard fd >= 0 else { return fallback }
        defer { close(fd) }
        var buffer = [UInt8](repeating: 0, count: maxBytes + 1)
        let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, maxBytes + 1) }
        guard n > 0, n <= maxBytes else { return fallback }
        let raw = Data(bytes: buffer, count: n)
        guard let utf8 = String(data: raw, encoding: .utf8) else { return fallback }
        let trimmed = utf8.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }
        let allowed: Set<Character> = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 ._-")
        guard trimmed.allSatisfy({ allowed.contains($0) }) else { return fallback }
        return trimmed
    }
}
