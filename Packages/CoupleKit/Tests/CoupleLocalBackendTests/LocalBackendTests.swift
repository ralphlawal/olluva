import CoupleDomain
import CoupleLocalBackend
import XCTest

/// Integration tests for the flows the app is built from, run against the
/// in-memory backend: sign-up → pair → note → react → save → schedule.
/// The same rules are tested against real Postgres in supabase/tests.
final class LocalBackendTests: XCTestCase {
    private var world: LocalWorld!
    private var clock: TestClock!

    override func setUp() {
        clock = TestClock()
        let clock = clock!
        world = LocalWorld(now: { clock.now })
    }

    private func session(_ name: String) async throws -> (LocalBackend, UUID) {
        let backend = LocalBackend(world: world)
        let outcome = try await backend.signUp(email: "\(name.lowercased())@example.test", password: "password1", displayName: name)
        XCTAssertEqual(outcome, .signedIn)
        return (backend, try XCTUnwrap(backend.currentUserID))
    }

    private func pairedSessions() async throws -> (a: LocalBackend, b: LocalBackend, couple: UUID, aID: UUID, bID: UUID) {
        let (a, aID) = try await session("Ada")
        let (b, bID) = try await session("Ben")
        try await a.createSpace()
        let invitation = try await a.createInvitation()
        try await b.acceptInvitation(code: invitation.code)
        let state = try await a.spaceState()
        let couple = try XCTUnwrap(state.space?.id)
        return (a, b, couple, aID, bID)
    }

