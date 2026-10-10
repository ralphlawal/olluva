import CoupleDomain
import CoupleWidgetUI
import XCTest

final class WidgetSnapshotTests: XCTestCase {
    private var directory: URL!
    private var store: WidgetSnapshotStore!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("widget-\(UUID().uuidString)")
        store = WidgetSnapshotStore(directory: directory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func noteSnapshot(_ body: String, id: UUID = UUID(), unseen: Bool = true, hidden: Bool = true) -> WidgetSnapshot {
        WidgetSnapshot(
            state: .note, partnerName: "Ben", hidesContentOnLockScreen: hidden,
            note: .init(id: id, content: NoteContent(body: body), createdAt: Date(timeIntervalSinceReferenceDate: 800_000_000), isUnseen: unseen),
            updatedAt: Date(timeIntervalSinceReferenceDate: 800_000_000)
        )
    }

    func testMissingOrCorruptSnapshotMeansSignedOut() throws {
        XCTAssertEqual(store.load().state, .signedOut)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: directory.appendingPathComponent("snapshot.json"))
        XCTAssertEqual(store.load().state, .signedOut)
    }

    func testRoundTrip() throws {
        let snapshot = noteSnapshot("see you at seven")
        try store.save(snapshot)
        XCTAssertEqual(store.load(), snapshot)
    }

    func testOnlyTheCurrentNotesImagesAreKept() throws {
        let first = UUID(), second = UUID()
        try store.save(noteSnapshot("one", id: first), photo: Data([1]), drawing: Data([2]))
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        XCTAssertEqual(files.count, 3)
        XCTAssertEqual(store.load().note?.photoFile, "\(first.uuidString.lowercased())-photo.jpg")

        try store.save(noteSnapshot("two", id: second), drawing: Data([3]))
        let after = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        XCTAssertEqual(after, ["\(second.uuidString.lowercased())-drawing.png", "snapshot.json"])
        XCTAssertNil(store.load().note?.photoFile)
    }

    func testClearRemovesAllNoteContent() throws {
        try store.save(noteSnapshot("private words"), photo: Data([1]))
        store.clear()
        XCTAssertEqual(store.load().state, .signedOut)
        XCTAssertNil(store.load().note)
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(files, ["snapshot.json"])
        let raw = try String(contentsOf: directory.appendingPathComponent("snapshot.json"), encoding: .utf8)
        XCTAssertFalse(raw.contains("private words"))
    }

    func testLockScreenHidesContentUnlessOptedIn() {
        let hidden = noteSnapshot("meet me by the bridge", hidden: true)
        XCTAssertNil(LockScreenText.body(for: hidden))
        XCTAssertFalse(LockScreenText.inline(for: hidden).contains("bridge"))
        XCTAssertEqual(LockScreenText.headline(for: hidden), "New note from Ben")

        let shown = noteSnapshot("meet me by the bridge", hidden: false)
        XCTAssertEqual(LockScreenText.body(for: shown), "meet me by the bridge")
        XCTAssertEqual(LockScreenText.inline(for: shown), "Ben: meet me by the bridge")
        XCTAssertEqual(LockScreenText.headline(for: noteSnapshot("x", unseen: false)), "From Ben")
    }

    func testLockScreenNeverShowsContentWithoutANote() {
        for state in [WidgetSnapshot.State.signedOut, .unpaired, .empty] {
            let snapshot = WidgetSnapshot(state: state, partnerName: "Ben", hidesContentOnLockScreen: false)
            XCTAssertNil(LockScreenText.body(for: snapshot))
            XCTAssertFalse(LockScreenText.headline(for: snapshot).isEmpty)
        }
    }

    func testDeepLinks() {
        let id = UUID()
        XCTAssertEqual(noteSnapshot("x", id: id).deepLink, DeepLink.note(id).url)
        XCTAssertEqual(WidgetSnapshot(state: .unpaired).deepLink, DeepLink.pair.url)
        XCTAssertEqual(WidgetSnapshot(state: .empty).deepLink, DeepLink.compose.url)

        XCTAssertEqual(DeepLink(url: DeepLink.note(id).url), .note(id))
        XCTAssertEqual(DeepLink(url: DeepLink.compose.url), .compose)
        XCTAssertEqual(DeepLink(url: URL(string: "couplenotes://join?code=ABCDEFGHJK")!), .join(code: "ABCDEFGHJK"))
        XCTAssertNil(DeepLink(url: URL(string: "couplenotes://note/not-a-uuid")!))
        XCTAssertNil(DeepLink(url: URL(string: "https://example.com/note/\(id)")!))
        XCTAssertNil(DeepLink(url: URL(string: "couplenotes://unknown")!))
    }

    func testDownsamplingRejectsNonImages() {
        XCTAssertNil(WidgetSnapshotStore.downsampledImage(from: Data("nope".utf8), maxPixel: 100))
        XCTAssertNil(store.image(named: nil))
        XCTAssertNil(store.image(named: "missing.jpg"))
    }
}
