import CoupleDomain
import Foundation
import Supabase

// Wire formats. Each row type mirrors one table (snake_case, exactly the
// columns the app is granted) and converts to its domain model. Nothing
// outside this module sees these types.

struct ProfileRow: Decodable {
    let id: UUID
    let display_name: String
    let avatar_path: String?
    let avatar_version: Int?
    let time_zone: String

    var model: Profile {
        Profile(id: id, displayName: display_name, avatarPath: avatar_path, avatarVersion: avatar_version ?? 0, timeZone: time_zone)
    }
}

struct StreakPayload: Decodable {
    let days: Int
    let me_today: Bool
    let partner_today: Bool
}

struct CoupleSpaceRow: Decodable {
    let id: UUID
    let theme_id: String
    let accent_hex: String?
    let paired_at: Date?
    let created_at: Date

    var model: CoupleSpace {
        CoupleSpace(id: id, themeID: theme_id, accentHex: accent_hex, pairedAt: paired_at, createdAt: created_at)
    }
}

struct MemberRow: Decodable {
    let user_id: UUID
    let profile: ProfileRow?
}

struct NoteRow: Decodable {
    let id: UUID
    let couple_id: UUID
    let author_id: UUID?
    let body: String
    let style: NoteStyle
    let photo_path: String?
    let drawing_path: String?
    let origin: String
    let version: Int
    let seen_at: Date?
    let deleted_at: Date?
    let created_at: Date
    let updated_at: Date

    var model: Note {
        Note(
            id: id, coupleID: couple_id, authorID: author_id, body: body, style: style,
            photoPath: photo_path, drawingPath: drawing_path, origin: Note.Origin(rawValue: origin) ?? .direct,
            version: version, seenAt: seen_at, deletedAt: deleted_at, createdAt: created_at, updatedAt: updated_at
        )
    }
}

struct NoteInsert: Encodable {
    let id: UUID
    let couple_id: UUID
    let author_id: UUID
    let body: String
    let style: NoteStyle
    let photo_path: String?
    let drawing_path: String?
}

struct ReactionRow: Decodable {
    let note_id: UUID
    let user_id: UUID
    let kind: String

    var model: Reaction? {
        ReactionKind(rawValue: kind).map { Reaction(noteID: note_id, userID: user_id, kind: $0) }
    }
}

struct MemoryRow: Decodable {
    let id: UUID
    let couple_id: UUID
    let created_by: UUID?
    let kind: String
    let title: String
    let caption: String
    let body: String
    let style: NoteStyle
    let photo_path: String?
    let drawing_path: String?
    let source_note_id: UUID?
    let occurred_on: DayDate
    let created_at: Date

    var model: Memory {
        Memory(
            id: id, coupleID: couple_id, createdBy: created_by, kind: Memory.Kind(rawValue: kind) ?? .moment,
            title: title, caption: caption,
            content: NoteContent(body: body, style: style, photoPath: photo_path, drawingPath: drawing_path),
            sourceNoteID: source_note_id, occurredOn: occurred_on, createdAt: created_at
        )
    }
}

struct MemoryInsert: Encodable {
    let id: UUID
    let couple_id: UUID
    let created_by: UUID
    let kind: String
    let title: String
    let caption: String
    let photo_path: String?
    let drawing_path: String?
    let occurred_on: DayDate
}

struct MemoryUpdate: Encodable {
    let title: String
    let caption: String
    let occurred_on: DayDate
}

struct ImportantDateRow: Codable {
    let id: UUID
    let couple_id: UUID
    let created_by: UUID
    let title: String
    let kind: String
    let starts_on: DayDate
    let recurrence: String
    let visibility: String
    let notify: Bool
    let remind_days_before: [Int]

    init(_ date: ImportantDate, createdBy: UUID) {
        id = date.id
        couple_id = date.coupleID
        created_by = createdBy
        title = date.title
        kind = date.kind.rawValue
        starts_on = date.startsOn
        recurrence = date.recurrence.rawValue
        visibility = date.visibility.rawValue
        notify = date.notify
        remind_days_before = DateRules.sanitizedReminders(date.remindDaysBefore)
    }

    var model: ImportantDate {
        ImportantDate(
            id: id, coupleID: couple_id, createdBy: created_by, title: title,
            kind: ImportantDate.Kind(rawValue: kind) ?? .custom, startsOn: starts_on,
            recurrence: ImportantDate.Recurrence(rawValue: recurrence) ?? .yearly,
            visibility: ImportantDate.Visibility(rawValue: visibility) ?? .shared,
            notify: notify, remindDaysBefore: remind_days_before
        )
    }
}

