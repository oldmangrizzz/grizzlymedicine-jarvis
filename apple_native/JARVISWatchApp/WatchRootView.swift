import SwiftUI

struct WatchRootView: View {
    @StateObject private var bridge = WatchBridge()
    @State private var commandText = ""

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [.black, Color(red: 0.00, green: 0.10, blue: 0.14), Color(red: 0.00, green: 0.18, blue: 0.22)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 12) {
                    VStack(spacing: 2) {
                        Text("GMRI")
                            .font(.caption2.weight(.bold))
                            .tracking(1.2)
                            .foregroundStyle(.cyan)
                        Text("JARVIS")
                            .font(.title2.weight(.bold))
                            .foregroundStyle(.white)
                    }

                    WatchOrb()

                    Text(bridge.status)
                        .font(.caption2.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(0.78))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.white.opacity(0.08), in: Capsule())

                    VStack(spacing: 8) {
                        TextField("Speak command", text: $commandText)
                            .textInputAutocapitalization(.sentences)

                        Button {
                            bridge.sendCommand(commandText)
                            commandText = ""
                        } label: {
                            Label("Execute", systemImage: "waveform.circle.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(commandText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .padding(10)
                    .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                    HStack(spacing: 8) {
                        Button {
                            bridge.sendCheckIn("watch_check_in")
                        } label: {
                            Image(systemName: "dot.radiowaves.left.and.right")
                        }

                        Button {
                            bridge.sendCommand("JARVIS, I need you. Check current companion context and respond with the next useful step.")
                        } label: {
                            Image(systemName: "sparkles")
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
}

private struct WatchOrb: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [.cyan.opacity(0.95), .blue.opacity(0.62), .black.opacity(0.10)],
                        center: .center,
                        startRadius: 2,
                        endRadius: 76
                    )
                )
                .frame(width: 86, height: 86)
                .shadow(color: .cyan.opacity(0.45), radius: 12)

            Circle()
                .stroke(.white.opacity(0.22), lineWidth: 1)
                .frame(width: 98, height: 98)

            Image(systemName: "waveform")
                .font(.title.weight(.semibold))
                .foregroundStyle(.white)
        }
        .padding(.vertical, 4)
    }
}
