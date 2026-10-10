import CoupleDomain
import CoupleLocalBackend
import CoupleWidgetUI
import XCTest
@testable import CoupleNotes

/// Two accounts paired in an in-memory world, with the app's stores built on
/// top exactly as the app builds them.
@MainActor
struct Fixture {
    let world = LocalWorld()
    let me: UUID
    let partner: UUID
    let couple: UUID
    let local: LocalBackend
    let partnerBackend: LocalBackend
    let backend: Backend
    let media: MediaStore
    let outboxDirectory: URL

    init() {
        me = world.addAccount(name: "Alex")
        partner = world.addAccount(name: "Sam")
        couple = world.pair(me, partner)
        local = LocalBackend(world: world, signedInAs: me)
        partnerBackend = LocalBackend(world: world, signedInAs: partner)
        backend = local.makeBackend()
        media = MediaStore(backend: backend)
        outboxDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("outbox-\(UUID().uuidString)")
    }

    func notesStore() -> NotesStore {
        NotesStore(backend: backend, media: media, outbox: OutboxStorage(directory: outboxDirectory))
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: outboxDirectory)
    }
}

@MainActor
final class NotesStoreTests: XCTestCase {
    private var fixture: Fixture!

    override func setUp() async throws {
        fixture = Fixture()
    }

    override func tearDown() async throws {
        fixture.cleanUp()
    }

    private func note(_ body: String) -> OutgoingNote {
        OutgoingNote(content: NoteContent(body: body))
    }

    func testSendingStoresTheNoteAndEmptiesTheOutbox() async throws {
        let store = fixture.notesStore()
        await store.load(coupleID: fixture.couple)
        let sent = try await store.send(note("hello"), coupleID: fixture.couple)

        XCTAssertEqual(store.latestSent(by: fixture.me)?.id, sent.id)
        XCTAssertTrue(store.pending.isEmpty)
        XCTAssertTrue(OutboxStorage(directory: fixture.outboxDirectory).load().isEmpty)
        XCTAssertEqual(fixture.world.noteCount(coupleID: fixture.couple), 1)
    }

    func testAFailedSendThrowsAndIsKeptForRetryNotReportedAsSent() async throws {
        let store = fixture.notesStore()
        await store.load(coupleID: fixture.couple)
        fixture.world.setSendFailure(.offline)

        do {
            _ = try await store.send(note("are you there"), coupleID: fixture.couple)
            XCTFail("send must throw when the server did not accept the note")
        } catch {
            XCTAssertEqual(error as? AppError, .offline)
        }
        XCTAssertNil(store.latestSent(by: fixture.me), "nothing may appear as sent")
        XCTAssertEqual(store.pending.map(\.state), [.failed])
        XCTAssertEqual(fixture.world.noteCount(coupleID: fixture.couple), 0)
    }

    func testAnUnsentNoteSurvivesRelaunchAndIsDeliveredExactlyOnce() async throws {
        let first = fixture.notesStore()
        await first.load(coupleID: fixture.couple)
        fixture.world.setSendFailure(.offline)
        _ = try? await first.send(
            OutgoingNote(content: NoteContent(body: "with a photo"), photo: Data([1, 2, 3])), coupleID: fixture.couple
        )
        let pendingID = try XCTUnwrap(first.pending.first?.id)
        first.reset() // the app is closed

        // Next launch: a new store finds the note on disk.
        let second = fixture.notesStore()
        await second.load(coupleID: fixture.couple)
        XCTAssertEqual(second.pending.map(\.id), [pendingID])

        fixture.world.setSendFailure(nil)
        try await second.retry(pendingID)
        // A stray duplicate attempt must not create a second note.
        _ = try? await second.send(note("with a photo"), coupleID: fixture.couple, id: pendingID)

        XCTAssertTrue(second.pending.isEmpty)
        XCTAssertEqual(fixture.world.noteCount(coupleID: fixture.couple), 1)
        let delivered = try XCTUnwrap(second.note(id: pendingID))
        XCTAssertNotNil(delivered.photoPath)
        let stored = try await fixture.partnerBackend.download(path: try XCTUnwrap(delivered.photoPath))
        XCTAssertEqual(stored, Data([1, 2, 3]))
    }

