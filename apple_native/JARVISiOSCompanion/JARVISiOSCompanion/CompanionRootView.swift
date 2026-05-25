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


struct CompanionRootView: View {
    @ObservedObject var model: CompanionAppModel

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                VStack(spacing: 8) {
                    Text("JARVIS")
                        .font(.largeTitle.bold())
                    Text("iPhone sensory / effector surface")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("Cognition remains on the paired Mac.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                statusPanel

                if model.pairingRecord == nil {
                    PairingView(model: model)
                } else {
                    VoiceSurfaceView(model: model)
                }

                Spacer()
            }
            .padding()
            .navigationTitle("JARVIS Surface")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Forget") { model.forgetPairing() }
                        .disabled(model.pairingRecord == nil)
                }
            }
        }
    }

    private var statusPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(model.connectionState.label, systemImage: model.connectionState.symbol)
            if let host = model.pairingRecord?.hostID {
                Text("Paired Mac: \(host)").font(.caption).foregroundStyle(.secondary)
            }
            if let error = model.lastError {
                Text(error).font(.caption).foregroundStyle(GMRITheme.color.danger)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

struct PairingView: View {
    @ObservedObject var model: CompanionAppModel
    @State private var qrPayload = ""
    @State private var displayedShortCode = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Pair with Mac")
                .font(.headline)
            Text("Paste the jarvis-wire QR payload or enter the short-code displayed by the Mac. This app does not request camera permission.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("jarvis-wire://pair?offer=…", text: $qrPayload, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("Short-code", text: $displayedShortCode)
                .keyboardType(.numberPad)
                .textFieldStyle(.roundedBorder)
            Button("Complete Pairing") {
                model.completePairing(qrPayload: qrPayload, displayedShortCode: displayedShortCode)
            }
            .onReceive(model.$incomingPairingPayload) { payload in
                guard !payload.isEmpty else { return }
                qrPayload = payload
            }
            .buttonStyle(.borderedProminent)
            .disabled(qrPayload.isEmpty || displayedShortCode.isEmpty)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct VoiceSurfaceView: View {
    @ObservedObject var model: CompanionAppModel

    var body: some View {
        VStack(spacing: 18) {
            Button {
                model.togglePushToTalk()
            } label: {
                Label(model.isTransmittingAudio ? "Tap to stop" : "Push to talk", systemImage: model.isTransmittingAudio ? "stop.circle.fill" : "mic.circle.fill")
                    .font(.title2.bold())
                    .frame(maxWidth: .infinity)
                    .padding()
            }
            .buttonStyle(.borderedProminent)
            .tint(model.isTransmittingAudio ? GMRITheme.color.danger : GMRITheme.color.info)
            .disabled(!model.connectionState.isConnected)

            Button("Reconnect to Mac") { model.reconnect() }
                .buttonStyle(.bordered)
                .disabled(model.connectionState == .connecting)

            Text("No transcripts are stored. Raw PCM is relayed only while push-to-talk is active.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }
}

extension CompanionConnectionState {
    var label: String {
        switch self {
        case .unpaired: "Unpaired"
        case .discovering: "Discovering Mac by Bonjour"
        case .connecting: "Connecting"
        case .connected: "Connected"
        case .disconnected: "Disconnected"
        }
    }

    var symbol: String {
        switch self {
        case .unpaired: "lock.open"
        case .discovering: "dot.radiowaves.left.and.right"
        case .connecting: "arrow.triangle.2.circlepath"
        case .connected: "lock"
        case .disconnected: "wifi.slash"
        }
    }

    var isConnected: Bool { self == .connected }
}
