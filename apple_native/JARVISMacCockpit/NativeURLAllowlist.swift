import Foundation

struct NativeURLAllowlist: Sendable {
    enum Category: String, Sendable {
        case model
        case convex
        case voiceTranscription = "voice_transcription"
        case voiceSpeech = "voice_speech"
    }

    private let hostsByCategory: [String: Set<String>]

    static func load(path: String = "~/.jarvis/config/url_allowlist.json") throws -> NativeURLAllowlist {
        let expanded = NSString(string: path).expandingTildeInPath
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: expanded))
        } catch {
            throw NativeURLAllowlistError.missingAllowlist(expanded)
        }
        let raw = try JSONDecoder().decode([String: [String]].self, from: data)
        var hostsByCategory: [String: Set<String>] = [:]
        for (category, hosts) in raw {
            hostsByCategory[category] = Set(hosts.map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        }
        return NativeURLAllowlist(hostsByCategory: hostsByCategory)
    }

    func validate(_ url: URL, category: Category) throws {
        guard url.scheme?.lowercased() == "https" else {
            throw NativeURLAllowlistError.urlNotAllowed(category.rawValue, url.absoluteString, "scheme_not_https")
        }
        guard let host = url.host?.lowercased(), !host.isEmpty else {
            throw NativeURLAllowlistError.urlNotAllowed(category.rawValue, url.absoluteString, "missing_host")
        }
        guard hostsByCategory[category.rawValue]?.contains(host) == true else {
            throw NativeURLAllowlistError.urlNotAllowed(category.rawValue, host, "host_not_allowlisted")
        }
    }
}

enum NativeURLAllowlistError: LocalizedError, Equatable {
    case missingAllowlist(String)
    case urlNotAllowed(String, String, String)

    var errorDescription: String? {
        switch self {
        case .missingAllowlist(let path):
            return "URL allowlist missing; outbound native clients fail closed until configured: \(path)"
        case .urlNotAllowed(let category, let value, let reason):
            return "URLNotAllowed category=\(category) value=\(value) reason=\(reason)"
        }
    }
}
