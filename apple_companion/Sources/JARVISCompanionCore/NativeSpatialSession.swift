import Foundation

public enum NativeSpatialRuntime: String, Codable, Sendable {
    case arKit = "arkit"
    case unavailable
}

public struct NativeSpatialCapability: Codable, Equatable, Sendable {
    public var runtime: NativeSpatialRuntime
    public var supported: Bool
    public var reason: String?
    public var requiresCameraUsageDescription: Bool

    public init(
        runtime: NativeSpatialRuntime,
        supported: Bool,
        reason: String? = nil,
        requiresCameraUsageDescription: Bool
    ) {
        self.runtime = runtime
        self.supported = supported
        self.reason = reason
        self.requiresCameraUsageDescription = requiresCameraUsageDescription
    }

    public static func current() -> NativeSpatialCapability {
        #if os(iOS) && canImport(ARKit)
        ARKitSpatialSession.capability()
        #else
        NativeSpatialCapability(
            runtime: .unavailable,
            supported: false,
            reason: "ARKit native spatial rendering is available only on supported iOS devices.",
            requiresCameraUsageDescription: false
        )
        #endif
    }
}

public struct NativeSpatialConfiguration: Codable, Equatable, Sendable {
    public var planeDetectionHorizontal: Bool
    public var planeDetectionVertical: Bool
    public var sceneReconstruction: Bool
    public var peopleOcclusion: Bool
    public var environmentTexturing: Bool
    public var collaboration: Bool

    public init(
        planeDetectionHorizontal: Bool = true,
        planeDetectionVertical: Bool = true,
        sceneReconstruction: Bool = true,
        peopleOcclusion: Bool = true,
        environmentTexturing: Bool = true,
        collaboration: Bool = true
    ) {
        self.planeDetectionHorizontal = planeDetectionHorizontal
        self.planeDetectionVertical = planeDetectionVertical
        self.sceneReconstruction = sceneReconstruction
        self.peopleOcclusion = peopleOcclusion
        self.environmentTexturing = environmentTexturing
        self.collaboration = collaboration
    }

    public static let fullFunctionality = NativeSpatialConfiguration()
}

public struct NativeSpatialStatus: Codable, Equatable, Sendable {
    public var runtime: NativeSpatialRuntime
    public var supported: Bool
    public var running: Bool
    public var tracking: String
    public var mapping: String
    public var reason: String?
    public var timestamp: TimeInterval

    public init(
        runtime: NativeSpatialRuntime,
        supported: Bool,
        running: Bool,
        tracking: String,
        mapping: String,
        reason: String? = nil,
        timestamp: TimeInterval = Date().timeIntervalSince1970
    ) {
        self.runtime = runtime
        self.supported = supported
        self.running = running
        self.tracking = tracking
        self.mapping = mapping
        self.reason = reason
        self.timestamp = timestamp
    }

    public static func unavailable(reason: String) -> NativeSpatialStatus {
        NativeSpatialStatus(
            runtime: .unavailable,
            supported: false,
            running: false,
            tracking: "unavailable",
            mapping: "unavailable",
            reason: reason
        )
    }
}

public enum NativeSpatialEventFactory {
    public static func statusEvent(_ status: NativeSpatialStatus, deviceID: String) -> CompanionEvent {
        CompanionEvent(
            source: .nativeSpatial,
            deviceID: deviceID,
            kind: "native_spatial_status",
            timestamp: status.timestamp,
            motion: status.running ? "tracking" : "idle",
            active: status.running,
            interactionMode: "native_spatial",
            confidence: status.supported ? 0.95 : 0.0,
            notes: status.reason,
            extra: [
                "runtime": .string(status.runtime.rawValue),
                "supported": .bool(status.supported),
                "running": .bool(status.running),
                "tracking": .string(status.tracking),
                "mapping": .string(status.mapping),
            ]
        )
    }
}