    func testANoteTheServerWillNeverAcceptIsNotLeftQueued() async throws {
        let store = fixture.notesStore()
        await store.load(coupleID: fixture.couple)
        do {
            _ = try await store.send(note("   "), coupleID: fixture.couple)
            XCTFail("an empty note is invalid")
        } catch {
            XCTAssertEqual(error as? AppError, .invalidContent(.empty))
        }
        XCTAssertTrue(store.pending.isEmpty)
    }

    func testDiscardingRemovesTheUnsentNoteFromDisk() async throws {
        let store = fixture.notesStore()
        await store.load(coupleID: fixture.couple)
        fixture.world.setSendFailure(.offline)
        _ = try? await store.send(note("never mind"), coupleID: fixture.couple)
        store.discard(try XCTUnwrap(store.pending.first?.id))
        XCTAssertTrue(store.pending.isEmpty)
        XCTAssertTrue(OutboxStorage(directory: fixture.outboxDirectory).load().isEmpty)
    }

    func testLiveEventsAndStaleEvents() async throws {
        let store = fixture.notesStore()
        await store.load(coupleID: fixture.couple)
        let incoming = try XCTUnwrap(fixture.world.deliverNote(from: fixture.partner, content: NoteContent(body: "v1")))
        await store.apply(.note(incoming))
        XCTAssertEqual(store.latestReceived(by: fixture.me)?.body, "v1")

        let edited = try await fixture.partnerBackend.update(noteID: incoming.id, expectedVersion: 1, content: NoteContent(body: "v2"))
        await store.apply(.note(edited))
        await store.apply(.note(incoming)) // a late duplicate of the old version
        XCTAssertEqual(store.latestReceived(by: fixture.me)?.body, "v2")
    }

    func testAStaleEditIsRefusedAndTheLatestVersionIsLoaded() async throws {
        let store = fixture.notesStore()
        await store.load(coupleID: fixture.couple)
        let original = try await store.send(note("first"), coupleID: fixture.couple)
        // The same account edits from another device.
        _ = try await LocalBackend(world: fixture.world, signedInAs: fixture.me)
            .update(noteID: original.id, expectedVersion: 1, content: NoteContent(body: "edited elsewhere"))

        do {
            _ = try await store.update(original, with: note("my stale edit"))
            XCTFail("a stale edit must not overwrite a newer one")
        } catch {
            XCTAssertEqual(error as? AppError, .versionConflict)
        }
        XCTAssertEqual(store.note(id: original.id)?.body, "edited elsewhere")
    }

    func testMarkSeenIsOnlyForReceivedNotes() async throws {
        let store = fixture.notesStore()
        await store.load(coupleID: fixture.couple)
        let mine = try await store.send(note("mine"), coupleID: fixture.couple)
        await store.markSeen(mine, by: fixture.me)
        XCTAssertNil(store.note(id: mine.id)?.seenAt)

        let theirs = try XCTUnwrap(fixture.world.deliverNote(from: fixture.partner, content: NoteContent(body: "theirs")))
        await store.apply(.note(theirs))
        XCTAssertEqual(store.feed.unseenCount(for: fixture.me), 1)
        await store.markSeen(theirs, by: fixture.me)
        XCTAssertEqual(store.feed.unseenCount(for: fixture.me), 0)
    }

    func testAReactionThatFailsIsRolledBack() async throws {
        let store = fixture.notesStore()
        await store.load(coupleID: fixture.couple)
        let theirs = try XCTUnwrap(fixture.world.deliverNote(from: fixture.partner, content: NoteContent(body: "hi")))
        await store.apply(.note(theirs))

        try await store.setReaction(.love, on: theirs, by: fixture.me)
        XCTAssertEqual(store.reaction(on: theirs.id, by: fixture.me), .love)

        fixture.world.setFailure(.offline)
        do {
            try await store.setReaction(.laugh, on: theirs, by: fixture.me)
            XCTFail("expected failure")
        } catch {}
        fixture.world.setFailure(nil)
        XCTAssertEqual(store.reaction(on: theirs.id, by: fixture.me), .love, "the failed change must not stick")
    }

