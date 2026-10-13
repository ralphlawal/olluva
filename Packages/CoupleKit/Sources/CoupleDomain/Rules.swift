import Foundation

// Pure business rules. No I/O, no clocks other than the ones passed in, so
// every rule here is unit tested directly.

// MARK: - Input validation

public enum InputRules {
    public static func validate(_ content: NoteContent) throws {
        if content.isEmpty {
            throw AppError.invalidContent(.empty)
        }
        if content.body.count > Validation.noteBodyLimit {
            throw AppError.invalidContent(.tooLong(limit: Validation.noteBodyLimit))
        }
        if content.style.stickers.count > Validation.maximumStickers {
            throw AppError.invalidContent(.tooManyStickers(limit: Validation.maximumStickers))
        }
    }

    public static func cleanedDisplayName(_ name: String) -> String {
        String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Validation.displayNameLimit))
    }

    public static func isValidDisplayName(_ name: String) -> Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && name.trimmingCharacters(in: .whitespacesAndNewlines).count <= Validation.displayNameLimit
    }
}

// MARK: - Invitation codes

public enum InviteCode {
    public static let length = 10
    /// Matches the server alphabet: no 0/O or 1/I.
    public static let alphabet = Set("23456789ABCDEFGHJKLMNPQRSTUVWXYZ")
    public static let scheme = "olluva"

    /// Strips everything people add when typing or pasting a code.
    public static func normalize(_ input: String) -> String {
        String(input.uppercased().filter { $0.isLetter || $0.isNumber }.prefix(length))
    }

    public static func isComplete(_ input: String) -> Bool {
        let code = normalize(input)
        return code.count == length && code.allSatisfy(alphabet.contains)
    }

    /// `ABCDE-FGHJK`, the form shown on screen and read aloud.
    public static func display(_ code: String) -> String {
        let clean = normalize(code)
        guard clean.count > 5 else { return clean }
        return clean.prefix(5) + "-" + clean.dropFirst(5)
    }

    public static func link(for code: String) -> URL {
        URL(string: "\(scheme)://join?code=\(normalize(code))")!
    }

    /// Extracts a code from an invitation link, or from text that is just a code.
    public static func extract(from url: URL) -> String? {
        guard url.scheme == scheme, url.host == "join",
              let item = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                  .queryItems?.first(where: { $0.name == "code" }),
              let value = item.value, isComplete(value)
        else { return nil }
        return normalize(value)
    }
}

// MARK: - Important dates

public enum DateRules {
    /// The next time `date` falls on or after `today`. `nil` once a
    /// non-recurring date has passed.
    ///
    /// A date on the 29th–31st is clamped to the last day of a shorter month
    /// (so 29 February is observed on the 28th in a non-leap year). The
    /// database's `app_private.next_occurrence` behaves identically.
    public static func nextOccurrence(
        of start: DayDate, recurrence: ImportantDate.Recurrence, onOrAfter today: DayDate
    ) -> DayDate? {
        if start >= today { return start }
        switch recurrence {
        case .none:
            return nil
        case .yearly:
            let thisYear = clamped(year: today.year, month: start.month, day: start.day)
            return thisYear >= today ? thisYear : clamped(year: today.year + 1, month: start.month, day: start.day)
        case .monthly:
            let thisMonth = clamped(year: today.year, month: today.month, day: start.day)
            if thisMonth >= today { return thisMonth }
            let (year, month) = today.month == 12 ? (today.year + 1, 1) : (today.year, today.month + 1)
            return clamped(year: year, month: month, day: start.day)
        }
    }

