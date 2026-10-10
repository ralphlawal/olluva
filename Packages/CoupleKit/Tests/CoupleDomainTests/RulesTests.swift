import XCTest
@testable import CoupleDomain

final class InputRulesTests: XCTestCase {
    func testEmptyNoteIsRejected() {
        XCTAssertThrowsError(try InputRules.validate(NoteContent(body: "  \n "))) {
            XCTAssertEqual($0 as? AppError, .invalidContent(.empty))
        }
    }

    func testNoteWithOnlyMediaIsAccepted() throws {
        try InputRules.validate(NoteContent(photoPath: "couples/x/y.jpg"))
        try InputRules.validate(NoteContent(drawingPath: "couples/x/y.png"))
    }

    func testBodyLimitIsInclusive() throws {
        try InputRules.validate(NoteContent(body: String(repeating: "a", count: Validation.noteBodyLimit)))
        XCTAssertThrowsError(try InputRules.validate(NoteContent(body: String(repeating: "a", count: Validation.noteBodyLimit + 1)))) {
            XCTAssertEqual($0 as? AppError, .invalidContent(.tooLong(limit: 280)))
        }
    }

    func testBodyLimitCountsCharactersNotBytes() throws {
        // 280 family emoji are far more than 280 bytes but exactly 280 characters.
        try InputRules.validate(NoteContent(body: String(repeating: "👨‍👩‍👧", count: 280)))
    }

    func testStickerLimit() {
        let stickers = (0...Validation.maximumStickers).map { _ in StickerPlacement(sticker: "heart") }
        XCTAssertThrowsError(try InputRules.validate(NoteContent(body: "x", style: NoteStyle(stickers: stickers))))
    }

    func testEmailValidation() {
        for good in ["a@b.co", "first.last+tag@example.com", "  padded@example.org  "] {
            XCTAssertTrue(InputRules.isValidEmail(good), good)
        }
        for bad in ["", "plain", "@example.com", "a@b", "a@.com", "a b@example.com", "a@b..com", "a@@b.com"] {
            XCTAssertFalse(InputRules.isValidEmail(bad), bad)
        }
    }

    func testDisplayNameCleaning() {
        XCTAssertEqual(InputRules.cleanedDisplayName("  Ada  "), "Ada")
        XCTAssertEqual(InputRules.cleanedDisplayName(String(repeating: "x", count: 60)).count, 40)
        XCTAssertFalse(InputRules.isValidDisplayName("   "))
        XCTAssertTrue(InputRules.isValidDisplayName("Ada"))
    }

    func testPasswordRule() {
        XCTAssertFalse(InputRules.isAcceptablePassword("short"))
        XCTAssertTrue(InputRules.isAcceptablePassword("longenough"))
    }
}

final class InviteCodeTests: XCTestCase {
    func testNormalizeAcceptsHowPeopleType() {
        XCTAssertEqual(InviteCode.normalize("abcde-fghjk"), "ABCDEFGHJK")
        XCTAssertEqual(InviteCode.normalize(" ab cd e - fg hj k "), "ABCDEFGHJK")
        XCTAssertEqual(InviteCode.normalize("ABCDEFGHJKLMNOP"), "ABCDEFGHJK")
    }

    func testCompleteness() {
        XCTAssertTrue(InviteCode.isComplete("ABCDE-FGHJK"))
        XCTAssertFalse(InviteCode.isComplete("ABCDE"))
        XCTAssertFalse(InviteCode.isComplete("ABCDE-FGH1O"), "0, 1, I and O are not in the alphabet")
    }

    func testDisplayFormatting() {
        XCTAssertEqual(InviteCode.display("abcdefghjk"), "ABCDE-FGHJK")
        XCTAssertEqual(InviteCode.display("abc"), "ABC")
    }

