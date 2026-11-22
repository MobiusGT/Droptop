import AppKit
import SwiftUI

enum AutoHideTabStyle: String, CaseIterable, Identifiable, Sendable {
    case fileIcons
    case shelfNumber
    case minimalColor

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fileIcons: return "File Icons"
        case .shelfNumber: return "Shelf Number"
        case .minimalColor: return "Color Only"
        }
    }

    var systemImage: String {
        switch self {
        case .fileIcons: return "square.grid.2x2.fill"
        case .shelfNumber: return "number.square.fill"
        case .minimalColor: return "rectangle.portrait.fill"
        }
    }

    var collapsedWidth: CGFloat {
        switch self {
        case .minimalColor: return 26
        case .shelfNumber: return 54
        case .fileIcons: return 54
        }
    }
}

enum ColorVariationLevel: String, CaseIterable, Identifiable, Sendable {
    case off
    case low
    case medium
    case high

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off: return "Off"
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        }
    }

    var multiplier: CGFloat {
        switch self {
        case .off: return 0.0
        case .low: return 1.0
        case .medium: return 2.0
        case .high: return 3.0
        }
    }
}

/// Subtle, harmonious HSB variation assigned to additional shelves (Shelf 2, Shelf 3, …)
/// scaled by `ColorVariationLevel` (Off = 0x, Low = 1x, Medium = 2x, High = 3x).
nonisolated struct ShelfColorVariation: Equatable, Hashable, Sendable {
    let slotIndex: Int
    let hueDelta: CGFloat
    let saturationDelta: CGFloat
    let brightnessDelta: CGFloat

    static let identity = ShelfColorVariation(
        slotIndex: 0,
        hueDelta: 0,
        saturationDelta: 0,
        brightnessDelta: 0
    )

    static let paletteVariants: [ShelfColorVariation] = [
        ShelfColorVariation(slotIndex: 1, hueDelta: -0.024, saturationDelta: -0.03, brightnessDelta: +0.085),
        ShelfColorVariation(slotIndex: 2, hueDelta: +0.024, saturationDelta: +0.07, brightnessDelta: -0.065),
        ShelfColorVariation(slotIndex: 3, hueDelta: +0.036, saturationDelta: +0.04, brightnessDelta: +0.060),
        ShelfColorVariation(slotIndex: 4, hueDelta: -0.036, saturationDelta: +0.06, brightnessDelta: -0.055),
        ShelfColorVariation(slotIndex: 5, hueDelta: +0.015, saturationDelta: +0.09, brightnessDelta: +0.100),
        ShelfColorVariation(slotIndex: 6, hueDelta: -0.016, saturationDelta: -0.04, brightnessDelta: -0.080),
        ShelfColorVariation(slotIndex: 7, hueDelta: +0.044, saturationDelta: -0.02, brightnessDelta: +0.040),
        ShelfColorVariation(slotIndex: 8, hueDelta: -0.044, saturationDelta: +0.05, brightnessDelta: +0.045)
    ]

    static func randomVariant(excluding usedSlots: Set<Int>) -> ShelfColorVariation {
        let unused = paletteVariants.filter { !usedSlots.contains($0.slotIndex) }
        if let picked = unused.randomElement() {
            return picked
        }
        return paletteVariants.randomElement() ?? paletteVariants[0]
    }
}

struct ResolvedShelfPalette {
    let isSystemGlass: Bool
    let isLightTheme: Bool
    let preferredColorScheme: ColorScheme?
    let nsAppearance: NSAppearance?
    let backgroundTint: Color
    let primaryTextColor: Color
    let secondaryTextColor: Color
    let tertiaryTextColor: Color
    let accentColor: Color
    let accentForegroundColor: Color
    let nsAccentColor: NSColor
    let borderColor: Color
    let controlFill: Color
    let dividerColor: Color
    let rowFill: Color
    let rowHoverFill: Color
}

private struct ThemeSpec: Sendable {
    let displayName: String
    let isLight: Bool
    let isNeutral: Bool
    let bgR: CGFloat
    let bgG: CGFloat
    let bgB: CGFloat
    let bgAlpha: CGFloat
    let accR: CGFloat
    let accG: CGFloat
    let accB: CGFloat
    let darkAccentForeground: Bool

