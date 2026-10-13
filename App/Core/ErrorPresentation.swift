import CoupleDomain
import OSLog
import SwiftUI

extension AppError {
    /// What the person is told. Plain, specific, and says what to do next
    /// wherever there is something they can do.
    var message: LocalizedStringKey {
        switch self {
        case .offline: "You’re offline. We’ll keep this safe until you’re back."
        case .timedOut: "That took too long. Check your connection and try again."
        case .sessionExpired: "This phone is no longer connected to your space."
        case .notConfigured: "This build isn’t connected to a server yet."

        case .appleSignInUnavailable: "Sign in with Apple isn’t available right now."
        case .backupAlreadyInUse: "That Apple ID already backs up a different space. To use it here, restore that space instead."

        case .invitationUnavailable: "That invitation can’t be used. Ask your partner for a new one."
        case .invitationExpired: "That invitation has expired. Ask your partner for a new one."
        case .ownInvitation: "That’s your own invitation. Send it to your partner."
        case .alreadyPaired: "You’re already connected to a partner."
        case .alreadyInSpace: "You already have a space."
        case .noSpace: "You’re not in a shared space yet."
        case .rateLimited: "Too many tries. Please wait a few minutes."

        case .noteNotFound: "That’s no longer available."
        case .notAuthor: "Only the person who wrote this can change it."
        case .versionConflict: "This was changed somewhere else. We’ve loaded the latest version."
        case .invalidContent(.empty): "Add some words, a drawing or a photo first."
        case .invalidContent(.tooLong(let limit)): "Notes can be up to \(limit) characters."
        case .invalidContent(.tooManyStickers(let limit)): "A note can hold up to \(limit) stickers."
        case .mediaTooLarge: "That image is too large to send."
        case .mediaUnreadable: "That image couldn’t be opened."
        case .uploadFailed: "The upload didn’t finish. Try again."

        case .momentUnavailable: "That question isn’t available any more."
        case .momentNotReady: "This opens once you’ve both answered."
        case .momentClosed: "That day has passed. There’s a new question waiting."
        case .momentAlreadyRevealed: "This has already been opened, so the answers can’t change now."
        case .invalidAnswer(let limit): "Write something, up to \(limit) characters."

        case .deliveryTooSoon: "Pick a time at least a few minutes from now."
        case .deliveryTooFar: "Pick a time within the next two years."
        case .scheduleNotEditable: "This has already been delivered or cancelled."

        case .memoryLimitReached: "Your scrapbook is full on the free plan."
        case .scheduledLimitReached: "You already have a surprise waiting. Premium lets you plan more."
        case .dateLimitReached: "You’ve reached the limit for saved dates."
        case .premiumRequired: "That’s part of Premium."

        case .purchaseFailed: "The purchase didn’t go through. You haven’t been charged."
        case .purchasePending: "Your purchase is waiting for approval. Premium will unlock once it’s approved."
        case .purchaseNotVerified: "We couldn’t verify that purchase with Apple."
        case .purchaseBelongsToAnotherAccount: "That subscription is linked to a different account."
        case .productsUnavailable: "Subscriptions aren’t available right now. Try again later."

        case .unexpected: "Something went wrong. Please try again."
        }
    }

    /// A short tag for logs. Never includes user content.
    var diagnosticCode: String {
        if case .unexpected(let code) = self { return "unexpected:\(code)" }
        return String(describing: self).components(separatedBy: "(").first ?? "error"
    }
}

/// Structured diagnostics. The rule for everything logged through here: codes
/// and counts only. No note text, names, emails, invitation codes or tokens.
enum Diagnostics {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "app"

    static let session = Logger(subsystem: subsystem, category: "session")
    static let sync = Logger(subsystem: subsystem, category: "sync")
    static let media = Logger(subsystem: subsystem, category: "media")
    static let widget = Logger(subsystem: subsystem, category: "widget")
    static let push = Logger(subsystem: subsystem, category: "push")
    static let store = Logger(subsystem: subsystem, category: "purchases")

    /// A step-by-step trace for diagnosing background behaviour on a device.
    /// States and step names only; never content.
    static func trace(_ message: String) {
        push.notice("\(message, privacy: .public)")
        #if DEBUG
        FileHandle.standardError.write(Data("[trace] \(message)\n".utf8))
        #endif
    }

    static func failure(_ logger: Logger, _ operation: StaticString, _ error: Error) {
        let code = (error as? AppError)?.diagnosticCode ?? String(describing: type(of: error))
        logger.error("\(operation, privacy: .public) failed: \(code, privacy: .public)")
    }
}

/// Runs a throwing operation and converts whatever it throws into an AppError.
func appError(from error: Error) -> AppError {
    (error as? AppError) ?? .unexpected(code: String(describing: type(of: error)))
}

/// The usual lifecycle of something fetched from the server.
enum LoadState: Equatable {
    case idle
    case loading
    case loaded
    case failed(AppError)

    var isLoading: Bool { self == .loading }
    var error: AppError? {
        if case .failed(let error) = self { error } else { nil }
    }
}
