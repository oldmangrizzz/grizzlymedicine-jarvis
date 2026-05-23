import Foundation

public struct CompanionEvent: Codable, Equatable, Sendable {
    public enum Source: String, Codable, Sendable {
        case iPhone = "iphone"
        case appleWatch = "apple_watch"
        case nativeSpatial = "native_spatial"
        case carPlay = "carplay"
        case homeKit = "homekit"
        case blink = "blink"
        case esp32Future = "esp32_future"
    }

    public var source: String
    public var deviceID: String?
    public var kind: String
    public var timestamp: TimeInterval?
    public var focus: String?
    public var sleepFocus: Bool?
    public var charging: Bool?
    public var battery: Double?
    public var motion: String?
    public var active: Bool?
    public var location: String?
    public var wristState: String?
    public var carPlayConnected: Bool?
    public var driving: Bool?
    public var vehicleMotion: String?
    public var routeState: String?
    public var interactionMode: String?
    public var heartRateBand: String?
    public var hrvBand: String?
    public var workout: String?
    public var checkIn: String?
    public var confidence: Double?
    public var notes: String?
    public var extra: [String: JSONValue]?

    public init(
        source: Source,
        deviceID: String? = nil,
        kind: String = "state",
        timestamp: TimeInterval? = nil,
        focus: String? = nil,
        sleepFocus: Bool? = nil,
        charging: Bool? = nil,
        battery: Double? = nil,
        motion: String? = nil,
        active: Bool? = nil,
        location: String? = nil,
        wristState: String? = nil,
        carPlayConnected: Bool? = nil,
        driving: Bool? = nil,
        vehicleMotion: String? = nil,
        routeState: String? = nil,
        interactionMode: String? = nil,
        heartRateBand: String? = nil,
        hrvBand: String? = nil,
        workout: String? = nil,
        checkIn: String? = nil,
        confidence: Double? = nil,
        notes: String? = nil,
        extra: [String: JSONValue]? = nil
    ) {
        self.source = source.rawValue
        self.deviceID = deviceID
        self.kind = kind
        self.timestamp = timestamp
        self.focus = focus
        self.sleepFocus = sleepFocus
        self.charging = charging
        self.battery = battery
        self.motion = motion
        self.active = active
        self.location = location
        self.wristState = wristState
        self.carPlayConnected = carPlayConnected
        self.driving = driving
        self.vehicleMotion = vehicleMotion
        self.routeState = routeState
        self.interactionMode = interactionMode
        self.heartRateBand = heartRateBand
        self.hrvBand = hrvBand
        self.workout = workout
        self.checkIn = checkIn
        self.confidence = confidence
        self.notes = notes
        self.extra = extra
    }

    enum CodingKeys: String, CodingKey {
        case source
        case deviceID = "device_id"
        case kind
        case timestamp
        case focus
        case sleepFocus = "sleep_focus"
        case charging
        case battery
        case motion
        case active
        case location
        case wristState = "wrist_state"
        case carPlayConnected = "carplay_connected"
        case driving
        case vehicleMotion = "vehicle_motion"
        case routeState = "route_state"
        case interactionMode = "interaction_mode"
        case heartRateBand = "heart_rate_band"
        case hrvBand = "hrv_band"
        case workout
        case checkIn = "check_in"
        case confidence
        case notes
        case extra
    }
}

public enum AppleSignalFactory {
    public static func phoneState(
        deviceID: String,
        focus: String? = nil,
        charging: Bool? = nil,
        battery: Double? = nil,
        active: Bool? = nil,
        location: String? = nil
    ) -> CompanionEvent {
        CompanionEvent(
            source: .iPhone,
            deviceID: deviceID,
            focus: focus,
            charging: charging,
            battery: battery,
            active: active,
            location: location,
            confidence: 0.8
        )
    }

    public static func watchState(
        deviceID: String,
        wristState: String? = nil,
        motion: String? = nil,
        sleepFocus: Bool? = nil,
        charging: Bool? = nil,
        heartRateBand: String? = nil,
        hrvBand: String? = nil
    ) -> CompanionEvent {
        CompanionEvent(
            source: .appleWatch,
            deviceID: deviceID,
            sleepFocus: sleepFocus,
            charging: charging,
            motion: motion,
            wristState: wristState,
            heartRateBand: heartRateBand,
            hrvBand: hrvBand,
            confidence: 0.8
        )
    }

    public static func carPlayState(
        deviceID: String,
        connected: Bool,
        driving: Bool,
        vehicleMotion: String,
        routeState: String? = nil
    ) -> CompanionEvent {
        CompanionEvent(
            source: .carPlay,
            deviceID: deviceID,
            carPlayConnected: connected,
            driving: driving,
            vehicleMotion: vehicleMotion,
            routeState: routeState,
            interactionMode: "carplay",
            confidence: 1.0
        )
    }

    public static func nativeSpatialState(
        deviceID: String,
        running: Bool,
        tracking: String,
        mapping: String,
        supported: Bool,
        notes: String? = nil
    ) -> CompanionEvent {
        CompanionEvent(
            source: .nativeSpatial,
            deviceID: deviceID,
            kind: "native_spatial_status",
            motion: running ? "tracking" : "idle",
            active: running,
            interactionMode: "native_spatial",
            confidence: supported ? 0.95 : 0.0,
            notes: notes,
            extra: [
                "tracking": .string(tracking),
                "mapping": .string(mapping),
                "supported": .bool(supported),
            ]
        )
    }

    public static func checkIn(source: CompanionEvent.Source, deviceID: String, value: String, notes: String? = nil) -> CompanionEvent {
        CompanionEvent(
            source: source,
            deviceID: deviceID,
            kind: "check_in",
            checkIn: value,
            confidence: 1.0,
            notes: notes
        )
    }
}