    init(
        _ displayName: String,
        isLight: Bool,
        isNeutral: Bool = false,
        bg: (CGFloat, CGFloat, CGFloat),
        alpha: CGFloat? = nil,
        acc: (CGFloat, CGFloat, CGFloat),
        darkAccText: Bool = false
    ) {
        self.displayName = displayName
        self.isLight = isLight
        self.isNeutral = isNeutral
        self.bgR = bg.0
        self.bgG = bg.1
        self.bgB = bg.2
        self.bgAlpha = alpha ?? (isLight ? 0.92 : 0.88)
        self.accR = acc.0
        self.accG = acc.1
        self.accB = acc.2
        self.darkAccentForeground = darkAccText
    }

    /// Computes a continuous rainbow sort key so reds group with reds, oranges with oranges,
    /// yellows, greens, teals, blues, indigos, purples, pinks, and neutrals at the end.
    var colorSortKey: (Int, CGFloat, CGFloat) {
        if isNeutral {
            let luma = 0.299 * bgR + 0.587 * bgG + 0.114 * bgB
            return (1, luma, accB)
        }
        // Derive hue primarily from the theme's signature accent color (blended slightly with tint)
        let color = NSColor(srgbRed: accR, green: accG, blue: accB, alpha: 1.0)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
        color.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        // Wrap deep crimson reds (hue >= 0.94, ~338°..360°) to sit right next to 0° reds!
        let wrappedHue = h >= 0.94 ? (h - 1.0) : h
        return (0, wrappedHue, b)
    }
}

/// 100 curated macOS shelf themes (1 Adaptive + 50 Dark + 49 Light),
/// separated cleanly into Dark & Light modes and sorted smoothly across the color spectrum.
enum ShelfTheme: String, CaseIterable, Identifiable, Sendable {
    // Adaptive (1)
    case systemGlass

    // Dark themes (50)
    case midnight, graphite, obsidianGold, ocean, forest, sunsetEmber, lavenderDusk, nordicFrost
    case cyberNeon, crimsonVelvet, coffeeEspresso, deepIndigo, emeraldNight, amethyst, volcanicAsh
    case cobaltSteel, matchaDark, rosewood, copperPatina, terminalGreen, noirMonochrome
    case garnetDark, scarletNight, cherryCola, rustIron, burntSienna, amberGlow, cinnamonDark
    case marigoldNight, honeyGold, citrineDark, chartreuseNight, pineShadow, jadeVelvet
    case oliveBunker, mintMidnight, abyssTeal, lagoonDark, arcticCyan, sapphireDark, denimNight
    case marineDepth, starlightBlue, royalPlum, mulberryDark, cosmicViolet, fuchsiaNight
    case hibiscusDark, velvetBerry, slateSteel

    // Light themes (50)
    case frostedLight, warmPaper, sageMist, blushQuartz, sakuraMilk, skyGlass, mintCream, solarSand
    case alabaster, peachSorbet, lavenderCream, buttercream, icePeriwinkle, pistachio, seafoam
    case sandstone, cloudGray, apricotLinen
    case coralBlush, strawberryCream, terracottaMist, rosePetal, tangerineIce, cantaloupe
    case amberSilk, marigoldCream, lemonFizz, vanillaBean, honeydewGold, chartreuseMist
    case matchaLatte, cloverLight, eucalyptus, meadowLight, glacierMint, lagoonMist, aquaGlass
    case turquoiseSilk, cornflower, powderBlue, ceruleanMist, denimWash, wisteria, irisLight
    case lilacCloud, orchidMilk, peonyLight, cottonCandy, raspberrySorbet, linenSilver

    var id: String { rawValue }

    /// All 50 dark themes sorted smoothly by color spectrum (Red → Orange → Yellow → Green → Teal → Blue → Purple → Pink → Neutral).
    static let darkThemes: [ShelfTheme] = {
        allCases
            .filter { $0 != .systemGlass && !$0.isLightTheme }
            .sorted { lhs, rhs in
                guard let ls = lhs.spec, let rs = rhs.spec else { return false }
                let lk = ls.colorSortKey
                let rk = rs.colorSortKey
                if lk.0 != rk.0 { return lk.0 < rk.0 }
                if abs(lk.1 - rk.1) > 0.002 { return lk.1 < rk.1 }
                return lk.2 < rk.2
            }
    }()

    /// All 50 light themes sorted smoothly by color spectrum (Red → Orange → Yellow → Green → Teal → Blue → Purple → Pink → Neutral).
    static let lightThemes: [ShelfTheme] = {
        allCases
            .filter { $0.isLightTheme }
            .sorted { lhs, rhs in
                guard let ls = lhs.spec, let rs = rhs.spec else { return false }
                let lk = ls.colorSortKey
                let rk = rs.colorSortKey
                if lk.0 != rk.0 { return lk.0 < rk.0 }
                if abs(lk.1 - rk.1) > 0.002 { return lk.1 < rk.1 }
                return lk.2 < rk.2
            }
    }()

