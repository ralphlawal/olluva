import CoupleDomain
import CoupleSupabase
import CoupleWidgetUI
import Foundation
import Observation
import SwiftUI

#if DEBUG
import CoupleLocalBackend
#endif

/// The composition root: builds the backend and every store once, wires them
/// together, and owns the cross-cutting behaviour (live sync, widget
/// publishing, what gets wiped when someone signs out).
@MainActor
@Observable
final class AppEnvironment {
    let configuration: AppConfiguration
    let backend: Backend
    let session: SessionStore
    let media: MediaStore
    let notes: NotesStore
    let memories: MemoriesStore
    let dates: DatesStore
    let schedule: ScheduleStore
    let purchases: PurchaseStore
    let notifications: NotificationCoordinator
    let settings: LocalSettings
    let router: AppRouter
    let widgets: WidgetBridge
    let drafts = DraftStorage()

    #if DEBUG
    /// Present only when running on the in-memory backend.
    let demo: DemoController?
    #endif

    private var syncTask: Task<Void, Never>?
    private var syncTarget: SyncTarget?

    private struct SyncTarget: Equatable {
        let coupleID: UUID
        let isPaired: Bool
    }
    private var hasStarted = false

    init(configuration: AppConfiguration = .current) {
        self.configuration = configuration

        var backend: Backend?
        #if DEBUG
        var demo: DemoController?
        if configuration.usesDemoBackend {
            let controller = DemoController(
                scenario: configuration.demoScenario, isUITesting: configuration.isUITesting,
                startsSignedOut: configuration.demoStartsSignedOut
            )
            backend = controller.backend
            demo = controller
        }
        self.demo = demo
        #endif
        if backend == nil, let supabase = configuration.supabase {
            backend = SupabaseBackendFactory.make(url: supabase.url, anonKey: supabase.anonKey)
        }
        // A release build with no configuration: every call fails with
        // `.notConfigured`, and the root view shows a screen saying so.
        self.backend = backend ?? UnconfiguredBackend.make()

        // UI tests start from a clean slate; anything left by a previous
        // launch (an unsent note, a draft) would make them order-dependent.
        let defaults: UserDefaults
        if configuration.isUITesting {
            let suite = "ui-testing"
            UserDefaults().removePersistentDomain(forName: suite)
            defaults = UserDefaults(suiteName: suite) ?? .standard
            OutboxStorage().removeAll()
            DraftStorage().clear()
        } else {
            defaults = .standard
        }

        settings = LocalSettings(defaults: defaults)
        if configuration.forcesDarkAppearance { settings.appearance = .dark }
        #if DEBUG
        if configuration.demoSendsFail { demo?.world.setSendFailure(.offline) }
        #endif
        router = AppRouter()
        session = SessionStore(backend: self.backend)
        media = MediaStore(backend: self.backend)
        notes = NotesStore(backend: self.backend, media: media)
        memories = MemoriesStore(backend: self.backend)
        dates = DatesStore(backend: self.backend)
        schedule = ScheduleStore(backend: self.backend, media: media)
        purchases = PurchaseStore(backend: self.backend, session: session)
        notifications = NotificationCoordinator(
            backend: self.backend, environment: configuration.pushEnvironment, defaults: defaults,
            isEnabled: !configuration.isUITesting
        )
        widgets = WidgetBridge(
            store: WidgetSnapshotStore(appGroupID: configuration.appGroupID), media: media, settings: settings
        )
    }

    /// Premium, from either the server's record or a purchase StoreKit has
    /// verified on this device. See `PurchaseStore` for why both exist.
    var entitlement: Entitlement {
        session.serverEntitlement.isPremium ? session.serverEntitlement : purchases.deviceEntitlement
    }

    // MARK: - Start-up

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true

        session.onRefreshed = { [weak self] in self?.sessionDidRefresh() }
        session.onSignedOut = { [weak self] in self?.wipeAccountData() }
        notes.onChanged = { [weak self] in self?.publishWidget() }
        notifications.onOpen = { [weak self] link in self?.router.open(link) }
        notifications.onRemoteChange = { [weak self] in await self?.refreshContent() }
        notifications.activate()
        purchases.start()

