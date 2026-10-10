import XCTest

final class HomeAndNotesUITests: UITestCase {
    func testANewCoupleIsInvitedToWriteTheirFirstNote() {
        let app = XCUIApplication.launched(.empty)
        app.element("home.firstNote").waitToAppear()
        XCTAssertTrue(app.staticTexts["A blank page"].exists)
        snapshot("20-home-empty")
        app.element("home.firstNote").tap()
        app.element("composer.text").waitToAppear()
    }

    func testHomeShowsTheLatestNoteAndOpensIt() {
        let app = XCUIApplication.launched(.paired)
        app.element("home.latestNote").waitToAppear()
        XCTAssertTrue(app.staticTexts["Sam"].exists)
        snapshot("21-home")

        app.element("home.latestNote").tap()
        app.element("note.reply").waitToAppear()
        snapshot("22-note-received")

        // React, then keep the note.
        app.element("note.reaction.love").tap()
        app.element("note.save").tap()
        app.buttons["Saved to Memories"].waitToAppear()
        snapshot("23-note-reacted-saved")
        app.element("note.done").tap()

        // Opening it marked it as read: the "New" flag is gone.
        app.element("home.latestNote").waitToAppear()
        XCTAssertFalse(app.staticTexts["New"].exists)
    }

    func testWritingStylingPreviewingAndSendingANote() {
        let app = XCUIApplication.launched(.paired)
        app.element("home.compose").tapWhenReady()

        let text = app.element("composer.text").waitToAppear()
        // An empty note cannot be sent: pressing Send leaves the composer open.
        app.element("composer.send").tap()
        XCTAssertTrue(text.exists)
        text.tap()
        text.typeText("Yes to dinner. I’ll bring dessert.")
        snapshot("24-composer-text")

        app.element("composer.tool.style").tap()
        app.element("swatch.lilac").tapWhenReady()
        app.element("swatch.ocean").tap()
        snapshot("25-composer-style")

        app.element("composer.tool.stickers").tap()
        app.element("sticker.add.heart").tapWhenReady()
        app.element("sticker.remove").waitToAppear()
        snapshot("26-composer-stickers")

        app.element("composer.preview").tap()
        app.element("preview.done").waitToAppear()
        snapshot("27-composer-preview")
        app.element("preview.done").tap()

        app.element("composer.send").tap()
        app.element("home.sentNote").waitToAppear(12)
        snapshot("28-home-after-send")

        // The demo partner reads it; the sender sees that it was seen.
        app.element("home.sentNote").tap()
        app.element("note.status").waitToAppear()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'saw this'")).firstMatch.waitForExistence(timeout: 10))
        snapshot("29-note-sent-seen")
    }

    func testDrawingANote() {
        let app = XCUIApplication.launched(.paired)
        app.element("home.draw").tapWhenReady()
        app.element("draw.tool.pen").waitToAppear()

        // Draw two strokes on the note, which fills the upper part of the screen.
        let screen = app.windows.firstMatch
        let from = screen.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.22))
        let via = screen.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.42))
        let to = screen.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.2))
        from.press(forDuration: 0.05, thenDragTo: via)
        via.press(forDuration: 0.05, thenDragTo: to)
        snapshot("30-composer-draw")

        // A drawing alone is a sendable note.
        XCTAssertTrue(app.element("draw.undo").isEnabled)
        app.element("composer.send").tap()
        app.element("home.sentNote").waitToAppear(12)
    }

    func testAFailedSendIsNeverReportedAsSent() {
        let app = XCUIApplication.launched(.paired, extraArguments: ["-demoSendsFail"])
        app.element("home.compose").tapWhenReady()
        let text = app.element("composer.text").waitToAppear()
        text.tap()
        text.typeText("Are you there?")
        app.element("composer.send").tap()

        // The composer stays open, says what happened, and keeps the note.
        app.staticTexts["You’re offline. We’ll keep this safe until you’re back."].waitToAppear()
        snapshot("31-composer-send-failed")
        XCTAssertFalse(app.staticTexts["Sent"].exists)

        app.element("composer.queue").tap()
        app.element("home.pending").waitToAppear()
        XCTAssertTrue(app.staticTexts["Not sent yet"].exists)
        snapshot("32-home-pending")
    }

    func testAnUnfinishedNoteIsKeptAsADraft() {
        let app = XCUIApplication.launched(.paired)
        app.element("home.compose").tapWhenReady()
        let text = app.element("composer.text").waitToAppear()
        text.tap()
        text.typeText("Half a thought")
        app.element("composer.close").tap()
        app.buttons["Keep as draft"].tapWhenReady()

        app.element("home.compose").tapWhenReady()
        XCTAssertEqual(app.element("composer.text").waitToAppear().value as? String, "Half a thought")
    }

    func testDeletingYourOwnNote() {
        let app = XCUIApplication.launched(.paired)
        app.element("home.sentNote").tapWhenReady()
        app.element("note.more").tapWhenReady()
        app.buttons["Delete"].tapWhenReady()
        app.buttons["Delete for both of us"].tapWhenReady()
        app.element("note.done").waitToDisappear()
    }
}

