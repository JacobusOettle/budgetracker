import XCTest
import SwiftData
@testable import Envelope

@MainActor
final class PaymentLoggerTests: XCTestCase {
    private var container: ModelContainer!

    override func setUp() async throws {
        container = try ModelContainer(
            for: DebugPayment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    private func log(cents: Int, merchant: String = "Woolworths", source: String = "text", at date: Date) throws -> DebugPayment {
        try PaymentLogger.log(
            source: source, rawAmount: "x", cents: cents, currencyCode: "ZAR",
            merchant: merchant, card: "FNB", rawInput: nil, at: date, in: container.mainContext
        )
    }

    func testRepeatWithinWindowIsFlaggedButStillLogged() throws {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let first = try log(cents: 4500, at: t0)
        let second = try log(cents: 4500, at: t0.addingTimeInterval(30))
        XCTAssertFalse(first.possibleDuplicate)
        XCTAssertTrue(second.possibleDuplicate)
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<DebugPayment>()), 2)
    }

    func testRepeatOutsideWindowIsNotFlagged() throws {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        _ = try log(cents: 4500, at: t0)
        let later = try log(cents: 4500, at: t0.addingTimeInterval(PaymentLogger.duplicateWindow + 1))
        XCTAssertFalse(later.possibleDuplicate)
    }

    func testDifferentAmountMerchantOrSourceIsNotFlagged() throws {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        _ = try log(cents: 4500, at: t0)
        XCTAssertFalse(try log(cents: 4501, at: t0.addingTimeInterval(1)).possibleDuplicate)
        XCTAssertFalse(try log(cents: 4500, merchant: "Spar", at: t0.addingTimeInterval(2)).possibleDuplicate)
        XCTAssertFalse(try log(cents: 4500, source: "currency", at: t0.addingTimeInterval(3)).possibleDuplicate)
    }
}