    func testPurgeForgetsEverythingIncludingUnsentNotes() async throws {
        let store = fixture.notesStore()
        await store.load(coupleID: fixture.couple)
        _ = try await store.send(note("kept on server"), coupleID: fixture.couple)
        fixture.world.setSendFailure(.offline)
        _ = try? await store.send(note("unsent"), coupleID: fixture.couple)
        store.purge()
        XCTAssertTrue(store.feed.notes.isEmpty)
        XCTAssertTrue(store.pending.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.outboxDirectory.path))
    }
}

@MainActor
final class SessionStoreTests: XCTestCase {
    func testPhasesFollowAPersonFromFirstLaunchToPaired() async throws {
        let world = LocalWorld()
        let partner = world.addAccount(name: "Sam")
        world.addWaitingSpace(owner: partner, invitationCode: "SAMSAM2345")
        let local = LocalBackend(world: world)
        let session = SessionStore(backend: local.makeBackend())
        var signedOutCalls = 0
        session.onSignedOut = { signedOutCalls += 1 }

        await session.start(isMissingBackend: false)
        XCTAssertEqual(session.phase, .signedOut)

        // "Get started": no form, no email.
        try await local.startAnonymously()
        try await waitFor { session.phase == .unpaired }
        XCTAssertFalse(session.isBackedUp)
        XCTAssertTrue(session.needsDisplayName, "the only thing asked for is a name")

        session.setProfile(try await local.updateProfile(displayName: "Alex", timeZone: nil))
        XCTAssertFalse(session.needsDisplayName)

        try await local.acceptInvitation(code: "SAMSAM2345")
        await session.refresh()
        XCTAssertEqual(session.phase, .paired)
        XCTAssertEqual(session.partner?.id, partner)

        try await session.leaveSpace(blockPartner: false)
        XCTAssertEqual(session.phase, .unpaired)
        XCTAssertNil(session.partner)

        // The server ends the session: the person is told why.
        local.expireSession()
        try await waitFor { session.phase == .signedOut }
        XCTAssertTrue(session.sessionEndedUnexpectedly)
        XCTAssertNil(session.userID)
        XCTAssertEqual(signedOutCalls, 1)
    }

    func testBackingUpIsReflectedWithoutChangingIdentityOrSpace() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let session = SessionStore(backend: fixture.backend)
        await session.start(isMissingBackend: false)
        XCTAssertEqual(session.phase, .paired)
        XCTAssertFalse(session.isBackedUp)

