import CoupleDomain
import CoupleLocalBackend
import XCTest

/// The in-memory backend must behave like the server for Together, because
/// demo mode and the app's own tests run on it. The server's rules are tested
/// for real in supabase/tests/together.test.js.
final class TogetherLocalTests: XCTestCase {
    private var world: LocalWorld!

    override func setUp() {
        world = LocalWorld()
    }

    private func session(_ name: String) async throws -> (LocalBackend, UUID) {
        let backend = LocalBackend(world: world)
        try await backend.startAnonymously()
        _ = try await backend.updateProfile(displayName: name, timeZone: nil)
        return (backend, try XCTUnwrap(backend.currentUserID))
    }

    private func couple() async throws -> (a: LocalBackend, b: LocalBackend) {
        let (a, _) = try await session("Ada")
        let (b, _) = try await session("Ben")
        try await a.createSpace()
        let invitation = try await a.createInvitation()
        try await b.acceptInvitation(code: invitation.code)
        return (a, b)
    }

    private func assertThrows(_ expected: AppError, file: StaticString = #filePath, line: UInt = #line, _ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? AppError, expected, file: file, line: line)
        }
    }

    func testSomeoneWithoutAPartnerHasNoMoment() async throws {
        let (solo, _) = try await session("Solo")
        let moment = try await solo.today()
        XCTAssertNil(moment)
        let history = try await solo.history(before: nil, limit: 20)
        XCTAssertTrue(history.isEmpty)
    }

    func testBothGetTheSameQuestionAndAnswersStayPrivateUntilRevealed() async throws {
        let (a, b) = try await couple()
        let mine = try await XCTUnwrapAsync(await a.today())
        let theirs = try await XCTUnwrapAsync(await b.today())
        XCTAssertEqual(mine.id, theirs.id)
        XCTAssertEqual(mine.question, theirs.question)
        XCTAssertEqual(mine.status, .open)

        let waiting = try await a.submit(momentID: mine.id, answer: "  The tea.  ")
        XCTAssertEqual(waiting.status, .waiting)
        XCTAssertEqual(waiting.myAnswer, "The tea.")

        let seenByB = try await b.moment(id: mine.id)
        XCTAssertEqual(seenByB.status, .open)
        XCTAssertTrue(seenByB.partnerAnswered)
        XCTAssertNil(seenByB.partnerAnswer)
        await assertThrows(.momentNotReady) { _ = try await b.reveal(momentID: mine.id) }

        let ready = try await b.submit(momentID: mine.id, answer: "The walk.")
        XCTAssertEqual(ready.status, .ready)
        XCTAssertNil(ready.partnerAnswer)
        // Editing before the reveal changes only your own.
        _ = try await a.submit(momentID: mine.id, answer: "The tea, and the toast.")
        let stillB = try await b.moment(id: mine.id)
        XCTAssertEqual(stillB.myAnswer, "The walk.")

        let opened = try await b.reveal(momentID: mine.id)
        XCTAssertEqual(opened.status, .revealed)
        XCTAssertEqual(opened.partnerAnswer, "The tea, and the toast.")
        let other = try await XCTUnwrapAsync(await a.today())
        XCTAssertEqual(other.status, .revealed)
        XCTAssertEqual(other.partnerAnswer, "The walk.")
        XCTAssertEqual(other.revealedAt, opened.revealedAt)
        let again = try await a.reveal(momentID: mine.id)
        XCTAssertEqual(again.revealedAt, opened.revealedAt)
        await assertThrows(.momentAlreadyRevealed) { _ = try await a.submit(momentID: mine.id, answer: "too late") }
    }

    func testAnswersAreValidated() async throws {
        let (a, _) = try await couple()
        let moment = try await XCTUnwrapAsync(await a.today())
        await assertThrows(.invalidAnswer(limit: 500)) { _ = try await a.submit(momentID: moment.id, answer: "   ") }
        await assertThrows(.invalidAnswer(limit: 500)) { _ = try await a.submit(momentID: moment.id, answer: String(repeating: "x", count: 501)) }
        let ok = try await a.submit(momentID: moment.id, answer: String(repeating: "x", count: 500))
        XCTAssertEqual(ok.myAnswer?.count, 500)
        XCTAssertTrue(TogetherRules.isValid(" hi "))
        XCTAssertFalse(TogetherRules.isValid("\n"))
    }

    func testAnotherCoupleCannotReachAMoment() async throws {
        let (a, b) = try await couple()
        let moment = try await XCTUnwrapAsync(await a.today())
        _ = try await a.submit(momentID: moment.id, answer: "ours")
        _ = try await b.submit(momentID: moment.id, answer: "also ours")
        let (c, _) = try await couple()
        await assertThrows(.momentUnavailable) { _ = try await c.moment(id: moment.id) }
        await assertThrows(.momentUnavailable) { _ = try await c.submit(momentID: moment.id, answer: "intrusion") }
        await assertThrows(.momentUnavailable) { _ = try await c.reveal(momentID: moment.id) }
        await assertThrows(.momentUnavailable) { _ = try await c.saveToMemories(momentID: moment.id) }
        let theirs = try await c.history(before: nil, limit: 20)
        XCTAssertTrue(theirs.isEmpty)
    }

    func testAMissedDayIsLeftBehindAndAFinishedOneCanStillBeOpened() async throws {
        let (a, b) = try await couple()
        let missed = try await XCTUnwrapAsync(await a.today())
        _ = try await a.submit(momentID: missed.id, answer: "only me")
        world.ageTogether(days: 2)
        await assertThrows(.momentClosed) { _ = try await b.submit(momentID: missed.id, answer: "late") }
        let none = try await b.history(before: nil, limit: 20)
        XCTAssertTrue(none.isEmpty)

        let next = try await XCTUnwrapAsync(await b.today())
        XCTAssertNotEqual(next.id, missed.id)
        XCTAssertEqual(next.status, .open)
        _ = try await a.submit(momentID: next.id, answer: "yes")
        _ = try await b.submit(momentID: next.id, answer: "and yes")
        world.ageTogether(days: 1)
        let listed = try await a.history(before: nil, limit: 20)
        XCTAssertEqual(listed.map(\.status), [.ready])
        let opened = try await a.reveal(momentID: next.id)
        XCTAssertEqual(opened.partnerAnswer, "and yes")
    }

    func testSavingToMemoriesHappensOnceAndUnsavingKeepsTheAnswers() async throws {
        let (a, b) = try await couple()
        let moment = try await XCTUnwrapAsync(await a.today())
        _ = try await a.submit(momentID: moment.id, answer: "one")
        _ = try await b.submit(momentID: moment.id, answer: "two")
        await assertThrows(.momentNotReady) { _ = try await a.saveToMemories(momentID: moment.id) }
        _ = try await a.reveal(momentID: moment.id)

        let first = try await a.saveToMemories(momentID: moment.id)
        let second = try await b.saveToMemories(momentID: moment.id)
        XCTAssertEqual(first, second)
        let saved = try await b.moment(id: moment.id)
        XCTAssertEqual(saved.memoryID, first)

        try await b.removeFromMemories(momentID: moment.id)
        let after = try await a.moment(id: moment.id)
        XCTAssertNil(after.memoryID)
        XCTAssertEqual(after.myAnswer, "one")
        XCTAssertEqual(after.partnerAnswer, "two")
    }

    func testThePartnerAnsweringArrivesAsALiveEvent() async throws {
        let (a, b) = try await couple()
        let moment = try await XCTUnwrapAsync(await a.today())
        let state = try await a.spaceState()
        let coupleID = try XCTUnwrap(state.space?.id)
        let events = a.events(coupleID: coupleID)
        let received = Task { () -> Bool in
            for await event in events where event == .togetherChanged { return true }
            return false
        }
        try await Task.sleep(for: .milliseconds(50))
        _ = try await b.submit(momentID: moment.id, answer: "hello")
        let got = await withTaskGroup(of: Bool.self) { group in
            group.addTask { await received.value }
            group.addTask { try? await Task.sleep(for: .seconds(2)); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        received.cancel()
        XCTAssertTrue(got)
    }
}

/// `XCTUnwrap` for a value produced by an `await`.
func XCTUnwrapAsync<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
    try XCTUnwrap(value, file: file, line: line)
}