    private var spec: ThemeSpec? {
        switch self {
        case .systemGlass:
            return nil

        // MARK: Dark Themes (50)
        // Reds & Crimsons
        case .crimsonVelvet:
            return ThemeSpec("Crimson Velvet", isLight: false, bg: (0.20, 0.06, 0.09), acc: (0.94, 0.24, 0.36))
        case .garnetDark:
            return ThemeSpec("Garnet", isLight: false, bg: (0.19, 0.05, 0.07), acc: (0.88, 0.20, 0.28))
        case .scarletNight:
            return ThemeSpec("Scarlet Night", isLight: false, bg: (0.17, 0.06, 0.06), acc: (0.97, 0.26, 0.24))
        case .cherryCola:
            return ThemeSpec("Cherry Cola", isLight: false, bg: (0.16, 0.05, 0.08), acc: (0.92, 0.22, 0.32))
        case .rustIron:
            return ThemeSpec("Rust Iron", isLight: false, bg: (0.17, 0.08, 0.06), acc: (0.90, 0.34, 0.22))
        case .sunsetEmber:
            return ThemeSpec("Sunset Ember", isLight: false, bg: (0.18, 0.08, 0.11), acc: (0.96, 0.42, 0.28))

        // Oranges & Ambers
        case .burntSienna:
            return ThemeSpec("Burnt Sienna", isLight: false, bg: (0.17, 0.09, 0.06), acc: (0.94, 0.46, 0.22))
        case .volcanicAsh:
            return ThemeSpec("Volcanic Ash", isLight: false, bg: (0.14, 0.11, 0.10), acc: (0.96, 0.54, 0.22), darkAccText: true)
        case .cinnamonDark:
            return ThemeSpec("Cinnamon", isLight: false, bg: (0.17, 0.10, 0.07), acc: (0.90, 0.55, 0.28), darkAccText: true)
        case .coffeeEspresso:
            return ThemeSpec("Espresso", isLight: false, bg: (0.16, 0.11, 0.08), acc: (0.88, 0.62, 0.32), darkAccText: true)
        case .amberGlow:
            return ThemeSpec("Amber Glow", isLight: false, bg: (0.16, 0.12, 0.06), acc: (0.96, 0.68, 0.20), darkAccText: true)
        case .marigoldNight:
            return ThemeSpec("Marigold Night", isLight: false, bg: (0.16, 0.12, 0.05), acc: (0.98, 0.74, 0.22), darkAccText: true)

        // Yellows & Golds
        case .obsidianGold:
            return ThemeSpec("Obsidian Gold", isLight: false, bg: (0.08, 0.07, 0.06), alpha: 0.90, acc: (0.92, 0.74, 0.30), darkAccText: true)
        case .honeyGold:
            return ThemeSpec("Honey Gold", isLight: false, bg: (0.15, 0.13, 0.06), acc: (0.95, 0.80, 0.26), darkAccText: true)
        case .citrineDark:
            return ThemeSpec("Citrine", isLight: false, bg: (0.13, 0.14, 0.06), acc: (0.86, 0.84, 0.26), darkAccText: true)
        case .chartreuseNight:
            return ThemeSpec("Chartreuse", isLight: false, bg: (0.11, 0.15, 0.06), acc: (0.74, 0.88, 0.26), darkAccText: true)

        // Greens
        case .matchaDark:
            return ThemeSpec("Matcha Dark", isLight: false, bg: (0.11, 0.15, 0.09), acc: (0.60, 0.82, 0.34), darkAccText: true)
        case .oliveBunker:
            return ThemeSpec("Olive Dusk", isLight: false, bg: (0.12, 0.14, 0.09), acc: (0.54, 0.78, 0.38), darkAccText: true)
        case .terminalGreen:
            return ThemeSpec("Terminal", isLight: false, bg: (0.05, 0.09, 0.06), alpha: 0.91, acc: (0.22, 0.88, 0.38), darkAccText: true)
        case .pineShadow:
            return ThemeSpec("Pine Shadow", isLight: false, bg: (0.06, 0.14, 0.09), acc: (0.24, 0.78, 0.44), darkAccText: true)
        case .forest:
            return ThemeSpec("Forest", isLight: false, bg: (0.06, 0.15, 0.11), acc: (0.22, 0.80, 0.50), darkAccText: true)
        case .jadeVelvet:
            return ThemeSpec("Jade Velvet", isLight: false, bg: (0.05, 0.16, 0.12), acc: (0.20, 0.84, 0.58), darkAccText: true)
        case .emeraldNight:
            return ThemeSpec("Emerald Night", isLight: false, bg: (0.04, 0.16, 0.13), acc: (0.16, 0.84, 0.64), darkAccText: true)
        case .mintMidnight:
            return ThemeSpec("Mint Night", isLight: false, bg: (0.06, 0.16, 0.14), acc: (0.28, 0.88, 0.70), darkAccText: true)

        // Teals & Cyans
        case .copperPatina:
            return ThemeSpec("Copper Patina", isLight: false, bg: (0.09, 0.16, 0.16), acc: (0.30, 0.82, 0.74), darkAccText: true)
        case .abyssTeal:
            return ThemeSpec("Abyss Teal", isLight: false, bg: (0.04, 0.15, 0.18), acc: (0.16, 0.82, 0.78), darkAccText: true)
        case .ocean:
            return ThemeSpec("Ocean", isLight: false, bg: (0.04, 0.14, 0.22), acc: (0.16, 0.78, 0.82), darkAccText: true)
        case .lagoonDark:
            return ThemeSpec("Lagoon", isLight: false, bg: (0.05, 0.16, 0.23), acc: (0.20, 0.82, 0.90), darkAccText: true)
        case .arcticCyan:
            return ThemeSpec("Arctic Cyan", isLight: false, bg: (0.06, 0.15, 0.24), acc: (0.28, 0.80, 0.96), darkAccText: true)
        case .nordicFrost:
            return ThemeSpec("Nordic Frost", isLight: false, bg: (0.11, 0.16, 0.23), acc: (0.36, 0.76, 0.94), darkAccText: true)

        // Blues & Indigos
        case .cobaltSteel:
            return ThemeSpec("Cobalt Steel", isLight: false, bg: (0.07, 0.13, 0.24), acc: (0.30, 0.68, 0.98), darkAccText: true)
        case .marineDepth:
            return ThemeSpec("Marine Depth", isLight: false, bg: (0.05, 0.10, 0.22), acc: (0.28, 0.60, 0.98))
        case .denimNight:
            return ThemeSpec("Denim Night", isLight: false, bg: (0.09, 0.13, 0.22), acc: (0.40, 0.64, 0.96))
        case .sapphireDark:
            return ThemeSpec("Sapphire", isLight: false, bg: (0.06, 0.10, 0.24), acc: (0.32, 0.56, 1.00))
        case .midnight:
            return ThemeSpec("Midnight", isLight: false, bg: (0.06, 0.08, 0.16), acc: (0.38, 0.54, 1.00))
        case .starlightBlue:
            return ThemeSpec("Starlight", isLight: false, bg: (0.08, 0.10, 0.22), acc: (0.46, 0.58, 1.00))
        case .deepIndigo:
            return ThemeSpec("Deep Indigo", isLight: false, bg: (0.08, 0.08, 0.24), acc: (0.52, 0.52, 1.00))

        // Purples & Violets
        case .lavenderDusk:
            return ThemeSpec("Lavender Dusk", isLight: false, bg: (0.13, 0.10, 0.23), acc: (0.64, 0.50, 0.98))
        case .cosmicViolet:
            return ThemeSpec("Cosmic Violet", isLight: false, bg: (0.14, 0.08, 0.25), acc: (0.72, 0.44, 1.00))
        case .amethyst:
            return ThemeSpec("Amethyst", isLight: false, bg: (0.18, 0.08, 0.24), acc: (0.80, 0.44, 0.96))
        case .royalPlum:
            return ThemeSpec("Royal Plum", isLight: false, bg: (0.19, 0.07, 0.22), acc: (0.86, 0.40, 0.92))
        case .mulberryDark:
            return ThemeSpec("Mulberry", isLight: false, bg: (0.20, 0.07, 0.20), acc: (0.90, 0.38, 0.84))

        // Pinks & Magentas
        case .cyberNeon:
            return ThemeSpec("Cyber Neon", isLight: false, bg: (0.10, 0.06, 0.19), alpha: 0.90, acc: (0.98, 0.32, 0.82))
        case .fuchsiaNight:
            return ThemeSpec("Fuchsia Night", isLight: false, bg: (0.18, 0.06, 0.17), acc: (0.96, 0.30, 0.72))
        case .velvetBerry:
            return ThemeSpec("Velvet Berry", isLight: false, bg: (0.20, 0.06, 0.14), acc: (0.94, 0.32, 0.60))
        case .hibiscusDark:
            return ThemeSpec("Hibiscus", isLight: false, bg: (0.21, 0.07, 0.13), acc: (0.96, 0.38, 0.54))
        case .rosewood:
            return ThemeSpec("Rosewood", isLight: false, bg: (0.20, 0.10, 0.13), acc: (0.92, 0.52, 0.60), darkAccText: true)

        // Dark Neutrals
        case .noirMonochrome:
            return ThemeSpec("Noir", isLight: false, isNeutral: true, bg: (0.06, 0.06, 0.07), alpha: 0.91, acc: (0.86, 0.88, 0.92), darkAccText: true)
        case .graphite:
            return ThemeSpec("Graphite", isLight: false, isNeutral: true, bg: (0.12, 0.13, 0.15), acc: (0.54, 0.66, 0.88))
        case .slateSteel:
            return ThemeSpec("Slate Steel", isLight: false, isNeutral: true, bg: (0.15, 0.16, 0.19), acc: (0.64, 0.74, 0.86), darkAccText: true)

        // MARK: Light Themes (49)
        // Reds & Corals
        case .rosePetal:
            return ThemeSpec("Rose Petal", isLight: true, bg: (0.99, 0.92, 0.93), acc: (0.82, 0.18, 0.30))
        case .strawberryCream:
            return ThemeSpec("Strawberry", isLight: true, bg: (0.99, 0.92, 0.92), acc: (0.86, 0.22, 0.26))
        case .coralBlush:
            return ThemeSpec("Coral Blush", isLight: true, bg: (0.99, 0.93, 0.91), acc: (0.88, 0.30, 0.24))
        case .apricotLinen:
            return ThemeSpec("Apricot Linen", isLight: true, bg: (0.98, 0.94, 0.91), acc: (0.80, 0.30, 0.20))
        case .terracottaMist:
            return ThemeSpec("Terracotta", isLight: true, bg: (0.98, 0.93, 0.89), acc: (0.78, 0.32, 0.18))

        // Oranges & Peaches
        case .peachSorbet:
            return ThemeSpec("Peach Sorbet", isLight: true, bg: (0.99, 0.93, 0.89), acc: (0.86, 0.36, 0.18))
        case .warmPaper:
            return ThemeSpec("Warm Paper", isLight: true, bg: (0.98, 0.95, 0.89), acc: (0.80, 0.38, 0.14))
        case .sandstone:
            return ThemeSpec("Sandstone", isLight: true, bg: (0.95, 0.92, 0.87), acc: (0.72, 0.38, 0.16))
        case .tangerineIce:
            return ThemeSpec("Tangerine Ice", isLight: true, bg: (0.99, 0.94, 0.87), acc: (0.88, 0.44, 0.10))
        case .cantaloupe:
            return ThemeSpec("Cantaloupe", isLight: true, bg: (0.99, 0.95, 0.88), acc: (0.84, 0.46, 0.12))
        case .amberSilk:
            return ThemeSpec("Amber Silk", isLight: true, bg: (0.99, 0.96, 0.88), acc: (0.80, 0.48, 0.08))

        // Yellows & Creams
        case .marigoldCream:
            return ThemeSpec("Marigold", isLight: true, bg: (0.99, 0.96, 0.86), acc: (0.78, 0.50, 0.06))
        case .buttercream:
            return ThemeSpec("Buttercream", isLight: true, bg: (0.99, 0.97, 0.88), acc: (0.74, 0.52, 0.06))
        case .vanillaBean:
            return ThemeSpec("Vanilla Bean", isLight: true, bg: (0.98, 0.96, 0.90), acc: (0.68, 0.50, 0.12))
        case .honeydewGold:
            return ThemeSpec("Honey Cream", isLight: true, bg: (0.99, 0.97, 0.87), acc: (0.72, 0.56, 0.06))
        case .lemonFizz:
            return ThemeSpec("Lemon Fizz", isLight: true, bg: (0.98, 0.98, 0.86), acc: (0.64, 0.58, 0.06))
        case .chartreuseMist:
            return ThemeSpec("Lime Mist", isLight: true, bg: (0.95, 0.98, 0.88), acc: (0.42, 0.58, 0.10))

        // Greens
        case .pistachio:
            return ThemeSpec("Pistachio", isLight: true, bg: (0.93, 0.97, 0.90), acc: (0.28, 0.56, 0.18))
        case .matchaLatte:
            return ThemeSpec("Matcha Latte", isLight: true, bg: (0.92, 0.96, 0.89), acc: (0.26, 0.54, 0.22))
        case .meadowLight:
            return ThemeSpec("Meadow", isLight: true, bg: (0.91, 0.97, 0.90), acc: (0.18, 0.56, 0.26))
        case .cloverLight:
            return ThemeSpec("Clover", isLight: true, bg: (0.90, 0.97, 0.91), acc: (0.14, 0.58, 0.30))
        case .sageMist:
            return ThemeSpec("Sage Mist", isLight: true, bg: (0.91, 0.95, 0.92), acc: (0.16, 0.54, 0.34))
        case .eucalyptus:
            return ThemeSpec("Eucalyptus", isLight: true, bg: (0.90, 0.96, 0.93), acc: (0.12, 0.52, 0.38))

        // Teals & Aquas
        case .mintCream:
            return ThemeSpec("Mint Cream", isLight: true, bg: (0.90, 0.98, 0.95), acc: (0.06, 0.52, 0.42))
        case .glacierMint:
            return ThemeSpec("Glacier Mint", isLight: true, bg: (0.89, 0.98, 0.96), acc: (0.04, 0.52, 0.48))
        case .turquoiseSilk:
            return ThemeSpec("Turquoise", isLight: true, bg: (0.89, 0.97, 0.97), acc: (0.04, 0.50, 0.52))
        case .seafoam:
            return ThemeSpec("Seafoam", isLight: true, bg: (0.89, 0.97, 0.97), acc: (0.04, 0.48, 0.56))
        case .lagoonMist:
            return ThemeSpec("Lagoon Mist", isLight: true, bg: (0.89, 0.96, 0.98), acc: (0.04, 0.48, 0.62))
        case .aquaGlass:
            return ThemeSpec("Aqua Glass", isLight: true, bg: (0.90, 0.97, 1.00), acc: (0.04, 0.46, 0.68))

        // Blues & Indigos
        case .solarSand:
            return ThemeSpec("Solar Sand", isLight: true, bg: (0.99, 0.96, 0.89), acc: (0.80, 0.46, 0.10))
        case .ceruleanMist:
            return ThemeSpec("Cerulean", isLight: true, bg: (0.90, 0.96, 1.00), acc: (0.06, 0.44, 0.80))
        case .skyGlass:
            return ThemeSpec("Sky Glass", isLight: true, bg: (0.91, 0.96, 1.00), acc: (0.06, 0.40, 0.84))
        case .powderBlue:
            return ThemeSpec("Powder Blue", isLight: true, bg: (0.91, 0.95, 0.99), acc: (0.10, 0.38, 0.82))
        case .denimWash:
            return ThemeSpec("Denim Light", isLight: true, bg: (0.91, 0.94, 0.98), acc: (0.18, 0.38, 0.72))
        case .frostedLight:
            return ThemeSpec("Frosted Light", isLight: true, isNeutral: true, bg: (0.96, 0.97, 0.99), alpha: 0.90, acc: (0.08, 0.40, 0.94))
        case .cornflower:
            return ThemeSpec("Cornflower", isLight: true, bg: (0.92, 0.94, 1.00), acc: (0.20, 0.38, 0.90))
        case .icePeriwinkle:
            return ThemeSpec("Ice Periwinkle", isLight: true, bg: (0.92, 0.94, 0.99), acc: (0.26, 0.34, 0.88))

        // Purples & Violets
        case .irisLight:
            return ThemeSpec("Iris Mist", isLight: true, bg: (0.93, 0.92, 0.99), acc: (0.36, 0.28, 0.86))
        case .lavenderCream:
            return ThemeSpec("Lavender Cream", isLight: true, bg: (0.95, 0.92, 0.99), acc: (0.46, 0.26, 0.84))
        case .wisteria:
            return ThemeSpec("Wisteria", isLight: true, bg: (0.95, 0.91, 0.99), acc: (0.54, 0.24, 0.82))
        case .lilacCloud:
            return ThemeSpec("Lilac Cloud", isLight: true, bg: (0.96, 0.92, 0.98), acc: (0.62, 0.24, 0.78))
        case .orchidMilk:
            return ThemeSpec("Orchid Milk", isLight: true, bg: (0.98, 0.92, 0.98), acc: (0.72, 0.24, 0.74))

        // Pinks & Magentas
        case .peonyLight:
            return ThemeSpec("Peony", isLight: true, bg: (0.99, 0.92, 0.96), acc: (0.80, 0.20, 0.58))
        case .cottonCandy:
            return ThemeSpec("Cotton Candy", isLight: true, bg: (0.99, 0.92, 0.95), acc: (0.84, 0.24, 0.54))
        case .raspberrySorbet:
            return ThemeSpec("Raspberry Sorbet", isLight: true, bg: (0.99, 0.91, 0.95), acc: (0.84, 0.18, 0.48))
        case .blushQuartz:
            return ThemeSpec("Blush Quartz", isLight: true, bg: (0.98, 0.92, 0.94), acc: (0.78, 0.22, 0.46))
        case .sakuraMilk:
            return ThemeSpec("Sakura Milk", isLight: true, bg: (0.99, 0.93, 0.95), acc: (0.82, 0.24, 0.42))

        // Light Neutrals
        case .alabaster:
            return ThemeSpec("Alabaster", isLight: true, isNeutral: true, bg: (0.97, 0.97, 0.96), alpha: 0.93, acc: (0.28, 0.34, 0.62))
        case .linenSilver:
            return ThemeSpec("Linen Silver", isLight: true, isNeutral: true, bg: (0.95, 0.95, 0.94), acc: (0.32, 0.36, 0.44))
        case .cloudGray:
            return ThemeSpec("Cloud Gray", isLight: true, isNeutral: true, bg: (0.92, 0.93, 0.95), acc: (0.24, 0.36, 0.54))
        }
    }

