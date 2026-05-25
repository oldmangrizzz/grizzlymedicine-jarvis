import SwiftUI

// Local copy of the canonical GMRI palette from JARVISMacCockpit/GMRITheme.swift.
// Mapping: success=emerald, danger/warning=crimson, info/neutral=GMRI silver,
// background=GMRI black, surface=slightly lifted black, accentHalo=emerald halo.
enum GMRITheme {
    enum color {
        static let background = Color(red: 0.02, green: 0.023, blue: 0.025)
        static let surface = Color(red: 0.035, green: 0.040, blue: 0.044)
        static let neutral = Color(red: 0.80, green: 0.82, blue: 0.84)
        static let info = neutral
        static let success = Color(red: 0.00, green: 0.78, blue: 0.42)
        static let danger = Color(red: 0.79, green: 0.09, blue: 0.18)
        static let warning = danger
        static let accentHalo = Color(red: 0.30, green: 0.95, blue: 0.58)
    }
}


enum CompanionAccentHue: String, CaseIterable, Identifiable, Sendable {
    case emerald = "green"
    case gold = "gold"
    case sunset = "orange"
    case crimson = "red"
    case rose = "pink"
    case violet = "purple"
    case sea = "teal"
    case azure = "blue"
    case neutral = "white"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .emerald: return "Green"
        case .gold: return "Gold"
        case .sunset: return "Orange"
        case .crimson: return "Red"
        case .rose: return "Pink"
        case .violet: return "Purple"
        case .sea: return "Teal"
        case .azure: return "Blue"
        case .neutral: return "White"
        }
    }

    var color: Color {
        switch self {
        case .emerald: return GMRITheme.color.success
        case .gold: return GMRITheme.color.info
        case .sunset: return GMRITheme.color.warning
        case .crimson: return GMRITheme.color.danger
        case .rose: return GMRITheme.color.danger
        case .violet: return GMRITheme.color.info
        case .sea: return GMRITheme.color.info
        case .azure: return GMRITheme.color.info
        case .neutral: return GMRITheme.color.neutral
        }
    }

    var spokenNames: [String] {
        switch self {
        case .emerald: return ["green", "growth"]
        case .gold: return ["gold", "yellow"]
        case .sunset: return ["orange"]
        case .crimson: return ["red"]
        case .rose: return ["pink"]
        case .violet: return ["purple", "violet"]
        case .sea: return ["teal"]
        case .azure: return ["blue"]
        case .neutral: return ["white"]
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
            .flatMap(CompanionAccentHue.init(rawValue:)) ?? .neutral
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
