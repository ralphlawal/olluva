import CoupleDomain
import CoupleSupabase
import XCTest

/// Drives the production Supabase client against a real project: the same
/// calls the app makes, from two people's points of view.
///
///   SUPABASE_HOST=<ref>.supabase.co SUPABASE_KEY=<publishable key> \
///     swift test --filter CoupleSupabaseLiveTests
///
/// Skipped when those are not set. It creates anonymous identities and rows in
/// that project; remove them afterwards (TESTING.md has the SQL).
final class LiveBackendTests: XCTestCase {
    private func makeBackend() throws -> Backend {
        let environment = ProcessInfo.processInfo.environment
        guard let host = environment["SUPABASE_HOST"], let key = environment["SUPABASE_KEY"],
              let url = URL(string: "https://\(host)")
        else { throw XCTSkip("Set SUPABASE_HOST and SUPABASE_KEY to run the live tests.") }
        return SupabaseBackendFactory.make(url: url, anonKey: key, keepsSessionInMemory: true)
    }

    private func assertThrows(_ expected: AppError, file: StaticString = #filePath, line: UInt = #line, _ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? AppError, expected, file: file, line: line)
        }
    }

    func testTheWholeProductThroughTheRealClient() async throws {
        let ada = try makeBackend()
        let ben = try makeBackend()

        // --- Starting without sign-up
        let signedOut = await ada.auth.restoreSession()
        XCTAssertEqual(signedOut, .signedOut)
        try await ada.auth.startAnonymously()
        try await ben.auth.startAnonymously()
        let adaState = await ada.auth.restoreSession()
        let benState = await ben.auth.restoreSession()
        let adaID = try XCTUnwrap(adaState.userID)
        let benID = try XCTUnwrap(benState.userID)
        XCTAssertFalse(adaState.isBackedUp)
        print("live test identities: \(adaID) \(benID)")

        var profile = try await ada.profiles.myProfile()
        XCTAssertEqual(profile.displayName, "", "a new identity has no name yet")
        profile = try await ada.profiles.updateProfile(displayName: "  Live Ada ", timeZone: "Europe/London")
        XCTAssertEqual(profile.displayName, "Live Ada")
        XCTAssertEqual(profile.timeZone, "Europe/London")
        _ = try await ben.profiles.updateProfile(displayName: "Live Ben", timeZone: "Europe/Lisbon")

        // --- Pairing
        var space = try await ada.couples.spaceState()
        XCTAssertEqual(space, .none)
        try await ada.couples.createSpace()
        await assertThrows(.alreadyInSpace) { try await ada.couples.createSpace() }
        space = try await ada.couples.spaceState()
        guard case .waiting = space else { return XCTFail("expected a waiting space, got \(space)") }

        let invitation = try await ada.couples.createInvitation()
        XCTAssertTrue(InviteCode.isComplete(invitation.code))
        XCTAssertGreaterThan(invitation.expiresAt, Date().addingTimeInterval(47 * 3600))
        await assertThrows(.ownInvitation) { try await ada.couples.acceptInvitation(code: invitation.code) }
        await assertThrows(.invitationUnavailable) { _ = try await ben.couples.previewInvitation(code: "ZZZZZ22222") }

        let preview = try await ben.couples.previewInvitation(code: InviteCode.display(invitation.code).lowercased())
        XCTAssertEqual(preview.inviterName, "Live Ada")
        try await ben.couples.acceptInvitation(code: invitation.code)

        space = try await ada.couples.spaceState()
        XCTAssertEqual(space.partner?.id, benID)
        XCTAssertEqual(space.partner?.displayName, "Live Ben")
        let coupleID = try XCTUnwrap(space.space?.id)
        XCTAssertNotNil(space.space?.pairedAt)
        await assertThrows(.alreadyPaired) { _ = try await ada.couples.createInvitation() }

        // --- Realtime: Ben is listening when Ada sends.
        let received = expectation(description: "Ben receives Ada's note live")
        received.assertForOverFulfill = false
        let noteID = UUID()
        let listener = Task {
            for await event in ben.realtime.events(coupleID: coupleID) {
                if case .note(let note) = event, note.id == noteID { received.fulfill() }
            }
        }
        defer { listener.cancel() }
        try await Task.sleep(for: .seconds(3)) // let the channel subscribe

        // --- Media and notes
        let photoPath = MediaPath.photo(coupleID: coupleID)
        let jpeg = try XCTUnwrap(Data(base64Encoded: "/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAP//////////////////////////////////////////////////////////////////////////////////////wgALCAABAAEBAREA/8QAFBABAAAAAAAAAAAAAAAAAAAAAP/aAAgBAQABPxA="))
        try await ada.media.upload(jpeg, to: photoPath, contentType: "image/jpeg")
        try await ada.media.upload(jpeg, to: photoPath, contentType: "image/jpeg") // a retry is not an error
        let downloaded = try await ben.media.download(path: photoPath)
        XCTAssertEqual(downloaded, jpeg)

        let style = NoteStyle(
            paper: "blush", ink: "rose", typeface: .serif, photoLayout: .full,
            stickers: [StickerPlacement(sticker: "heart", x: 0.8, y: 0.2, scale: 1.2, rotation: -10)]
        )
        let content = NoteContent(body: "Live check — dinner at eight? 🍝", style: style, photoPath: photoPath)
        let sent = try await ada.notes.send(id: noteID, coupleID: coupleID, content: content)
        XCTAssertEqual(sent.authorID, adaID)
        XCTAssertEqual(sent.version, 1)
        XCTAssertEqual(sent.content, content, "text, style and paths survive the round trip")
        let retried = try await ada.notes.send(id: noteID, coupleID: coupleID, content: content)
        XCTAssertEqual(retried.id, sent.id, "sending again returns the stored note")

        await fulfillment(of: [received], timeout: 15)

        var notes = try await ben.notes.recentNotes(coupleID: coupleID, before: nil, limit: 10)
        XCTAssertEqual(notes.map(\.id), [noteID])
        XCTAssertEqual(notes.first?.style, style)
        XCTAssertNil(notes.first?.seenAt)
        let older = try await ben.notes.recentNotes(coupleID: coupleID, before: sent.createdAt, limit: 10)
        XCTAssertTrue(older.isEmpty)

        try await ben.notes.markSeen(noteID: noteID)
        try await ben.notes.setReaction(noteID: noteID, kind: .love)
        await assertThrows(.notAuthor) { try await ada.notes.setReaction(noteID: noteID, kind: .love) }
        let reactions = try await ada.notes.reactions(coupleID: coupleID)
        XCTAssertEqual(reactions, [Reaction(noteID: noteID, userID: benID, kind: .love)])
        notes = try await ada.notes.recentNotes(coupleID: coupleID, before: nil, limit: 10)
        XCTAssertNotNil(notes.first?.seenAt)

        // --- Editing with version checks
        await assertThrows(.notAuthor) { _ = try await ben.notes.update(noteID: noteID, expectedVersion: 1, content: NoteContent(body: "hijack")) }
        let edited = try await ada.notes.update(noteID: noteID, expectedVersion: 1, content: NoteContent(body: "Make it nine.", style: style, photoPath: photoPath))
        XCTAssertEqual(edited.version, 2)
        await assertThrows(.versionConflict) { _ = try await ada.notes.update(noteID: noteID, expectedVersion: 1, content: NoteContent(body: "stale")) }
        await assertThrows(.invalidContent(.empty)) { _ = try await ada.notes.send(id: UUID(), coupleID: coupleID, content: NoteContent(body: "  ")) }

        // --- Memories
        let memoryID = try await ben.memories.saveNote(noteID: noteID, caption: "Our first live note")
        let again = try await ada.memories.saveNote(noteID: noteID, caption: "")
        XCTAssertEqual(memoryID, again)
        let moment = try await ada.memories.add(
            NewMoment(title: "Went live", caption: "It works.", occurredOn: DayDate(year: 2026, month: 10, day: 10)), coupleID: coupleID
        )
        let updated = try await ben.memories.update(id: moment.id, title: "We went live", caption: "It works.", occurredOn: moment.occurredOn)
        XCTAssertEqual(updated.title, "We went live")
        let count = try await ada.memories.count(coupleID: coupleID)
        XCTAssertEqual(count, 2)
        let firstPage = try await ada.memories.memories(coupleID: coupleID, after: nil, limit: 1)
        XCTAssertEqual(firstPage.count, 1)
        let secondPage = try await ada.memories.memories(coupleID: coupleID, after: MemoryCursor(after: firstPage[0]), limit: 5)
        XCTAssertEqual(secondPage.count, 1)
        XCTAssertNotEqual(firstPage[0].id, secondPage[0].id, "pagination neither repeats nor skips")
        let saved = try XCTUnwrap((firstPage + secondPage).first { $0.id == memoryID })
        XCTAssertEqual(saved.kind, .note)
        XCTAssertEqual(saved.content.photoPath, photoPath)
        try await ben.memories.deleteMemory(id: moment.id)

        // --- Important dates
        let shared = try await ada.dates.add(ImportantDate(
            coupleID: coupleID, createdBy: adaID, title: "Anniversary", kind: .anniversary,
            startsOn: DayDate(year: 2024, month: 6, day: 14), remindDaysBefore: [7, 0]
        ))
        XCTAssertEqual(shared.remindDaysBefore.sorted(), [0, 7])
        let secret = try await ada.dates.add(ImportantDate(
            coupleID: coupleID, createdBy: adaID, title: "Proposal", kind: .milestone,
            startsOn: DayDate(year: 2027, month: 2, day: 14), recurrence: .none, visibility: .private
        ))
        let benDates = try await ben.dates.dates(coupleID: coupleID)
        XCTAssertEqual(benDates.map(\.title), ["Anniversary"], "a private date stays private")
        var tampered = secret
        tampered.title = "found it"
        await assertThrows(.noteNotFound) { _ = try await ben.dates.update(tampered) }
        var renamed = shared
        renamed.title = "Our day"
        let benEdit = try await ben.dates.update(renamed)
        XCTAssertEqual(benEdit.title, "Our day")
        try await ada.dates.deleteDate(id: secret.id)

        // --- Scheduled messages
        let surpriseID = UUID()
        let deliverAt = Date().addingTimeInterval(3600)
        let scheduled = try await ada.schedule.schedule(
            id: surpriseID, coupleID: coupleID, content: NoteContent(body: "Surprise."), deliverAt: deliverAt, timeZone: "Europe/London"
        )
        XCTAssertEqual(scheduled.status, .pending)
        XCTAssertEqual(scheduled.deliverAt.timeIntervalSince1970, deliverAt.timeIntervalSince1970, accuracy: 0.001)
        let hidden = try await ben.schedule.scheduledMessages()
        XCTAssertTrue(hidden.isEmpty, "a surprise is invisible to the partner")
        await assertThrows(.scheduledLimitReached) {
            _ = try await ada.schedule.schedule(id: UUID(), coupleID: coupleID, content: NoteContent(body: "Two."), deliverAt: deliverAt, timeZone: "UTC")
        }
        await assertThrows(.deliveryTooSoon) {
            _ = try await ada.schedule.update(id: surpriseID, expectedVersion: 1, content: NoteContent(body: "x"), deliverAt: Date(), timeZone: "UTC")
        }
        let rescheduled = try await ada.schedule.update(
            id: surpriseID, expectedVersion: 1, content: NoteContent(body: "Surprise!"), deliverAt: deliverAt.addingTimeInterval(600), timeZone: "Europe/London"
        )
        XCTAssertEqual(rescheduled.version, 2)
        try await ada.schedule.cancel(id: surpriseID)
        let mine = try await ada.schedule.scheduledMessages()
        XCTAssertEqual(mine.first?.status, .cancelled)

        // --- Themes and entitlement
        let entitlement = try await ada.entitlements.entitlement()
        XCTAssertEqual(entitlement, .free)
        try await ada.couples.setTheme(id: "plum", accentHex: nil)
        await assertThrows(.premiumRequired) { try await ada.couples.setTheme(id: "dusk", accentHex: nil) }
        let themed = try await ben.couples.spaceState()
        XCTAssertEqual(themed.space?.themeID, "plum")

        // --- Notifications
        var preferences = try await ada.notifications.preferences()
        XCTAssertEqual(preferences, NotificationPreferences(), "previews are off by default")
        preferences.showPreviews = true
        try await ada.notifications.update(preferences)
        let stored = try await ada.notifications.preferences()
        XCTAssertTrue(stored.showPreviews)
        let token = String(repeating: "ab", count: 32)
        try await ada.notifications.registerDevice(token: token, environment: .sandbox)
        try await ada.notifications.unregisterDevice(token: token)

        // --- Avatar
        let withAvatar = try await ada.profiles.setAvatar(jpeg: jpeg)
        let avatarPath = try XCTUnwrap(withAvatar.avatarPath)
        let partnerSees = try await ben.media.downloadAvatar(path: avatarPath)
        XCTAssertEqual(partnerSees, jpeg)

        // --- Export
        let exportData = try await ada.auth.exportData()
        let export = try XCTUnwrap(String(data: exportData, encoding: .utf8))
        XCTAssertTrue(export.contains("Make it nine."))
        XCTAssertTrue(export.contains("Live Ada"))
        XCTAssertFalse(export.contains("Live Ben"))

        // --- Deleting a note, then unlinking
        await assertThrows(.notAuthor) { try await ben.notes.delete(noteID: noteID) }
        try await ada.notes.delete(noteID: noteID)
        notes = try await ben.notes.recentNotes(coupleID: coupleID, before: nil, limit: 10)
        XCTAssertEqual(notes.first?.isDeleted, true)
        XCTAssertEqual(notes.first?.body, "")

        try await ben.couples.leaveSpace(blockPartner: false)
        let adaAfter = try await ada.couples.spaceState()
        let benAfter = try await ben.couples.spaceState()
        XCTAssertEqual(adaAfter, .none)
        XCTAssertEqual(benAfter, .none)
        let afterNotes = try await ada.notes.recentNotes(coupleID: coupleID, before: nil, limit: 10)
        XCTAssertTrue(afterNotes.isEmpty)

        // --- Session end
        try await ben.auth.signOut()
        let benEnd = await ben.auth.restoreSession()
        XCTAssertEqual(benEnd, .signedOut)
        await assertThrows(.sessionExpired) { _ = try await ben.profiles.myProfile() }
    }
}
