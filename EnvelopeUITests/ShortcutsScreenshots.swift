import XCTest

/// Not a pass/fail test: drives the real Shortcuts app in the simulator and
/// attaches a screenshot (and the element tree) at every step, for the in-app
/// setup guide. The simulator has no Wallet cards, so a Wallet automation
/// can't be finished here (Next stays disabled); the action-editing screens
/// are captured in a normal shortcut instead, which uses the same editor.
final class ShortcutsScreenshots: XCTestCase {
    private let shortcuts = XCUIApplication(bundleIdentifier: "com.apple.shortcuts")
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    private var step = 0

    override func setUp() {
        continueAfterFailure = true
    }

    func testCaptureAutomationSetup() {
        // Launch Spaar once so Shortcuts knows its actions; allow notifications.
        let spaar = XCUIApplication()
        spaar.launch()
        allowAlerts()
        sleep(2)
        spaar.terminate()

        shortcuts.launch()
        sleep(3)
        allowAlerts()
        dismissWelcome()

        // 1. Automation tab
        tapButton("Automation")
        snap("a-automation-tab")

        // 2. New automation → trigger list, scrolled to Wallet
        tapButton("New Automation") || tapButton("Add")
        sleep(1)
        snap("b-trigger-list-top")
        let wallet = shortcuts.staticTexts["Wallet"]
        for _ in 0..<8 where !(wallet.exists && wallet.isHittable) {
            shortcuts.swipeUp(velocity: .slow)
        }
        snap("c-trigger-list-wallet")
        if wallet.exists { wallet.tap(); sleep(2) }
        snap("d-wallet-trigger")
        tapButton("Run Immediately") || tapStatic("Run Immediately")
        snap("e-run-immediately")

        // Leave the automation (can't finish without Wallet cards).
        tapButton("Back")
        tapButton("Close") || tapButton("Cancel")
        sleep(1)

        // 3. Same editor in a normal shortcut: add Spaar's Log Payment
        tapButton("Library")
        tapButton("Add") || tapButton("New Shortcut")
        sleep(2)
        snap("f-new-shortcut")
        let search = shortcuts.searchFields.firstMatch
        if search.waitForExistence(timeout: 3) {
            search.tap()
            search.typeText("Spaar")
            sleep(2)
        }
        snap("g-search-spaar")
        tapStatic("Log Payment") || tapButton("Log Payment")
        sleep(2)
        snap("h-log-payment-added")

        tapButton("Amount") || tapStatic("Amount")
        snap("i-amount-tapped")
        tapButton("Shortcut Input") || tapStatic("Shortcut Input")
        snap("j-shortcut-input-chosen")
        tapButton("Shortcut Input") || tapStatic("Shortcut Input")
        snap("k-variable-menu")
        shortcuts.tap() // dismiss any menu
        tapButton("Show More") || tapButton("chevron.right.circle") || tapButton("More")
        snap("l-expanded")
    }

    // MARK: Helpers

    private func allowAlerts() {
        for label in ["Allow", "OK", "Allow While Using App"] {
            let button = springboard.alerts.buttons[label]
            if button.waitForExistence(timeout: 2) { button.tap(); sleep(1) }
        }
    }

    private func dismissWelcome() {
        for label in ["Continue", "Get Started", "Not Now", "OK"] {
            let button = shortcuts.buttons[label]
            if button.waitForExistence(timeout: 1) { button.tap(); sleep(1) }
        }
    }

    @discardableResult
    private func tapButton(_ label: String) -> Bool {
        let element = shortcuts.buttons[label].firstMatch
        guard element.waitForExistence(timeout: 3), element.isHittable else { return false }
        element.tap()
        sleep(2)
        return true
    }

    @discardableResult
    private func tapStatic(_ label: String) -> Bool {
        let element = shortcuts.staticTexts[label].firstMatch
        guard element.waitForExistence(timeout: 3), element.isHittable else { return false }
        element.tap()
        sleep(2)
        return true
    }

    private func snap(_ name: String) {
        step += 1
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = String(format: "%02d-%@", step, name)
        shot.lifetime = .keepAlways
        add(shot)
        let tree = XCTAttachment(string: shortcuts.debugDescription)
        tree.name = String(format: "%02d-%@-tree", step, name)
        tree.lifetime = .keepAlways
        add(tree)
    }
}
