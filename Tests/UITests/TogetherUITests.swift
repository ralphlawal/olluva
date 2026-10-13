import XCTest

final class TogetherUITests: UITestCase {
    func testAnsweringOpeningSavingAndFindingItAgain() {
        // In this scenario the partner has already answered today's question.
        let app = XCUIApplication.launched(.paired)
        app.element("home.together").tapWhenReady()
        app.element("together.question").waitToAppear()
        app.element("together.partnerAnswered").waitToAppear()
        // Their answer is nowhere on screen yet.
        XCTAssertFalse(app.element("together.answer.partner").exists)
        snapshot("70-together-open")

        let submit = app.element("together.submit")
        XCTAssertFalse(submit.isEnabled, "nothing to send yet")
        let answer = app.element("together.answer")
        answer.tap()
        answer.typeText("When you saved me the last slice.")
        XCTAssertTrue(app.staticTexts["Draft, saved on this phone"].waitForExistence(timeout: 4))
        snapshot("71-together-draft")
        submit.tap()

        // Both answers are in: it waits to be opened, still sealed.
        app.element("together.ready").waitToAppear()
        app.element("together.sealed").waitToAppear()
        XCTAssertFalse(app.element("together.answer.partner").exists)
        snapshot("72-together-ready")

        app.element("together.reveal").tap()
        let theirs = app.element("together.answer.partner").waitToAppear()
        XCTAssertEqual(theirs.label, "Dancing in the kitchen while the pasta boiled over.")
        XCTAssertEqual(app.element("together.answer.mine").label, "When you saved me the last slice.")
        XCTAssertFalse(app.element("together.edit").exists, "an opened answer cannot be changed")
        snapshot("73-together-revealed")

        let save = app.element("together.save")
        save.tap()
        XCTAssertTrue(app.buttons["Saved to Memories"].waitForExistence(timeout: 6))

        app.element("together.history").tap()
        let rows = app.descendants(matching: .any).matching(identifier: "together.history.row")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 8))
        XCTAssertEqual(rows.count, 2, "today's and yesterday's")
        snapshot("74-together-history")
        rows.element(boundBy: 1).tap()
        XCTAssertEqual(
            app.element("together.answer.partner").waitToAppear().label,
            "The pancakes on Sunday. You remembered the lemon."
        )
        snapshot("75-together-earlier")
    }

    func testADraftIsKeptWhenLeavingAndIsNotTreatedAsSent() {
        let app = XCUIApplication.launched(.paired)
        app.element("home.together").tapWhenReady()
        let answer = app.element("together.answer").waitToAppear()
        answer.tap()
        answer.typeText("Still thinking")
        app.navigationBars.buttons.firstMatch.tap()

        // Today still asks for an answer: a draft is not an answer.
        XCTAssertTrue(app.staticTexts["Sam has answered. Your turn."].waitForExistence(timeout: 6))
        app.element("home.together").tap()
        XCTAssertEqual(app.element("together.answer").waitToAppear().value as? String, "Still thinking")
        XCTAssertFalse(app.element("together.ready").exists)
    }

    func testWaitingForAPartnerAndEditingBeforeItIsOpened() {
        // A couple with nothing yet: the partner has not answered.
        let app = XCUIApplication.launched(.empty)
        app.element("home.together").tapWhenReady()
        XCTAssertFalse(app.element("together.partnerAnswered").exists)
        let answer = app.element("together.answer").waitToAppear()
        answer.tap()
        answer.typeText("First go")
        app.element("together.submit").tap()

        app.element("together.waiting").waitToAppear()
        XCTAssertEqual(app.element("together.answer.mine").label, "First go")
        XCTAssertFalse(app.element("together.reveal").exists, "it cannot be opened with one answer")
        snapshot("76-together-waiting")

        app.element("together.edit").tap()
        let editor = app.element("together.answer").waitToAppear()
        editor.typeText(", improved")
        app.element("together.submit").tap()
        app.element("together.waiting").waitToAppear()
        XCTAssertEqual(app.element("together.answer.mine").label, "First go, improved")

        // Nothing has been answered by both, so there is no history yet.
        app.element("together.history").tap()
        XCTAssertTrue(app.staticTexts["Nothing here yet"].waitForExistence(timeout: 8))
        snapshot("77-together-history-empty")
    }

    func testTogetherInDarkAppearance() {
        let app = XCUIApplication.launched(.paired, extraArguments: ["-forceDark"])
        app.element("home.together").tapWhenReady()
        app.element("together.question").waitToAppear()
        snapshot("78-together-dark")
    }
}
