import Foundation

// The data-access boundary. Feature code depends on these protocols only; it
// never imports Supabase. Every method throws `AppError`.

public enum AuthState: Equatable, Sendable {
    case signedOut
    case signedIn(userID: UUID, email: String?)

    public var userID: UUID? {
        if case .signedIn(let id, _) = self { id } else { nil }
    }
}

public enum SignUpOutcome: Equatable, Sendable {
    case signedIn
    /// The project requires email confirmation; a code has been sent.
    case confirmationRequired
}

public protocol AuthRepository: Sendable {
    /// Restores a stored session, refreshing it if needed.
    func restoreSession() async -> AuthState
    /// Emits whenever the session starts, ends or is lost (expiry, remote sign-out).
    func stateChanges() -> AsyncStream<AuthState>

    func signUp(email: String, password: String, displayName: String) async throws -> SignUpOutcome
    func confirmSignUp(email: String, code: String) async throws
    func resendConfirmation(email: String) async throws
    func signIn(email: String, password: String) async throws
    func signInWithApple(idToken: String, nonce: String, displayName: String?) async throws
    func requestPasswordReset(email: String) async throws
    func resetPassword(email: String, code: String, newPassword: String) async throws
    func changePassword(to newPassword: String) async throws
    func signOut() async throws

    /// Permanently deletes the account and the data it owns.
    func deleteAccount() async throws
    /// Everything the signed-in person has authored, as a JSON document.
    func exportData() async throws -> Data
}

public protocol ProfileRepository: Sendable {
    func myProfile() async throws -> Profile
    func updateProfile(displayName: String?, timeZone: String?) async throws -> Profile
    func setAvatar(jpeg: Data) async throws -> Profile
    func removeAvatar() async throws -> Profile
}

public protocol CoupleRepository: Sendable {
    func spaceState() async throws -> SpaceState
    func createSpace() async throws
    func createInvitation() async throws -> IssuedInvitation
    func revokeInvitation(id: UUID) async throws
    func previewInvitation(code: String) async throws -> InvitationPreview
    func acceptInvitation(code: String) async throws
    func declineInvitation(code: String) async throws
    /// Ends the space for both partners. Does not delete either account.
    func leaveSpace(blockPartner: Bool) async throws
    func setTheme(id: String, accentHex: String?) async throws
}

public protocol NoteRepository: Sendable {
    /// Newest first. Includes tombstones so callers can retire deleted notes.
    func recentNotes(coupleID: UUID, before: Date?, limit: Int) async throws -> [Note]
    /// Idempotent: sending the same `id` again returns the stored note.
    func send(id: UUID, coupleID: UUID, content: NoteContent) async throws -> Note
    /// Fails with `.versionConflict` if the note changed since `expectedVersion`.
    func update(noteID: UUID, expectedVersion: Int, content: NoteContent) async throws -> Note
    func delete(noteID: UUID) async throws
    func markSeen(noteID: UUID) async throws
    func reactions(coupleID: UUID) async throws -> [Reaction]
    func setReaction(noteID: UUID, kind: ReactionKind?) async throws
}

/// Something changed in the shared space. Events carry as little as possible;
/// most just tell the app which list to fetch again.
public enum SpaceEvent: Equatable, Sendable {
    case note(Note)
    case reactionsChanged
    case spaceChanged
    case memoriesChanged
    case datesChanged
    /// The live connection was re-established; anything may have been missed.
    case resynchronise
}

public protocol RealtimeRepository: Sendable {
    /// A live stream of changes for one space. Ends when the consumer cancels.
    func events(coupleID: UUID) -> AsyncStream<SpaceEvent>
}

public protocol MediaRepository: Sendable {
    func upload(_ data: Data, to path: String, contentType: String) async throws
    func download(path: String) async throws -> Data
    func downloadAvatar(path: String) async throws -> Data
}

public protocol MemoryRepository: Sendable {
    func memories(coupleID: UUID, after cursor: MemoryCursor?, limit: Int) async throws -> [Memory]
    func count(coupleID: UUID) async throws -> Int
    /// Idempotent per note: saving twice returns the same memory.
    func saveNote(noteID: UUID, caption: String) async throws -> UUID
    func add(_ moment: NewMoment, coupleID: UUID) async throws -> Memory
    func update(id: UUID, title: String, caption: String, occurredOn: DayDate) async throws -> Memory
    func deleteMemory(id: UUID) async throws
}

public protocol DatesRepository: Sendable {
    func dates(coupleID: UUID) async throws -> [ImportantDate]
    func add(_ date: ImportantDate) async throws -> ImportantDate
    func update(_ date: ImportantDate) async throws -> ImportantDate
    func deleteDate(id: UUID) async throws
}

public protocol ScheduleRepository: Sendable {
    /// The signed-in person's own scheduled messages, soonest first.
    func scheduledMessages() async throws -> [ScheduledMessage]
    func schedule(id: UUID, coupleID: UUID, content: NoteContent, deliverAt: Date, timeZone: String) async throws -> ScheduledMessage
    func update(id: UUID, expectedVersion: Int, content: NoteContent, deliverAt: Date, timeZone: String) async throws -> ScheduledMessage
    func cancel(id: UUID) async throws
}

public protocol NotificationRepository: Sendable {
    func preferences() async throws -> NotificationPreferences
    func update(_ preferences: NotificationPreferences) async throws
    func registerDevice(token: String, environment: PushEnvironment) async throws
    func unregisterDevice(token: String) async throws
}

public protocol EntitlementRepository: Sendable {
    func entitlement() async throws -> Entitlement
    /// Hands a StoreKit-signed transaction to the server, which verifies
    /// Apple's signature itself before recording anything.
    func submitTransaction(jws: String) async throws -> Entitlement
}

/// The complete set of repositories the app runs on.
public struct Backend: Sendable {
    public let auth: any AuthRepository
    public let profiles: any ProfileRepository
    public let couples: any CoupleRepository
    public let notes: any NoteRepository
    public let realtime: any RealtimeRepository
    public let media: any MediaRepository
    public let memories: any MemoryRepository
    public let dates: any DatesRepository
    public let schedule: any ScheduleRepository
    public let notifications: any NotificationRepository
    public let entitlements: any EntitlementRepository
    /// True for the in-memory backend. Nothing leaves the device and nothing
    /// is kept; the app says so wherever it matters.
    public let isDemo: Bool

    public init(
        auth: any AuthRepository, profiles: any ProfileRepository, couples: any CoupleRepository,
        notes: any NoteRepository, realtime: any RealtimeRepository, media: any MediaRepository,
        memories: any MemoryRepository, dates: any DatesRepository, schedule: any ScheduleRepository,
        notifications: any NotificationRepository, entitlements: any EntitlementRepository, isDemo: Bool
    ) {
        self.auth = auth
        self.profiles = profiles
        self.couples = couples
        self.notes = notes
        self.realtime = realtime
        self.media = media
        self.memories = memories
        self.dates = dates
        self.schedule = schedule
        self.notifications = notifications
        self.entitlements = entitlements
        self.isDemo = isDemo
    }
}
