import XCTest

/// Not a pass/fail test: drives the real Shortcuts app in the simulator
/// through creating the Wallet automation and attaches a screenshot (and the
/// screen's element tree) at every step, for the in-app setup guide.
/// Run from CI with the "Screenshots" scheme; best effort.
final class ShortcutsScreenshots: XCTestCase {
    private let shortcuts = XCUIApplication(bundleIdentifier: "com.apple.shortcuts")
    private var step = 0

    override func setUp() {
        continueAfterFailure = true
    }

    func testCaptureAutomationSetup() {
        // Launch Spaar once so Shortcuts knows its actions.
        let spaar = XCUIApplication()
        spaar.launch()
        sleep(2)
        snap("spaar-launched", app: spaar)
        spaar.terminate()

        shortcuts.launch()
        sleep(3)
        snap("shortcuts-launched")
        dismissWelcome()

        tap(["Automation"], kinds: [.tabBar, .button])
        snap("automation-tab")

        tap(["Add", "New Automation", "Create Personal Automation", "plus", "Plus"], kinds: [.button])
        snap("new-automation")

        // Find the Wallet trigger (older iOS: Transaction).
        if !tap(["Wallet", "Transaction"], kinds: [.cell, .button, .staticText]) {
            for _ in 0..<6 {
                shortcuts.swipeUp()
                if tap(["Wallet", "Transaction"], kinds: [.cell, .button, .staticText]) { break }
            }
        }
        snap("wallet-trigger")

        tap(["Any Card"], kinds: [.button, .cell, .staticText])
        snap("any-card")
        tap(["Done"], kinds: [.button])

        tap(["Run Immediately"], kinds: [.button, .cell, .staticText])
        snap("run-immediately")

        tap(["Next"], kinds: [.button])
        snap("after-next")

        tap(["New Blank Automation", "Create New Shortcut"], kinds: [.button, .cell, .staticText])
        snap("blank-automation")

        let search = shortcuts.searchFields.firstMatch
        if search.waitForExistence(timeout: 3) {
            search.tap()
            search.typeText("Spaar")
            sleep(2)
        }
        snap("search-spaar")

        tap(["Log Payment"], kinds: [.button, .cell, .staticText])
        snap("log-payment-added")

        tap(["Amount"], kinds: [.button, .staticText])
        snap("amount-tapped")
        tap(["Shortcut Input"], kinds: [.button, .staticText])
        snap("shortcut-input-chosen")
        tap(["Shortcut Input"], kinds: [.button, .staticText])
        snap("variable-menu")
        tap(["Amount"], kinds: [.button, .cell, .staticText])
        snap("amount-set")
    }

    // MARK: Helpers

    private enum Kind { case button, cell, staticText, tabBar }

    private func dismissWelcome() {
        for label in ["Continue", "Get Started", "Not Now", "OK"] {
            let button = shortcuts.buttons[label]
            if button.waitForExistence(timeout: 1) { button.tap(); sleep(1) }
        }
    }

    @discardableResult
    private func tap(_ labels: [String], kinds: [Kind]) -> Bool {
        for label in labels {
            for kind in kinds {
                let element: XCUIElement
                switch kind {
                case .button: element = shortcuts.buttons[label]
                case .cell: element = shortcuts.cells.containing(.staticText, identifier: label).firstMatch
                case .staticText: element = shortcuts.staticTexts[label]
                case .tabBar: element = shortcuts.tabBars.buttons[label]
                }
                if element.waitForExistence(timeout: 2), element.isHittable {
                    element.tap()
                    sleep(2)
                    return true
                }
            }
        }
        return false
    }

    private func snap(_ name: String, app: XCUIApplication? = nil) {
        step += 1
        let target = app ?? shortcuts
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = String(format: "%02d-%@", step, name)
        shot.lifetime = .keepAlways
        add(shot)
        let tree = XCTAttachment(string: target.debugDescription)
        tree.name = String(format: "%02d-%@-tree", step, name)
        tree.lifetime = .keepAlways
        add(tree)
    }
}
