import SwiftUI

struct WatchRootView: View {
    @StateObject private var bridge = WatchBridge()

    var body: some View {
        VStack(spacing: 12) {
            Text("JARVIS")
                .font(.headline)
            Text(bridge.status)
                .font(.caption)
                .multilineTextAlignment(.center)

            Button("Check in") {
                bridge.sendCheckIn("watch_check_in")
            }

            Button("Need JARVIS") {
                bridge.sendCheckIn("need_jarvis")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .onAppear {
            bridge.activate()
        }
    }
}
