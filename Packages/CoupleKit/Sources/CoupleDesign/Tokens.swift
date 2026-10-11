import CoupleDomain
import SwiftUI

// The design tokens. Screens never use a literal colour, font size, spacing
// value or corner radius; they use these. See DESIGN_SYSTEM.md for the intent
// behind each one.

// MARK: - Colour

public extension Color {
    /// `#RRGGBB`. Anything unparseable becomes magenta so it is noticed.
    init(hex: String) {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else {
            self = Color(red: 1, green: 0, blue: 1)
            return
        }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

public enum ColorMath {
    /// Relative luminance (WCAG) of a `#RRGGBB` colour.
    public static func luminance(hex: String) -> Double {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return 0 }
        func channel(_ shift: UInt32) -> Double {
            let c = Double((value >> shift) & 0xFF) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0)
    }

    public static func contrast(_ a: String, _ b: String) -> Double {
        let (la, lb) = (luminance(hex: a), luminance(hex: b))
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// Linear mix of two hex colours; `amount` 0 gives `a`, 1 gives `b`.
    public static func mix(_ a: String, _ b: String, _ amount: Double) -> String {
        func parts(_ hex: String) -> [Double] {
            let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
            guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return [0, 0, 0] }
            return [16, 8, 0].map { Double((value >> UInt32($0)) & 0xFF) }
        }
        let (pa, pb) = (parts(a), parts(b))
        let mixed = zip(pa, pb).map { Int(($0 + ($1 - $0) * amount).rounded()) }
        return String(format: "#%02X%02X%02X", mixed[0], mixed[1], mixed[2])
    }
}

/// The semantic colours for one appearance of one theme.
public struct Palette: Equatable, Sendable {
    /// The page itself.
    public let canvas: Color
    /// Raised content: sheets, fields, rows that need to lift off the canvas.
    public let surface: Color
    /// Recessed areas: wells, tracks, quiet grouping.
    public let sunken: Color
    public let ink: Color
    public let inkSecondary: Color
    /// Decoration and placeholders only; never for text that must be read.
    public let inkTertiary: Color
    /// Primary actions and selected states.
    public let accent: Color
    public let onAccent: Color
    /// Small moments of warmth: the unread mark, a chosen reaction.
    public let highlight: Color
    public let hairline: Color
    public let danger: Color
    public let success: Color
    public let isDark: Bool

    public init(theme: Theme, accentHex: String? = nil, scheme: ColorScheme) {
        let dark = scheme == .dark
        let source = dark ? theme.dark : theme.light
        var accent = source.accent
        if let custom = accentHex {
            // A custom accent must stay legible against the canvas in both appearances.
            accent = custom
            if ColorMath.contrast(custom, source.canvas) < 3 {
                accent = ColorMath.mix(custom, dark ? "#FFFFFF" : "#000000", 0.45)
            }
        }
        canvas = Color(hex: source.canvas)
        sunken = Color(hex: source.sunken)
        surface = dark ? Color(hex: ColorMath.mix(source.canvas, "#FFFFFF", 0.07)) : Color(hex: "#FFFFFF")
        ink = Color(hex: dark ? "#F3EDF5" : "#28242C")
        inkSecondary = Color(hex: dark ? "#B9AFBF" : "#69636D")
        inkTertiary = Color(hex: dark ? "#7E7484" : "#A39CA6")
        self.accent = Color(hex: accent)
        onAccent = ColorMath.luminance(hex: accent) > 0.4 ? Color(hex: "#1E1524") : Color(hex: "#FFFFFF")
        highlight = Color(hex: source.highlight)
        hairline = (dark ? Color.white : Color(hex: "#28242C")).opacity(dark ? 0.12 : 0.1)
        danger = Color(hex: dark ? "#F08A80" : "#B3372F")
        success = Color(hex: dark ? "#8CCBA6" : "#3F7D5C")
        isDark = dark
    }

    public static let fallback = Palette(theme: Theme.find(Theme.defaultID), scheme: .light)
}

private struct PaletteKey: EnvironmentKey {
    static let defaultValue = Palette.fallback
}

public extension EnvironmentValues {
    var palette: Palette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}

private struct ThemeModifier: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    let themeID: String
    let accentHex: String?

    func body(content: Content) -> some View {
        let palette = Palette(theme: Theme.find(themeID), accentHex: accentHex, scheme: scheme)
        content
            .environment(\.palette, palette)
            .tint(palette.accent)
    }
}

public extension View {
    /// Resolves the couple's theme for the current appearance and makes it
    /// available to everything below.
    func coupleTheme(_ themeID: String = Theme.defaultID, accentHex: String? = nil) -> some View {
        modifier(ThemeModifier(themeID: themeID, accentHex: accentHex))
    }
}

// MARK: - Space, shape, depth, motion