    public static func daysBetween(_ from: DayDate, _ to: DayDate) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = calendar.date(from: DateComponents(year: from.year, month: from.month, day: from.day))!
        let end = calendar.date(from: DateComponents(year: to.year, month: to.month, day: to.day))!
        return calendar.dateComponents([.day], from: start, to: end).day ?? 0
    }

    /// How many whole years (or months) the next occurrence marks; `nil` for
    /// the original day itself and for one-off dates.
    public static func anniversaryCount(of date: ImportantDate, at occurrence: DayDate) -> Int? {
        switch date.recurrence {
        case .none:
            return nil
        case .yearly:
            let years = occurrence.year - date.startsOn.year
            return years > 0 ? years : nil
        case .monthly:
            let months = (occurrence.year - date.startsOn.year) * 12 + (occurrence.month - date.startsOn.month)
            return months > 0 ? months : nil
        }
    }

    public struct Upcoming: Equatable, Sendable {
        public let date: ImportantDate
        public let occursOn: DayDate
        public let daysAway: Int
    }

    /// Dates still to come, soonest first.
    public static func upcoming(_ dates: [ImportantDate], today: DayDate, limit: Int? = nil) -> [Upcoming] {
        let sorted = dates
            .compactMap { date -> Upcoming? in
                guard let next = nextOccurrence(of: date.startsOn, recurrence: date.recurrence, onOrAfter: today) else {
                    return nil
                }
                return Upcoming(date: date, occursOn: next, daysAway: daysBetween(today, next))
            }
            .sorted { ($0.daysAway, $0.date.title) < ($1.daysAway, $1.date.title) }
        return limit.map { Array(sorted.prefix($0)) } ?? sorted
    }

    public static func sanitizedReminders(_ offsets: [Int]) -> [Int] {
        Array(Set(offsets).intersection(ImportantDate.allowedReminderOffsets).sorted().prefix(ImportantDate.maximumReminders))
    }

    private static func clamped(year: Int, month: Int, day: Int) -> DayDate {
        DayDate(year: year, month: month, day: min(day, daysIn(month: month, year: year)))
    }

    private static func daysIn(month: Int, year: Int) -> Int {
        switch month {
        case 2: (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28
        case 4, 6, 9, 11: 30
        default: 31
        }
    }
}

// MARK: - Scheduling

public enum ScheduleRules {
    public static let minimumLead: TimeInterval = 5 * 60
    public static let maximumLead: TimeInterval = 2 * 365 * 24 * 60 * 60

    public static func validate(deliverAt: Date, now: Date) throws {
        if deliverAt < now.addingTimeInterval(minimumLead) { throw AppError.deliveryTooSoon }
        if deliverAt > now.addingTimeInterval(maximumLead) { throw AppError.deliveryTooFar }
    }

    /// The earliest time the picker should offer, rounded up to five minutes.
    public static func earliestSelectable(now: Date) -> Date {
        let step: TimeInterval = 5 * 60
        let earliest = now.addingTimeInterval(minimumLead + 60)
        return Date(timeIntervalSinceReferenceDate: (earliest.timeIntervalSinceReferenceDate / step).rounded(.up) * step)
    }

    public static func canEdit(_ message: ScheduledMessage) -> Bool {
        message.status == .pending
    }
}

// MARK: - Entitlement

public enum EntitlementRules {
    public static func canUse(_ paper: Paper, with entitlement: Entitlement) -> Bool {
        !paper.isPremium || entitlement.isPremium
    }

    public static func canUse(_ ink: Ink, with entitlement: Entitlement) -> Bool {
        !ink.isPremium || entitlement.isPremium
    }

    public static func canUse(_ sticker: Sticker, with entitlement: Entitlement) -> Bool {
        !sticker.isPremium || entitlement.isPremium
    }

    public static func canUse(_ tool: DrawingTool, with entitlement: Entitlement) -> Bool {
        !tool.isPremium || entitlement.isPremium
    }

    public static func canUse(_ theme: Theme, with entitlement: Entitlement) -> Bool {
        !theme.isPremium || entitlement.isPremium
    }

    public static func canUse(_ template: NoteTemplate, with entitlement: Entitlement) -> Bool {
        !template.isPremium || entitlement.isPremium
    }

    public static func canUse(_ style: WidgetStyle, with entitlement: Entitlement) -> Bool {
        !style.isPremium || entitlement.isPremium
    }

    public static func canUseCustomAccent(with entitlement: Entitlement) -> Bool {
        entitlement.isPremium
    }

    public static func canSaveMemory(currentCount: Int, entitlement: Entitlement) -> Bool {
        currentCount < entitlement.limits.memories
    }

    public static func canSchedule(pendingCount: Int, entitlement: Entitlement) -> Bool {
        pendingCount < entitlement.limits.pendingScheduledMessages
    }