final class MemoriesAndDatesUITests: UITestCase {
    func testMemoriesTimelineAddAndRemove() {
        let app = XCUIApplication.launched(.paired)
        app.tabBars.buttons["Memories"].tapWhenReady()
        app.staticTexts["Moved in together"].waitToAppear()
        snapshot("40-memories")

        app.element("memories.add").tap()
        app.element("moment.title").replaceText("Adopted Biscuit")
        snapshot("41-moment-editor")
        app.element("moment.save").tap()
        app.staticTexts["Adopted Biscuit"].waitToAppear()

        app.staticTexts["Adopted Biscuit"].tap()
        app.element("memory.more").tapWhenReady()
        snapshot("42-memory-detail")
        app.buttons["Remove"].tapWhenReady()
        app.buttons["Remove for both of us"].tapWhenReady()
        app.staticTexts["Adopted Biscuit"].waitToDisappear()
    }

    func testEmptyMemories() {
        let app = XCUIApplication.launched(.empty)
        app.tabBars.buttons["Memories"].tapWhenReady()
        app.element("memories.addFirst").waitToAppear()
        snapshot("43-memories-empty")
    }

    func testAddingAnImportantDate() {
        let app = XCUIApplication.launched(.paired)
        app.tabBars.buttons["Us"].tapWhenReady()
        app.element("us.addDate").waitToAppear()
        snapshot("44-us")

        app.element("us.addDate").tap()
        app.element("date.title").replaceText("First holiday")
        snapshot("45-date-editor")
        app.element("date.save").tap()
        app.staticTexts["First holiday"].waitToAppear()
    }

    func testPlanningEditingAndCancellingASurprise() {
        let app = XCUIApplication.launched(.paired)
        app.tabBars.buttons["Us"].tapWhenReady()
        app.element("us.planSurprise").tapWhenReady()

        let text = app.element("composer.text").waitToAppear()
        app.element("composer.deliveryTime").waitToAppear()
        text.tap()
        text.typeText("Open this on the train.")
        snapshot("46-composer-surprise")
        app.element("composer.schedule").tap()
        app.element("schedule.confirm").waitToAppear()
        snapshot("47-schedule-sheet")
        app.element("schedule.confirm").tap()

        app.element("composer.send").tap()
        app.element("us.surpriseRow").waitToAppear(12)
        snapshot("48-us-with-surprise")

        // The free plan holds one surprise at a time; a second leads to Premium.
        app.element("us.planSurprise").tap()
        app.element("paywall.close").waitToAppear()
        snapshot("49-paywall")
        app.element("paywall.close").tap()

        app.buttons["Options for this surprise"].tapWhenReady()
        app.buttons["Cancel surprise"].tapWhenReady()
        app.buttons["Cancel surprise"].firstMatch.tapWhenReady()
        app.element("us.surpriseRow").waitToDisappear()
    }
}

