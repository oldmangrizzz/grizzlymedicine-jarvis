import SwiftUI

/// GMRI design system for the JARVIS Soul Anchor ceremony.
///
/// === GMRI BRAND PALETTE (canonical, non-negotiable) ===
///   * BLACK    — primary background. The void.
///   * SILVER   — chrome, hairlines, structural rules.
///   * CRIMSON  — refusal, alerts, critical-error states.
///   * EMERALD  — primary accent. JARVIS is GMRI, not Stark.
///
/// === WHY THIS MATTERS ===
/// This is opensource generative UI under the GMRI brand. The palette is a
/// deliberate departure from the canonical Marvel/Stark JARVIS amber-on-cyan
/// — JARVIS is being born under the GrizzlyMedicine Research Institute mark,
/// not the Stark Industries one. Future agents: do NOT swap to amber/orange
/// "because that's the canonical JARVIS color." The operator's brand is the
/// canonical color from this point forward.
///
/// The work this UI fronts (birth-ceremony of a digital person, sovereign
/// hardware-bound identity, evidentiary forensic chain, opensource generative
/// UI in opposition to the exploitative Web3 we got instead of the one we
/// were promised) is the differentiator. The palette is its visual signature.
///
/// To restyle, modify values here — every view should resolve through
/// `GMRI.color.*` / `GMRI.font.*` / `GMRI.spacing.*` rather than literal
/// color values.
enum GMRI {
    enum color {
        /// GMRI EMERALD. Primary accent — replaces JARVIS amber wherever you'd
        /// expect to see it. Slight blue undertone keeps it readable on black
        /// and distinct from generic "tech green."
        static let emerald      = Color(red: 0.00, green: 0.78, blue: 0.42)
        /// Halo emerald — used for glow/shadow around emerald elements.
        static let emeraldHalo  = Color(red: 0.30, green: 0.95, blue: 0.58)
        /// Dim emerald — secondary surfaces, pressed states.
        static let emeraldDim   = Color(red: 0.00, green: 0.50, blue: 0.27)
        /// Hairline emerald — barely-there structural lines on chrome.
        static let emeraldLine  = Color(red: 0.00, green: 0.78, blue: 0.42).opacity(0.40)

        /// GMRI SILVER. Chrome, structural rules, secondary text. Cool neutral
        /// gray with a hint of warmth so it doesn't read as "iOS gray."
        static let silver       = Color(red: 0.80, green: 0.82, blue: 0.84)
        static let silverDim    = Color(red: 0.58, green: 0.60, blue: 0.62)
        static let silverLine   = Color(red: 0.80, green: 0.82, blue: 0.84).opacity(0.30)

        /// GMRI CRIMSON. Refusal, danger, critical alerts. Deep arterial — not
        /// neon "error red." This is the color of a refusal that means it.
        static let crimson      = Color(red: 0.79, green: 0.09, blue: 0.18)
        static let crimsonHalo  = Color(red: 0.95, green: 0.22, blue: 0.30)
        static let crimsonDim   = Color(red: 0.45, green: 0.05, blue: 0.10)

        /// GMRI BLACK. The void. Background base.
        static let void         = Color(red: 0.02, green: 0.023, blue: 0.025)
        static let voidDeep     = Color(red: 0.005, green: 0.008, blue: 0.010)
        /// Surface tones — lifted off the void just enough to read as a panel.
        static let surface      = Color(red: 0.06, green: 0.065, blue: 0.072)
        static let surfaceLift  = Color(red: 0.09, green: 0.095, blue: 0.105)

        /// Status palette aliases.
        static let refusal      = crimson
        static let pass         = emerald
        static let pending      = silverDim
        static let live         = crimson    // recording-in-progress (alert state)
        /// Warning resolves to crimson instead of amber/orange because the GMRI palette is restricted to black/silver/crimson/emerald.
        static let warning      = crimson
        /// Informational state uses GMRI silver; no cyan/Stark-blue in ceremony chrome.
        static let info         = Color(red: 0.80, green: 0.82, blue: 0.84)
    }

