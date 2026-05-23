#if os(iOS) && canImport(ARKit)
import ARKit
import Foundation

public enum ARKitSpatialSessionError: Error, Equatable {
    case unsupportedDevice
}

@MainActor
public final class ARKitSpatialSession: NSObject {
    public let session: ARSession
    private let configuration: NativeSpatialConfiguration
    public var onStatusChange: ((NativeSpatialStatus) -> Void)?
    public private(set) var status: NativeSpatialStatus

    public init(
        session: ARSession = ARSession(),
        configuration: NativeSpatialConfiguration = .fullFunctionality
    ) {
        self.session = session
        self.configuration = configuration
        self.status = NativeSpatialStatus(
            runtime: .arKit,
            supported: ARWorldTrackingConfiguration.isSupported,
            running: false,
            tracking: "not_started",
            mapping: "not_available",
            reason: ARWorldTrackingConfiguration.isSupported ? nil : "ARWorldTrackingConfiguration is not supported on this device."
        )
        super.init()
        self.session.delegate = self
    }

    public nonisolated static func capability() -> NativeSpatialCapability {
        NativeSpatialCapability(
            runtime: .arKit,
            supported: ARWorldTrackingConfiguration.isSupported,
            reason: ARWorldTrackingConfiguration.isSupported ? nil : "ARKit world tracking is not supported on this device.",
            requiresCameraUsageDescription: true
        )
    }

    @discardableResult
    public func start(resetTracking: Bool = true, removeExistingAnchors: Bool = true) throws -> NativeSpatialStatus {
        guard ARWorldTrackingConfiguration.isSupported else {
            publish(NativeSpatialStatus(
                runtime: .arKit,
                supported: false,
                running: false,
                tracking: "unsupported",
                mapping: "not_available",
                reason: "ARKit world tracking is not supported on this device."
            ))
            throw ARKitSpatialSessionError.unsupportedDevice
        }

        var options: ARSession.RunOptions = []
        if resetTracking {
            options.insert(.resetTracking)
        }
        if removeExistingAnchors {
            options.insert(.removeExistingAnchors)
        }

        session.run(makeARConfiguration(), options: options)
        return publish(makeStatus(running: true, frame: session.currentFrame, reason: nil))
    }

    @discardableResult
    public func pause() -> NativeSpatialStatus {
        session.pause()
        return publish(makeStatus(running: false, frame: session.currentFrame, reason: "paused"))
    }

    public func snapshot() -> NativeSpatialStatus {
        makeStatus(running: status.running, frame: session.currentFrame, reason: status.reason)
    }

    private func makeARConfiguration() -> ARWorldTrackingConfiguration {
        let arConfiguration = ARWorldTrackingConfiguration()

        var planes: ARWorldTrackingConfiguration.PlaneDetection = []
        if configuration.planeDetectionHorizontal {
            planes.insert(.horizontal)
        }
        if configuration.planeDetectionVertical {
            planes.insert(.vertical)
        }
        arConfiguration.planeDetection = planes

        if configuration.environmentTexturing {
            arConfiguration.environmentTexturing = .automatic
        }
        if configuration.sceneReconstruction,
           ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            arConfiguration.sceneReconstruction = .mesh
        }
        if configuration.peopleOcclusion,
           ARWorldTrackingConfiguration.supportsFrameSemantics(.personSegmentationWithDepth) {
            arConfiguration.frameSemantics.insert(.personSegmentationWithDepth)
        }
        if configuration.collaboration {
            arConfiguration.isCollaborationEnabled = true
        }

        return arConfiguration
    }

    private func makeStatus(running: Bool, frame: ARFrame?, reason: String?) -> NativeSpatialStatus {
        NativeSpatialStatus(
            runtime: .arKit,
            supported: ARWorldTrackingConfiguration.isSupported,
            running: running,
            tracking: Self.trackingLabel(frame?.camera.trackingState),
            mapping: Self.mappingLabel(frame?.worldMappingStatus),
            reason: reason
        )
    }

    @discardableResult
    private func publish(_ newStatus: NativeSpatialStatus) -> NativeSpatialStatus {
        status = newStatus
        onStatusChange?(newStatus)
        return newStatus
    }

    private static func trackingLabel(_ state: ARCamera.TrackingState?) -> String {
        guard let state else {
            return "not_available"
        }
        switch state {
        case .normal:
            return "normal"
        case .notAvailable:
            return "not_available"
        case .limited(let reason):
            switch reason {
            case .excessiveMotion:
                return "limited_excessive_motion"
            case .insufficientFeatures:
                return "limited_insufficient_features"
            case .initializing:
                return "limited_initializing"
            case .relocalizing:
                return "limited_relocalizing"
            @unknown default:
                return "limited_unknown"
            }
        }
    }

    private static func mappingLabel(_ status: ARFrame.WorldMappingStatus?) -> String {
        guard let status else {
            return "not_available"
        }
        switch status {
        case .notAvailable:
            return "not_available"
        case .limited:
            return "limited"
        case .extending:
            return "extending"
        case .mapped:
            return "mapped"
        @unknown default:
            return "unknown"
        }
    }
}

extension ARKitSpatialSession: @preconcurrency ARSessionDelegate {
    public func session(_ session: ARSession, didUpdate frame: ARFrame) {
        publish(makeStatus(running: true, frame: frame, reason: nil))
    }

    public func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        publish(makeStatus(running: status.running, frame: session.currentFrame, reason: nil))
    }

    public func session(_ session: ARSession, didFailWithError error: Error) {
        publish(makeStatus(running: false, frame: session.currentFrame, reason: error.localizedDescription))
    }
}
#endif
