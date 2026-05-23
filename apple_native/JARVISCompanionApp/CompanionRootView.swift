import JARVISCompanionUI
import SwiftUI

struct CompanionRootView: View {
    @StateObject private var appState = CompanionAppState()
    @StateObject private var watchBridge = PhoneWatchBridge()

    var body: some View {
        TabView {
            ControlView()
                .tabItem { Label("JARVIS", systemImage: "waveform.circle.fill") }

            SpatialHostView()
                .tabItem { Label("Vision", systemImage: "arkit") }

            OnboardingHostView()
                .tabItem { Label("People", systemImage: "person.2") }

            VoiceRegistrationView()
                .tabItem { Label("Voice ID", systemImage: "person.wave.2") }

            SetupView()
                .tabItem { Label("Link", systemImage: "link") }
        }
        .environmentObject(appState)
        .tint(.cyan)
        .toolbarBackground(.black.opacity(0.85), for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
        .onAppear {
            watchBridge.activate(appState: appState)
        }
    }
}

private struct SetupView: View {
    @EnvironmentObject private var appState: CompanionAppState

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [.black, Color(red: 0.01, green: 0.07, blue: 0.10), Color(red: 0.00, green: 0.14, blue: 0.18)],
                    startPoint: .top,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("GMRI LINK")
                            .font(.caption.weight(.bold))
                            .tracking(1.4)
                            .foregroundStyle(.cyan)
                        Text("Pair once. Speak after.")
                            .font(.largeTitle.weight(.semibold))
                            .foregroundStyle(.white)
                        Text("No laptop IP address. No Mac bridge token. This device joins JARVIS through Convex and then becomes a voice-first control surface.")
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.70))
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        TextField("Cloud endpoint", text: $appState.cloudURLText)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                            .textFieldStyle(.roundedBorder)
                        TextField("Pairing code", text: $appState.pairingCode)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .textFieldStyle(.roundedBorder)
                        Button {
                            Task { await appState.pairDevice() }
                        } label: {
                            Label("Pair this device", systemImage: "link.badge.plus")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        Button {
                            Task { await appState.checkConnection() }
                        } label: {
                            Label("Check cloud connection", systemImage: "cloud.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(18)
                    .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .stroke(.cyan.opacity(0.20), lineWidth: 1)
                    )

                    VStack(alignment: .leading, spacing: 8) {
                        Text("STATUS")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.cyan)
                        Text(appState.connectionStatus)
                            .foregroundStyle(.white)
                        if !appState.lastError.isEmpty {
                            Text(appState.lastError)
                                .foregroundStyle(.orange)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 20, style: .continuous))

                    Spacer()
                }
                .padding(20)
            }
            .navigationTitle("Link")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct OnboardingHostView: View {
    @State private var model: CompanionOnboardingViewModel?
    @State private var errorText: String = ""

    var body: some View {
        Group {
            if let model {
                CompanionOnboardingView(model: model)
            } else {
                ContentUnavailableView(
                    "Onboarding unavailable",
                    systemImage: "person.crop.circle.badge.exclamationmark",
                    description: Text(errorText.isEmpty ? "Loading onboarding store..." : errorText)
                )
            }
        }
        .task {
            guard model == nil else {
                return
            }
            do {
                model = try CompanionOnboardingViewModel()
            } catch {
                errorText = String(describing: error)
            }
        }
    }
}
