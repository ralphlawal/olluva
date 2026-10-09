import Foundation

/// Every failure the app knows how to explain. Backends translate their own
/// errors into these; screens only ever present an `AppError`.
public enum AppError: Error, Equatable, Sendable {
    // Connectivity and session
    case offline
    case timedOut
    case sessionExpired
    case notConfigured

    // Authentication
    case invalidCredentials
    case emailAlreadyRegistered
    case emailNotConfirmed
    case invalidCode
    case weakPassword
    case appleSignInUnavailable

    // Pairing
    case invitationUnavailable
    case invitationExpired
    case ownInvitation
    case alreadyPaired
    case alreadyInSpace
    case noSpace
    case rateLimited

    // Content
    case noteNotFound
    case notAuthor
    /// Someone (or another of your devices) changed this since you opened it.
    case versionConflict
    case invalidContent(ContentIssue)
    case mediaTooLarge
    case mediaUnreadable
    case uploadFailed

    // Scheduling
    case deliveryTooSoon
    case deliveryTooFar
    case scheduleNotEditable

    // Limits and entitlement
    case memoryLimitReached
    case scheduledLimitReached
    case dateLimitReached
    case premiumRequired

    // Purchases
    case purchaseFailed
    case purchasePending
    case purchaseNotVerified
    case purchaseBelongsToAnotherAccount
    case productsUnavailable

    /// Anything unrecognised. `code` is a short diagnostic tag, never content.
    case unexpected(code: String)

    public enum ContentIssue: Equatable, Sendable {
        case empty
        case tooLong(limit: Int)
        case tooManyStickers(limit: Int)
    }

    /// Whether trying the same action again could plausibly succeed.
    public var isRetryable: Bool {
        switch self {
        case .offline, .timedOut, .uploadFailed, .unexpected, .productsUnavailable, .purchaseFailed:
            true
        default:
            false
        }
    }

    /// Maps the stable snake_case messages raised by the database functions.
    public init?(serverMessage: String) {
        let key = serverMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        switch key {
        case "not_authenticated": self = .sessionExpired
        case "invitation_unavailable": self = .invitationUnavailable
        case "invitation_expired": self = .invitationExpired
        case "own_invitation": self = .ownInvitation
        case "already_paired": self = .alreadyPaired
        case "already_in_space": self = .alreadyInSpace
        case "no_space": self = .noSpace
        case "rate_limited": self = .rateLimited
        case "note_not_found", "scheduled_not_found": self = .noteNotFound
        case "not_note_author", "not_date_owner", "cannot_react_to_own_note": self = .notAuthor
        case "version_conflict": self = .versionConflict
        case "deliver_at_too_soon": self = .deliveryTooSoon
        case "deliver_at_too_far": self = .deliveryTooFar
        case "scheduled_not_pending": self = .scheduleNotEditable
        case "memory_limit_reached": self = .memoryLimitReached
        case "scheduled_limit_reached": self = .scheduledLimitReached
        case "date_limit_reached": self = .dateLimitReached
        case "premium_required": self = .premiumRequired
        default: return nil
        }
    }
}
