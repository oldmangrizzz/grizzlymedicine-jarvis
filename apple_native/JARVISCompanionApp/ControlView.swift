import SwiftUI

struct ControlView: View {
    @EnvironmentObject private var appState: CompanionAppState
    @State private var turnText: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Talk to JARVIS") {
                    TextField("Jarvis, are you there?", text: $turnText, axis: .vertical)
                        .lineLimit(2...5)
                    Button("Send") {
                        let text = turnText
                        turnText = ""
                        Task { await appState.sendTurn(text) }
                    }
                }

                if !appState.lastReply.isEmpty {
                    Section("JARVIS") {
                        Text(appState.lastReply)
                            .textSelection(.enabled)
                    }
                }

                if !appState.lastError.isEmpty {
                    Section("Needs attention") {
                        Text(appState.lastError)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("JARVIS Control")
        }
    }
}
