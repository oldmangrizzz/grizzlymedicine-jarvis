#if os(iOS) && canImport(ARKit) && canImport(SwiftUI)
import ARKit
import JARVISCompanionCore
import SwiftUI

public struct ARKitSpatialSurfaceView: UIViewRepresentable {
    @Binding private var status: NativeSpatialStatus
    private let configuration: NativeSpatialConfiguration

    public init(
        status: Binding<NativeSpatialStatus>,
        configuration: NativeSpatialConfiguration = .fullFunctionality
    ) {
        self._status = status
        self.configuration = configuration
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(status: $status)
    }

    public func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.automaticallyUpdatesLighting = true

        do {
            let spatialSession = ARKitSpatialSession(
                session: view.session,
                configuration: configuration
            )
            spatialSession.onStatusChange = { [weak coordinator = context.coordinator] newStatus in
                coordinator?.status.wrappedValue = newStatus
            }
            context.coordinator.spatialSession = spatialSession
            status = try spatialSession.start()
        } catch {
            status = NativeSpatialStatus(
                runtime: .arKit,
                supported: false,
                running: false,
                tracking: "failed",
                mapping: "not_available",
                reason: error.localizedDescription
            )
        }

        return view
    }

    public func updateUIView(_ uiView: ARSCNView, context: Context) {
        if let current = context.coordinator.spatialSession?.snapshot() {
            status = current
        }
    }

    public static func dismantleUIView(_ uiView: ARSCNView, coordinator: Coordinator) {
        _ = coordinator.spatialSession?.pause()
        uiView.session.delegate = nil
    }

    @MainActor
    public final class Coordinator: NSObject {
        fileprivate var spatialSession: ARKitSpatialSession?
        fileprivate var status: Binding<NativeSpatialStatus>

        fileprivate init(status: Binding<NativeSpatialStatus>) {
            self.status = status
        }
    }
}
#endif