    var displayName: String {
        spec?.displayName ?? "System Glass"
    }

    var isLightTheme: Bool {
        spec?.isLight ?? false
    }

    var preferredColorScheme: ColorScheme? {
        guard let spec else { return nil }
        return spec.isLight ? .light : .dark
    }

    var nsAppearance: NSAppearance? {
        guard let spec else { return nil }
        return spec.isLight ? NSAppearance(named: .aqua) : NSAppearance(named: .darkAqua)
    }

    var nsAccentColor: NSColor {
        guard let spec else { return .controlAccentColor }
        return NSColor(red: spec.accR, green: spec.accG, blue: spec.accB, alpha: 1.0)
    }

    var accentColor: Color {
        guard let spec else { return .accentColor }
        return Color(red: spec.accR, green: spec.accG, blue: spec.accB)
    }

    var swatchBackground: Color {
        guard let spec else { return Color.gray.opacity(0.35) }
        return Color(red: spec.bgR, green: spec.bgG, blue: spec.bgB)
    }

    var borderColor: Color {
        palette(variation: .identity, level: .off).borderColor
    }

    /// Resolves the final shelf palette scaled by `ColorVariationLevel` (Off = 0x, Low = 1x, Medium = 2x, High = 3x).
    func palette(
        variation: ShelfColorVariation = .identity,
        level: ColorVariationLevel = .off
    ) -> ResolvedShelfPalette {
        let scale = (variation == .identity) ? 0.0 : level.multiplier

        guard let spec else {
            let glassTint: Color
            let accentNS: NSColor
            if scale > 0 {
                let baseAcc = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? NSColor(red: 0.2, green: 0.5, blue: 0.95, alpha: 1.0)
                let shiftedAcc = Self.shiftedHSBColor(
                    baseAcc,
                    hueDelta: variation.hueDelta * 1.4 * scale,
                    satDelta: variation.saturationDelta * scale,
                    brightDelta: variation.brightnessDelta * scale,
                    minBrightness: 0.28,
                    maxBrightness: 0.94
                )
                accentNS = shiftedAcc
                let washOpacity: CGFloat = min(0.38, 0.12 * scale + 0.02)
                glassTint = Color(nsColor: shiftedAcc).opacity(washOpacity)
            } else {
                accentNS = .controlAccentColor
                glassTint = .clear
            }
            return ResolvedShelfPalette(
                isSystemGlass: true,
                isLightTheme: false,
                preferredColorScheme: nil,
                nsAppearance: nil,
                backgroundTint: glassTint,
                primaryTextColor: .primary,
                secondaryTextColor: .secondary,
                tertiaryTextColor: Color.secondary.opacity(0.75),
                accentColor: scale == 0 ? Color.accentColor : Color(nsColor: accentNS),
                accentForegroundColor: .white,
                nsAccentColor: accentNS,
                borderColor: Color.primary.opacity(0.16),
                controlFill: Color.primary.opacity(0.08),
                dividerColor: Color.primary.opacity(0.12),
                rowFill: Color.primary.opacity(0.035),
                rowHoverFill: Color.primary.opacity(0.08)
            )
        }

        let baseBg = NSColor(srgbRed: spec.bgR, green: spec.bgG, blue: spec.bgB, alpha: 1.0)
        let baseAcc = NSColor(srgbRed: spec.accR, green: spec.accG, blue: spec.accB, alpha: 1.0)

        let finalBgNS: NSColor
        let finalAccNS: NSColor
        if scale == 0 {
            finalBgNS = baseBg
            finalAccNS = baseAcc
        } else if spec.isLight {
            // Light themes sit near b=0.92...0.98, so reflect excess positive brightness into a
            // gentle pastel depth & saturation lift so Medium (2x) and High (3x) stay visibly distinct.
            let satBoost: CGFloat = spec.isNeutral ? 0.012 : 0.045
            finalBgNS = Self.shiftedHSBColor(
                baseBg,
                hueDelta: variation.hueDelta * scale,
                satDelta: (variation.saturationDelta * 0.65 + satBoost) * scale,
                brightDelta: variation.brightnessDelta * 0.55 * scale,
                minBrightness: 0.74,
                maxBrightness: 0.992
            )
            finalAccNS = Self.shiftedHSBColor(
                baseAcc,
                hueDelta: variation.hueDelta * 0.95 * scale,
                satDelta: variation.saturationDelta * 0.55 * scale,
                brightDelta: variation.brightnessDelta * 0.45 * scale,
                minBrightness: 0.28,
                maxBrightness: 0.86
            )
        } else {
            finalBgNS = Self.shiftedHSBColor(
                baseBg,
                hueDelta: variation.hueDelta * scale,
                satDelta: variation.saturationDelta * 0.8 * scale,
                brightDelta: variation.brightnessDelta * 0.75 * scale,
                minBrightness: 0.04,
                maxBrightness: 0.38
            )
            finalAccNS = Self.shiftedHSBColor(
                baseAcc,
                hueDelta: variation.hueDelta * 0.9 * scale,
                satDelta: variation.saturationDelta * 0.5 * scale,
                brightDelta: variation.brightnessDelta * 0.45 * scale,
                minBrightness: 0.46,
                maxBrightness: 0.99
            )
        }

        // High-contrast ink colors derived cleanly from light/dark mode
        let primaryText = spec.isLight
            ? Color(red: 0.11, green: 0.12, blue: 0.16)
            : Color(red: 0.96, green: 0.97, blue: 0.99)
        let secondaryText = spec.isLight
            ? Color(red: 0.33, green: 0.35, blue: 0.41)
            : Color(red: 0.74, green: 0.78, blue: 0.85)
        let accentSwiftUI = Color(nsColor: finalAccNS)
        let border = accentSwiftUI.opacity(spec.isLight ? 0.25 : 0.34)

        return ResolvedShelfPalette(
            isSystemGlass: false,
            isLightTheme: spec.isLight,
            preferredColorScheme: spec.isLight ? .light : .dark,
            nsAppearance: spec.isLight ? NSAppearance(named: .aqua) : NSAppearance(named: .darkAqua),
            backgroundTint: Color(nsColor: finalBgNS).opacity(spec.bgAlpha),
            primaryTextColor: primaryText,
            secondaryTextColor: secondaryText,
            tertiaryTextColor: secondaryText.opacity(spec.isLight ? 0.80 : 0.74),
            accentColor: accentSwiftUI,
            accentForegroundColor: spec.darkAccentForeground ? Color(red: 0.06, green: 0.09, blue: 0.11) : .white,
            nsAccentColor: finalAccNS,
            borderColor: border,
            controlFill: spec.isLight ? Color.black.opacity(0.075) : Color.white.opacity(0.10),
            dividerColor: spec.isLight ? Color.black.opacity(0.10) : Color.white.opacity(0.12),
            rowFill: spec.isLight ? Color.black.opacity(0.045) : Color.white.opacity(0.055),
            rowHoverFill: spec.isLight ? Color.black.opacity(0.09) : Color.white.opacity(0.11)
        )
    }

    private static func shiftedHSBColor(
        _ color: NSColor,
        hueDelta: CGFloat,
        satDelta: CGFloat,
        brightDelta: CGFloat,
        minBrightness: CGFloat,
        maxBrightness: CGFloat
    ) -> NSColor {
        let srgb = color.usingColorSpace(.sRGB) ?? color
        var h: CGFloat = 0
        var s: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 1
        srgb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)

        var newH = (h + hueDelta).truncatingRemainder(dividingBy: 1.0)
        if newH < 0 { newH += 1.0 }
        let newS = min(max(s + satDelta, 0.0), 1.0)
        let newB = min(max(b + brightDelta, minBrightness), maxBrightness)

        return NSColor(hue: newH, saturation: newS, brightness: newB, alpha: a)
    }
}