        try await fixture.local.backUpWithApple(idToken: "apple-alex", nonce: "n")
        try await waitFor { session.isBackedUp }
        XCTAssertEqual(session.userID, fixture.me)
        XCTAssertEqual(session.phase, .paired)
    }

    func testRestoringOnANewPhoneLandsBackInTheSameSpace() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        try await fixture.local.backUpWithApple(idToken: "apple-alex", nonce: "n")

        let newPhone = LocalBackend(world: fixture.world)
        let session = SessionStore(backend: newPhone.makeBackend())
        await session.start(isMissingBackend: false)
        XCTAssertEqual(session.phase, .signedOut)

        try await newPhone.restoreWithApple(idToken: "apple-alex", nonce: "n2")
        try await waitFor { session.phase == .paired }
        XCTAssertEqual(session.userID, fixture.me)
        XCTAssertEqual(session.partner?.id, fixture.partner)
        XCTAssertTrue(session.isBackedUp)
    }

    func testADeliberateSignOutIsNotReportedAsUnexpected() async throws {
        let world = LocalWorld()
        let me = world.addAccount(name: "Alex", appleID: "apple-alex")
        let session = SessionStore(backend: LocalBackend(world: world, signedInAs: me).makeBackend())
        await session.start(isMissingBackend: false)
        XCTAssertEqual(session.phase, .unpaired)
        XCTAssertTrue(session.isBackedUp)
        try await session.signOut()
        XCTAssertEqual(session.phase, .signedOut)
        XCTAssertFalse(session.sessionEndedUnexpectedly)
    }

    func testAFailedFirstLoadIsShownAndCanBeRetried() async throws {
        let world = LocalWorld()
        let me = world.addAccount(name: "Alex")
        let session = SessionStore(backend: LocalBackend(world: world, signedInAs: me).makeBackend())
        world.setFailure(.offline)
        await session.start(isMissingBackend: false)
        XCTAssertEqual(session.phase, .loadFailed(.offline))
        world.setFailure(nil)
        await session.retryInitialLoad()
        XCTAssertEqual(session.phase, .unpaired)
    }

    func testAReleaseBuildWithNoBackendSaysSo() async {
        let session = SessionStore(backend: UnconfiguredBackend.make())
        await session.start(isMissingBackend: true)
        XCTAssertEqual(session.phase, .notConfigured)
    }

    func testAnIdentityWithNoNameIsAskedForOne() async {
        let world = LocalWorld()
        let me = world.addAccount(name: "")
        let session = SessionStore(backend: LocalBackend(world: world, signedInAs: me).makeBackend())
        await session.start(isMissingBackend: false)
        XCTAssertTrue(session.needsDisplayName)
    }

    private func waitFor(_ condition: @escaping () -> Bool) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "condition not met in time")
    }
}

@MainActor
final class WidgetBridgeTests: XCTestCase {
    private func makeStores(paired: Bool, signedIn: Bool = true) async -> (Fixture, SessionStore, NotesStore, WidgetBridge, LocalSettings) {
        let fixture = Fixture()
        if !paired {
            try? await fixture.local.leaveSpace(blockPartner: false)
        }
        if !signedIn {
            try? await fixture.local.signOut()
        }
        let session = SessionStore(backend: fixture.backend)
        await session.start(isMissingBackend: false)
        let notes = fixture.notesStore()
        let defaults = UserDefaults(suiteName: "widget-tests-\(UUID().uuidString)")!
        let settings = LocalSettings(defaults: defaults)
        let bridge = WidgetBridge(store: nil, media: fixture.media, settings: settings)
        return (fixture, session, notes, bridge, settings)
    }

    func testSnapshotStatesFollowTheSession() async {
        var (fixture, session, notes, bridge, _) = await makeStores(paired: true, signedIn: false)
        XCTAssertEqual(bridge.snapshot(session: session, notes: notes).state, .signedOut)
        fixture.cleanUp()

        (fixture, session, notes, bridge, _) = await makeStores(paired: false)
        XCTAssertEqual(bridge.snapshot(session: session, notes: notes).state, .unpaired)
        fixture.cleanUp()

        (fixture, session, notes, bridge, _) = await makeStores(paired: true)
        await notes.load(coupleID: fixture.couple)
        let empty = bridge.snapshot(session: session, notes: notes)
        XCTAssertEqual(empty.state, .empty)
        XCTAssertEqual(empty.partnerName, "Sam")
        fixture.cleanUp()
    }

    func testTheWidgetShowsThePartnersLatestNoteNeverYourOwn() async throws {
        let (fixture, session, notes, bridge, _) = await makeStores(paired: true)
        defer { fixture.cleanUp() }
        await notes.load(coupleID: fixture.couple)

        _ = try await notes.send(OutgoingNote(content: NoteContent(body: "from me")), coupleID: fixture.couple)
        XCTAssertEqual(bridge.snapshot(session: session, notes: notes).state, .empty)

        let theirs = try XCTUnwrap(fixture.world.deliverNote(from: fixture.partner, content: NoteContent(body: "from Sam")))
        await notes.apply(.note(theirs))
        let snapshot = bridge.snapshot(session: session, notes: notes)
        XCTAssertEqual(snapshot.note?.content.body, "from Sam")
        XCTAssertEqual(snapshot.note?.isUnseen, true)
        XCTAssertEqual(snapshot.deepLink, DeepLink.note(theirs.id).url)
    }

