import XCTest
@testable import Envelope

final class ReplacementPlannerTests: XCTestCase {
    private let cal = TestCalendar.utc
    private func d(_ y: Int, _ m: Int, _ day: Int) -> Date { TestCalendar.date(y, m, day) }

    private func plan(bought: Date, target: Int, saved: Int = 0, months: Int, contributed: Bool = false, today: Date) -> ReplacementPlan {
        ReplacementPlanner.plan(
            purchasedOn: bought, targetCents: target, savedCents: saved,
            lifespan: Lifespan(months: months, source: .custom),
            contributedThisMonth: contributed, today: today, calendar: cal
        )
    }

    // The example: R24 000 phone, replaced every 4 years -> R500/month.
    func testR24000PhoneOverFourYearsIsR500PerMonth() {
        let p = plan(bought: d(2026, 11, 3), target: 2_400_000, months: 48, today: d(2026, 11, 3))
        XCTAssertEqual(p.remainingMonths, 48)
        XCTAssertEqual(p.monthlyCents, 50_000)
        XCTAssertEqual(p.status, .saving)
        XCTAssertEqual(p.expectedReplacementDate, d(2030, 11, 3))
    }

    func testMonthlyStaysTheSameAfterContributingThisMonth() {
        let p = plan(bought: d(2026, 11, 3), target: 2_400_000, saved: 50_000, months: 48, contributed: true, today: d(2026, 11, 20))
        XCTAssertEqual(p.remainingMonths, 47)
        XCTAssertEqual(p.monthlyCents, 50_000)
    }

    func testMonthlyStaysOnTrackNextMonth() {
        let p = plan(bought: d(2026, 11, 3), target: 2_400_000, saved: 50_000, months: 48, today: d(2026, 12, 1))
        XCTAssertEqual(p.monthlyCents, 50_000)
    }

    func testItemAddedMidLifeCatchesUpOverRemainingMonths() {
        // Bought two years ago, nothing saved: R24 000 over the 24 months left.
        let p = plan(bought: d(2024, 11, 1), target: 2_400_000, months: 48, today: d(2026, 11, 3))
        XCTAssertEqual(p.remainingMonths, 24)
        XCTAssertEqual(p.monthlyCents, 100_000)
    }

    func testMonthlyRoundsUpToTheCent() {
        // R20 000 / 36 = R555.555… -> R555.56 so the target is reached.
        let p = plan(bought: d(2026, 1, 1), target: 2_000_000, months: 36, today: d(2026, 1, 1))
        XCTAssertEqual(p.monthlyCents, 55_556)
        XCTAssertGreaterThanOrEqual(p.monthlyCents * p.remainingMonths, 2_000_000)
    }

    func testFullyFundedNeedsNothingMore() {
        let p = plan(bought: d(2026, 1, 1), target: 2_400_000, saved: 2_400_000, months: 48, today: d(2027, 1, 1))
        XCTAssertEqual(p.status, .funded)
        XCTAssertEqual(p.monthlyCents, 0)
        XCTAssertFalse(p.isPastExpectedLife)
    }

    func testOutlastingExpectedLifeStopsContributions() {
        let p = plan(bought: d(2020, 1, 1), target: 2_400_000, saved: 2_400_000, months: 48, today: d(2025, 6, 1))
        XCTAssertEqual(p.status, .funded)
        XCTAssertTrue(p.isPastExpectedLife)
        XCTAssertEqual(p.monthlyCents, 0)
    }

    func testPastExpectedLifeButShortIsDue() {
        let p = plan(bought: d(2020, 1, 1), target: 2_400_000, saved: 1_000_000, months: 48, today: d(2025, 6, 1))
        XCTAssertEqual(p.status, .due)
        XCTAssertEqual(p.monthlyCents, 0)
        XCTAssertEqual(p.shortfallCents, 1_400_000)
    }

    func testOverSavedHasNoShortfall() {
        let p = plan(bought: d(2026, 1, 1), target: 100_000, saved: 150_000, months: 12, today: d(2026, 2, 1))
        XCTAssertEqual(p.shortfallCents, 0)
        XCTAssertEqual(p.status, .funded)
    }

    // MARK: Lifespan priority

