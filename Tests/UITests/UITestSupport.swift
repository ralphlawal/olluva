import XCTest

/// Launches the app on its in-memory demo backend in a named scenario.
/// See DemoController for what each scenario contains.
enum Scenario: String {
    case fresh, solo, empty, paired, premium
}

extension XCUIApplication {
    static func launched(_ scenario: Scenario, extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-demoScenario", scenario.rawValue] + extraArguments
        // For App Store screenshots: the sample data without the demo notice.
        if ProcessInfo.processInfo.environment["STORE_SCREENSHOTS"] == "1" { app.launchArguments.append("-storeScreenshots") }
        app.launch()
        return app
    }

    /// Any element with this accessibility identifier, whatever its type.
    func element(_ identifier: String) -> XCUIElement {
        descendants(matching: .any).matching(identifier: identifier).firstMatch
    }
}

extension XCUIElement {
    @discardableResult
    func waitToAppear(_ timeout: TimeInterval = 8, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        XCTAssertTrue(waitForExistence(timeout: timeout), "\(self) did not appear", file: file, line: line)
        return self
    }

    func waitToDisappear(_ timeout: TimeInterval = 8, file: StaticString = #filePath, line: UInt = #line) {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: self)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: timeout), .completed, "\(self) did not disappear", file: file, line: line)
    }

    func tapWhenReady(_ timeout: TimeInterval = 8, file: StaticString = #filePath, line: UInt = #line) {
        waitToAppear(timeout, file: file, line: line)
        tap()
    }

    /// Taps something in a sideways-scrolling row, bringing it into view first.
    func tapInRow(of app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        waitToAppear(file: file, line: line)
        let window = app.windows.firstMatch.frame
        for _ in 0..<8 where !(frame.minX >= 8 && frame.maxX <= window.maxX - 8) {
            let y = frame.midY / window.height
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: y))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: y)))
        }
        tap()
    }

    func replaceText(_ text: String) {
        tapWhenReady()
        typeText(text)
    }
}

extension XCTestCase {
    /// Attaches a screenshot to the test report and, when SCREENSHOT_DIR is
    /// set (pass TEST_RUNNER_SCREENSHOT_DIR to xcodebuild), also writes it
    /// there for design review.
    func snapshot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let directory = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"], !directory.isEmpty {
            try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
        }
    }
}

/// Base class: stops at the first failure and keeps a picture of the screen
/// it failed on.
class UITestCase: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    override func tearDown() {
        if (testRun?.failureCount ?? 0) > 0 {
            snapshot("FAILED-\(name.replacingOccurrences(of: "[^A-Za-z0-9]+", with: "-", options: .regularExpression))")
        }
    }
}
