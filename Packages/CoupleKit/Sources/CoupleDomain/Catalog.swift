import Foundation

// The fixed catalogue of things a note can be made from, and the single
// definition of what is free and what is premium. Colours are stored as hex so
// this module stays free of UI frameworks; CoupleDesign turns them into Color.

// MARK: - Product configuration

/// The one place the free/premium split is defined on the client.
/// Quantities here are mirrored by `app_private.couple_limit` in the database,
/// which is what actually enforces them.
public enum ProductConfiguration {
    public struct Limits: Equatable, Sendable {
        public let memories: Int
        public let pendingScheduledMessages: Int
    }

    public static let free = Limits(memories: 30, pendingScheduledMessages: 1)
    public static let premium = Limits(memories: 2000, pendingScheduledMessages: 50)
    public static let importantDatesLimit = 100

    /// Placeholder identifiers. Replace with the products created in App Store
    /// Connect; the bundled `Products.storekit` file must use the same values.
    public static let monthlyProductID = "com.example.couplenotes.premium.monthly"
    public static let yearlyProductID = "com.example.couplenotes.premium.yearly"
    public static let productIDs = [yearlyProductID, monthlyProductID]
    public static let subscriptionGroupID = "premium"

    /// What premium adds, in the order the paywall presents it.
    public enum Feature: String, CaseIterable, Sendable {
        case themes, papers, drawingTools, scheduled, memories, templates, widgetStyles
    }
}

public enum Validation {
    public static let noteBodyLimit = 280
    public static let displayNameLimit = 40
    public static let memoryTitleLimit = 80
    public static let memoryCaptionLimit = 300
    public static let dateTitleLimit = 60
    public static let maximumStickers = 8
}

// MARK: - Paper

public struct Paper: Identifiable, Equatable, Sendable {
    public enum Pattern: String, Sendable {
        case plain, lined, grid, dotted
    }

    public let id: String
    public let hex: String
    /// Used in dark appearance so a note does not glare on a dark screen.
    public let darkHex: String
    public let pattern: Pattern
    public let isPremium: Bool
    /// A dark sheet needs light ink by default.
    public let isDark: Bool

    public static let defaultID = "cream"

    public static let all: [Paper] = [
        Paper(id: "cream", hex: "#FFF9EC", darkHex: "#EDE5D3", pattern: .plain, isPremium: false, isDark: false),
        Paper(id: "blush", hex: "#F9E4E4", darkHex: "#E6CDCF", pattern: .plain, isPremium: false, isDark: false),
        Paper(id: "lilac", hex: "#E9E2F5", darkHex: "#D3C9E6", pattern: .plain, isPremium: false, isDark: false),
        Paper(id: "lined", hex: "#FBF6E9", darkHex: "#EAE3D1", pattern: .lined, isPremium: false, isDark: false),
        Paper(id: "grid", hex: "#F3F1EA", darkHex: "#E1DED4", pattern: .grid, isPremium: true, isDark: false),
        Paper(id: "dotted", hex: "#F6EFE6", darkHex: "#E4DBCF", pattern: .dotted, isPremium: true, isDark: false),
        Paper(id: "sage", hex: "#DFE8DC", darkHex: "#CAD6C6", pattern: .plain, isPremium: true, isDark: false),
        Paper(id: "sky", hex: "#DCE8F0", darkHex: "#C6D5E0", pattern: .plain, isPremium: true, isDark: false),
        Paper(id: "kraft", hex: "#D9C3A0", darkHex: "#C7B08B", pattern: .plain, isPremium: true, isDark: false),
        Paper(id: "midnight", hex: "#2A2233", darkHex: "#2A2233", pattern: .plain, isPremium: true, isDark: true),
    ]

    public static func find(_ id: String) -> Paper {
        all.first { $0.id == id } ?? all[0]
    }
}

// MARK: - Ink

public struct Ink: Identifiable, Equatable, Sendable {
    public let id: String
    public let hex: String
    public let isPremium: Bool

    public static let defaultID = "plum"
    public static let lightID = "chalk"

