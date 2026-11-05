import XCTest
import UIKit
@testable import Envelope

final class SetupWalkthroughTests: XCTestCase {
    func testEveryStepHasItsPictureInTheApp() {
        XCTAssertEqual(SetupWalkthroughView.steps.count, 10)
        for step in SetupWalkthroughView.steps {
            XCTAssertNotNil(UIImage(named: step.image, in: Bundle(for: PaymentProcessorBundleToken.self), compatibleWith: nil) ?? UIImage(named: step.image),
                            "missing picture \(step.image)")
        }
    }
}

/// Any class from the app module, to find the app bundle.
private typealias PaymentProcessorBundleToken = AppDelegate
