import XCTest
@testable import CoupleDomain

final class NoteFeedTests: XCTestCase {
    private let couple = UUID()
    private let me = UUID()
    private let partner = UUID()
    private let base = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func note(_ author: UUID, _ body: String, at offset: TimeInterval, id: UUID = UUID(), version: Int = 1, seen: Bool = false, deleted: Bool = false) -> Note {
        Note(
            id: id, coupleID: couple, authorID: author, body: body, version: version,
            seenAt: seen ? base : nil, deletedAt: deleted ? base : nil, createdAt: base.addingTimeInterval(offset)
        )
    }

    func testLatestReceivedAndSentAreTrackedSeparately() {
        let feed = NoteFeed([
            note(partner, "theirs old", at: 0), note(me, "mine", at: 10), note(partner, "theirs new", at: 20),
        ])
        XCTAssertEqual(feed.latestReceived(by: me)?.body, "theirs new")
        XCTAssertEqual(feed.latestSent(by: me)?.body, "mine")
        XCTAssertEqual(feed.notes.map(\.body), ["theirs new", "mine", "theirs old"])
    }

    func testAnOlderVersionNeverReplacesANewerOne() {
        let id = UUID()
        var feed = NoteFeed([note(partner, "edited", at: 0, id: id, version: 3)])
        feed.apply(note(partner, "stale", at: 0, id: id, version: 2))
        XCTAssertEqual(feed.notes.first?.body, "edited")
        feed.apply(note(partner, "newest", at: 0, id: id, version: 4))
        XCTAssertEqual(feed.notes.first?.body, "newest")
        XCTAssertEqual(feed.notes.count, 1)
    }

    func testDuplicateEventsAreIdempotent() {
        let incoming = note(partner, "hello", at: 0)
        var feed = NoteFeed()
        feed.apply(incoming)
        feed.apply(incoming)
        XCTAssertEqual(feed.notes.count, 1)
    }

    func testSeenStateSurvivesAReplayOfTheUnseenRow() {
        let id = UUID()
        var feed = NoteFeed([note(partner, "hello", at: 0, id: id, seen: true)])
        feed.apply(note(partner, "hello", at: 0, id: id, seen: false))
        XCTAssertNotNil(feed.notes.first?.seenAt)
    }

    func testDeletedNotesAreHiddenAndTheLatestFallsBack() {
        let newest = UUID()
        var feed = NoteFeed([note(partner, "older", at: 0), note(partner, "newer", at: 10, id: newest)])
        feed.apply(note(partner, "", at: 10, id: newest, version: 2, deleted: true))
        XCTAssertEqual(feed.latestReceived(by: me)?.body, "older")
        XCTAssertEqual(feed.visible.count, 1)
        XCTAssertEqual(feed.notes.count, 2, "the tombstone is kept so a stale copy cannot resurrect the note")
        feed.apply(note(partner, "newer", at: 10, id: newest, version: 1))
        XCTAssertEqual(feed.visible.count, 1)
    }

    func testUnseenCountOnlyCountsReceivedNotes() {
        let feed = NoteFeed([
            note(partner, "a", at: 0), note(partner, "b", at: 1, seen: true), note(me, "c", at: 2),
        ])
        XCTAssertEqual(feed.unseenCount(for: me), 1)
        XCTAssertEqual(feed.unseenCount(for: partner), 1)
    }

    func testEmptyFeed() {
        let feed = NoteFeed()
        XCTAssertNil(feed.latestReceived(by: me))
        XCTAssertEqual(feed.unseenCount(for: me), 0)
    }
}

final class ModelTests: XCTestCase {
    func testNoteStyleDecodesFromEmptyAndUnknownJSON() throws {
        let empty = try JSONDecoder().decode(NoteStyle.self, from: Data("{}".utf8))
        XCTAssertEqual(empty, NoteStyle())
        let future = try JSONDecoder().decode(
            NoteStyle.self, from: Data(#"{"paper":"blush","typeface":"hologram","stickers":"oops","new_field":1}"#.utf8)
        )
        XCTAssertEqual(future.paper, "blush")
        XCTAssertEqual(future.typeface, .hand)
        XCTAssertEqual(future.stickers, [])
    }

    func testNoteStyleRoundTrips() throws {
        let style = NoteStyle(paper: "lined", ink: "ocean", typeface: .serif, photoLayout: .full, stickers: [StickerPlacement(sticker: "sun", x: 0.2, y: 0.3, scale: 1.4, rotation: 12)])
        XCTAssertEqual(try JSONDecoder().decode(NoteStyle.self, from: JSONEncoder().encode(style)), style)
    }

    func testUnknownCatalogueIdsFallBackToDefaults() {
        XCTAssertEqual(Paper.find("retired-paper").id, Paper.defaultID)
        XCTAssertEqual(Ink.find("???").id, Ink.defaultID)
        XCTAssertEqual(Theme.find("???").id, Theme.defaultID)
        XCTAssertNil(Sticker.find("???"))
    }

    func testMediaPathsMatchTheStoragePolicyShape() {
        let couple = UUID()
        let photo = MediaPath.photo(coupleID: couple)
        XCTAssertNotNil(photo.range(of: #"^couples/[0-9a-f-]{36}/[0-9a-f-]{36}\.jpg$"#, options: .regularExpression))
        XCTAssertTrue(photo.hasPrefix("couples/\(couple.uuidString.lowercased())/"))
        XCTAssertNotNil(MediaPath.drawing(coupleID: couple).range(of: #"\.png$"#, options: .regularExpression))
        let user = UUID()
        XCTAssertEqual(MediaPath.avatar(userID: user), "\(user.uuidString.lowercased())/avatar.jpg")
    }

    func testPendingSendBackoff() {
        var send = PendingSend(coupleID: UUID(), content: NoteContent(body: "x"), createdAt: Date())
        XCTAssertEqual(send.retryDelay, 2)
        send.attempts = 3
        XCTAssertEqual(send.retryDelay, 8)
        send.attempts = 20
        XCTAssertEqual(send.retryDelay, 60)
        XCTAssertFalse(send.shouldRetryAutomatically)
    }

    func testProfileInitial() {
        XCTAssertEqual(Profile(id: UUID(), displayName: " ada").initial, "A")
        XCTAssertEqual(Profile(id: UUID(), displayName: "").initial, "·")
    }

    func testSpaceStateAccessors() {
        let space = CoupleSpace(id: UUID(), createdAt: Date())
        let partner = Profile(id: UUID(), displayName: "Ben")
        XCTAssertNil(SpaceState.none.space)
        XCTAssertNil(SpaceState.waiting(space).partner)
        XCTAssertEqual(SpaceState.paired(space, partner: partner).partner, partner)
    }
}
