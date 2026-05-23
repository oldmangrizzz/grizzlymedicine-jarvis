import Foundation
import UIKit

struct DeviceActionResult: Equatable, Sendable {
    let title: String
    let detail: String
    let url: URL
    let succeeded: Bool
}

@MainActor
enum DeviceActionRouter {
    static func route(_ rawCommand: String) async -> DeviceActionResult? {
        let command = normalized(rawCommand)
        guard !command.isEmpty else {
            return nil
        }

        if let shortcut = payload(command, triggers: ["run shortcut", "start shortcut", "shortcut"]) {
            return await open(.shortcut(shortcut))
        }

        if isVideoCommand(command), let query = payload(command, triggers: ["open youtube", "youtube", "watch video", "play video", "watch"]) {
            return await open(.youtube(query))
        }

        if isMusicCommand(command), let query = payload(command, triggers: ["play music", "play song", "play album", "play artist", "music", "play"]) {
            return await open(.music(query))
        }

        if isMapCommand(command), let query = payload(command, triggers: ["navigate to", "directions to", "map", "maps", "go to"]) {
            return await open(.maps(query))
        }

        if isWebCommand(command), let query = payload(command, triggers: ["search web for", "search for", "google", "look up", "browser", "safari", "open web", "open"]) {
            return await open(.web(query))
        }

        return nil
    }

    private static func open(_ action: DeviceAction) async -> DeviceActionResult {
        let succeeded = await openURL(action.url)
        return DeviceActionResult(
            title: action.title,
            detail: action.detail,
            url: action.url,
            succeeded: succeeded
        )
    }

    private static func openURL(_ url: URL) async -> Bool {
        await withCheckedContinuation { continuation in
            UIApplication.shared.open(url, options: [:]) { succeeded in
                continuation.resume(returning: succeeded)
            }
        }
    }

    private static func normalized(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "JARVIS", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func payload(_ command: String, triggers: [String]) -> String? {
        for trigger in triggers {
            if let range = command.range(of: trigger, options: [.caseInsensitive, .diacriticInsensitive]) {
                let text = command[range.upperBound...]
                    .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
                return text.isEmpty ? nil : text
            }
        }
        return command
    }

    private static func isVideoCommand(_ command: String) -> Bool {
        contains(command, ["youtube", "video", "watch"])
    }

    private static func isMusicCommand(_ command: String) -> Bool {
        contains(command, ["music", "song", "album", "artist", "playlist"]) || command.lowercased().hasPrefix("play ")
    }

    private static func isMapCommand(_ command: String) -> Bool {
        contains(command, ["map", "maps", "navigate", "directions", "go to"])
    }

    private static func isWebCommand(_ command: String) -> Bool {
        contains(command, ["search", "google", "look up", "browser", "safari", "open", "website", "web"]) || looksLikeWebAddress(command)
    }

    private static func contains(_ command: String, _ terms: [String]) -> Bool {
        let lower = command.lowercased()
        return terms.contains { lower.contains($0) }
    }

    private static func looksLikeWebAddress(_ text: String) -> Bool {
        let lower = text.lowercased()
        return (lower.contains(".") && !lower.contains(" ")) || lower.hasPrefix("http://") || lower.hasPrefix("https://")
    }
}

private enum DeviceAction {
    case web(String)
    case youtube(String)
    case music(String)
    case maps(String)
    case shortcut(String)

    var title: String {
        switch self {
        case .web:
            return "Opening web"
        case .youtube:
            return "Opening video"
        case .music:
            return "Opening music"
        case .maps:
            return "Opening maps"
        case .shortcut:
            return "Running shortcut"
        }
    }

    var detail: String {
        switch self {
        case .web(let query), .youtube(let query), .music(let query), .maps(let query), .shortcut(let query):
            return query
        }
    }

    var url: URL {
        switch self {
        case .web(let query):
            if let direct = directWebURL(query) {
                return direct
            }
            return queryURL("https://www.google.com/search", item: "q", value: query)
        case .youtube(let query):
            return queryURL("https://www.youtube.com/results", item: "search_query", value: query)
        case .music(let query):
            return queryURL("https://music.apple.com/search", item: "term", value: query)
        case .maps(let query):
            return queryURL("http://maps.apple.com/", item: "q", value: query)
        case .shortcut(let name):
            return queryURL("shortcuts://run-shortcut", item: "name", value: name)
        }
    }

    private func queryURL(_ base: String, item: String, value: String) -> URL {
        var components = URLComponents(string: base)
        components?.queryItems = [URLQueryItem(name: item, value: value)]
        return components?.url ?? URL(fileURLWithPath: "/")
    }

    private func directWebURL(_ value: String) -> URL? {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: clean), url.scheme != nil {
            return url
        }
        if clean.contains("."), !clean.contains(" ") {
            return URL(string: "https://\(clean)")
        }
        return nil
    }
}
