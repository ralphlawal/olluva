import CoupleDomain
import CoupleLocalBackend
import CoupleWidgetUI
import XCTest
@testable import CoupleNotes

@MainActor
final class TogetherStoreTests: XCTestCase {
    private var fixture: Fixture!
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() async throws {
        fixture = Fixture()
        suite = "together-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        fixture.cleanUp()
    }

    private func store() -> TogetherStore {
        TogetherStore(backend: fixture.backend, defaults: defaults)
    }

    private func partnerStore() -> TogetherStore {
        TogetherStore(backend: fixture.partnerBackend.makeBackend(), defaults: UserDefaults(suiteName: suite + "-partner")!)
    }

    func testBothPeopleLoadTheSameQuestion() async throws {
        let mine = store()
        let theirs = partnerStore()
        await mine.load()
        await theirs.load()
        XCTAssertEqual(mine.loadState, .loaded)
        XCTAssertFalse(mine.isUnpaired)
        XCTAssertEqual(try XCTUnwrap(mine.today).id, try XCTUnwrap(theirs.today).id)
        XCTAssertEqual(mine.today?.question, theirs.today?.question)
        XCTAssertEqual(mine.today?.status, .open)
    }

    func testSomeoneWithoutAPartnerIsToldSoRatherThanShownAnError() async {
        let world = LocalWorld()
        let solo = world.addAccount(name: "Solo")
        let store = TogetherStore(backend: LocalBackend(world: world, signedInAs: solo).makeBackend(), defaults: defaults)
        await store.load()
        XCTAssertEqual(store.loadState, .loaded)
        XCTAssertTrue(store.isUnpaired)
        XCTAssertNil(store.today)
    }

    func testADraftIsKeptOnThePhoneAndIsNotAnAnswer() async throws {
        let mine = store()
        await mine.load()
        let id = try XCTUnwrap(mine.today).id
        mine.setDraft("Half a thou", for: id)

        // A new store, as after quitting and reopening the app.
        let reopened = store()
        await reopened.load()
        XCTAssertEqual(reopened.draft(for: id), "Half a thou")
        XCTAssertEqual(reopened.today?.status, .open)
        XCTAssertNil(reopened.today?.myAnswer)
        // The partner has no sign of it.
        let theirs = partnerStore()
        await theirs.load()
        XCTAssertEqual(theirs.today?.partnerAnswered, false)
    }

    func testSubmittingStoresTheAnswerAndClearsTheDraft() async throws {
        let mine = store()
        await mine.load()
        let id = try XCTUnwrap(mine.today).id
        mine.setDraft("The tea.", for: id)
        let sent = await mine.submit(momentID: id, answer: "The tea.")
        XCTAssertTrue(sent)
        XCTAssertEqual(mine.today?.status, .waiting)
        XCTAssertEqual(mine.today?.myAnswer, "The tea.")
        XCTAssertEqual(mine.draft(for: id), "")
        XCTAssertNil(mine.actionError)
    }

    func testAnAnswerThatFailsToSendIsKeptAndCanBeSentAgain() async throws {
        let mine = store()
        await mine.load()
        let id = try XCTUnwrap(mine.today).id

        fixture.world.setFailure(.offline)
        let failed = await mine.submit(momentID: id, answer: "Written on the train")
        XCTAssertFalse(failed)
        XCTAssertEqual(mine.actionError, .offline)
        XCTAssertEqual(mine.draft(for: id), "Written on the train")
        XCTAssertEqual(mine.today?.status, .open, "nothing is shown as sent")

        // Refreshing while offline keeps what is on screen and says it may be stale.
        await mine.load()
        XCTAssertNotNil(mine.today)
        XCTAssertTrue(mine.isStale)

        fixture.world.setFailure(nil)
        let retried = await mine.submit(momentID: id, answer: mine.draft(for: id))
        XCTAssertTrue(retried)
        XCTAssertEqual(mine.today?.myAnswer, "Written on the train")
        XCTAssertEqual(mine.draft(for: id), "")
        await mine.load()
        XCTAssertFalse(mine.isStale)
    }

    func testAFirstLoadThatFailsIsAnErrorWithNothingInvented() async {
        fixture.world.setFailure(.offline)
        let mine = store()
        await mine.load()
        XCTAssertEqual(mine.loadState, .failed(.offline))
        XCTAssertNil(mine.today)
        XCTAssertFalse(mine.isUnpaired)
    }

    func testInvalidAnswersAreRefusedBeforeAnythingIsSent() async throws {
        let mine = store()
        await mine.load()
        let id = try XCTUnwrap(mine.today).id
        let blank = await mine.submit(momentID: id, answer: "   ")
        XCTAssertFalse(blank)
        XCTAssertEqual(mine.actionError, .invalidAnswer(limit: 500))
        let long = await mine.submit(momentID: id, answer: String(repeating: "x", count: 501))
        XCTAssertFalse(long)
        XCTAssertEqual(mine.today?.status, .open)
    }

