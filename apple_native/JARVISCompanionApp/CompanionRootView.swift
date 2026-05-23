import JARVISCompanionUI
import SwiftUI

struct CompanionRootView: View {
    @StateObject private var appState = CompanionAppState()
    @StateObject private var watchBridge = PhoneWatchBridge()

    var body: some View {
        TabView {
            SetupView()
                .tabItem { Label("Setup", systemImage: "link") }

            OnboardingHostView()
                .tabItem { Label("People", systemImage: "person.2") }

            VoiceRegistrationView()
                .tabItem { Label("Voice", systemImage: "waveform") }

            SpatialHostView()
                .tabItem { Label("Spatial", systemImage: "arkit") }

            ControlView()
                .tabItem { Label("Control", systemImage: "terminal") }
        }
        .environmentObject(appState)
        .onAppear {
            watchBridge.activate(appState: appState)
        }
    }
}

private struct SetupView: View {
    @EnvironmentObject private var appState: CompanionAppState

    var body: some View {
        NavigationStack {
            Form {
                Section("JARVIS Cloud") {
                    TextField("Cloud endpoint", text: $appState.cloudURLText)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                    TextField("Pairing code", text: $appState.pairingCode)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    Button("Pair this device") {
                        Task { await appState.pairDevice() }
                    }
                    Button("Check cloud connection") {
                        Task { await appState.checkConnection() }
                    }
                }

                Section("Status") {
                    Text(appState.connectionStatus)
                    if !appState.lastError.isEmpty {
                        Text(appState.lastError)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }

                Section("Beta expectation") {
                    Text("This build uses Convex as the companion spine. Testers pair once, then People, Voice, Spatial, Watch, and Control signals route through JARVIS Cloud without a laptop IP address.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("JARVIS Setup")
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
