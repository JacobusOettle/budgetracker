import XCTest
@testable import Envelope

final class MoneyTests: XCTestCase {
    func testCentsRoundsHalfAwayFromZero() {
        XCTAssertEqual(Money.cents(from: Decimal(string: "0.005")!), 1)
        XCTAssertEqual(Money.cents(from: Decimal(string: "-0.005")!), -1)
        XCTAssertEqual(Money.cents(from: Decimal(string: "10.994")!), 1099)
        XCTAssertEqual(Money.cents(from: Decimal(string: "10.995")!), 1100)
        XCTAssertEqual(Money.cents(from: Decimal(string: "19.99")!), 1999)
    }

    func testDecimalAvoidsBinaryFloatError() {
        // 0.1 + 0.2 is 0.30000000000000004 as Double; Decimal stays exact.
        let sum = Decimal(string: "0.1")! + Decimal(string: "0.2")!
        XCTAssertEqual(Money.cents(from: sum), 30)
    }

    func testFormat() {
        XCTAssertEqual(Money.format(cents: 0), "R0.00")
        XCTAssertEqual(Money.format(cents: 5), "R0.05")
        XCTAssertEqual(Money.format(cents: -5), "-R0.05")
        XCTAssertEqual(Money.format(cents: 4550), "R45.50")
        XCTAssertEqual(Money.format(cents: 123456), "R1 234.56")
        XCTAssertEqual(Money.format(cents: 123456789), "R1 234 567.89")
    }
}
