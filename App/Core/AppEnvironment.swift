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
    let together: TogetherStore
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

    /// The one environment for the process. The app delegate needs it before
    /// any window exists: iOS can launch the app in the background, with no
    /// scene at all, purely to handle a push.
    static let shared = AppEnvironment()

    private var startTask: Task<Void, Never>?
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
        together = TogetherStore(backend: self.backend, defaults: defaults)
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

    /// Safe to call from several places at once: everyone waits for the same
    /// start-up to finish.
    func start() async {
        if let startTask {
            await startTask.value
            return
        }
        let task = Task { await self.performStart() }
        startTask = task
        await task.value
    }

    private func performStart() async {
        guard !hasStarted else { return }
        hasStarted = true

        session.onRefreshed = { [weak self] in self?.sessionDidRefresh() }
        session.onSignedOut = { [weak self] in self?.wipeAccountData() }
        notes.onChanged = { [weak self] in self?.publishWidget() }
        notifications.onOpen = { [weak self] link in self?.router.open(link) }
        notifications.onRemoteChange = { [weak self] in await self?.refreshContent() }
        notifications.activate()
        purchases.start()
        #if DEBUG
        // Development aid: ask the store for the products at launch, so the
        // result can be read from the console without opening the paywall.
        if ProcessInfo.processInfo.arguments.contains("-probeProducts") {
            Task { await purchases.loadProducts() }
            StoreProbe.shared.run()
        }
        #endif

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
            await widgets.configureRemoteIfNeeded(backend: backend, configuration: configuration)
            await widgets.registerWidgetPush(environment: configuration.pushEnvironment)
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
        async let together: Void = together.load()
        _ = await (notes, dates, memories, schedule, together)
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
        case .togetherChanged:
            await together.refresh()
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
        await together.refresh()
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

    func publishWidgetAndWait() async {
        await widgets.publishAndWait(session: session, notes: notes)
    }

    /// Handles a push that arrived while the app was not on screen: make sure
    /// the app has started, fetch the current notes, and put them on the widget.
    func handleBackgroundPush() async -> Bool {
        Diagnostics.trace("push: background wake")
        await start()
        guard session.userID != nil else {
            Diagnostics.trace("push: no session, nothing to refresh")
            return false
        }
        await session.refresh()
        if session.phase == .paired, let coupleID = session.coupleID {
            await notes.load(coupleID: coupleID)
        }
        await publishWidgetAndWait()
        Diagnostics.trace("push: widget published, state=\(widgets.lastState)")
        return true
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
        together.reset()
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
        try await session.signOut { [notifications, widgets, backend] in
            await notifications.unregisterDevice()
            // While the session can still authorise it: after sign-out the
            // widget must not be able to fetch anything.
            await widgets.revokeRemote(backend: backend)
        }
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
            memories: stub, dates: stub, schedule: stub, notifications: stub, entitlements: stub,
            together: stub, isDemo: false
        )
    }

    private final class Stub: Sendable, AuthRepository, ProfileRepository, CoupleRepository, NoteRepository, RealtimeRepository,
        MediaRepository, MemoryRepository, DatesRepository, ScheduleRepository, NotificationRepository, EntitlementRepository,
        TogetherRepository {
        private var fail: AppError { .notConfigured }

        func restoreSession() async -> AuthState { .signedOut }
        func stateChanges() -> AsyncStream<AuthState> { AsyncStream { $0.finish() } }
        func startAnonymously() async throws { throw fail }
        func backUpWithApple(idToken: String, nonce: String) async throws { throw fail }
        func restoreWithApple(idToken: String, nonce: String) async throws { throw fail }
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
        func today() async throws -> TogetherMoment? { throw fail }
        func submit(momentID: UUID, answer: String) async throws -> TogetherMoment { throw fail }
        func reveal(momentID: UUID) async throws -> TogetherMoment { throw fail }
        func moment(id: UUID) async throws -> TogetherMoment { throw fail }
        func history(before: DayDate?, limit: Int) async throws -> [TogetherMoment] { throw fail }
        func saveToMemories(momentID: UUID) async throws -> UUID { throw fail }
        func removeFromMemories(momentID: UUID) async throws { throw fail }
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
        func issueWidgetToken() async throws -> String { throw fail }
        func revokeWidgetToken(_ token: String) async throws { throw fail }
        func entitlement() async throws -> Entitlement { throw fail }
        func submitTransaction(jws: String) async throws -> Entitlement { throw fail }
    }
}
