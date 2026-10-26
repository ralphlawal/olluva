import Foundation

// MARK: - People and spaces

public struct Profile: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var displayName: String
    public var avatarPath: String?
    /// Counts changes to the picture. The path never changes, so this is what
    /// tells a cached copy that it is out of date.
    public var avatarVersion: Int
    public var timeZone: String

    public init(id: UUID, displayName: String, avatarPath: String? = nil, avatarVersion: Int = 0, timeZone: String = "UTC") {
        self.id = id
        self.displayName = displayName
        self.avatarPath = avatarPath
        self.avatarVersion = avatarVersion
        self.timeZone = timeZone
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        avatarPath = try container.decodeIfPresent(String.self, forKey: .avatarPath)
        avatarVersion = try container.decodeIfPresent(Int.self, forKey: .avatarVersion) ?? 0
        timeZone = try container.decode(String.self, forKey: .timeZone)
    }

    /// The single letter shown when there is no avatar.
    public var initial: String {
        displayName.trimmingCharacters(in: .whitespaces).first.map { String($0).uppercased() } ?? "·"
    }
}

public struct CoupleSpace: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var themeID: String
    public var accentHex: String?
    public var pairedAt: Date?
    public var createdAt: Date

    public init(id: UUID, themeID: String = Theme.defaultID, accentHex: String? = nil, pairedAt: Date? = nil, createdAt: Date) {
        self.id = id
        self.themeID = themeID
        self.accentHex = accentHex
        self.pairedAt = pairedAt
        self.createdAt = createdAt
    }
}

/// What the signed-in person's relationship to a space currently is.
public enum SpaceState: Equatable, Sendable {
    /// Not in any space yet.
    case none
    /// In a space, waiting for a partner to join.
    case waiting(CoupleSpace)
    case paired(CoupleSpace, partner: Profile)

    public var space: CoupleSpace? {
        switch self {
        case .none: nil
        case .waiting(let space), .paired(let space, _): space
        }
    }

    public var partner: Profile? {
        if case .paired(_, let partner) = self { partner } else { nil }
    }
}

// MARK: - Invitations

public struct IssuedInvitation: Equatable, Sendable {
    public let id: UUID
    /// The plaintext code. Returned once by the server and never stored there.
    public let code: String
    public let expiresAt: Date

    public init(id: UUID, code: String, expiresAt: Date) {
        self.id = id
        self.code = code
        self.expiresAt = expiresAt
    }
}

public struct InvitationPreview: Equatable, Sendable {
    public let inviterName: String
    public let expiresAt: Date

    public init(inviterName: String, expiresAt: Date) {
        self.inviterName = inviterName
        self.expiresAt = expiresAt
    }
}

// MARK: - Notes

public struct Note: Identifiable, Codable, Equatable, Sendable {
    public enum Origin: String, Codable, Sendable {
        case direct
        case scheduled
    }

    public let id: UUID
    public let coupleID: UUID
    public var authorID: UUID?
    public var body: String
    public var style: NoteStyle
    public var photoPath: String?
    public var drawingPath: String?
    public var origin: Origin
    public var version: Int
    public var seenAt: Date?
    public var deletedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID, coupleID: UUID, authorID: UUID?, body: String, style: NoteStyle = NoteStyle(),
        photoPath: String? = nil, drawingPath: String? = nil, origin: Origin = .direct, version: Int = 1,
        seenAt: Date? = nil, deletedAt: Date? = nil, createdAt: Date, updatedAt: Date? = nil
    ) {
        self.id = id
        self.coupleID = coupleID
        self.authorID = authorID
        self.body = body
        self.style = style
        self.photoPath = photoPath
        self.drawingPath = drawingPath
        self.origin = origin
        self.version = version
        self.seenAt = seenAt
        self.deletedAt = deletedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }

    public var isDeleted: Bool { deletedAt != nil }
    public var isEdited: Bool { version > 1 && !isDeleted }
    public var content: NoteContent {
        NoteContent(body: body, style: style, photoPath: photoPath, drawingPath: drawingPath)
    }
}

/// The part of a note that a person composes. Shared by notes, scheduled
/// messages and saved memories so all three render identically.
public struct NoteContent: Codable, Equatable, Sendable {
    public var body: String
    public var style: NoteStyle
    public var photoPath: String?
    public var drawingPath: String?

    public init(body: String = "", style: NoteStyle = NoteStyle(), photoPath: String? = nil, drawingPath: String? = nil) {
        self.body = body
        self.style = style
        self.photoPath = photoPath
        self.drawingPath = drawingPath
    }

    public var isEmpty: Bool {
        body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && photoPath == nil && drawingPath == nil
    }
}

