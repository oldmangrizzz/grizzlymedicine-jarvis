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

import WatchKit

struct WatchRootView: View {
    @StateObject private var bridge = WatchBridge()

    var body: some View {
        let accent = WatchAccent.color(for: bridge.accentHue)
        ZStack {
            LinearGradient(
                colors: [GMRITheme.color.background, accent.opacity(0.16), accent.opacity(0.08)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 12) {
                    VStack(spacing: 2) {
                        Image("GMRISeal")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 54, height: 54)
                        Text("GMRI")
                            .font(.caption2.weight(.bold))
                            .tracking(1.2)
                            .foregroundStyle(accent)
                        Text("JARVIS")
                            .font(.title2.weight(.bold))
                            .foregroundStyle(GMRITheme.color.neutral)
                    }

                    WatchOrb(accent: accent)

                    Text(bridge.status)
                        .font(.caption2.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(GMRITheme.color.neutral.opacity(0.78))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(GMRITheme.color.neutral.opacity(0.08), in: Capsule())

                    VStack(spacing: 8) {
                        Button {
                            askForCommand()
                        } label: {
                            Label("Talk to JARVIS", systemImage: "waveform.circle.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)

                        Text("Tap, speak, then press Done.")
                            .font(.caption2)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(GMRITheme.color.neutral.opacity(0.64))
                    }
                    .padding(10)
                    .background(GMRITheme.color.neutral.opacity(0.10), in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                    HStack(spacing: 8) {
                        Button {
                            bridge.sendCheckIn("watch_check_in")
                        } label: {
                            Label("I'm OK", systemImage: "dot.radiowaves.left.and.right")
                        }

                        Button {
                            bridge.sendCommand("JARVIS, I need you. Check current companion context and respond with the next useful step.")
                        } label: {
                            Label("Help", systemImage: "sparkles")
                        }
                    }
                    .buttonStyle(.bordered)
                }
                .padding()
            }
        }
        .onAppear {
            bridge.activate()
        }
    }

    private func askForCommand() {
        WKExtension.shared().visibleInterfaceController?.presentTextInputController(
            withSuggestions: ["Open music", "Call for help", "What should I do next?"],
            allowedInputMode: .plain
        ) { results in
            let text = results?
                .compactMap { $0 as? String }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else {
                return
            }
            Task { @MainActor in
                bridge.sendCommand(text)
            }
        }
    }
}

private struct WatchOrb: View {
    let accent: Color

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [accent.opacity(0.95), accent.opacity(0.58), GMRITheme.color.background.opacity(0.10)],
                        center: .center,
                        startRadius: 2,
                        endRadius: 76
                    )
                )
                .frame(width: 86, height: 86)
                .shadow(color: accent.opacity(0.45), radius: 12)

            Circle()
                .stroke(GMRITheme.color.neutral.opacity(0.22), lineWidth: 1)
                .frame(width: 98, height: 98)

            Image(systemName: "waveform")
                .font(.title.weight(.semibold))
                .foregroundStyle(GMRITheme.color.neutral)
        }
        .padding(.vertical, 4)
    }
}

private enum WatchAccent {
    static func color(for rawValue: String) -> Color {
        switch rawValue {
        case "green":
            return GMRITheme.color.success
        case "gold":
            return GMRITheme.color.info
        case "orange":
            return GMRITheme.color.warning
        case "red":
            return GMRITheme.color.danger
        case "pink":
            return GMRITheme.color.danger
        case "purple":
            return GMRITheme.color.info
        case "teal":
            return GMRITheme.color.info
        case "blue":
            return GMRITheme.color.info
        default:
            return GMRITheme.color.neutral
        }
    }
}
