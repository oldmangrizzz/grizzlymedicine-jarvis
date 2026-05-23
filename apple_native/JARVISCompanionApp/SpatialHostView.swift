import JARVISCompanionCore
import JARVISCompanionUI
import SwiftUI

struct SpatialHostView: View {
    @EnvironmentObject private var appState: CompanionAppState
    @State private var status = NativeSpatialStatus.unavailable(reason: "ARKit has not started.")

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                if NativeSpatialCapability.current().supported {
                    ARKitSpatialSurfaceView(status: $status)
                        .ignoresSafeArea()
                } else {
                    ContentUnavailableView(
                        "Native spatial unavailable",
                        systemImage: "arkit",
                        description: Text(NativeSpatialCapability.current().reason ?? "This device does not support ARKit world tracking.")
                    )
                }

                SpatialStatusCard(status: status) {
                    Task {
                        await appState.send(event: NativeSpatialEventFactory.statusEvent(
                            status,
                            deviceID: UIDevice.current.identifierForVendor?.uuidString ?? "iphone-native-spatial"
                        ))
                    }
                }
                .padding()
            }
            .navigationTitle("Native Spatial")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct SpatialStatusCard: View {
    let status: NativeSpatialStatus
    let sendStatus: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ARKit native surface")
                .font(.headline)
            Text("Tracking: \(status.tracking)")
            Text("Mapping: \(status.mapping)")
            if let reason = status.reason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Send spatial status to JARVIS", action: sendStatus)
                .buttonStyle(.borderedProminent)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }
}
