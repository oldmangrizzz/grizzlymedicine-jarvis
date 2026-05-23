import Foundation

public struct CompanionTurnRequest: Codable, Equatable, Sendable {
    public var text: String

    public init(text: String) {
        self.text = text
    }
}

public struct CompanionTurnResponse: Codable, Equatable, Sendable {
    public var reply: String?
    public var driftToPrototype: Bool?
    public var endocrine: JSONValue?
    public var ecTone: JSONValue?
    public var ethicsConflict: JSONValue?
    public var model: String?

    enum CodingKeys: String, CodingKey {
        case reply
        case driftToPrototype = "drift_to_prototype"
        case endocrine
        case ecTone = "ec_tone"
        case ethicsConflict = "ethics_conflict"
        case model
    }
}

public struct CompanionSkillDescriptor: Codable, Equatable, Sendable {
    public var name: String
    public var risk: String
    public var baseRisk: String?
    public var description: String

    enum CodingKeys: String, CodingKey {
        case name
        case risk
        case baseRisk = "base_risk"
        case description
    }
}

public struct CompanionSkillCatalog: Codable, Equatable, Sendable {
    public var skills: [CompanionSkillDescriptor]
}

public struct CompanionSkillCommand: Codable, Equatable, Sendable {
    public var name: String
    public var args: [String: JSONValue]
    public var authorizationCode: String?

    public init(
        name: String,
        args: [String: JSONValue] = [:],
        authorizationCode: String? = nil
    ) {
        self.name = name
        self.args = args
        self.authorizationCode = authorizationCode
    }

    enum CodingKeys: String, CodingKey {
        case name
        case args
        case authorizationCode = "authorization_code"
    }
}

public struct CompanionSkillResult: Codable, Equatable, Sendable {
    public var ok: Bool
    public var skill: String?
    public var output: JSONValue?
    public var refused: Bool?
    public var reason: String?
    public var error: String?
    public var authorizationRequired: Bool?

    enum CodingKeys: String, CodingKey {
        case ok
        case skill
        case output
        case refused
        case reason
        case error
        case authorizationRequired = "authorization_required"
    }
}
