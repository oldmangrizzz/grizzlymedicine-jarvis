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
                .tabItem { Label("See", systemImage: "eye") }

            OnboardingHostView()
                .tabItem { Label("People", systemImage: "person.2") }

            VoiceRegistrationView()
                .tabItem { Label("My Voice", systemImage: "person.wave.2") }

            SetupView()
                .tabItem { Label("Help", systemImage: "questionmark.circle") }
        }
        .environmentObject(appState)
        .tint(.cyan)
        .toolbarBackground(.black.opacity(0.85), for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
        .onAppear {
            watchBridge.activate(appState: appState)
        }
        .task {
            await appState.checkConnection()
        }
    }
}

private struct SetupView: View {
    @EnvironmentObject private var appState: CompanionAppState
    @State private var showAdvanced = false

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
                        Text("JARVIS HELP")
                            .font(.caption.weight(.bold))
                            .tracking(1.4)
                            .foregroundStyle(.cyan)
                        Text("If something feels stuck, press the button below.")
                            .font(.largeTitle.weight(.semibold))
                            .foregroundStyle(.white)
                        Text("JARVIS connects in the background. You should not need codes, tokens, IP addresses, or setup steps.")
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.70))
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Label(appState.connectionStatus, systemImage: appState.isPaired ? "checkmark.seal.fill" : "wifi.exclamationmark")
                            .font(.headline)
                            .foregroundStyle(appState.isPaired ? .green : .orange)
                        Button {
                            Task { await appState.registerDevice() }
                        } label: {
                            Label(appState.isConnecting ? "Trying now" : "Fix connection", systemImage: "arrow.clockwise")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(appState.isConnecting)
                        Button {
                            Task { await appState.checkConnection() }
                        } label: {
                            Label("Check again", systemImage: "cloud.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(appState.isConnecting)

                        DisclosureGroup(isExpanded: $showAdvanced) {
                            TextField("Cloud endpoint", text: $appState.cloudURLText)
                                .textInputAutocapitalization(.never)
                                .keyboardType(.URL)
                                .textFieldStyle(.roundedBorder)
                                .padding(.top, 8)
                        } label: {
                            Text("Advanced")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.72))
                        }
                        .tint(.cyan)
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
            .navigationTitle("Help")
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