struct ImportantDateUpdate: Encodable {
    let title: String
    let kind: String
    let starts_on: DayDate
    let recurrence: String
    let visibility: String
    let notify: Bool
    let remind_days_before: [Int]

    init(_ date: ImportantDate) {
        title = date.title
        kind = date.kind.rawValue
        starts_on = date.startsOn
        recurrence = date.recurrence.rawValue
        visibility = date.visibility.rawValue
        notify = date.notify
        remind_days_before = DateRules.sanitizedReminders(date.remindDaysBefore)
    }
}

struct ScheduledRow: Decodable {
    let id: UUID
    let couple_id: UUID
    let body: String
    let style: NoteStyle
    let photo_path: String?
    let drawing_path: String?
    let deliver_at: Date
    let time_zone: String
    let status: String
    let failure_reason: String?
    let version: Int
    let created_at: Date

    var model: ScheduledMessage {
        ScheduledMessage(
            id: id, coupleID: couple_id,
            content: NoteContent(body: body, style: style, photoPath: photo_path, drawingPath: drawing_path),
            deliverAt: deliver_at, timeZone: time_zone,
            status: ScheduledMessage.Status(rawValue: status) ?? .failed,
            failureReason: failure_reason, version: version, createdAt: created_at
        )
    }
}

struct ScheduledInsert: Encodable {
    let id: UUID
    let couple_id: UUID
    let author_id: UUID
    let body: String
    let style: NoteStyle
    let photo_path: String?
    let drawing_path: String?
    let deliver_at: Date
    let time_zone: String
}

struct PreferencesRow: Codable {
    let new_notes: Bool
    let surprises: Bool
    let important_dates: Bool
    let pairing: Bool
    let account: Bool
    let show_previews: Bool

    init(_ preferences: NotificationPreferences) {
        new_notes = preferences.newNotes
        surprises = preferences.surprises
        important_dates = preferences.importantDates
        pairing = preferences.pairing
        account = preferences.account
        show_previews = preferences.showPreviews
    }

    var model: NotificationPreferences {
        NotificationPreferences(
            newNotes: new_notes, surprises: surprises, importantDates: important_dates,
            pairing: pairing, account: account, showPreviews: show_previews
        )
    }
}

struct EntitlementPayload: Decodable {
    let is_premium: Bool
    let source: String?
    let expires_at: Date?

    var model: Entitlement {
        Entitlement(isPremium: is_premium, source: source.flatMap(Entitlement.Source.init), expiresAt: expires_at)
    }
}

/// The `{ ok, error, … }` object the pairing functions return.
struct PairingResult: Decodable {
    let ok: Bool
    let error: String?
    let inviter_name: String?
    let expires_at: Date?

    func requireSuccess() throws {
        guard ok else {
            throw error.flatMap(AppError.init(serverMessage:)) ?? AppError.unexpected(code: "pairing")
        }
    }
}

struct IssuedInvitationPayload: Decodable {
    let id: UUID
    let code: String
    let expires_at: Date
}

// MARK: - RPC parameters

struct CodeParams: Encodable { let p_code: String }
struct InvitationIDParams: Encodable { let p_invitation_id: UUID }
struct LeaveParams: Encodable { let p_block_partner: Bool }
struct NoteIDParams: Encodable { let p_note_id: UUID }
struct IDParams: Encodable { let p_id: UUID }
struct TokenParams: Encodable { let p_token: String }
struct RegisterTokenParams: Encodable { let p_token: String; let p_environment: String }
struct SaveNoteParams: Encodable { let p_note_id: UUID; let p_caption: String }

struct ThemeParams: Encodable {
    let p_theme_id: String
    let p_accent_hex: String?

    // Send an explicit null so the function clears the accent.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(p_theme_id, forKey: .p_theme_id)
        try container.encode(p_accent_hex, forKey: .p_accent_hex)
    }

    enum CodingKeys: String, CodingKey { case p_theme_id, p_accent_hex }
}

struct ReactionParams: Encodable {
    let p_note_id: UUID
    let p_kind: String?

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(p_note_id, forKey: .p_note_id)
        try container.encode(p_kind, forKey: .p_kind)
    }

    enum CodingKeys: String, CodingKey { case p_note_id, p_kind }
}

struct UpdateNoteParams: Encodable {
    let p_note_id: UUID
    let p_expected_version: Int
    let p_body: String
    let p_style: NoteStyle
    let p_photo_path: String?
    let p_drawing_path: String?

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(p_note_id, forKey: .p_note_id)
        try container.encode(p_expected_version, forKey: .p_expected_version)
        try container.encode(p_body, forKey: .p_body)
        try container.encode(p_style, forKey: .p_style)
        try container.encode(p_photo_path, forKey: .p_photo_path)
        try container.encode(p_drawing_path, forKey: .p_drawing_path)
    }

    enum CodingKeys: String, CodingKey {
        case p_note_id, p_expected_version, p_body, p_style, p_photo_path, p_drawing_path
    }
}