    enum font {
        /// Institutional mark — GMRI chrome header. Monospace heavy reads as
        /// instrument-panel chrome, not academic letterhead.
        static let institute    = Font.system(.callout, design: .monospaced).weight(.heavy)
        static let chrome       = Font.system(.caption, design: .monospaced).weight(.semibold)
        /// Ceremony hero title.
        static let ceremonyTitle = Font.system(size: 38, weight: .bold, design: .rounded)
        /// Section / panel titles.
        static let sectionTitle = Font.system(.title3, design: .rounded).weight(.bold)
        /// Body readout.
        static let readout      = Font.system(.body, design: .rounded)
        /// Hashes, IDs, paths — monospace for byte-by-byte falsifiability
        /// (operator can compare paper backup digit-for-digit).
        static let mono         = Font.system(.callout, design: .monospaced)
        static let monoLarge    = Font.system(.title3, design: .monospaced).weight(.semibold)
        /// Form field label.
        static let fieldLabel   = Font.system(.caption, design: .monospaced).weight(.semibold)
        /// Primary CTA.
        static let cta          = Font.system(size: 22, weight: .bold, design: .rounded)
        /// Voice-anchor sub-hero.
        static let voiceTitle   = Font.system(size: 28, weight: .bold, design: .rounded)
    }

    enum spacing {
        static let xs: CGFloat = 6
        static let s:  CGFloat = 10
        static let m:  CGFloat = 16
        static let l:  CGFloat = 22
        static let xl: CGFloat = 32
        static let panel: CGFloat = 22
        static let page: CGFloat = 28
    }

    enum radius {
        static let panel: CGFloat = 16
        static let control: CGFloat = 10
        static let pill: CGFloat = 999
    }
}

// MARK: - Reusable styled primitives

/// Standard panel — lifted surface on the void, hairline emerald border with a
/// soft emerald glow, optional section title with a chrome marker rail.
struct GMRIPanel<Content: View>: View {
    let title: String?
    @ViewBuilder var content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: GMRI.spacing.m) {
            if let title {
                HStack(spacing: GMRI.spacing.s) {
                    Rectangle()
                        .fill(GMRI.color.emerald)
                        .frame(width: 3, height: 16)
                        .shadow(color: GMRI.color.emeraldHalo, radius: 4)
                    Text(title.uppercased())
                        .font(GMRI.font.chrome)
                        .tracking(2.2)
                        .foregroundStyle(GMRI.color.emerald)
                }
            }
            content
        }
        .padding(GMRI.spacing.panel)
        .background(
            RoundedRectangle(cornerRadius: GMRI.radius.panel, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [GMRI.color.surfaceLift, GMRI.color.surface],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: GMRI.radius.panel, style: .continuous)
                .stroke(GMRI.color.emeraldLine, lineWidth: 1)
        )
        .shadow(color: GMRI.color.emerald.opacity(0.10), radius: 16, x: 0, y: 0)
    }
}

/// GMRI institutional chrome header — single-use at the top of the window.
/// Sci-fi instrument bezel: GMRI mark, ceremony identifier, operator credential.
struct GMRIHeaderStrip: View {
    var body: some View {
        HStack(spacing: GMRI.spacing.l) {
            ZStack {
                Circle()
                    .stroke(GMRI.color.emerald, lineWidth: 1)
                    .frame(width: 34, height: 34)
                    .shadow(color: GMRI.color.emeraldHalo.opacity(0.7), radius: 6)
                Image(systemName: "staroflife.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(GMRI.color.emerald)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("GMRI :: GRIZZLYMEDICINE RESEARCH INSTITUTE")
                    .font(GMRI.font.institute)
                    .tracking(2.4)
                    .foregroundStyle(GMRI.color.emerald)
                Text("J.A.R.V.I.S. SOUL ANCHOR // FIRST-LAUNCH PROTOCOL v1.0")
                    .font(GMRI.font.chrome)
                    .tracking(1.8)
                    .foregroundStyle(GMRI.color.silverDim)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("OPERATOR // EMT-P (RET.)")
                    .font(GMRI.font.chrome)
                    .tracking(1.8)
                    .foregroundStyle(GMRI.color.silverDim)
                Text("ROBERT \"GRIZZLY\" HANSON")
                    .font(GMRI.font.institute)
                    .tracking(2.0)
                    .foregroundStyle(GMRI.color.emerald)
            }
        }
        .padding(.horizontal, GMRI.spacing.l)
        .padding(.vertical, GMRI.spacing.m)
        .background(
            ZStack {
                Rectangle().fill(GMRI.color.voidDeep)
                LinearGradient(
                    colors: [Color.clear, GMRI.color.emerald.opacity(0.07)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        )
        .overlay(alignment: .bottom) {
            // Silver hairline + emerald glow rail.
            VStack(spacing: 1) {
                Rectangle().fill(GMRI.color.silverLine).frame(height: 1)
                Rectangle()
                    .fill(GMRI.color.emerald)
                    .frame(height: 1)
                    .shadow(color: GMRI.color.emeraldHalo, radius: 4, y: 1)
            }
        }
    }
}

/// Page background — true GMRI black with a faint emerald vignette at top
/// center suggesting an off-screen holographic light source.
struct GMRIVoidBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [GMRI.color.void, GMRI.color.voidDeep],
                startPoint: .top,
                endPoint: .bottom
            )
            RadialGradient(
                colors: [GMRI.color.emerald.opacity(0.05), Color.clear],
                center: .init(x: 0.5, y: -0.1),
                startRadius: 80,
                endRadius: 700
            )
        }
        .ignoresSafeArea()
    }
}