    private func assertThrows(_ expected: AppError, file: StaticString = #filePath, line: UInt = #line, _ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? AppError, expected, file: file, line: line)
        }
    }

    // MARK: Authentication

    func testSignUpSignOutSignIn() async throws {
        let (backend, id) = try await session("Ada")
        let profile = try await backend.myProfile()
        XCTAssertEqual(profile.displayName, "Ada")
        try await backend.signOut()
        XCTAssertNil(backend.currentUserID)
        await assertThrows(.sessionExpired) { _ = try await backend.myProfile() }
        await assertThrows(.invalidCredentials) { try await backend.signIn(email: "ada@example.test", password: "wrong-password") }
        try await backend.signIn(email: "ADA@example.test", password: "password1")
        XCTAssertEqual(backend.currentUserID, id)
    }

    func testDuplicateEmailAndWeakPasswordAreRejected() async throws {
        _ = try await session("Ada")
        let other = LocalBackend(world: world)
        await assertThrows(.emailAlreadyRegistered) {
            _ = try await other.signUp(email: "ada@example.test", password: "password1", displayName: "Imposter")
        }
        await assertThrows(.weakPassword) {
            _ = try await other.signUp(email: "new@example.test", password: "short", displayName: "New")
        }
    }

    func testEmailConfirmationFlow() async throws {
        let strict = LocalWorld(requiresEmailConfirmation: true)
        let backend = LocalBackend(world: strict)
        let outcome = try await backend.signUp(email: "ada@example.test", password: "password1", displayName: "Ada")
        XCTAssertEqual(outcome, .confirmationRequired)
        XCTAssertNil(backend.currentUserID)
        await assertThrows(.emailNotConfirmed) { try await backend.signIn(email: "ada@example.test", password: "password1") }
        await assertThrows(.invalidCode) { try await backend.confirmSignUp(email: "ada@example.test", code: "000000") }
        try await backend.confirmSignUp(email: "ada@example.test", code: LocalWorld.verificationCode)
        XCTAssertNotNil(backend.currentUserID)
    }

    func testPasswordRecovery() async throws {
        let (backend, id) = try await session("Ada")
        try await backend.signOut()
        try await backend.requestPasswordReset(email: "ada@example.test")
        try await backend.requestPasswordReset(email: "nobody@example.test") // does not reveal existence
        await assertThrows(.invalidCode) { try await backend.resetPassword(email: "ada@example.test", code: "999999", newPassword: "newpassword") }
        try await backend.resetPassword(email: "ada@example.test", code: LocalWorld.verificationCode, newPassword: "newpassword")
        XCTAssertEqual(backend.currentUserID, id)
        try await backend.signOut()
        await assertThrows(.invalidCredentials) { try await backend.signIn(email: "ada@example.test", password: "password1") }
        try await backend.signIn(email: "ada@example.test", password: "newpassword")
    }

    func testAuthStateStreamReportsExpiry() async throws {
        let (backend, id) = try await session("Ada")
        var iterator = backend.stateChanges().makeAsyncIterator()
        backend.expireSession()
        let first = await iterator.next()
        XCTAssertEqual(first, .signedOut)
        try await backend.signIn(email: "ada@example.test", password: "password1")
        let second = await iterator.next()
        XCTAssertEqual(second?.userID, id)
    }

    // MARK: Pairing

    func testPairingThroughAnInvitation() async throws {
        let (a, _) = try await session("Ada")
        let (b, bID) = try await session("Ben")
        var state = try await a.spaceState()
        XCTAssertEqual(state, .none)

        try await a.createSpace()
        state = try await a.spaceState()
        guard case .waiting = state else { return XCTFail("expected waiting") }

        let invitation = try await a.createInvitation()
        XCTAssertTrue(InviteCode.isComplete(invitation.code))
        let preview = try await b.previewInvitation(code: InviteCode.display(invitation.code).lowercased())
        XCTAssertEqual(preview.inviterName, "Ada")

        try await b.acceptInvitation(code: invitation.code)
        state = try await a.spaceState()
        XCTAssertEqual(state.partner?.id, bID)
        let other = try await b.spaceState()
        XCTAssertEqual(other.partner?.displayName, "Ada")
    }

    func testInvitationEdgeCases() async throws {
        let (a, _) = try await session("Ada")
        let (b, _) = try await session("Ben")
        let (c, _) = try await session("Cal")
        try await a.createSpace()
        let first = try await a.createInvitation()

        await assertThrows(.ownInvitation) { try await a.acceptInvitation(code: first.code) }

        let second = try await a.createInvitation()
        await assertThrows(.invitationUnavailable) { try await b.acceptInvitation(code: first.code) }

        clock.advance(49 * 3600)
        await assertThrows(.invitationExpired) { try await b.acceptInvitation(code: second.code) }

        let third = try await a.createInvitation()
        try await a.revokeInvitation(id: third.id)
        await assertThrows(.invitationUnavailable) { try await b.acceptInvitation(code: third.code) }

        let fourth = try await a.createInvitation()
        try await b.acceptInvitation(code: fourth.code)
        await assertThrows(.invitationUnavailable) { try await c.acceptInvitation(code: fourth.code) }
        await assertThrows(.alreadyPaired) { _ = try await a.createInvitation() }
        await assertThrows(.alreadyInSpace) { try await b.createSpace() }
    }

    func testGuessingCodesIsRateLimited() async throws {
        let (a, _) = try await session("Ada")
        let (attacker, _) = try await session("Eve")
        try await a.createSpace()
        let invitation = try await a.createInvitation()
        for _ in 0..<5 {
            await assertThrows(.invitationUnavailable) { try await attacker.acceptInvitation(code: "ZZZZZZZZZZ") }
        }
        await assertThrows(.rateLimited) { try await attacker.acceptInvitation(code: invitation.code) }
        clock.advance(16 * 60)
        try await attacker.acceptInvitation(code: invitation.code)
    }

    func testJoiningClosesYourOwnEmptySpace() async throws {
        let (a, _) = try await session("Ada")
        let (b, _) = try await session("Ben")
        try await a.createSpace()
        try await b.createSpace()
        let mine = try await b.createInvitation()
        let theirs = try await a.createInvitation()
        try await b.acceptInvitation(code: theirs.code)
        let (c, _) = try await session("Cal")
        await assertThrows(.invitationUnavailable) { try await c.acceptInvitation(code: mine.code) }
    }

    func testUnlinkingEndsTheSpaceForBothAndBlockPreventsRepairing() async throws {
        let s = try await pairedSessions()
        _ = try await s.a.send(id: UUID(), coupleID: s.couple, content: NoteContent(body: "hi"))
        try await s.b.leaveSpace(blockPartner: true)

        let aState = try await s.a.spaceState()
        let bState = try await s.b.spaceState()
        XCTAssertEqual(aState, .none)
        XCTAssertEqual(bState, .none)
        let notes = try await s.a.recentNotes(coupleID: s.couple, before: nil, limit: 10)
        XCTAssertEqual(notes, [])
        // Both accounts still exist.
        _ = try await s.a.myProfile()
        _ = try await s.b.myProfile()

        try await s.a.createSpace()
        let invitation = try await s.a.createInvitation()
        await assertThrows(.invitationUnavailable) { try await s.b.acceptInvitation(code: invitation.code) }
    }

    // MARK: Notes

    func testSendingIsIdempotentAndReachesThePartner() async throws {
        let s = try await pairedSessions()
        let id = UUID()
        let first = try await s.a.send(id: id, coupleID: s.couple, content: NoteContent(body: "good morning"))
        let retry = try await s.a.send(id: id, coupleID: s.couple, content: NoteContent(body: "good morning"))
        XCTAssertEqual(first, retry)
        XCTAssertEqual(world.noteCount(coupleID: s.couple), 1)

        let received = try await s.b.recentNotes(coupleID: s.couple, before: nil, limit: 10)
        XCTAssertEqual(received.map(\.body), ["good morning"])
        XCTAssertEqual(received.first?.authorID, s.aID)
    }

    func testAFailedSendIsReportedAndCreatesNothing() async throws {
        let s = try await pairedSessions()
        world.setFailure(.offline)
        await assertThrows(.offline) { _ = try await s.a.send(id: UUID(), coupleID: s.couple, content: NoteContent(body: "lost?")) }
        world.setFailure(nil)
        XCTAssertEqual(world.noteCount(coupleID: s.couple), 0)
    }

    func testRealtimeDeliversThePartnersNote() async throws {
        let s = try await pairedSessions()
        var iterator = s.b.events(coupleID: s.couple).makeAsyncIterator()
        let sent = try await s.a.send(id: UUID(), coupleID: s.couple, content: NoteContent(body: "ping"))
        let event = await iterator.next()
        XCTAssertEqual(event, .note(sent))
    }

    func testEditingUsesVersionChecks() async throws {
        let s = try await pairedSessions()
        let note = try await s.a.send(id: UUID(), coupleID: s.couple, content: NoteContent(body: "v1"))
        await assertThrows(.notAuthor) { _ = try await s.b.update(noteID: note.id, expectedVersion: 1, content: NoteContent(body: "hijack")) }

        let edited = try await s.a.update(noteID: note.id, expectedVersion: 1, content: NoteContent(body: "v2"))
        XCTAssertEqual(edited.version, 2)
        // A second device that still has version 1 must not overwrite v2.
        await assertThrows(.versionConflict) { _ = try await s.a.update(noteID: note.id, expectedVersion: 1, content: NoteContent(body: "stale")) }
        let current = try await s.b.recentNotes(coupleID: s.couple, before: nil, limit: 1)
        XCTAssertEqual(current.first?.body, "v2")
    }

    func testDeleteLeavesATombstoneAndOnlyTheAuthorCanDelete() async throws {
        let s = try await pairedSessions()
        let note = try await s.a.send(id: UUID(), coupleID: s.couple, content: NoteContent(body: "secret"))
        await assertThrows(.notAuthor) { try await s.b.delete(noteID: note.id) }
        try await s.a.delete(noteID: note.id)
        let rows = try await s.b.recentNotes(coupleID: s.couple, before: nil, limit: 10)
        XCTAssertEqual(rows.count, 1)
        XCTAssertTrue(rows[0].isDeleted)
        XCTAssertEqual(rows[0].body, "")
        XCTAssertNil(NoteFeed(rows).latestReceived(by: s.bID))
    }

    func testSeenAndReactions() async throws {
        let s = try await pairedSessions()
        let note = try await s.a.send(id: UUID(), coupleID: s.couple, content: NoteContent(body: "hi"))
        try await s.a.markSeen(noteID: note.id) // the author cannot acknowledge their own note
        var rows = try await s.a.recentNotes(coupleID: s.couple, before: nil, limit: 1)
        XCTAssertNil(rows[0].seenAt)
        try await s.b.markSeen(noteID: note.id)
        rows = try await s.a.recentNotes(coupleID: s.couple, before: nil, limit: 1)
        XCTAssertNotNil(rows[0].seenAt)

        await assertThrows(.notAuthor) { try await s.a.setReaction(noteID: note.id, kind: .love) }
        try await s.b.setReaction(noteID: note.id, kind: .love)
        try await s.b.setReaction(noteID: note.id, kind: .laugh)
        var reactions = try await s.a.reactions(coupleID: s.couple)
        XCTAssertEqual(reactions, [Reaction(noteID: note.id, userID: s.bID, kind: .laugh)])
        try await s.b.setReaction(noteID: note.id, kind: nil)
        reactions = try await s.a.reactions(coupleID: s.couple)
        XCTAssertEqual(reactions, [])
    }

    func testAnotherCoupleCannotReachThisCouplesContent() async throws {
        let s = try await pairedSessions()
        let (c, _) = try await session("Cal")
        let (d, _) = try await session("Dee")
        try await c.createSpace()
        let invitation = try await c.createInvitation()
        try await d.acceptInvitation(code: invitation.code)

        let path = MediaPath.photo(coupleID: s.couple)
        try await s.a.upload(Data([1, 2, 3]), to: path, contentType: "image/jpeg")
        let note = try await s.a.send(id: UUID(), coupleID: s.couple, content: NoteContent(body: "ours", photoPath: path))

        let leaked = try await c.recentNotes(coupleID: s.couple, before: nil, limit: 10)
        XCTAssertEqual(leaked, [])
        await assertThrows(.noteNotFound) { _ = try await c.send(id: UUID(), coupleID: s.couple, content: NoteContent(body: "intrusion")) }
        await assertThrows(.noteNotFound) { _ = try await c.update(noteID: note.id, expectedVersion: 1, content: NoteContent(body: "x")) }
        await assertThrows(.noteNotFound) { try await c.delete(noteID: note.id) }
        await assertThrows(.noteNotFound) { try await c.setReaction(noteID: note.id, kind: .love) }
        await assertThrows(.noteNotFound) { _ = try await c.saveNote(noteID: note.id, caption: "") }
        await assertThrows(.mediaUnreadable) { _ = try await c.download(path: path) }
        await assertThrows(.uploadFailed) { try await c.upload(Data([9]), to: MediaPath.photo(coupleID: s.couple), contentType: "image/jpeg") }
        let mine = try await s.b.download(path: path)
        XCTAssertEqual(mine, Data([1, 2, 3]))
    }

    func testMediaIsWriteOnceAndSizeLimited() async throws {
        let s = try await pairedSessions()
        let path = MediaPath.photo(coupleID: s.couple)
        try await s.a.upload(Data([1]), to: path, contentType: "image/jpeg")
        await assertThrows(.uploadFailed) { try await s.b.upload(Data([2]), to: path, contentType: "image/jpeg") }
        await assertThrows(.mediaTooLarge) {
            try await s.a.upload(Data(count: MediaPath.maximumMediaBytes + 1), to: MediaPath.photo(coupleID: s.couple), contentType: "image/jpeg")
        }
    }

    // MARK: Memories

    func testSavingANoteIsIdempotentAndOutlivesTheNote() async throws {
        let s = try await pairedSessions()
        let note = try await s.a.send(id: UUID(), coupleID: s.couple, content: NoteContent(body: "keep me"))
        let first = try await s.b.saveNote(noteID: note.id, caption: "first")
        let second = try await s.a.saveNote(noteID: note.id, caption: "again")
        XCTAssertEqual(first, second)
        try await s.a.delete(noteID: note.id)
        let memories = try await s.a.memories(coupleID: s.couple, after: nil, limit: 10)
        XCTAssertEqual(memories.map(\.content.body), ["keep me"])
        XCTAssertEqual(memories.first?.caption, "first")
    }

    func testMemoryPaginationIsStableAndComplete() async throws {
        let s = try await pairedSessions()
        world.setPremium(true, for: s.aID)
        for index in 0..<45 {
            clock.advance(1)
            _ = try await s.a.add(NewMoment(title: "m\(index)", occurredOn: DayDate(year: 2026, month: 1 + index % 3, day: 1 + index % 5)), coupleID: s.couple)
        }
        var collected: [Memory] = []
        var cursor: MemoryCursor?
        while true {
            let page = try await s.b.memories(coupleID: s.couple, after: cursor, limit: 20)
            collected += page
            guard page.count == 20, let last = page.last else { break }
            cursor = MemoryCursor(after: last)
        }
        XCTAssertEqual(collected.count, 45)
        XCTAssertEqual(Set(collected.map(\.id)).count, 45, "no duplicates across pages")
        XCTAssertEqual(collected.map(\.occurredOn), collected.map(\.occurredOn).sorted(by: >))
    }

    func testFreeMemoryLimitIsLiftedByEitherPartnersPremium() async throws {
        let s = try await pairedSessions()
        for index in 0..<ProductConfiguration.free.memories {
            _ = try await s.a.add(NewMoment(title: "m\(index)", occurredOn: DayDate(year: 2026, month: 1, day: 1)), coupleID: s.couple)
        }
        await assertThrows(.memoryLimitReached) {
            _ = try await s.a.add(NewMoment(title: "one more", occurredOn: DayDate(year: 2026, month: 1, day: 1)), coupleID: s.couple)
        }
        world.setPremium(true, for: s.bID)
        _ = try await s.a.add(NewMoment(title: "one more", occurredOn: DayDate(year: 2026, month: 1, day: 1)), coupleID: s.couple)
        let count = try await s.a.count(coupleID: s.couple)
        XCTAssertEqual(count, 31)
    }

    func testEitherPartnerCanEditAndRemoveAMemory() async throws {
        let s = try await pairedSessions()
        let memory = try await s.a.add(NewMoment(title: "First trip", occurredOn: DayDate(year: 2025, month: 8, day: 2)), coupleID: s.couple)
        let edited = try await s.b.update(id: memory.id, title: "Our first trip", caption: "Lisbon", occurredOn: memory.occurredOn)
        XCTAssertEqual(edited.title, "Our first trip")
        try await s.b.deleteMemory(id: memory.id)
        let remaining = try await s.a.count(coupleID: s.couple)
        XCTAssertEqual(remaining, 0)
    }

    // MARK: Important dates

    func testPrivateDatesStayPrivate() async throws {
        let s = try await pairedSessions()
        let day = DayDate(year: 2020, month: 6, day: 14)
        _ = try await s.a.add(ImportantDate(coupleID: s.couple, createdBy: s.aID, title: "Anniversary", kind: .anniversary, startsOn: day))
        let secret = try await s.a.add(ImportantDate(coupleID: s.couple, createdBy: s.aID, title: "Proposal", startsOn: day, visibility: .private))

        let partnerView = try await s.b.dates(coupleID: s.couple)
        XCTAssertEqual(partnerView.map(\.title), ["Anniversary"])
        var tampered = secret
        tampered.title = "found it"
        await assertThrows(.noteNotFound) { _ = try await s.b.update(tampered) }
        try await s.b.deleteDate(id: secret.id)
        let mine = try await s.a.dates(coupleID: s.couple)
        XCTAssertEqual(mine.count, 2)
    }

    func testPartnerCanEditASharedDateButNotItsVisibility() async throws {
        let s = try await pairedSessions()
        var date = try await s.a.add(ImportantDate(coupleID: s.couple, createdBy: s.aID, title: "Us", startsOn: DayDate(year: 2020, month: 6, day: 14), remindDaysBefore: [7, 0, 2]))
        XCTAssertEqual(date.remindDaysBefore, [0, 7], "invalid offsets are dropped")
        date.title = "Our day"
        let edited = try await s.b.update(date)
        XCTAssertEqual(edited.title, "Our day")
        XCTAssertEqual(edited.createdBy, s.aID)
        date.visibility = .private
        await assertThrows(.notAuthor) { _ = try await s.b.update(date) }
    }

    // MARK: Scheduled messages

    func testAScheduledMessageIsSecretThenDeliveredExactlyOnce() async throws {
        let s = try await pairedSessions()
        let id = UUID()
        let when = clock.now.addingTimeInterval(3600)
        _ = try await s.a.schedule(id: id, coupleID: s.couple, content: NoteContent(body: "surprise"), deliverAt: when, timeZone: "Europe/Lisbon")

        let partnerList = try await s.b.scheduledMessages()
        XCTAssertEqual(partnerList, [])
        XCTAssertEqual(world.deliverDueScheduledMessages(), 0, "not due yet")

        clock.advance(3601)
        XCTAssertEqual(world.deliverDueScheduledMessages(), 1)
        XCTAssertEqual(world.deliverDueScheduledMessages(), 0, "a second run delivers nothing")
        let notes = try await s.b.recentNotes(coupleID: s.couple, before: nil, limit: 10)
        XCTAssertEqual(notes.map(\.id), [id])
        XCTAssertEqual(notes.first?.origin, .scheduled)
        let mine = try await s.a.scheduledMessages()
        XCTAssertEqual(mine.first?.status, .delivered)
    }

    func testSchedulingRules() async throws {
        let s = try await pairedSessions()
        await assertThrows(.deliveryTooSoon) {
            _ = try await s.a.schedule(id: UUID(), coupleID: s.couple, content: NoteContent(body: "x"), deliverAt: self.clock.now, timeZone: "UTC")
        }
        let id = UUID()
        let when = clock.now.addingTimeInterval(7200)
        let message = try await s.a.schedule(id: id, coupleID: s.couple, content: NoteContent(body: "one"), deliverAt: when, timeZone: "UTC")
        // The same request again is the same message, not a second one.
        let again = try await s.a.schedule(id: id, coupleID: s.couple, content: NoteContent(body: "one"), deliverAt: when, timeZone: "UTC")
        XCTAssertEqual(message, again)
        await assertThrows(.scheduledLimitReached) {
            _ = try await s.a.schedule(id: UUID(), coupleID: s.couple, content: NoteContent(body: "two"), deliverAt: when, timeZone: "UTC")
        }

        let edited = try await s.a.update(id: id, expectedVersion: 1, content: NoteContent(body: "edited"), deliverAt: when.addingTimeInterval(60), timeZone: "UTC")
        XCTAssertEqual(edited.version, 2)
        await assertThrows(.versionConflict) {
            _ = try await s.a.update(id: id, expectedVersion: 1, content: NoteContent(body: "stale"), deliverAt: when, timeZone: "UTC")
        }

        try await s.a.cancel(id: id)
        clock.advance(8000)
        XCTAssertEqual(world.deliverDueScheduledMessages(), 0, "cancelled messages are never delivered")
        await assertThrows(.scheduleNotEditable) {
            _ = try await s.a.update(id: id, expectedVersion: 2, content: NoteContent(body: "late"), deliverAt: self.clock.now.addingTimeInterval(3600), timeZone: "UTC")
        }
    }

    func testNothingIsDeliveredAfterUnlinking() async throws {
        let s = try await pairedSessions()
        _ = try await s.a.schedule(id: UUID(), coupleID: s.couple, content: NoteContent(body: "too late"), deliverAt: clock.now.addingTimeInterval(3600), timeZone: "UTC")
        try await s.b.leaveSpace(blockPartner: false)
        clock.advance(4000)
        XCTAssertEqual(world.deliverDueScheduledMessages(), 0)
        let mine = try await s.a.scheduledMessages()
        XCTAssertEqual(mine.first?.status, .failed)
    }

    // MARK: Entitlement, themes, account

    func testSharedEntitlementAndThemeGating() async throws {
        let s = try await pairedSessions()
        await assertThrows(.premiumRequired) { try await s.a.setTheme(id: "dusk", accentHex: nil) }
        await assertThrows(.premiumRequired) { try await s.a.setTheme(id: "paper", accentHex: "#112233") }
        try await s.a.setTheme(id: "plum", accentHex: nil)

        world.setPremium(true, for: s.aID)
        let own = try await s.a.entitlement()
        let shared = try await s.b.entitlement()
        XCTAssertEqual(own.source, .own)
        XCTAssertEqual(shared, Entitlement(isPremium: true, source: .partner))
        try await s.b.setTheme(id: "dusk", accentHex: "#AA5577")
        let space = try await s.a.spaceState().space
        XCTAssertEqual(space?.themeID, "dusk")

        // Premium follows the purchaser after unlinking.
        try await s.a.leaveSpace(blockPartner: false)
        let after = try await s.b.entitlement()
        XCTAssertEqual(after, .free)
        let purchaser = try await s.a.entitlement()
        XCTAssertTrue(purchaser.isPremium)
    }

    func testSubmittingATransactionGrantsNothingByItself() async throws {
        let (backend, _) = try await session("Ada")
        let result = try await backend.submitTransaction(jws: "anything.at.all")
        XCTAssertEqual(result, .free)
    }

    func testAccountDeletionRemovesTheUserAndFreesThePartner() async throws {
        let s = try await pairedSessions()
        _ = try await s.a.send(id: UUID(), coupleID: s.couple, content: NoteContent(body: "from ada"))
        try await s.a.registerDevice(token: String(repeating: "ab", count: 32), environment: .sandbox)
        try await s.a.deleteAccount()

        XCTAssertFalse(world.hasAccount(s.aID))
        XCTAssertNil(s.a.currentUserID)
        XCTAssertEqual(world.deviceTokens(for: s.aID), [])
        XCTAssertEqual(world.noteCount(coupleID: s.couple), 0)
        let partnerState = try await s.b.spaceState()
        XCTAssertEqual(partnerState, .none)
        XCTAssertTrue(world.hasAccount(s.bID))
        await assertThrows(.invalidCredentials) { try await s.a.signIn(email: "ada@example.test", password: "password1") }
    }

    func testExportContainsOnlyTheUsersOwnWriting() async throws {
        let s = try await pairedSessions()
        _ = try await s.a.send(id: UUID(), coupleID: s.couple, content: NoteContent(body: "from ada"))
        _ = try await s.b.send(id: UUID(), coupleID: s.couple, content: NoteContent(body: "from ben"))
        let data = try await s.a.exportData()
        let export = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(export.contains("from ada"))
        XCTAssertFalse(export.contains("from ben"))
    }

    func testNotificationPreferencesAndTokens() async throws {
        let s = try await pairedSessions()
        var preferences = try await s.a.preferences()
        XCTAssertFalse(preferences.showPreviews, "previews are off by default")
        preferences.showPreviews = true
        preferences.newNotes = false
        try await s.a.update(preferences)
        let stored = try await s.a.preferences()
        XCTAssertEqual(stored, preferences)
        let partnerPreferences = try await s.b.preferences()
        XCTAssertEqual(partnerPreferences, NotificationPreferences())

        let token = String(repeating: "cd", count: 32)
        try await s.a.registerDevice(token: token, environment: .sandbox)
        try await s.b.registerDevice(token: token, environment: .sandbox) // the device changed hands
        XCTAssertEqual(world.deviceTokens(for: s.aID), [])
        try await s.a.unregisterDevice(token: token) // no longer theirs: no effect
        XCTAssertEqual(world.deviceTokens(for: s.bID), [token])
    }
}

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSinceReferenceDate: 800_000_000)

    var now: Date { lock.withLock { current } }

    func advance(_ seconds: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(seconds) }
    }
}