    /// Whether a note uses anything the person is no longer entitled to (after
    /// a lapse, say). Such a note still renders; it just cannot be sent as new.
    public static func premiumElements(in style: NoteStyle) -> Bool {
        Paper.find(style.paper).isPremium
            || Ink.find(style.ink).isPremium
            || style.stickers.contains { Sticker.find($0.sticker)?.isPremium == true }
    }
}

// MARK: - Note feed

/// Decides what the home screen and widget show from a list of notes, and
/// folds server changes into that list. Notes are append-only per author, so
/// merging never has to choose between two people's edits.
public struct NoteFeed: Equatable, Sendable {
    public private(set) var notes: [Note]

    public init(_ notes: [Note] = []) {
        self.notes = []
        for note in notes { apply(note) }
    }

    /// Inserts or replaces a note. An older version never replaces a newer
    /// one, so a late or duplicated realtime event cannot roll a note back.
    public mutating func apply(_ note: Note) {
        if let index = notes.firstIndex(where: { $0.id == note.id }) {
            guard note.version >= notes[index].version else { return }
            // `seen_at` is set without a version bump; keep it once known.
            var merged = note
            if merged.seenAt == nil { merged.seenAt = notes[index].seenAt }
            notes[index] = merged
        } else {
            notes.append(note)
        }
        notes.sort { ($0.createdAt, $0.id.uuidString) > ($1.createdAt, $1.id.uuidString) }
    }

    public mutating func remove(id: UUID) {
        notes.removeAll { $0.id == id }
    }

    public var visible: [Note] {
        notes.filter { !$0.isDeleted }
    }

    /// The most recent note written by someone other than `userID`.
    public func latestReceived(by userID: UUID) -> Note? {
        visible.first { $0.authorID != userID }
    }

    public func latestSent(by userID: UUID) -> Note? {
        visible.first { $0.authorID == userID }
    }

    public func unseenCount(for userID: UUID) -> Int {
        visible.filter { $0.authorID != userID && $0.seenAt == nil }.count
    }

    public var oldest: Note? { notes.last }
}

// MARK: - Send queue

/// A note waiting to reach the server. Its id is fixed when it is created, so
/// however many times the send is retried the server can only ever store it once.
public struct PendingSend: Identifiable, Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        case waiting, uploading, sending, failed
    }

    public let id: UUID
    public let coupleID: UUID
    public var content: NoteContent
    /// Local files still to upload, keyed by the storage path they will take.
    public var photoFile: String?
    public var drawingFile: String?
    public var state: State
    public var attempts: Int
    public var createdAt: Date

    public init(
        id: UUID = UUID(), coupleID: UUID, content: NoteContent, photoFile: String? = nil,
        drawingFile: String? = nil, state: State = .waiting, attempts: Int = 0, createdAt: Date
    ) {
        self.id = id
        self.coupleID = coupleID
        self.content = content
        self.photoFile = photoFile
        self.drawingFile = drawingFile
        self.state = state
        self.attempts = attempts
        self.createdAt = createdAt
    }

    /// Seconds to wait before the next automatic attempt: 2, 4, 8 … capped at a minute.
    public var retryDelay: TimeInterval {
        min(60, pow(2, Double(max(1, attempts))))
    }

    public static let maximumAutomaticAttempts = 6

    public var shouldRetryAutomatically: Bool {
        attempts < Self.maximumAutomaticAttempts
    }
}

public enum MediaPath {
    /// `couples/<couple>/<uuid>.jpg` — the only shape the storage policy accepts.
    public static func photo(coupleID: UUID, id: UUID = UUID()) -> String {
        "couples/\(coupleID.uuidString.lowercased())/\(id.uuidString.lowercased()).jpg"
    }

    public static func drawing(coupleID: UUID, id: UUID = UUID()) -> String {
        "couples/\(coupleID.uuidString.lowercased())/\(id.uuidString.lowercased()).png"
    }

    public static func avatar(userID: UUID) -> String {
        "\(userID.uuidString.lowercased())/avatar.jpg"
    }

    public static let maximumMediaBytes = 5 * 1024 * 1024
    public static let maximumAvatarBytes = 1024 * 1024
}