    func testFirstTimeUsesTypicalLifespan() {
        let l = ReplacementPlanner.resolveLifespan(customMonths: nil, previousMonths: nil, category: .phone)
        XCTAssertEqual(l, Lifespan(months: BelongingCategory.phone.typicalLifespanMonths, source: .typical))
    }

    func testOwnedBeforeUsesHowLongTheLastOneLasted() {
        let l = ReplacementPlanner.resolveLifespan(customMonths: nil, previousMonths: 52, category: .phone)
        XCTAssertEqual(l, Lifespan(months: 52, source: .previous))
    }

    func testCustomLifespanWinsOverEverything() {
        let l = ReplacementPlanner.resolveLifespan(customMonths: 48, previousMonths: 52, category: .phone)
        XCTAssertEqual(l, Lifespan(months: 48, source: .custom))
    }

    func testZeroValuesAreIgnored() {
        let l = ReplacementPlanner.resolveLifespan(customMonths: 0, previousMonths: 0, category: .laptop)
        XCTAssertEqual(l.source, .typical)
    }

    func testEveryCategoryHasAPositiveTypicalLifespan() {
        for c in BelongingCategory.allCases { XCTAssertGreaterThan(c.typicalLifespanMonths, 0, c.rawValue) }
    }

    // MARK: Settlement

    func testCheaperReplacementReleasesLeftoverToTrueSavings() {
        let s = ReplacementPlanner.settle(fundCents: 2_400_000, newPriceCents: 2_000_000)
        XCTAssertEqual(s, ReplacementSettlement(spentFromFundCents: 2_000_000, releasedToTrueSavingsCents: 400_000, shortfallFromTrueSavingsCents: 0))
    }

    func testEarlyFailureShortfallComesFromTrueSavings() {
        let s = ReplacementPlanner.settle(fundCents: 1_000_000, newPriceCents: 2_400_000)
        XCTAssertEqual(s, ReplacementSettlement(spentFromFundCents: 1_000_000, releasedToTrueSavingsCents: 0, shortfallFromTrueSavingsCents: 1_400_000))
    }

    func testRetireWithoutReplacingReleasesWholeFund() {
        let s = ReplacementPlanner.settle(fundCents: 300_000, newPriceCents: nil)
        XCTAssertEqual(s, ReplacementSettlement(spentFromFundCents: 0, releasedToTrueSavingsCents: 300_000, shortfallFromTrueSavingsCents: 0))
    }

    // MARK: Helpers

    func testActualLifespanMonths() {
        XCTAssertEqual(ReplacementPlanner.actualLifespanMonths(purchasedOn: d(2022, 3, 10), retiredOn: d(2026, 3, 10), calendar: cal), 48)
        XCTAssertEqual(ReplacementPlanner.actualLifespanMonths(purchasedOn: d(2026, 3, 10), retiredOn: d(2026, 3, 20), calendar: cal), 1)
    }

    func testMonthsBetweenAndMonthKey() {
        XCTAssertEqual(ReplacementPlanner.monthsBetween(d(2026, 11, 30), d(2030, 11, 1), calendar: cal), 48)
        XCTAssertEqual(ReplacementPlanner.monthKey(for: d(2026, 3, 5), calendar: cal), "2026-03")
    }

    func testTrueSavingsSplit() {
        XCTAssertEqual(SavingsSplit.trueSavings(totalCents: 5_000_000, setAsideCents: 1_200_000), 3_800_000)
        XCTAssertEqual(SavingsSplit.trueSavings(totalCents: 100_000, setAsideCents: 300_000), -200_000)
    }

    func testLifespanDescription() {
        XCTAssertEqual(Lifespan.describe(months: 48), "4 years")
        XCTAssertEqual(Lifespan.describe(months: 18), "1 year 6 months")
        XCTAssertEqual(Lifespan.describe(months: 1), "1 month")
        XCTAssertEqual(Lifespan.describe(months: 13), "1 year 1 month")
    }

    func testMoneyPlain() {
        XCTAssertEqual(Money.plain(cents: 2_400_000), "24000.00")
        XCTAssertEqual(Money.plain(cents: 5), "0.05")
        XCTAssertEqual(Money.plain(cents: -12_345), "-123.45")
    }
}