public struct NoteStyle: Codable, Equatable, Sendable {
    public enum Typeface: String, Codable, CaseIterable, Sendable {
        case hand
        case serif
        case rounded
    }

    public enum PhotoLayout: String, Codable, CaseIterable, Sendable {
        /// The photo fills the card; text sits over a scrim at the bottom.
        case full
        /// The photo sits in an inset frame with the text as a caption beneath.
        case framed
    }

    public var paper: String
    public var ink: String
    public var typeface: Typeface
    public var photoLayout: PhotoLayout
    public var stickers: [StickerPlacement]

    public init(
        paper: String = Paper.defaultID, ink: String = Ink.defaultID, typeface: Typeface = .hand,
        photoLayout: PhotoLayout = .framed, stickers: [StickerPlacement] = []
    ) {
        self.paper = paper
        self.ink = ink
        self.typeface = typeface
        self.photoLayout = photoLayout
        self.stickers = stickers
    }

    // Decoding is deliberately forgiving: a style written by a newer app
    // version, or an empty `{}` from the server, must still render.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        paper = (try? container.decode(String.self, forKey: .paper)) ?? Paper.defaultID
        ink = (try? container.decode(String.self, forKey: .ink)) ?? Ink.defaultID
        typeface = (try? container.decode(Typeface.self, forKey: .typeface)) ?? .hand
        photoLayout = (try? container.decode(PhotoLayout.self, forKey: .photoLayout)) ?? .framed
        stickers = (try? container.decode([StickerPlacement].self, forKey: .stickers)) ?? []
    }

    enum CodingKeys: String, CodingKey {
        case paper, ink, typeface, stickers
        case photoLayout = "photo_layout"
    }
}

/// A sticker positioned in the card's unit square, so it lands in the same
/// place on a phone, in a widget and in the scrapbook.
public struct StickerPlacement: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var sticker: String
    public var x: Double
    public var y: Double
    public var scale: Double
    public var rotation: Double

    public init(id: UUID = UUID(), sticker: String, x: Double = 0.5, y: Double = 0.5, scale: Double = 1, rotation: Double = 0) {
        self.id = id
        self.sticker = sticker
        self.x = x
        self.y = y
        self.scale = scale
        self.rotation = rotation
    }
}

public enum ReactionKind: String, Codable, CaseIterable, Sendable {
    case love, smile, laugh, hug, moved, spark
}

public struct Reaction: Codable, Equatable, Sendable {
    public let noteID: UUID
    public let userID: UUID
    public var kind: ReactionKind

    public init(noteID: UUID, userID: UUID, kind: ReactionKind) {
        self.noteID = noteID
        self.userID = userID
        self.kind = kind
    }
}

// MARK: - Memories

public struct Memory: Identifiable, Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case note, photo, drawing, moment
    }

    public let id: UUID
    public let coupleID: UUID
    public var createdBy: UUID?
    public var kind: Kind
    public var title: String
    public var caption: String
    public var content: NoteContent
    public var sourceNoteID: UUID?
    public var occurredOn: DayDate
    public var createdAt: Date

    public init(
        id: UUID, coupleID: UUID, createdBy: UUID?, kind: Kind, title: String = "", caption: String = "",
        content: NoteContent = NoteContent(), sourceNoteID: UUID? = nil, occurredOn: DayDate, createdAt: Date
    ) {
        self.id = id
        self.coupleID = coupleID
        self.createdBy = createdBy
        self.kind = kind
        self.title = title
        self.caption = caption
        self.content = content
        self.sourceNoteID = sourceNoteID
        self.occurredOn = occurredOn
        self.createdAt = createdAt
    }
}

public struct NewMoment: Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var caption: String
    public var occurredOn: DayDate
    public var photoPath: String?
    public var drawingPath: String?

    public init(id: UUID = UUID(), title: String, caption: String = "", occurredOn: DayDate, photoPath: String? = nil, drawingPath: String? = nil) {
        self.id = id
        self.title = title
        self.caption = caption
        self.occurredOn = occurredOn
        self.photoPath = photoPath
        self.drawingPath = drawingPath
    }

    public var kind: Memory.Kind {
        if photoPath != nil { return .photo }
        if drawingPath != nil { return .drawing }
        return .moment
    }
}

/// Keyset cursor for the memories timeline: newest day first, then by id.
public struct MemoryCursor: Equatable, Sendable {
    public let occurredOn: DayDate
    public let id: UUID

    public init(after memory: Memory) {
        occurredOn = memory.occurredOn
        id = memory.id
    }
}

// MARK: - Important dates