        await session.start(isMissingBackend: configuration.isMissingBackend)
        if session.userID == nil { widgets.clear() }
    }

    private func sessionDidRefresh() {
        // Listen to the space whether paired or still waiting alone in it, so
        // the app moves on the moment a partner joins.
        let target = session.coupleID.map { SyncTarget(coupleID: $0, isPaired: session.phase == .paired) }
        if target != syncTarget {
            let wasPaired = syncTarget?.isPaired == true
            syncTarget = target
            syncTask?.cancel()
            syncTask = nil
            if wasPaired, target?.isPaired != true {
                // The space ended (unlinked, or the partner left): nothing from
                // it may remain on this device.
                wipeSpaceData()
            }
            if let target { startSync(target) }
        }
        publishWidget()
        Task {
            await purchases.syncWithServer()
            await notifications.refreshAuthorization()
        }
    }

    // MARK: - Live sync

    private func startSync(_ target: SyncTarget) {
        let (coupleID, isPaired) = (target.coupleID, target.isPaired)
        let stream = backend.realtime.events(coupleID: coupleID)
        syncTask = Task { [weak self] in
            if isPaired { await self?.loadContent(coupleID: coupleID) }
            for await event in stream {
                await self?.handle(event, coupleID: coupleID)
            }
        }
    }

    private func loadContent(coupleID: UUID) async {
        async let notes: Void = notes.load(coupleID: coupleID)
        async let dates: Void = dates.load(coupleID: coupleID)
        async let memories: Void = memories.load(coupleID: coupleID)
        async let schedule: Void = schedule.load()
        _ = await (notes, dates, memories, schedule)
    }

    private func handle(_ event: SpaceEvent, coupleID: UUID) async {
        switch event {
        case .note, .reactionsChanged:
            await notes.apply(event)
        case .spaceChanged:
            await session.refresh()
        case .memoriesChanged:
            await memories.load(coupleID: coupleID)
        case .datesChanged:
            await dates.load(coupleID: coupleID)
        case .resynchronise:
            await session.refresh()
            if session.phase == .paired { await loadContent(coupleID: coupleID) }
        }
    }

    /// Called when the app comes to the foreground or a push says something
    /// changed. Realtime is not relied on to have delivered everything.
    func refreshContent() async {
        await session.refresh()
        guard session.phase == .paired, let coupleID = session.coupleID else { return }
        await notes.load(coupleID: coupleID)
        await schedule.load()
        notes.retryAllPending()
    }

    func sceneBecameActive() async {
        notifications.clearBadge()
        guard hasStarted, session.userID != nil else { return }
        await refreshContent()
        await purchases.refreshDeviceEntitlement()
        await notifications.refreshAuthorization()
    }

    // MARK: - Widget

    func publishWidget() {
        widgets.publish(session: session, notes: notes)
    }

    // MARK: - Links

    func open(_ url: URL) {
        guard let link = DeepLink(url: url) else { return }
        router.open(link)
    }

    // MARK: - Wiping

    /// Removes the shared space's content from this device.
    private func wipeSpaceData() {
        notes.purge()
        memories.reset()
        dates.reset()
        schedule.reset()
        media.clear()
        drafts.clear()
        router.reset()
    }

    /// Removes everything belonging to the account that just signed out.
    private func wipeAccountData() {
        syncTask?.cancel()
        syncTask = nil
        syncTarget = nil
        wipeSpaceData()
        purchases.reset()
        notifications.reset()
        settings.resetForSignOut()
        InvitationKeychain.removeAll()
        widgets.clear()
    }

    func signOut() async throws {
        try await session.signOut { [notifications] in await notifications.unregisterDevice() }
    }

    func deleteAccount() async throws {
        await notifications.unregisterDevice()
        try await session.deleteAccount()
    }
}

/// Stands in when a release build has no backend configured. Every call
/// fails loudly; nothing is simulated.
enum UnconfiguredBackend {
    static func make() -> Backend {
        let stub = Stub()
        return Backend(
            auth: stub, profiles: stub, couples: stub, notes: stub, realtime: stub, media: stub,
            memories: stub, dates: stub, schedule: stub, notifications: stub, entitlements: stub, isDemo: false
        )
    }

