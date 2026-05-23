import SwiftUI

struct CompanionRootView: View {
    @StateObject private var appState = CompanionAppState()
    @StateObject private var accent = CompanionAccentTheme()
    @StateObject private var watchBridge = PhoneWatchBridge()

    var body: some View {
        TabView {
            ControlView()
                .tabItem { Label("JARVIS", systemImage: "waveform.circle.fill") }

            SpatialHostView()
                .tabItem { Label("See", systemImage: "eye") }

            PeopleView()
                .tabItem { Label("People", systemImage: "person.2") }

            VoiceRegistrationView()
                .tabItem { Label("My Voice", systemImage: "person.wave.2") }

            HelpView()
                .tabItem { Label("Help", systemImage: "questionmark.circle") }
        }
        .environmentObject(appState)
        .environmentObject(accent)
        .tint(accent.color)
        .toolbarBackground(.black.opacity(0.85), for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
        .onAppear {
            watchBridge.activate(appState: appState)
            watchBridge.sendAccent(accent.selected)
        }
        .onChange(of: accent.selected) { _, selected in
            watchBridge.sendAccent(selected)
        }
        .task {
            await appState.checkConnection()
        }
    }
}

private struct HelpView: View {
    @EnvironmentObject private var appState: CompanionAppState
    @EnvironmentObject private var accent: CompanionAccentTheme
    @State private var showAdvanced = false

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [.black, accent.color.opacity(0.16), accent.color.opacity(0.08)],
                    startPoint: .top,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack(alignment: .top, spacing: 14) {
                            BrandSealView(size: 72)
                            VStack(alignment: .leading, spacing: 6) {
                                Text("JARVIS HELP")
                                    .font(.caption.weight(.bold))
                                    .tracking(1.4)
                                    .foregroundStyle(accent.color)
                                Text("If something feels stuck, press the button below.")
                                    .font(.largeTitle.weight(.semibold))
                                    .foregroundStyle(.white)
                                Text("JARVIS connects in the background. You should not need codes, tokens, or IP addresses.")
                                    .font(.callout)
                                    .foregroundStyle(.white.opacity(0.70))
                            }
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
                            .tint(accent.color)
                        }
                        .padding(18)
                        .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 24, style: .continuous)
                                .stroke(accent.color.opacity(0.20), lineWidth: 1)
                        )

                        AccentPickerCard()

                        VStack(alignment: .leading, spacing: 8) {
                            Text("STATUS")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(accent.color)
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
                    }
                    .padding(20)
                }
            }
            .navigationTitle("Help")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct AccentPickerCard: View {
    @EnvironmentObject private var accent: CompanionAccentTheme

    private let columns = [
        GridItem(.adaptive(minimum: 86), spacing: 8),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("YOUR HIGHLIGHT COLOR")
                .font(.caption2.weight(.bold))
                .foregroundStyle(accent.color)
            Text("Pick the color JARVIS uses for you. You can also say, \"JARVIS, my color is purple.\"")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.72))

            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(CompanionAccentHue.allCases) { hue in
                    Button {
                        accent.choose(hue)
                    } label: {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(hue.color)
                                .frame(width: 14, height: 14)
                            Text(hue.label)
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity)
                        .background(.white.opacity(accent.selected == hue ? 0.18 : 0.08), in: Capsule())
                        .overlay(
                            Capsule()
                                .stroke(hue.color.opacity(accent.selected == hue ? 0.70 : 0.28), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}