public struct ImportantDate: Identifiable, Codable, Equatable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case anniversary, birthday
        case firstMeeting = "first_meeting"
        case milestone, custom
    }

    public enum Recurrence: String, Codable, CaseIterable, Sendable {
        case none, monthly, yearly
    }

    public enum Visibility: String, Codable, CaseIterable, Sendable {
        case shared
        case `private`
    }

    public static let allowedReminderOffsets = [0, 1, 3, 7, 14, 30]
    public static let maximumReminders = 4

    public let id: UUID
    public let coupleID: UUID
    public var createdBy: UUID
    public var title: String
    public var kind: Kind
    public var startsOn: DayDate
    public var recurrence: Recurrence
    public var visibility: Visibility
    public var notify: Bool
    public var remindDaysBefore: [Int]

    public init(
        id: UUID = UUID(), coupleID: UUID, createdBy: UUID, title: String, kind: Kind = .custom,
        startsOn: DayDate, recurrence: Recurrence = .yearly, visibility: Visibility = .shared,
        notify: Bool = true, remindDaysBefore: [Int] = [0]
    ) {
        self.id = id
        self.coupleID = coupleID
        self.createdBy = createdBy
        self.title = title
        self.kind = kind
        self.startsOn = startsOn
        self.recurrence = recurrence
        self.visibility = visibility
        self.notify = notify
        self.remindDaysBefore = remindDaysBefore
    }
}

// MARK: - Scheduled messages

public struct ScheduledMessage: Identifiable, Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case pending, delivered, cancelled, failed
    }

    public let id: UUID
    public let coupleID: UUID
    public var content: NoteContent
    public var deliverAt: Date
    public var timeZone: String
    public var status: Status
    public var failureReason: String?
    public var version: Int
    public var createdAt: Date

    public init(
        id: UUID, coupleID: UUID, content: NoteContent, deliverAt: Date, timeZone: String,
        status: Status = .pending, failureReason: String? = nil, version: Int = 1, createdAt: Date
    ) {
        self.id = id
        self.coupleID = coupleID
        self.content = content
        self.deliverAt = deliverAt
        self.timeZone = timeZone
        self.status = status
        self.failureReason = failureReason
        self.version = version
        self.createdAt = createdAt
    }
}

// MARK: - Notifications

public struct NotificationPreferences: Codable, Equatable, Sendable {
    public var newNotes: Bool
    public var surprises: Bool
    public var importantDates: Bool
    public var pairing: Bool
    public var account: Bool
    public var showPreviews: Bool

    public init(
        newNotes: Bool = true, surprises: Bool = true, importantDates: Bool = true,
        pairing: Bool = true, account: Bool = true, showPreviews: Bool = false
    ) {
        self.newNotes = newNotes
        self.surprises = surprises
        self.importantDates = importantDates
        self.pairing = pairing
        self.account = account
        self.showPreviews = showPreviews
    }
}

public enum PushEnvironment: String, Sendable {
    case sandbox, production
}

// MARK: - Entitlement

public struct Entitlement: Codable, Equatable, Sendable {
    public enum Source: String, Codable, Sendable {
        /// The signed-in person holds the subscription.
        case own = "self"
        /// Their partner does, and it covers the shared space.
        case partner
    }

    public var isPremium: Bool
    public var source: Source?
    public var expiresAt: Date?

    public init(isPremium: Bool, source: Source? = nil, expiresAt: Date? = nil) {
        self.isPremium = isPremium
        self.source = source
        self.expiresAt = expiresAt
    }

    public static let free = Entitlement(isPremium: false)

    public var limits: ProductConfiguration.Limits {
        isPremium ? ProductConfiguration.premium : ProductConfiguration.free
    }
}

// MARK: - Calendar day

/// A calendar day with no time and no time zone: an anniversary is "14 June",
/// wherever either partner happens to be. Stored as `yyyy-MM-dd`.
public struct DayDate: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    public init(_ date: Date, calendar: Calendar = .current) {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: parts.year ?? 1970, month: parts.month ?? 1, day: parts.day ?? 1)
    }

    public init?(iso: String) {
        let parts = iso.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...12).contains(parts[1]), (1...31).contains(parts[2]) else { return nil }
        self.init(year: parts[0], month: parts[1], day: parts[2])
    }

    public var description: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    /// Noon on this day in the calendar's zone: safely inside the day whatever
    /// daylight-saving does at midnight.
    public func date(in calendar: Calendar = .current) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12)) ?? .distantPast
    }

    public static func < (lhs: DayDate, rhs: DayDate) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let value = DayDate(iso: String(raw.prefix(10))) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Expected yyyy-MM-dd"))
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}
