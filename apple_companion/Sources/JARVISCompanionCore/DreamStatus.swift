import Foundation

public struct DreamStatus: Codable, Equatable, Sendable {
    public var microReady: Bool
    public var deepReady: Bool
    public var quietEnough: Bool
    public var deepOverdue: Bool
    public var idleSeconds: Double?
    public var activeSignals: [String]
    public var quietSignals: [String]
    public var lastMicroDreamAt: Double?
    public var lastDeepDreamAt: Double?
    public var lastTransitionDreamAt: Double?
    public var decisionBoundary: String

    enum CodingKeys: String, CodingKey {
        case microReady = "micro_ready"
        case deepReady = "deep_ready"
        case quietEnough = "quiet_enough"
        case deepOverdue = "deep_overdue"
        case idleSeconds = "idle_seconds"
        case activeSignals = "active_signals"
        case quietSignals = "quiet_signals"
        case lastMicroDreamAt = "last_micro_dream_at"
        case lastDeepDreamAt = "last_deep_dream_at"
        case lastTransitionDreamAt = "last_transition_dream_at"
        case decisionBoundary = "decision_boundary"
    }
}

public struct AmbientStatus: Codable, Equatable, Sendable {
    public var path: String?
    public var policy: [String: JSONValue]?
    public var runtime: [String: JSONValue]?
    public var dream: DreamStatus
    public var eventCount: Int
    public var latest: [String: JSONValue]?

    enum CodingKeys: String, CodingKey {
        case path
        case policy
        case runtime
        case dream
        case eventCount = "event_count"
        case latest
    }
}

public struct CompanionManifest: Codable, Equatable, Sendable {
    public var service: String
    public var version: String
    public var baseURL: String
    public var tokenHeader: String
    public var tokenSource: String
    public var sources: [String]

    enum CodingKeys: String, CodingKey {
        case service
        case version
        case baseURL = "base_url"
        case tokenHeader = "token_header"
        case tokenSource = "token_source"
        case sources
    }
}

public struct CompanionEventResponse: Codable, Equatable, Sendable {
    public var ok: Bool
    public var event: CompanionEvent?
    public var dream: DreamStatus?
    public var path: String?
}