    func testThePartnersAnswerNeverReachesThisPhoneBeforeTheReveal() async throws {
        let mine = store()
        let theirs = partnerStore()
        await mine.load()
        let id = try XCTUnwrap(mine.today).id
        await theirs.load()
        _ = await theirs.submit(momentID: id, answer: "THEIR-SECRET")

        await mine.refresh()
        XCTAssertEqual(mine.today?.partnerAnswered, true)
        XCTAssertNil(mine.today?.partnerAnswer)
        let blocked = await mine.reveal(momentID: id)
        XCTAssertFalse(blocked)
        XCTAssertEqual(mine.actionError, .momentNotReady)

        _ = await mine.submit(momentID: id, answer: "mine")
        XCTAssertEqual(mine.today?.status, .ready)
        XCTAssertNil(mine.today?.partnerAnswer)
        await mine.loadHistory()
        XCTAssertEqual(mine.history.map(\.status), [.ready])
        XCTAssertNil(mine.history.first?.partnerAnswer)

        let opened = await mine.reveal(momentID: id)
        XCTAssertTrue(opened)
        XCTAssertEqual(mine.today?.partnerAnswer, "THEIR-SECRET")
        XCTAssertEqual(mine.history.first?.status, .revealed, "the list on screen is updated too")
        // The other phone converges on the same state when it next looks.
        await theirs.refresh()
        XCTAssertEqual(theirs.today?.status, .revealed)
        XCTAssertEqual(theirs.today?.partnerAnswer, "mine")
        XCTAssertEqual(theirs.today?.revealedAt, mine.today?.revealedAt)
    }

    func testAnAnswerCanBeEditedUntilItIsOpenedAndNotAfter() async throws {
        let mine = store()
        let theirs = partnerStore()
        await mine.load()
        await theirs.load()
        let id = try XCTUnwrap(mine.today).id
        _ = await mine.submit(momentID: id, answer: "first")
        _ = await mine.submit(momentID: id, answer: "second")
        XCTAssertEqual(mine.today?.myAnswer, "second")
        _ = await theirs.submit(momentID: id, answer: "theirs")
        _ = await theirs.reveal(momentID: id)

        // This phone has not heard yet and tries to edit.
        let edited = await mine.submit(momentID: id, answer: "third")
        XCTAssertFalse(edited)
        XCTAssertEqual(mine.actionError, .momentAlreadyRevealed)
        XCTAssertEqual(mine.today?.status, .revealed, "it shows the opened moment instead")
        XCTAssertEqual(mine.today?.myAnswer, "second")
    }

    func testSavingToMemoriesIsReflectedAndUnsavingKeepsTheAnswers() async throws {
        let mine = store()
        let theirs = partnerStore()
        await mine.load()
        await theirs.load()
        let id = try XCTUnwrap(mine.today).id
        _ = await mine.submit(momentID: id, answer: "one")
        _ = await theirs.submit(momentID: id, answer: "two")
        _ = await mine.reveal(momentID: id)

        await mine.setSaved(true, momentID: id)
        await theirs.setSaved(true, momentID: id)
        XCTAssertNotNil(mine.today?.memoryID)
        let memories = MemoriesStore(backend: fixture.backend)
        await memories.load(coupleID: fixture.couple)
        XCTAssertEqual(memories.memories.filter { $0.togetherMomentID == id }.count, 1)

        await theirs.setSaved(false, momentID: id)
        await mine.refresh()
        XCTAssertNil(mine.today?.memoryID)
        XCTAssertEqual(mine.today?.partnerAnswer, "two")
    }

    func testHistoryHoldsOnlyDaysBothFinished() async throws {
        let mine = store()
        await mine.load()
        let missed = try XCTUnwrap(mine.today).id
        _ = await mine.submit(momentID: missed, answer: "only me")
        fixture.world.ageTogether(days: 1)

        await mine.load()
        let next = try XCTUnwrap(mine.today).id
        XCTAssertNotEqual(next, missed)
        XCTAssertEqual(mine.today?.status, .open, "a missed day is not carried forward")
        fixture.world.answerTogether(as: fixture.partner, "theirs")
        _ = await mine.submit(momentID: next, answer: "mine")
        _ = await mine.reveal(momentID: next)

        await mine.loadHistory()
        XCTAssertEqual(mine.history.map(\.id), [next])
        XCTAssertEqual(mine.historyState, .loaded)
        XCTAssertFalse(mine.hasMoreHistory)
    }

    func testTheRevealIsPlayedOncePerPhoneAndEverythingIsClearedOnReset() async throws {
        let mine = store()
        await mine.load()
        let id = try XCTUnwrap(mine.today).id
        XCTAssertFalse(mine.hasPlayedReveal(id))
        mine.markRevealPlayed(id)
        XCTAssertTrue(store().hasPlayedReveal(id))

        mine.setDraft("unsent", for: id)
        mine.reset()
        XCTAssertNil(mine.today)
        XCTAssertEqual(mine.loadState, .idle)
        XCTAssertEqual(mine.draft(for: id), "")
        XCTAssertFalse(mine.hasPlayedReveal(id))
        XCTAssertTrue(mine.history.isEmpty)
    }

    func testNotificationsAndLinksOpenTheRightPlace() {
        XCTAssertEqual(NotificationCoordinator.deepLink(from: ["category": "together", "together": "1"]), .together)
        XCTAssertEqual(DeepLink(url: DeepLink.together.url), .together)
        let router = AppRouter()
        router.open(.together)
        XCTAssertEqual(router.tab, .today)
        XCTAssertTrue(router.isShowingTogether)
        router.reset()
        XCTAssertFalse(router.isShowingTogether)
    }
}
