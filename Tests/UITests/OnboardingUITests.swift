import XCTest

final class OnboardingUITests: UITestCase {
    func testWelcomeExplainsPrivacyBeforeAnyAccountExists() {
        let app = XCUIApplication.launched(.fresh)
        app.element("welcome.getStarted").waitToAppear()
        snapshot("01-welcome")
        app.element("welcome.privacy").tap()
        app.staticTexts["Only you and your partner"].waitToAppear()
        snapshot("02-privacy")
        app.buttons["Done"].tap()
    }

    func testCreateAccountValidatesThenLandsOnPairing() {
        let app = XCUIApplication.launched(.fresh)
        app.element("welcome.getStarted").tapWhenReady()

        // Submitting an empty form explains what is missing instead of failing silently.
        app.element("signUp.submit").tapWhenReady()
        app.staticTexts["Enter a valid email address."].waitToAppear()
        snapshot("03-signup-validation")

        app.element("signUp.name").replaceText("Alex")
        app.element("signUp.email").replaceText("alex@example.test")
        // Reveal the password first: iOS treats a hidden password field on a
        // sign-up form as a strong-password target and intercepts typed input.
        app.buttons["Show password"].tap()
        app.element("signUp.password").replaceText("password1")
        snapshot("04-signup-filled")
        app.element("signUp.submit").tap()

        app.element("pairing.invite").waitToAppear()
        XCTAssertTrue(app.staticTexts["Find each other"].exists)
        snapshot("05-pairing-home")
    }

    func testSignInWithWrongPasswordShowsAnErrorThenSucceeds() {
        let app = XCUIApplication.launched(.solo, extraArguments: ["-startSignedOut"])
        app.element("welcome.signIn").tapWhenReady()
        app.element("signIn.email").replaceText("alex@example.test")
        app.element("signIn.password").replaceText("not-the-password")
        app.element("signIn.submit").tap()
        app.staticTexts["That email and password don’t match."].waitToAppear()
        snapshot("06-signin-error")

        let password = app.element("signIn.password")
        password.tap()
        password.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 20) + "password1")
        app.element("signIn.submit").tap()
        app.element("pairing.invite").waitToAppear()
    }

    func testPasswordRecovery() {
        let app = XCUIApplication.launched(.solo, extraArguments: ["-startSignedOut"])
        app.element("welcome.signIn").tapWhenReady()
        app.element("signIn.forgot").tapWhenReady()
        app.element("reset.email").replaceText("alex@example.test")
        app.element("reset.send").tap()
        app.element("reset.code").replaceText("123456")
        app.element("reset.password").replaceText("brandnewpass")
        snapshot("07-reset-password")
        app.element("reset.submit").tap()
        app.element("pairing.invite").waitToAppear()
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
