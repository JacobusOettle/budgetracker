import XCTest
@testable import Spaar

final class ArmingTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testArmedForTenMinutes() {
        XCTAssertTrue(Arming.isArmed(armedAt: t0, now: t0))
        XCTAssertTrue(Arming.isArmed(armedAt: t0, now: t0.addingTimeInterval(599)))
        XCTAssertEqual(Arming.remaining(armedAt: t0, now: t0.addingTimeInterval(60)), 540)
    }

    func testExpiresAfterTenMinutes() {
        XCTAssertFalse(Arming.isArmed(armedAt: t0, now: t0.addingTimeInterval(600)))
        XCTAssertFalse(Arming.isArmed(armedAt: t0, now: t0.addingTimeInterval(3600)))
        XCTAssertEqual(Arming.remaining(armedAt: t0, now: t0.addingTimeInterval(700)), 0)
    }

    func testNotArmed() {
        XCTAssertFalse(Arming.isArmed(armedAt: nil, now: t0))
    }

    func testClockMovedBackStaysCappedAtTenMinutes() {
        XCTAssertEqual(Arming.remaining(armedAt: t0, now: t0.addingTimeInterval(-300)), 600)
    }

    func testCountdown() {
        XCTAssertEqual(Arming.countdown(600), "10:00")
        XCTAssertEqual(Arming.countdown(65), "1:05")
        XCTAssertEqual(Arming.countdown(0.2), "0:01")
    }

    func testWarningLevels() {
        XCTAssertEqual(BudgetWarning.level(leftCents: 100_000, monthlyCents: 300_000), .none)
        XCTAssertEqual(BudgetWarning.level(leftCents: 60_000, monthlyCents: 300_000), .low)   // exactly 20%
        XCTAssertEqual(BudgetWarning.level(leftCents: 60_001, monthlyCents: 300_000), .none)
        XCTAssertEqual(BudgetWarning.level(leftCents: 1, monthlyCents: 300_000), .low)
        XCTAssertEqual(BudgetWarning.level(leftCents: 0, monthlyCents: 300_000), .empty)
        XCTAssertEqual(BudgetWarning.level(leftCents: -500, monthlyCents: 300_000), .empty)
    }
}