    private final class Stub: Sendable, AuthRepository, ProfileRepository, CoupleRepository, NoteRepository, RealtimeRepository,
        MediaRepository, MemoryRepository, DatesRepository, ScheduleRepository, NotificationRepository, EntitlementRepository {
        private var fail: AppError { .notConfigured }

        func restoreSession() async -> AuthState { .signedOut }
        func stateChanges() -> AsyncStream<AuthState> { AsyncStream { $0.finish() } }
        func signUp(email: String, password: String, displayName: String) async throws -> SignUpOutcome { throw fail }
        func confirmSignUp(email: String, code: String) async throws { throw fail }
        func resendConfirmation(email: String) async throws { throw fail }
        func signIn(email: String, password: String) async throws { throw fail }
        func signInWithApple(idToken: String, nonce: String, displayName: String?) async throws { throw fail }
        func requestPasswordReset(email: String) async throws { throw fail }
        func resetPassword(email: String, code: String, newPassword: String) async throws { throw fail }
        func changePassword(to newPassword: String) async throws { throw fail }
        func signOut() async throws { throw fail }
        func deleteAccount() async throws { throw fail }
        func exportData() async throws -> Data { throw fail }
        func myProfile() async throws -> Profile { throw fail }
        func updateProfile(displayName: String?, timeZone: String?) async throws -> Profile { throw fail }
        func setAvatar(jpeg: Data) async throws -> Profile { throw fail }
        func removeAvatar() async throws -> Profile { throw fail }
        func spaceState() async throws -> SpaceState { throw fail }
        func createSpace() async throws { throw fail }
        func createInvitation() async throws -> IssuedInvitation { throw fail }
        func revokeInvitation(id: UUID) async throws { throw fail }
        func previewInvitation(code: String) async throws -> InvitationPreview { throw fail }
        func acceptInvitation(code: String) async throws { throw fail }
        func declineInvitation(code: String) async throws { throw fail }
        func leaveSpace(blockPartner: Bool) async throws { throw fail }
        func setTheme(id: String, accentHex: String?) async throws { throw fail }
        func recentNotes(coupleID: UUID, before: Date?, limit: Int) async throws -> [Note] { throw fail }
        func send(id: UUID, coupleID: UUID, content: NoteContent) async throws -> Note { throw fail }
        func update(noteID: UUID, expectedVersion: Int, content: NoteContent) async throws -> Note { throw fail }
        func delete(noteID: UUID) async throws { throw fail }
        func markSeen(noteID: UUID) async throws { throw fail }
        func reactions(coupleID: UUID) async throws -> [Reaction] { throw fail }
        func setReaction(noteID: UUID, kind: ReactionKind?) async throws { throw fail }
        func events(coupleID: UUID) -> AsyncStream<SpaceEvent> { AsyncStream { $0.finish() } }
        func upload(_ data: Data, to path: String, contentType: String) async throws { throw fail }
        func download(path: String) async throws -> Data { throw fail }
        func downloadAvatar(path: String) async throws -> Data { throw fail }
        func memories(coupleID: UUID, after cursor: MemoryCursor?, limit: Int) async throws -> [Memory] { throw fail }
        func count(coupleID: UUID) async throws -> Int { throw fail }
        func saveNote(noteID: UUID, caption: String) async throws -> UUID { throw fail }
        func add(_ moment: NewMoment, coupleID: UUID) async throws -> Memory { throw fail }
        func update(id: UUID, title: String, caption: String, occurredOn: DayDate) async throws -> Memory { throw fail }
        func deleteMemory(id: UUID) async throws { throw fail }
        func dates(coupleID: UUID) async throws -> [ImportantDate] { throw fail }
        func add(_ date: ImportantDate) async throws -> ImportantDate { throw fail }
        func update(_ date: ImportantDate) async throws -> ImportantDate { throw fail }
        func deleteDate(id: UUID) async throws { throw fail }
        func scheduledMessages() async throws -> [ScheduledMessage] { throw fail }
        func schedule(id: UUID, coupleID: UUID, content: NoteContent, deliverAt: Date, timeZone: String) async throws -> ScheduledMessage { throw fail }
        func update(id: UUID, expectedVersion: Int, content: NoteContent, deliverAt: Date, timeZone: String) async throws -> ScheduledMessage { throw fail }
        func cancel(id: UUID) async throws { throw fail }
        func preferences() async throws -> NotificationPreferences { throw fail }
        func update(_ preferences: NotificationPreferences) async throws { throw fail }
        func registerDevice(token: String, environment: PushEnvironment) async throws { throw fail }
        func unregisterDevice(token: String) async throws { throw fail }
        func entitlement() async throws -> Entitlement { throw fail }
        func submitTransaction(jws: String) async throws -> Entitlement { throw fail }
    }
}