    func testADeletedNoteDisappearsFromTheWidget() async throws {
        let (fixture, session, notes, bridge, _) = await makeStores(paired: true)
        defer { fixture.cleanUp() }
        await notes.load(coupleID: fixture.couple)
        let older = try XCTUnwrap(fixture.world.deliverNote(from: fixture.partner, content: NoteContent(body: "older"), at: Date().addingTimeInterval(-60)))
        let newer = try XCTUnwrap(fixture.world.deliverNote(from: fixture.partner, content: NoteContent(body: "newer")))
        await notes.apply(.note(older))
        await notes.apply(.note(newer))
        XCTAssertEqual(bridge.snapshot(session: session, notes: notes).note?.content.body, "newer")

        try await fixture.partnerBackend.delete(noteID: newer.id)
        await notes.load(coupleID: fixture.couple)
        XCTAssertEqual(bridge.snapshot(session: session, notes: notes).note?.content.body, "older")
    }

    func testLockScreenPrivacyDefaultsToHiddenAndFollowsTheSetting() async {
        let (fixture, session, notes, bridge, settings) = await makeStores(paired: true)
        defer { fixture.cleanUp() }
        XCTAssertTrue(bridge.snapshot(session: session, notes: notes).hidesContentOnLockScreen)
        settings.hidesContentOnLockScreen = false
        settings.widgetStyle = .minimal
        let snapshot = bridge.snapshot(session: session, notes: notes)
        XCTAssertFalse(snapshot.hidesContentOnLockScreen)
        XCTAssertEqual(snapshot.style, .minimal)
    }
}

@MainActor
final class ContentStoreTests: XCTestCase {
    func testSchedulingRejectsAPastTimeBeforeTouchingTheServer() async {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let store = ScheduleStore(backend: fixture.backend, media: fixture.media)
        // If this reached the server it would fail with .offline instead.
        fixture.world.setFailure(.offline)
        do {
            try await store.schedule(OutgoingNote(content: NoteContent(body: "x")), coupleID: fixture.couple, deliverAt: Date())
            XCTFail("expected rejection")
        } catch {
            XCTAssertEqual(error as? AppError, .deliveryTooSoon)
        }
    }

    func testScheduleCancelAndStatusTracking() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let store = ScheduleStore(backend: fixture.backend, media: fixture.media)
        try await store.schedule(
            OutgoingNote(content: NoteContent(body: "later"), photo: Data([7])), coupleID: fixture.couple,
            deliverAt: Date().addingTimeInterval(3600)
        )
        XCTAssertEqual(store.pending.count, 1)
        XCTAssertNotNil(store.pending.first?.content.photoPath, "media is uploaded when scheduling, not at delivery")
        // The partner cannot see it.
        let partnerView = try await fixture.partnerBackend.scheduledMessages()
        XCTAssertTrue(partnerView.isEmpty)