    public static let all: [Ink] = [
        Ink(id: "plum", hex: "#302238", isPremium: false),
        Ink(id: "graphite", hex: "#3A3A3C", isPremium: false),
        Ink(id: "rose", hex: "#B4566A", isPremium: false),
        Ink(id: "ocean", hex: "#2F5D8A", isPremium: false),
        Ink(id: "forest", hex: "#3F6B4F", isPremium: false),
        Ink(id: "terracotta", hex: "#B5573A", isPremium: false),
        Ink(id: "chalk", hex: "#FBF7F0", isPremium: false),
        Ink(id: "violet", hex: "#7A5CC2", isPremium: true),
        Ink(id: "gold", hex: "#A8842C", isPremium: true),
        Ink(id: "coral", hex: "#E2675A", isPremium: true),
        Ink(id: "teal", hex: "#2B8A8A", isPremium: true),
    ]

    public static func find(_ id: String) -> Ink {
        all.first { $0.id == id } ?? all[0]
    }
}

// MARK: - Drawing tools

public enum DrawingTool: String, CaseIterable, Sendable {
    case pen, marker, pencil, eraser

    public var isPremium: Bool {
        self == .marker || self == .pencil
    }
}

// MARK: - Stickers

public struct Sticker: Identifiable, Equatable, Sendable {
    public let id: String
    /// SF Symbol name.
    public let symbol: String
    public let hex: String
    public let isPremium: Bool

    public static let all: [Sticker] = [
        Sticker(id: "heart", symbol: "heart.fill", hex: "#C9566B", isPremium: false),
        Sticker(id: "star", symbol: "star.fill", hex: "#D9A441", isPremium: false),
        Sticker(id: "sun", symbol: "sun.max.fill", hex: "#E0913A", isPremium: false),
        Sticker(id: "moon", symbol: "moon.stars.fill", hex: "#6C5BA8", isPremium: false),
        Sticker(id: "leaf", symbol: "leaf.fill", hex: "#5C8A62", isPremium: false),
        Sticker(id: "coffee", symbol: "cup.and.saucer.fill", hex: "#8A5A3C", isPremium: false),
        Sticker(id: "sparkles", symbol: "sparkles", hex: "#B78FD6", isPremium: true),
        Sticker(id: "plane", symbol: "airplane", hex: "#3F7FB0", isPremium: true),
        Sticker(id: "home", symbol: "house.fill", hex: "#A6634A", isPremium: true),
        Sticker(id: "music", symbol: "music.note", hex: "#7A5CC2", isPremium: true),
        Sticker(id: "gift", symbol: "gift.fill", hex: "#C9566B", isPremium: true),
        Sticker(id: "balloon", symbol: "balloon.2.fill", hex: "#E2675A", isPremium: true),
        Sticker(id: "paw", symbol: "pawprint.fill", hex: "#6B5B4B", isPremium: true),
        Sticker(id: "umbrella", symbol: "umbrella.fill", hex: "#2B8A8A", isPremium: true),
    ]

    public static func find(_ id: String) -> Sticker? {
        all.first { $0.id == id }
    }
}

// MARK: - Themes

/// A shared look for the whole space. Ids match `public.themes` in the database.
public struct Theme: Identifiable, Equatable, Sendable {
    public struct Palette: Equatable, Sendable {
        public let canvas: String
        public let sunken: String
        public let accent: String
        public let highlight: String
    }

    public let id: String
    public let isPremium: Bool
    public let light: Palette
    public let dark: Palette

    public static let defaultID = "paper"

    public static let all: [Theme] = [
        Theme(
            id: "paper", isPremium: false,
            light: Palette(canvas: "#FAF7F2", sunken: "#F1E9DE", accent: "#302238", highlight: "#B4566A"),
            dark: Palette(canvas: "#16111A", sunken: "#1F1825", accent: "#D9C8F0", highlight: "#E9A9B6")
        ),
        Theme(
            id: "plum", isPremium: false,
            light: Palette(canvas: "#F4EFF8", sunken: "#E8DFF0", accent: "#4A2F5C", highlight: "#9A5BB0"),
            dark: Palette(canvas: "#17101D", sunken: "#22182B", accent: "#DCC4F2", highlight: "#C89BE0")
        ),
        Theme(
            id: "linen", isPremium: true,
            light: Palette(canvas: "#F6F3EC", sunken: "#EAE5D9", accent: "#3D3A33", highlight: "#A8743C"),
            dark: Palette(canvas: "#151411", sunken: "#201E19", accent: "#E8E0CF", highlight: "#D9A56B")
        ),
        Theme(
            id: "dusk", isPremium: true,
            light: Palette(canvas: "#F8F0EE", sunken: "#F0DFDB", accent: "#5A2E3E", highlight: "#C4576E"),
            dark: Palette(canvas: "#1A1014", sunken: "#26171D", accent: "#F2C6D1", highlight: "#EE8FA3")
        ),
        Theme(
            id: "sage", isPremium: true,
            light: Palette(canvas: "#F3F6F1", sunken: "#E3EADF", accent: "#2C4234", highlight: "#4F8A63"),
            dark: Palette(canvas: "#101612", sunken: "#18211B", accent: "#CDE5D3", highlight: "#8CCBA0")
        ),
        Theme(
            id: "ink", isPremium: true,
            light: Palette(canvas: "#F2F4F8", sunken: "#E2E7EF", accent: "#1F2D47", highlight: "#3F6FB5"),
            dark: Palette(canvas: "#0F1218", sunken: "#171C26", accent: "#C8D7F2", highlight: "#8FB3EE")
        ),
    ]

