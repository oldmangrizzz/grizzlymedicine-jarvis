import SwiftUI

/// Canonical GMRI app-surface palette.
/// Mapping: success=emerald, danger/warning=crimson, info/neutral=GMRI silver,
/// background=GMRI black, surface=slightly lifted black, accentHalo=emerald halo.
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
