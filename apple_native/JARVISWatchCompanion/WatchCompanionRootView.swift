import SwiftUI

// Local copy of the canonical GMRI palette from JARVISMacCockpit/GMRITheme.swift.
// Mapping: success=emerald, danger/warning=crimson, info/neutral=GMRI silver,
// background=GMRI black, surface=slightly lifted black, accentHalo=emerald halo.
enum GMRITheme {
    enum color {
        static let background = Color(red: 0.02, green: 0.023, blue: 0.025)
        static let surface = Color(red: 0.035, green: 0.040, blue: 0.044)
        static let neutral = Color(red: 0.80, green: 0.82, blue: 0.84)
        static let info = neutral
        static let success = Color(red: 0.00, green: 0.78, blue: 0.42)
        static let danger = Color(red: 0.79, green: 0.09, blue: 0.18)
        static let warning = danger
        static let accentHalo = Color(red: 0.30, green: 0.95, blue: 0.58)
    }
}


struct WatchCompanionRootView: View {
    @EnvironmentObject private var model: WatchCompanionModel
    @State private var alertPressed = false

    var body: some View {
        ZStack {
            LinearGradient(colors: backgroundColors, startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()
            if model.siriMitigation.isAcknowledged {
                mainSurface
            } else {
                siriMitigationSurface
            }
        }
    }

    private var mainSurface: some View {
        VStack(spacing: 10) {
            Image(systemName: model.sessionState.symbolName)
                .font(.system(size: 46, weight: .semibold))
                .foregroundStyle(statusColor)
                .symbolEffect(.pulse, options: .repeating, value: model.sessionState == .distress)
                .accessibilityLabel("JARVIS status \(model.sessionState.label)")

            Text(model.sessionState.label.uppercased())
                .font(.caption.weight(.bold))
                .tracking(1.2)
                .foregroundStyle(statusColor)

            Text(model.transportStatus)
                .font(.caption2)
                .multilineTextAlignment(.center)
                .foregroundStyle(GMRITheme.color.neutral.opacity(0.72))
                .lineLimit(3)

            Button {
                model.beginTapToSpeak()
            } label: {
                Label(model.isRecording ? "Recording" : "Speak", systemImage: "mic.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(GMRITheme.color.info)

            Button {} label: {
                Label("ALERT", systemImage: "exclamationmark.triangle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(GMRITheme.color.danger)
            .simultaneousGesture(LongPressGesture(minimumDuration: 2.0).onEnded { _ in model.sendAlert() })
            .accessibilityHint("Long-press for two seconds to send an operator-attested emergency alert through the iPhone proxy.")
        }
        .padding(.horizontal, 12)
    }

    private var siriMitigationSurface: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Label("Siri Face Installed?", systemImage: "exclamationmark.shield.fill")
                    .font(.headline)
                    .foregroundStyle(GMRITheme.color.warning)
                Text("JARVIS refuses to run until Residual R5 is handled.")
                    .font(.caption)
                    .foregroundStyle(GMRITheme.color.neutral)
                Text(model.siriMitigation.remediation)
                    .font(.caption2)
                    .foregroundStyle(GMRITheme.color.neutral.opacity(0.72))
                Button("I removed it") {
                    model.acknowledgeSiriFaceRemoved()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
    }

    private var statusColor: Color {
        switch model.sessionState {
        case .idle: return GMRITheme.color.neutral
        case .active: return GMRITheme.color.info
        case .distress: return GMRITheme.color.danger
        }
    }

    private var backgroundColors: [Color] {
        switch model.sessionState {
        case .idle: return [GMRITheme.color.background, GMRITheme.color.neutral.opacity(0.25)]
        case .active: return [GMRITheme.color.background, GMRITheme.color.info.opacity(0.35)]
        case .distress: return [GMRITheme.color.background, GMRITheme.color.danger.opacity(0.55)]
        }
    }
}
