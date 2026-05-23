import SwiftUI

enum CompanionAccentHue: String, CaseIterable, Identifiable, Sendable {
    case green
    case gold
    case orange
    case red
    case pink
    case purple
    case teal
    case blue
    case white

    var id: String { rawValue }

    var label: String {
        switch self {
        case .green: return "Green"
        case .gold: return "Gold"
        case .orange: return "Orange"
        case .red: return "Red"
        case .pink: return "Pink"
        case .purple: return "Purple"
        case .teal: return "Teal"
        case .blue: return "Blue"
        case .white: return "White"
        }
    }

    var color: Color {
        switch self {
        case .green: return .green
        case .gold: return .yellow
        case .orange: return .orange
        case .red: return .red
        case .pink: return .pink
        case .purple: return .purple
        case .teal: return .teal
        case .blue: return .blue
        case .white: return .white
        }
    }

    var spokenNames: [String] {
        switch self {
        case .green: return ["green", "growth"]
        case .gold: return ["gold", "yellow"]
        case .orange: return ["orange"]
        case .red: return ["red"]
        case .pink: return ["pink"]
        case .purple: return ["purple", "violet"]
        case .teal: return ["teal"]
        case .blue: return ["blue"]
        case .white: return ["white"]
        }
    }
}

@MainActor
final class CompanionAccentTheme: ObservableObject {
    @Published private(set) var selected: CompanionAccentHue
    @Published private(set) var hasChosenAccent: Bool

    private let defaults: UserDefaults
    private let selectedKey = "jarvis.companion.accentHue"
    private let chosenKey = "jarvis.companion.hasChosenAccentHue"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.string(forKey: selectedKey)
            .flatMap(CompanionAccentHue.init(rawValue:)) ?? .white
        self.selected = stored
        self.hasChosenAccent = defaults.bool(forKey: chosenKey)
    }

    var color: Color {
        selected.color
    }

    func choose(_ hue: CompanionAccentHue) {
        selected = hue
        hasChosenAccent = true
        defaults.set(hue.rawValue, forKey: selectedKey)
        defaults.set(true, forKey: chosenKey)
    }

    func choose(fromSpeech text: String) -> CompanionAccentHue? {
        let clean = text.lowercased()
        let looksLikeColorCommand = clean.contains("my color") ||
            clean.contains("highlight color") ||
            clean.contains("accent color") ||
            clean.contains("set my color") ||
            clean.contains("make my color")
        guard looksLikeColorCommand else {
            return nil
        }
        guard let hue = CompanionAccentHue.allCases.first(where: { candidate in
            candidate.spokenNames.contains(where: clean.contains)
        }) else {
            return nil
        }
        choose(hue)
        return hue
    }
}
