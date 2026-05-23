import SwiftUI

struct WatchRootView: View {
    @StateObject private var bridge = WatchBridge()
    @State private var commandText = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Text("JARVIS")
                    .font(.title3.bold())
                Text("GMRI Companion")
                    .font(.caption2)
                    .foregroundStyle(.cyan)
                Text(bridge.status)
                    .font(.caption)
                    .multilineTextAlignment(.center)

                TextField("Dictate command", text: $commandText)
                    .textInputAutocapitalization(.sentences)

                Button("Send command") {
                    bridge.sendCommand(commandText)
                    commandText = ""
                }
                .buttonStyle(.borderedProminent)

                Text("Open web, video, music, maps, or shortcuts through the phone.")
                    .font(.caption2)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)

                Button("Check in") {
                    bridge.sendCheckIn("watch_check_in")
                }

                Button("Need JARVIS") {
                    bridge.sendCommand("JARVIS, I need you. Check current companion context and respond with the next useful step.")
                }
            }
            .padding()
        }
        .onAppear {
            bridge.activate()
        }
    }
}