    public static func find(_ id: String) -> Theme {
        all.first { $0.id == id } ?? all[0]
    }
}

// MARK: - Templates

/// A starting point for a note: a look and an opening line, both editable.
public struct NoteTemplate: Identifiable, Equatable, Sendable {
    public let id: String
    public let isPremium: Bool
    public let style: NoteStyle

    public static let all: [NoteTemplate] = [
        NoteTemplate(id: "morning", isPremium: false, style: NoteStyle(
            paper: "cream", ink: "terracotta", typeface: .hand,
            stickers: [StickerPlacement(id: fixedID(1), sticker: "sun", x: 0.82, y: 0.17, scale: 1.1, rotation: 8)]
        )),
        NoteTemplate(id: "thinking", isPremium: false, style: NoteStyle(
            paper: "blush", ink: "rose", typeface: .hand,
            stickers: [StickerPlacement(id: fixedID(2), sticker: "heart", x: 0.2, y: 0.82, scale: 0.9, rotation: -10)]
        )),
        NoteTemplate(id: "luck", isPremium: false, style: NoteStyle(
            paper: "lilac", ink: "plum", typeface: .serif,
            stickers: [StickerPlacement(id: fixedID(3), sticker: "star", x: 0.8, y: 0.2, scale: 1, rotation: 12)]
        )),
        NoteTemplate(id: "anniversary", isPremium: true, style: NoteStyle(
            paper: "midnight", ink: "chalk", typeface: .serif,
            stickers: [
                StickerPlacement(id: fixedID(4), sticker: "sparkles", x: 0.8, y: 0.18, scale: 1.2, rotation: 0),
                StickerPlacement(id: fixedID(5), sticker: "heart", x: 0.2, y: 0.82, scale: 0.8, rotation: -8),
            ]
        )),
        NoteTemplate(id: "birthday", isPremium: true, style: NoteStyle(
            paper: "sky", ink: "ocean", typeface: .rounded,
            stickers: [
                StickerPlacement(id: fixedID(6), sticker: "balloon", x: 0.8, y: 0.2, scale: 1.3, rotation: 6),
                StickerPlacement(id: fixedID(7), sticker: "gift", x: 0.2, y: 0.82, scale: 1, rotation: -6),
            ]
        )),
        NoteTemplate(id: "sorry", isPremium: true, style: NoteStyle(
            paper: "sage", ink: "forest", typeface: .hand,
            stickers: [StickerPlacement(id: fixedID(8), sticker: "leaf", x: 0.82, y: 0.82, scale: 1, rotation: 20)]
        )),
        NoteTemplate(id: "missing", isPremium: true, style: NoteStyle(
            paper: "dotted", ink: "violet", typeface: .hand,
            stickers: [StickerPlacement(id: fixedID(9), sticker: "plane", x: 0.8, y: 0.18, scale: 1, rotation: -18)]
        )),
        NoteTemplate(id: "datenight", isPremium: true, style: NoteStyle(
            paper: "kraft", ink: "plum", typeface: .serif,
            stickers: [StickerPlacement(id: fixedID(10), sticker: "moon", x: 0.82, y: 0.18, scale: 1.1, rotation: 0)]
        )),
    ]

    private static func fixedID(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", n))!
    }
}

// MARK: - Widget styles

public enum WidgetStyle: String, CaseIterable, Codable, Sendable {
    /// The note exactly as composed.
    case note
    /// Text only on the theme's canvas.
    case minimal
    /// The note as a tilted print with a caption strip.
    case print
    /// Light text on the theme's accent colour.
    case bold

    public var isPremium: Bool {
        self == .print || self == .bold
    }
}
