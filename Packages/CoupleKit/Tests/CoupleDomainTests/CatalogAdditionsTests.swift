import CoupleDomain
import XCTest

final class CatalogAdditionsTests: XCTestCase {
    func testStickerIDsAreUniqueAndTheOriginalsStillExist() {
        XCTAssertEqual(Set(Sticker.all.map(\.id)).count, Sticker.all.count)
        // Ids stored in notes already sent must keep drawing.
        for id in ["heart", "star", "sun", "moon", "leaf", "coffee", "sparkles", "plane", "home", "music", "gift", "balloon", "paw", "umbrella"] {
            XCTAssertNotNil(Sticker.find(id), id)
        }
        for pack in Sticker.Pack.allCases {
            XCTAssertFalse(Sticker.inPack(pack).isEmpty, pack.rawValue)
        }
        // Something to try in the packs people will open first, without paying.
        for pack in [Sticker.Pack.love, .cute, .food, .mood, .celebrate, .classic] {
            XCTAssertTrue(Sticker.inPack(pack).contains { !$0.isPremium }, pack.rawValue)
        }
    }

    func testAStyleFromANewerOrOlderAppStillDecodes() throws {
        let future = Data(#"{"paper":"hologram","ink":"neon","typeface":"graffiti","effect":"fireworks","stickers":[]}"#.utf8)
        let style = try JSONDecoder().decode(NoteStyle.self, from: future)
        XCTAssertEqual(style.typeface, .hand)
        XCTAssertNil(style.effect)
        XCTAssertEqual(Paper.find(style.paper).id, Paper.defaultID)

        let old = Data(#"{"paper":"blush","ink":"rose","typeface":"serif"}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(NoteStyle.self, from: old).effect)

        let sent = NoteStyle(paper: "sunset", typeface: .script, effect: .confetti)
        let round = try JSONDecoder().decode(NoteStyle.self, from: JSONEncoder().encode(sent))
        XCTAssertEqual(round, sent)
    }

    func testNewLooksArePremiumAndTheOriginalsAreUnchanged() {
        XCTAssertFalse(EntitlementRules.premiumElements(in: NoteStyle()))
        XCTAssertTrue(EntitlementRules.premiumElements(in: NoteStyle(typeface: .script)))
        XCTAssertTrue(EntitlementRules.premiumElements(in: NoteStyle(effect: .hearts)))
        XCTAssertTrue(EntitlementRules.premiumElements(in: NoteStyle(paper: "sunset")))
        XCTAssertTrue(EntitlementRules.premiumElements(in: NoteStyle(stickers: [StickerPlacement(sticker: "panda")])))
        XCTAssertFalse(EntitlementRules.premiumElements(in: NoteStyle(stickers: [StickerPlacement(sticker: "kiss")])))
        for tool in [DrawingTool.pen, .eraser] { XCTAssertFalse(tool.isPremium) }
        for tool in [DrawingTool.marker, .pencil, .fountain, .fineliner, .watercolour, .crayon] { XCTAssertTrue(tool.isPremium) }
    }

    func testTheDailyQuestionIsTheSameForEveryoneOnADayAndChangesTheNext() {
        let day = DayDate(year: 2026, month: 10, day: 12)
        let next = DayDate(year: 2026, month: 10, day: 13)
        XCTAssertEqual(DailyQuestion.question(on: day), DailyQuestion.question(on: day))
        XCTAssertEqual((DailyQuestion.index(on: day) + 1) % DailyQuestion.all.count, DailyQuestion.index(on: next))
        XCTAssertEqual(Set(DailyQuestion.all).count, DailyQuestion.all.count)
        XCTAssertGreaterThanOrEqual(DailyQuestion.all.count, 60)
    }

    func testStreakCountsDaysBothWroteAndForgivesAnUnfinishedToday() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        func day(_ d: Int) -> DayDate { DayDate(year: 2026, month: 10, day: d) }
        let today = day(12)
        let mine: Set<DayDate> = [day(9), day(10), day(11)]
        let theirs: Set<DayDate> = [day(9), day(10), day(11)]
        XCTAssertEqual(StreakRules.streak(mine: mine, partner: theirs, today: today, calendar: calendar), Streak(days: 3))
        XCTAssertEqual(
            StreakRules.streak(mine: mine.union([today]), partner: theirs, today: today, calendar: calendar),
            Streak(days: 3, wroteToday: true)
        )
        XCTAssertEqual(
            StreakRules.streak(mine: mine.union([today]), partner: theirs.union([today]), today: today, calendar: calendar),
            Streak(days: 4, wroteToday: true, partnerWroteToday: true)
        )
        XCTAssertEqual(StreakRules.streak(mine: [day(9), day(11)], partner: [day(9), day(10), day(11)], today: today, calendar: calendar).days, 1)
        XCTAssertEqual(StreakRules.streak(mine: [day(10)], partner: [day(10)], today: today, calendar: calendar).days, 0)
        // Across a month boundary.
        let first = DayDate(year: 2026, month: 11, day: 1)
        let both: Set<DayDate> = [DayDate(year: 2026, month: 10, day: 30), DayDate(year: 2026, month: 10, day: 31)]
        XCTAssertEqual(StreakRules.streak(mine: both, partner: both, today: first, calendar: calendar).days, 2)
    }
}