public enum Space {
    public static let xxs: CGFloat = 4
    public static let xs: CGFloat = 8
    public static let sm: CGFloat = 12
    public static let md: CGFloat = 16
    public static let lg: CGFloat = 24
    public static let xl: CGFloat = 32
    public static let xxl: CGFloat = 48
    /// Standard distance from the screen edge to content.
    public static let gutter: CGFloat = 24
}

public enum Radius {
    public static let chip: CGFloat = 10
    public static let field: CGFloat = 14
    public static let card: CGFloat = 22
    /// A sheet of paper has barely any corner at all.
    public static let paper: CGFloat = 5
}

public enum Size {
    /// Minimum hit area for anything tappable.
    public static let touch: CGFloat = 44
    public static let button: CGFloat = 54
    public static let iconInline: CGFloat = 17
    public static let iconControl: CGFloat = 20
    public static let iconFeature: CGFloat = 28
}

public enum Motion {
    /// The default for things that move or resize.
    public static let standard = Animation.spring(response: 0.42, dampingFraction: 0.86)
    /// For things that only appear or disappear.
    public static let fade = Animation.easeOut(duration: 0.2)
    public static let gentle = Animation.spring(response: 0.6, dampingFraction: 0.9)
}

public extension View {
    /// Depth is reserved for paper: the note is the only thing that lifts off the page.
    func paperShadow(_ palette: Palette, lifted: Bool = true) -> some View {
        let tint = palette.isDark ? Color.black : Color(hex: "#302238")
        return shadow(color: tint.opacity(palette.isDark ? 0.5 : 0.07), radius: 1.5, y: 1)
            .shadow(color: tint.opacity(lifted ? (palette.isDark ? 0.55 : 0.16) : 0), radius: 22, y: 14)
    }

    /// The quiet lift used for the few raised controls.
    func softShadow(_ palette: Palette) -> some View {
        shadow(color: (palette.isDark ? Color.black : Color(hex: "#302238")).opacity(palette.isDark ? 0.4 : 0.07), radius: 10, y: 4)
    }
}

// MARK: - Type

/// The type scale. Every style is built on a system text style, so all of it
/// follows the reader's Dynamic Type setting.
public enum Typo {
    /// Screen-defining moments: the welcome line, an empty home.
    public static let display = Font.system(.largeTitle, design: .serif).weight(.semibold)
    public static let title = Font.system(.title, design: .serif).weight(.semibold)
    public static let heading = Font.system(.title3, design: .serif).weight(.semibold)
    public static let body = Font.system(.body)
    public static let bodyStrong = Font.system(.body).weight(.semibold)
    public static let callout = Font.system(.subheadline)
    public static let calloutStrong = Font.system(.subheadline).weight(.semibold)
    public static let caption = Font.system(.footnote)
    public static let overline = Font.system(.caption).weight(.semibold)
    /// The pairing code and other things read out character by character.
    public static let code = Font.system(.title, design: .monospaced).weight(.medium)
}

public extension View {
    /// Small capitalised label that introduces a group.
    func overlineStyle(_ palette: Palette) -> some View {
        font(Typo.overline)
            .textCase(.uppercase)
            .tracking(0.9)
            .foregroundStyle(palette.inkSecondary)
    }
}

public extension Text {
    /// Handwriting, used sparingly outside notes: a signature, a date.
    func handwritten(size: CGFloat, relativeTo style: Font.TextStyle = .body) -> Text {
        font(.custom(NoteFont.handName, size: size, relativeTo: style))
    }
}

public enum NoteFont {
    /// Ships with iOS, so there is nothing to license or bundle.
    public static let handName = "BradleyHandITCTT-Bold"

    public static func font(_ typeface: NoteStyle.Typeface, size: CGFloat) -> Font {
        switch typeface {
        case .hand: .custom(handName, fixedSize: size)
        case .serif: .system(size: size * 0.9, weight: .regular, design: .serif)
        case .rounded: .system(size: size * 0.86, weight: .medium, design: .rounded)
        // All of these ship with iOS. Each is scaled so that the same words
        // take up about the same room whichever lettering is chosen.
        case .typewriter: .custom("AmericanTypewriter", fixedSize: size * 0.8)
        case .script: .custom("SnellRoundhand-Bold", fixedSize: size * 0.98)
        case .marker: .custom("MarkerFelt-Wide", fixedSize: size * 0.84)
        case .casual: .custom("Noteworthy-Bold", fixedSize: size * 0.82)
        }
    }
}

// MARK: - Haptics

#if canImport(UIKit)
import UIKit

@MainActor
public enum Haptics {
    public static func tap() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    public static func selection() {
        UISelectionFeedbackGenerator().selectionChanged()
    }

    public static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    public static func warning() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }
}
#else
@MainActor
public enum Haptics {
    public static func tap() {}
    public static func selection() {}
    public static func success() {}
    public static func warning() {}
}
#endif