final class SettingsUITests: UITestCase {
    /// Settings is a lazy list: rows below the fold do not exist until scrolled to.
    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) -> XCUIElement {
        for _ in 0..<6 where !element.isHittable {
            app.swipeUp(velocity: .slow)
        }
        return element
    }

    private func openSettings(_ app: XCUIApplication) {
        app.tabBars.buttons["Us"].tapWhenReady()
        app.element("us.settings").tapWhenReady()
        app.element("settings.profile").waitToAppear()
    }

    func testPersonaliseAppliesAFreeThemeAndGatesPremiumOnes() {
        let app = XCUIApplication.launched(.paired)
        app.element("home.personalise").tapWhenReady()
        app.element("theme.plum").tapWhenReady()
        snapshot("50-personalise")
        app.element("personalise.apply").tap()
        app.element("home.personalise").waitToAppear()
        snapshot("51-home-plum-theme")

        app.element("home.personalise").tap()
        app.element("theme.dusk").tapWhenReady()
        app.element("personalise.apply").tap()
        app.element("paywall.close").waitToAppear()
    }

    func testPremiumFromAPartnerUnlocksThemesWithNoPurchase() {
        let app = XCUIApplication.launched(.premium)
        app.element("home.personalise").tapWhenReady()
        app.element("theme.dusk").tapWhenReady()
        app.element("personalise.apply").tap()
        app.element("home.personalise").waitToAppear()
        snapshot("52-home-dusk-theme")
    }

    func testNotificationSettingsAndWidgetHelp() {
        let app = XCUIApplication.launched(.paired)
        openSettings(app)
        snapshot("53-settings")

        app.element("settings.notifications").tap()
        let previews = app.switches["notifications.previews"].waitToAppear()
        XCTAssertEqual(previews.value as? String, "0", "note text is hidden from notifications by default")
        snapshot("54-notification-settings")
        previews.switches.firstMatch.tap()
        XCTAssertEqual(app.switches["notifications.previews"].value as? String, "1")
        app.navigationBars.buttons.firstMatch.tap()

        app.element("settings.widgetHelp").tapWhenReady()
        app.element("widgetHelp.done").waitToAppear()
        snapshot("55-widget-help")
        app.element("widgetHelp.done").tap()
    }

    func testPaywallIsHonestWhenTheStoreIsUnavailableAndCanBeClosed() {
        let app = XCUIApplication.launched(.paired)
        openSettings(app)
        app.element("settings.premium").tap()
        app.element("paywall.close").waitToAppear()
        XCTAssertTrue(app.staticTexts["Premium, for both of you"].exists)
        // Under xcodebuild there is no StoreKit configuration attached, so
        // products cannot load. The screen must say so, not show invented prices.
        let unavailable = app.element("paywall.unavailable")
        let subscribe = app.element("paywall.subscribe")
        XCTAssertTrue(unavailable.waitForExistence(timeout: 15) || subscribe.exists)
        snapshot("56-paywall-settings")
        app.element("paywall.close").tap()
    }

    func testUnlinkingReturnsBothToPairingWithoutDeletingTheAccount() {
        let app = XCUIApplication.launched(.paired)
        openSettings(app)
        scrollTo(app.element("settings.unlink"), in: app).tap()
        app.element("unlink.submit").waitToAppear()
        snapshot("57-unlink")
        app.element("unlink.submit").tap()
        app.element("unlink.confirm").tapWhenReady()

        app.element("pairing.invite").waitToAppear(12)
        XCTAssertTrue(app.staticTexts["Find each other"].exists, "still signed in, just no longer paired")
    }

    func testDeletingEverythingRequiresTypedConfirmationAndReturnsToTheStart() {
        let app = XCUIApplication.launched(.paired)
        openSettings(app)
        scrollTo(app.element("settings.delete"), in: app).tap()
        let submit = app.element("delete.submit").waitToAppear()
        XCTAssertFalse(submit.isEnabled)
        snapshot("58-delete-everything")
        app.element("delete.confirmField").replaceText("DELETE")
        XCTAssertTrue(submit.isEnabled)
        submit.tap()
        app.element("welcome.getStarted").waitToAppear(12)
    }

    func testWithoutABackupThereIsNoSignOutAndBackingUpAddsIt() {
        let app = XCUIApplication.launched(.paired)
        openSettings(app)
        let backup = scrollTo(app.element("settings.backup"), in: app)
        // Signing out with no backup would strand the space, so it isn't offered.
        XCTAssertFalse(app.element("settings.signOut").exists)
        snapshot("59-settings-not-backed-up")

        backup.tap()
        app.element("backup.demo").waitToAppear()
        snapshot("59a-backup")
        app.element("backup.demo").tap()
        app.element("backup.done").waitToAppear()
        app.navigationBars.buttons.firstMatch.tap()

        scrollTo(app.element("settings.signOut"), in: app).tap()
        app.buttons["Sign out"].firstMatch.tapWhenReady()
        app.element("welcome.getStarted").waitToAppear(12)

        // And the backup works: restoring returns to the same space.
        app.element("welcome.restore").tap()
        app.element("restore.demo").tapWhenReady()
        app.element("home.latestNote").waitToAppear(12)
    }

    func testTheBackupOfferAppearsOnceAndCanBeSkipped() {
        let app = XCUIApplication.launched(.paired, extraArguments: ["-showBackupOffer"])
        app.element("backupOffer.skip").waitToAppear(12)
        snapshot("59b-backup-offer")
        app.element("backupOffer.skip").tap()
        app.element("home.compose").waitToAppear()
    }

    func testDarkAppearance() {
        let app = XCUIApplication.launched(.paired, extraArguments: ["-forceDark"])
        app.element("home.latestNote").waitToAppear()
        snapshot("60-home-dark")
        app.element("home.latestNote").tap()
        app.element("note.reply").waitToAppear()
        snapshot("61-note-dark")
        app.element("note.done").tap()
        app.tabBars.buttons["Memories"].tap()
        app.staticTexts["Moved in together"].waitToAppear()
        snapshot("62-memories-dark")
        app.tabBars.buttons["Us"].tap()
        app.element("us.addDate").waitToAppear()
        snapshot("63-us-dark")
    }
}