struct UpdateScheduledParams: Encodable {
    let p_id: UUID
    let p_expected_version: Int
    let p_body: String
    let p_style: NoteStyle
    let p_photo_path: String?
    let p_drawing_path: String?
    let p_deliver_at: Date
    let p_time_zone: String

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(p_id, forKey: .p_id)
        try container.encode(p_expected_version, forKey: .p_expected_version)
        try container.encode(p_body, forKey: .p_body)
        try container.encode(p_style, forKey: .p_style)
        try container.encode(p_photo_path, forKey: .p_photo_path)
        try container.encode(p_drawing_path, forKey: .p_drawing_path)
        try container.encode(p_deliver_at, forKey: .p_deliver_at)
        try container.encode(p_time_zone, forKey: .p_time_zone)
    }

    enum CodingKeys: String, CodingKey {
        case p_id, p_expected_version, p_body, p_style, p_photo_path, p_drawing_path, p_deliver_at, p_time_zone
    }
}

// MARK: - Error translation

enum SupabaseErrorMapper {
    /// Translates anything the SDK can throw into the app's own vocabulary.
    /// Unrecognised errors carry a short code for diagnostics, never a message
    /// that might echo user content back into a log.
    static func map(_ error: Error) -> AppError {
        if let known = error as? AppError { return known }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut: return .timedOut
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .cannotFindHost,
                 .cannotConnectToHost, .dnsLookupFailed, .internationalRoamingOff, .secureConnectionFailed:
                return .offline
            default: return .unexpected(code: "url:\(urlError.code.rawValue)")
            }
        }

        if let postgrest = error as? PostgrestError {
            if let mapped = AppError(serverMessage: postgrest.message) { return mapped }
            switch postgrest.code {
            case "PGRST301", "PGRST302", "PGRST303": return .sessionExpired
            case "23514":
                if postgrest.message.contains("has_content") { return .invalidContent(.empty) }
                if postgrest.message.contains("body_check") { return .invalidContent(.tooLong(limit: Validation.noteBodyLimit)) }
                return .unexpected(code: "pg:23514")
            case "42501": return .noteNotFound
            default: return .unexpected(code: "pg:\(postgrest.code ?? "unknown")")
            }
        }

        if let auth = error as? AuthError {
            switch auth {
            case .sessionMissing:
                return .sessionExpired
            case .api(_, let code, _, _):
                switch code {
                case .identityAlreadyExists, .emailExists, .userAlreadyExists:
                    return .backupAlreadyInUse
                case .anonymousProviderDisabled, .providerDisabled:
                    return .notConfigured
                case .overRequestRateLimit, .overEmailSendRateLimit:
                    return .rateLimited
                case .sessionNotFound, .refreshTokenNotFound, .refreshTokenAlreadyUsed, .sessionExpired, .userNotFound:
                    return .sessionExpired
                default:
                    return .unexpected(code: "auth:\(code.rawValue)")
                }
            default:
                return .unexpected(code: "auth")
            }
        }

        if let storage = error as? StorageError {
            switch storage.statusCode {
            case "413": return .mediaTooLarge
            case "404", "400", "403": return .mediaUnreadable
            default: return .unexpected(code: "storage:\(storage.statusCode ?? "unknown")")
            }
        }

        if let functions = error as? FunctionsError {
            if case .httpError(let status, let data) = functions {
                struct Body: Decodable { let error: String? }
                let code = (try? JSONDecoder().decode(Body.self, from: data))?.error
                switch code {
                case "owned_by_other_account": return .purchaseBelongsToAnotherAccount
                case "verification_failed", "invalid_transaction": return .purchaseNotVerified
                default: break
                }
                if let code, let mapped = AppError(serverMessage: code) { return mapped }
                if status == 401 { return .sessionExpired }
                return .unexpected(code: "function:\(status)")
            }
            return .unexpected(code: "function")
        }

        if error is CancellationError { return .unexpected(code: "cancelled") }
        if error is DecodingError { return .unexpected(code: "decoding") }
        return .unexpected(code: String(describing: type(of: error)))
    }

    static func isDuplicate(_ error: Error) -> Bool {
        if let postgrest = error as? PostgrestError { return postgrest.code == "23505" }
        if let storage = error as? StorageError {
            return storage.statusCode == "409" || storage.error == "Duplicate"
        }
        return false
    }
}
