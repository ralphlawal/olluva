import XCTest

final class OnboardingUITests: UITestCase {
    func testWelcomeExplainsPrivacyBeforeAnythingIsCreated() {
        let app = XCUIApplication.launched(.fresh)
        app.element("welcome.getStarted").waitToAppear()
        snapshot("01-welcome")
        app.element("welcome.privacy").tap()
        app.staticTexts["No account, no email"].waitToAppear()
        snapshot("02-privacy")
        app.buttons["Done"].tap()
    }

    func testGettingStartedNeedsOnlyAName() {
        let app = XCUIApplication.launched(.fresh)
        app.element("welcome.getStarted").tapWhenReady()

        // No email, no password, no code: the next thing asked for is a name.
        let name = app.element("name.field").waitToAppear()
        XCTAssertFalse(app.textFields["you@example.com"].exists)
        XCTAssertFalse(app.secureTextFields.firstMatch.exists)
        snapshot("03-name")
        name.typeText("Alex")
        app.element("name.submit").tap()

        app.element("pairing.invite").waitToAppear()
        XCTAssertTrue(app.staticTexts["Find each other"].exists)
        snapshot("05-pairing-home")
    }

    func testFromFirstLaunchToPairedInFourSteps() {
        let app = XCUIApplication.launched(.fresh)
        app.element("welcome.getStarted").tapWhenReady()
        app.element("name.field").waitToAppear().typeText("Alex")
        app.element("name.submit").tap()
        app.element("pairing.join").tapWhenReady()
        app.element("join.code").replaceText("SAMSAM2345")
        app.element("join.continue").tap()
        app.element("join.accept").tapWhenReady()
        app.element("home.firstNote").waitToAppear(12)
    }

    func testRestoringABackedUpSpaceOnANewPhone() {
        // A space that was backed up on another phone; this one starts empty.
        let app = XCUIApplication.launched(.paired, extraArguments: ["-startSignedOut"])
        app.element("welcome.restore").tapWhenReady()
        app.element("restore.demo").waitToAppear()
        snapshot("06-restore")
        app.element("restore.demo").tap()

        // Straight back into the same space, with the same partner and notes.
        app.element("home.latestNote").waitToAppear(12)
        XCTAssertTrue(app.staticTexts["Sam"].exists)
    }
}

final class PairingUITests: UITestCase {
    func testInvitingAPartnerShowsACodeAndMovesOnWhenTheyAccept() {
        let app = XCUIApplication.launched(.solo)
        app.element("pairing.invite").tapWhenReady()
        app.element("invite.code").waitToAppear()
        XCTAssertTrue(app.element("invite.share").exists)
        snapshot("08-invite")

        app.element("invite.demoAccept").tap()
        app.element("home.compose").waitToAppear(12)
    }

    func testJoiningWithACodeAsksForConfirmationFirst() {
        let app = XCUIApplication.launched(.solo)
        app.element("pairing.join").tapWhenReady()

        // A wrong code is refused with a clear message.
        app.element("join.code").replaceText("ZZZZZ22222")
        snapshot("09-join-entry")
        app.element("join.continue").tap()
        app.staticTexts["That invitation can’t be used. Ask your partner for a new one."].waitToAppear()

        app.navigationBars.buttons.firstMatch.tap()
        app.element("pairing.join").tapWhenReady()
        app.element("join.code").replaceText("samsam2345")
        app.element("join.continue").tap()

        // Nothing is joined until the person has seen who it is and accepted.
        app.staticTexts["Share a space with Sam?"].waitToAppear()
        snapshot("10-join-confirm")
        app.element("join.accept").tap()
        app.element("home.compose").waitToAppear(12)
    }

    func testDecliningAnInvitationJoinsNothing() {
        let app = XCUIApplication.launched(.solo)
        app.element("pairing.join").tapWhenReady()
        app.element("join.code").replaceText("SAMSAM2345")
        app.element("join.continue").tap()
        app.element("join.decline").tapWhenReady()
        // Back at the start, still unpaired.
        app.element("pairing.join").waitToAppear()
        XCTAssertFalse(app.element("home.compose").exists)
    }
}