    func testLinkRoundTrip() {
        let url = InviteCode.link(for: "abcde-fghjk")
        XCTAssertEqual(url.absoluteString, "olluva://join?code=ABCDEFGHJK")
        XCTAssertEqual(InviteCode.extract(from: url), "ABCDEFGHJK")
    }

    func testExtractRejectsForeignOrMalformedLinks() {
        XCTAssertNil(InviteCode.extract(from: URL(string: "https://example.com/join?code=ABCDEFGHJK")!))
        XCTAssertNil(InviteCode.extract(from: URL(string: "olluva://note?code=ABCDEFGHJK")!))
        XCTAssertNil(InviteCode.extract(from: URL(string: "olluva://join?code=short")!))
        XCTAssertNil(InviteCode.extract(from: URL(string: "olluva://join")!))
    }
}

final class DateRulesTests: XCTestCase {
    private func day(_ iso: String) -> DayDate { DayDate(iso: iso)! }

    func testDayDateParsingAndOrdering() {
        XCTAssertEqual(day("2026-06-14").description, "2026-06-14")
        XCTAssertNil(DayDate(iso: "2026-13-01"))
        XCTAssertNil(DayDate(iso: "nonsense"))
        XCTAssertLessThan(day("2025-12-31"), day("2026-01-01"))
    }

    func testDayDateCodableUsesPlainString() throws {
        let data = try JSONEncoder().encode([day("2026-02-03")])
        XCTAssertEqual(String(data: data, encoding: .utf8), "[\"2026-02-03\"]")
        XCTAssertEqual(try JSONDecoder().decode([DayDate].self, from: data), [day("2026-02-03")])
    }

    // These cases are the same ones asserted against the SQL implementation in
    // supabase/tests/content.test.js, so the two cannot drift apart unnoticed.
    func testNextOccurrenceMatchesDatabase() {
        let cases: [(String, ImportantDate.Recurrence, String, String?)] = [
            ("2020-06-14", .yearly, "2026-06-14", "2026-06-14"),
            ("2020-06-14", .yearly, "2026-06-15", "2027-06-14"),
            ("2020-02-29", .yearly, "2026-01-01", "2026-02-28"),
            ("2020-02-29", .yearly, "2028-02-01", "2028-02-29"),
            ("2026-01-31", .monthly, "2026-02-10", "2026-02-28"),
            ("2026-01-31", .monthly, "2026-03-01", "2026-03-31"),
            ("2030-05-01", .yearly, "2026-01-01", "2030-05-01"),
            ("2020-05-01", .none, "2026-01-01", nil),
        ]
        for (start, recurrence, today, expected) in cases {
            XCTAssertEqual(
                DateRules.nextOccurrence(of: day(start), recurrence: recurrence, onOrAfter: day(today)),
                expected.map(day), "\(start) \(recurrence) from \(today)"
            )
        }
    }

    func testMonthlyRollsOverYearEnd() {
        XCTAssertEqual(DateRules.nextOccurrence(of: day("2024-03-15"), recurrence: .monthly, onOrAfter: day("2026-12-20")), day("2027-01-15"))
    }

    func testDaysBetween() {
        XCTAssertEqual(DateRules.daysBetween(day("2026-01-01"), day("2026-01-01")), 0)
        XCTAssertEqual(DateRules.daysBetween(day("2026-02-27"), day("2026-03-01")), 2)
        XCTAssertEqual(DateRules.daysBetween(day("2024-02-27"), day("2024-03-01")), 3)
        XCTAssertEqual(DateRules.daysBetween(day("2026-03-28"), day("2026-03-30")), 2, "unaffected by daylight saving")
    }