        try await store.cancel(try XCTUnwrap(store.pending.first))
        XCTAssertTrue(store.pending.isEmpty)
        XCTAssertEqual(store.history.first?.status, .cancelled)
    }

    func testMemoriesSaveCountAndDelete() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let store = MemoriesStore(backend: fixture.backend)
        await store.load(coupleID: fixture.couple)
        XCTAssertEqual(store.loadState, .loaded)
        XCTAssertTrue(store.memories.isEmpty)

        let note = try XCTUnwrap(fixture.world.deliverNote(from: fixture.partner, content: NoteContent(body: "keep me")))
        try await store.saveNote(note)
        try await store.saveNote(note) // saving twice keeps one
        XCTAssertEqual(store.totalCount, 1)
        XCTAssertTrue(store.isSaved(noteID: note.id))

        try await store.add(NewMoment(title: "First trip", occurredOn: DayDate(year: 2025, month: 8, day: 2)), photo: nil, media: fixture.media)
        XCTAssertEqual(store.memories.count, 2)
        try await store.delete(try XCTUnwrap(store.memories.first { $0.title == "First trip" }))
        XCTAssertEqual(store.totalCount, 1)
    }

    func testDatesAreSortedByWhatComesNext() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let store = DatesStore(backend: fixture.backend)
        await store.load(coupleID: fixture.couple)
        let today = DayDate(year: 2026, month: 10, day: 10)
        try await store.save(ImportantDate(coupleID: fixture.couple, createdBy: fixture.me, title: "Birthday", startsOn: DayDate(year: 1995, month: 11, day: 20)), isNew: true)
        try await store.save(ImportantDate(coupleID: fixture.couple, createdBy: fixture.me, title: "Anniversary", startsOn: DayDate(year: 2024, month: 10, day: 19)), isNew: true)
        try await store.save(ImportantDate(coupleID: fixture.couple, createdBy: fixture.me, title: "Concert", startsOn: DayDate(year: 2026, month: 1, day: 5), recurrence: .none), isNew: true)

        XCTAssertEqual(store.upcoming(today: today).map(\.date.title), ["Anniversary", "Birthday"])
        XCTAssertEqual(store.upcoming(today: today).first?.daysAway, 9)
        XCTAssertEqual(store.past(today: today).map(\.title), ["Concert"])
    }
}

@MainActor
final class AccountDeletionTests: XCTestCase {
    /// Reproduces the app's wiring: a live event stream is refreshing the
    /// session while the account is being deleted.
    func testDeletingAnAccountEndsSignedOutWithNoErrorAndTheAccountIsGone() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let session = SessionStore(backend: fixture.backend)
        await session.start(isMissingBackend: false)
        XCTAssertEqual(session.phase, .paired)

        let events = fixture.backend.realtime.events(coupleID: fixture.couple)
        let listener = Task {
            for await _ in events { await session.refresh() }
        }
        defer { listener.cancel() }

        try await session.deleteAccount()
        XCTAssertEqual(session.phase, .signedOut)
        XCTAssertFalse(session.sessionEndedUnexpectedly)
        XCTAssertFalse(fixture.world.hasAccount(fixture.me))
        XCTAssertTrue(fixture.world.hasAccount(fixture.partner), "the partner's account is untouched")
    }

    func testAFailedDeletionKeepsTheAccountAndReportsTheError() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let session = SessionStore(backend: fixture.backend)
        await session.start(isMissingBackend: false)
        fixture.world.setFailure(.offline)
        do {
            try await session.deleteAccount()
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? AppError, .offline)
        }
        fixture.world.setFailure(nil)
        XCTAssertEqual(session.phase, .paired)
        XCTAssertTrue(fixture.world.hasAccount(fixture.me))
    }
}

@MainActor
final class StaleNoteTests: XCTestCase {
    func testANoteRemovedOnTheServerDisappearsFromTheFeedAndTheWidgetOnRefresh() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let session = SessionStore(backend: fixture.backend)
        await session.start(isMissingBackend: false)
        let notes = fixture.notesStore()
        let settings = LocalSettings(defaults: UserDefaults(suiteName: "stale-\(UUID().uuidString)")!)
        let bridge = WidgetBridge(store: nil, media: fixture.media, settings: settings)

        let kept = try XCTUnwrap(fixture.world.deliverNote(from: fixture.partner, content: NoteContent(body: "kept"), at: Date().addingTimeInterval(-60)))
        _ = try XCTUnwrap(fixture.world.deliverNote(from: fixture.partner, content: NoteContent(body: "taken back")))
        await notes.load(coupleID: fixture.couple)
        XCTAssertEqual(bridge.snapshot(session: session, notes: notes).note?.content.body, "taken back")

        // The partner deletes their whole account: their notes are gone from
        // the server outright, with no tombstone to announce it.
        try await fixture.partnerBackend.deleteAccount()
        _ = kept
        await session.refresh()
        await notes.load(coupleID: fixture.couple)
        XCTAssertTrue(notes.feed.notes.isEmpty, "nothing the server no longer has may remain")
        XCTAssertNotEqual(bridge.snapshot(session: session, notes: notes).state, .note)
    }
}