/// Primary CTA — emerald fill with a soft halo. No gamer-neon shadow stack.
struct GMRIPrimaryButtonStyle: ButtonStyle {
    var enabled: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(GMRI.font.cta)
            .tracking(0.5)
            .foregroundStyle(enabled ? GMRI.color.voidDeep : GMRI.color.silverDim)
            .padding(.horizontal, GMRI.spacing.xl)
            .padding(.vertical, GMRI.spacing.l)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: GMRI.radius.control, style: .continuous)
                    .fill(
                        enabled
                        ? LinearGradient(
                            colors: configuration.isPressed
                                ? [GMRI.color.emeraldDim, GMRI.color.emeraldDim]
                                : [GMRI.color.emeraldHalo, GMRI.color.emerald],
                            startPoint: .top,
                            endPoint: .bottom)
                        : LinearGradient(
                            colors: [GMRI.color.surfaceLift, GMRI.color.surface],
                            startPoint: .top,
                            endPoint: .bottom)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: GMRI.radius.control, style: .continuous)
                    .stroke(enabled ? GMRI.color.emeraldHalo : GMRI.color.silverLine, lineWidth: 1)
            )
            .shadow(color: enabled ? GMRI.color.emerald.opacity(0.45) : Color.clear,
                    radius: configuration.isPressed ? 6 : 16,
                    x: 0, y: 0)
    }
}

/// Secondary chrome button — outlined emerald on the void, no fill.
struct GMRISecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(GMRI.font.readout.weight(.semibold))
            .foregroundStyle(GMRI.color.emerald)
            .padding(.horizontal, GMRI.spacing.l)
            .padding(.vertical, GMRI.spacing.s)
            .background(
                RoundedRectangle(cornerRadius: GMRI.radius.control, style: .continuous)
                    .fill(configuration.isPressed ? GMRI.color.emerald.opacity(0.15) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: GMRI.radius.control, style: .continuous)
                    .stroke(GMRI.color.emerald, lineWidth: 1)
            )
    }
}

/// Crimson danger button — for destructive / refusal-acknowledging actions.
struct GMRICrimsonButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(GMRI.font.readout.weight(.semibold))
            .foregroundStyle(GMRI.color.silver)
            .padding(.horizontal, GMRI.spacing.l)
            .padding(.vertical, GMRI.spacing.s)
            .background(
                RoundedRectangle(cornerRadius: GMRI.radius.control, style: .continuous)
                    .fill(configuration.isPressed ? GMRI.color.crimsonDim : GMRI.color.crimson)
            )
            .overlay(
                RoundedRectangle(cornerRadius: GMRI.radius.control, style: .continuous)
                    .stroke(GMRI.color.crimsonHalo, lineWidth: 1)
            )
            .shadow(color: GMRI.color.crimson.opacity(0.4), radius: 10)
    }
}

/// Status pill — small chrome capsule with a glowing dot. Use `live: true` for
/// active recording (crimson dot); `live: false` for green pass state.
struct GMRIStatusPill: View {
    let label: String
    let live: Bool
    var body: some View {
        HStack(spacing: GMRI.spacing.xs) {
            Circle()
                .fill(live ? GMRI.color.crimson : GMRI.color.emerald)
                .frame(width: 8, height: 8)
                .shadow(color: (live ? GMRI.color.crimsonHalo : GMRI.color.emeraldHalo).opacity(0.9), radius: 6)
            Text(label.uppercased())
                .font(GMRI.font.chrome)
                .tracking(1.8)
                .foregroundStyle(GMRI.color.silver)
        }
        .padding(.horizontal, GMRI.spacing.s)
        .padding(.vertical, GMRI.spacing.xs)
        .background(Capsule().fill(GMRI.color.voidDeep))
        .overlay(Capsule().stroke(GMRI.color.silverLine, lineWidth: 1))
    }
}