    func testUpcomingSortsSoonestFirstAndDropsPassedOneOffs() {
        let couple = UUID(), me = UUID()
        let dates = [
            ImportantDate(coupleID: couple, createdBy: me, title: "Trip", startsOn: day("2026-01-05"), recurrence: .none),
            ImportantDate(coupleID: couple, createdBy: me, title: "Anniversary", kind: .anniversary, startsOn: day("2020-06-14")),
            ImportantDate(coupleID: couple, createdBy: me, title: "Birthday", kind: .birthday, startsOn: day("1994-06-01")),
        ]
        let upcoming = DateRules.upcoming(dates, today: day("2026-05-30"))
        XCTAssertEqual(upcoming.map(\.date.title), ["Birthday", "Anniversary"])
        XCTAssertEqual(upcoming.map(\.daysAway), [2, 15])
        XCTAssertEqual(DateRules.upcoming(dates, today: day("2026-05-30"), limit: 1).count, 1)
    }

    func testAnniversaryCount() {
        let date = ImportantDate(coupleID: UUID(), createdBy: UUID(), title: "Us", startsOn: day("2020-06-14"))
        XCTAssertEqual(DateRules.anniversaryCount(of: date, at: day("2026-06-14")), 6)
        XCTAssertNil(DateRules.anniversaryCount(of: date, at: day("2020-06-14")))
    }

    func testReminderSanitising() {
        XCTAssertEqual(DateRules.sanitizedReminders([7, 7, 2, 0, 99]), [0, 7])
        XCTAssertEqual(DateRules.sanitizedReminders([30, 14, 7, 3, 1, 0]).count, ImportantDate.maximumReminders)
    }
}

final class ScheduleRulesTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    func testDeliveryWindow() throws {
        XCTAssertThrowsError(try ScheduleRules.validate(deliverAt: now.addingTimeInterval(60), now: now)) {
            XCTAssertEqual($0 as? AppError, .deliveryTooSoon)
        }
        try ScheduleRules.validate(deliverAt: now.addingTimeInterval(600), now: now)
        XCTAssertThrowsError(try ScheduleRules.validate(deliverAt: now.addingTimeInterval(3 * 365 * 86_400), now: now)) {
            XCTAssertEqual($0 as? AppError, .deliveryTooFar)
        }
    }

    func testEarliestSelectableIsValidAndOnAFiveMinuteBoundary() throws {
        let earliest = ScheduleRules.earliestSelectable(now: now)
        try ScheduleRules.validate(deliverAt: earliest, now: now)
        XCTAssertEqual(earliest.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 300), 0)
    }

    func testOnlyPendingMessagesAreEditable() {
        var message = ScheduledMessage(id: UUID(), coupleID: UUID(), content: NoteContent(body: "x"), deliverAt: now, timeZone: "UTC", createdAt: now)
        XCTAssertTrue(ScheduleRules.canEdit(message))
        for status in [ScheduledMessage.Status.delivered, .cancelled, .failed] {
            message.status = status
            XCTAssertFalse(ScheduleRules.canEdit(message))
        }
    }
}

final class EntitlementRulesTests: XCTestCase {
    private let premium = Entitlement(isPremium: true, source: .partner)

    func testLimitsMatchTheDatabase() {
        // app_private.couple_limit: memories 30 / 2000, scheduled_pending 1 / 50.
        XCTAssertEqual(Entitlement.free.limits, ProductConfiguration.Limits(memories: 30, pendingScheduledMessages: 1))
        XCTAssertEqual(premium.limits, ProductConfiguration.Limits(memories: 2000, pendingScheduledMessages: 50))
    }

    func testThemeCatalogueMatchesTheDatabaseSeed() {
        XCTAssertEqual(Theme.all.map(\.id), ["paper", "plum", "linen", "dusk", "sage", "ink"])
        XCTAssertEqual(Theme.all.filter { !$0.isPremium }.map(\.id), ["paper", "plum"])
    }