final class DemoArrangementTests: XCTestCase {
    func testAWaitingSpaceWithAKnownCodeCanBeJoined() async throws {
        let world = LocalWorld()
        let sam = world.addAccount(name: "Sam", email: "sam@example.test")
        world.addWaitingSpace(owner: sam, invitationCode: "SAMSAM2345")
        let alex = world.addAccount(name: "Alex", email: "alex@example.test")
        let backend = LocalBackend(world: world, signedInAs: alex)

        let preview = try await backend.previewInvitation(code: "samsa-m2345")
        XCTAssertEqual(preview.inviterName, "Sam")
        try await backend.acceptInvitation(code: "SAMSAM2345")
        let state = try await backend.spaceState()
        XCTAssertEqual(state.partner?.id, sam)
    }

    func testSendFailureLeavesReadsWorking() async throws {
        let world = LocalWorld()
        let a = world.addAccount(name: "A", email: "a@example.test")
        let b = world.addAccount(name: "B", email: "b@example.test")
        let couple = world.pair(a, b)
        let backend = LocalBackend(world: world, signedInAs: a)
        world.setSendFailure(.offline)
        do {
            _ = try await backend.send(id: UUID(), coupleID: couple, content: NoteContent(body: "x"))
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? AppError, .offline)
        }
        let notes = try await backend.recentNotes(coupleID: couple, before: nil, limit: 5)
        XCTAssertEqual(notes, [])
    }
}