    func testFreeTierIsGenuinelyUsable() {
        XCTAssertGreaterThanOrEqual(Paper.all.filter { !$0.isPremium }.count, 4)
        XCTAssertGreaterThanOrEqual(Ink.all.filter { !$0.isPremium }.count, 6)
        XCTAssertGreaterThanOrEqual(Sticker.all.filter { !$0.isPremium }.count, 6)
        XCTAssertTrue(EntitlementRules.canUse(DrawingTool.pen, with: .free))
        XCTAssertTrue(EntitlementRules.canUse(DrawingTool.eraser, with: .free))
        XCTAssertTrue(EntitlementRules.canUse(WidgetStyle.note, with: .free))
        XCTAssertTrue(EntitlementRules.canUse(Paper.find(Paper.defaultID), with: .free))
        XCTAssertTrue(EntitlementRules.canUse(Ink.find(Ink.defaultID), with: .free))
    }

    func testPremiumGating() {
        XCTAssertFalse(EntitlementRules.canUse(Paper.find("midnight"), with: .free))
        XCTAssertTrue(EntitlementRules.canUse(Paper.find("midnight"), with: premium))
        XCTAssertFalse(EntitlementRules.canUse(DrawingTool.marker, with: .free))
        XCTAssertFalse(EntitlementRules.canUseCustomAccent(with: .free))
        XCTAssertFalse(EntitlementRules.canSaveMemory(currentCount: 30, entitlement: .free))
        XCTAssertTrue(EntitlementRules.canSaveMemory(currentCount: 30, entitlement: premium))
        XCTAssertTrue(EntitlementRules.canSchedule(pendingCount: 0, entitlement: .free))
        XCTAssertFalse(EntitlementRules.canSchedule(pendingCount: 1, entitlement: .free))
    }

    func testPartnerSourcedPremiumCountsTheSame() {
        XCTAssertEqual(premium.source, .partner)
        XCTAssertTrue(EntitlementRules.canUse(Theme.find("dusk"), with: premium))
    }

    func testPremiumElementDetection() {
        XCTAssertFalse(EntitlementRules.premiumElements(in: NoteStyle()))
        XCTAssertTrue(EntitlementRules.premiumElements(in: NoteStyle(paper: "kraft")))
        XCTAssertTrue(EntitlementRules.premiumElements(in: NoteStyle(stickers: [StickerPlacement(sticker: "gift")])))
    }

    func testCatalogueIdsAreUniqueAndTemplatesResolve() {
        XCTAssertEqual(Set(Paper.all.map(\.id)).count, Paper.all.count)
        XCTAssertEqual(Set(Ink.all.map(\.id)).count, Ink.all.count)
        XCTAssertEqual(Set(Sticker.all.map(\.id)).count, Sticker.all.count)
        for template in NoteTemplate.all {
            XCTAssertTrue(Paper.all.contains { $0.id == template.style.paper }, template.id)
            XCTAssertTrue(Ink.all.contains { $0.id == template.style.ink }, template.id)
            for placement in template.style.stickers {
                XCTAssertNotNil(Sticker.find(placement.sticker), template.id)
            }
            // A free template must not smuggle in premium elements.
            if !template.isPremium {
                XCTAssertFalse(EntitlementRules.premiumElements(in: template.style), template.id)
            }
        }
    }
}

final class ErrorMappingTests: XCTestCase {
    func testServerMessagesMapToTypedErrors() {
        XCTAssertEqual(AppError(serverMessage: "version_conflict"), .versionConflict)
        XCTAssertEqual(AppError(serverMessage: "invitation_expired"), .invitationExpired)
        XCTAssertEqual(AppError(serverMessage: "memory_limit_reached"), .memoryLimitReached)
        XCTAssertEqual(AppError(serverMessage: " premium_required\n"), .premiumRequired)
        XCTAssertNil(AppError(serverMessage: "something else entirely"))
    }

    func testRetryability() {
        XCTAssertTrue(AppError.offline.isRetryable)
        XCTAssertTrue(AppError.uploadFailed.isRetryable)
        XCTAssertFalse(AppError.versionConflict.isRetryable)
        XCTAssertFalse(AppError.invalidContent(.empty).isRetryable)
        XCTAssertFalse(AppError.memoryLimitReached.isRetryable)
    }
}
