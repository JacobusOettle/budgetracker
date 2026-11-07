import XCTest
import SwiftData
@testable import Spaar

@MainActor
final class MonthEndTests: XCTestCase {
    private let cal = TestCalendar.utc
    private func d(_ y: Int, _ m: Int, _ day: Int) -> Date { TestCalendar.date(y, m, day) }

    // MARK: Pure totals

    func testTotalsWithOverspendAndUnassigned() {
        let summary = MonthEnd.summary(
            lines: [
                MonthEndLine(name: "Food", monthlyCents: 300_000, spentCents: 250_000),  // +500
                MonthEndLine(name: "Fuel", monthlyCents: 200_000, spentCents: 220_000),  // -200
                MonthEndLine(name: "Fun", monthlyCents: 100_000, spentCents: 0),          // +1000
            ],
            unassigned: [10_070, 5_000]
        )
        XCTAssertEqual(summary.totalLeftCents, 130_000)
        XCTAssertEqual(summary.unassignedCents, 15_070)
        XCTAssertEqual(summary.unassignedCount, 2)
        XCTAssertEqual(summary.toSaveCents, 114_930)
    }

    func testToSaveIsNeverNegative() {
        let summary = MonthEnd.summary(lines: [MonthEndLine(name: "Food", monthlyCents: 100_000, spentCents: 150_000)], unassigned: [])
        XCTAssertEqual(summary.totalLeftCents, -50_000)
        XCTAssertEqual(summary.toSaveCents, 0)
    }

    func testCentsAddUpExactly() {
        // Many small rand amounts: integer cents never drift (Double would).
        let lines = (0..<1000).map { MonthEndLine(name: "B\($0)", monthlyCents: 10, spentCents: 0) }  // 1000 x R0.10
        XCTAssertEqual(MonthEnd.summary(lines: lines, unassigned: []).toSaveCents, 10_000)
        XCTAssertEqual(Money.format(cents: 10_000), "R100.00")
    }

    func testUnclosedMonths() {
        let months = MonthEnd.unclosedMonths(firstUse: d(2026, 9, 15), closedKeys: ["2026-09"], now: d(2026, 11, 4), calendar: cal)
        XCTAssertEqual(months.map { ReplacementPlanner.monthKey(for: $0, calendar: cal) }, ["2026-10"])
        XCTAssertTrue(MonthEnd.unclosedMonths(firstUse: d(2026, 11, 1), closedKeys: [], now: d(2026, 11, 30), calendar: cal).isEmpty, "current month isn't due yet")
        XCTAssertTrue(MonthEnd.unclosedMonths(firstUse: nil, closedKeys: [], now: d(2026, 11, 4), calendar: cal).isEmpty)
    }

    // MARK: With data

    func testSummaryFromBudgetsAndPayments() throws {
        let container = try Persistence.inMemory()
        let context = container.mainContext
        let food = try BudgetService.addBudget(name: "Food", monthlyCents: 300_000, now: d(2026, 10, 1), in: context)
        let old = try BudgetService.addBudget(name: "Old", monthlyCents: 50_000, now: d(2026, 9, 1), in: context)
        try BudgetService.arm(old, now: d(2026, 9, 10), in: context)
        try PaymentProcessor.process(amountText: "R 10.00", merchant: "X", card: "C", source: .shortcut, now: d(2026, 9, 10), in: context, calendar: cal)
        try BudgetService.remove(old, now: d(2026, 9, 30), in: context)  // archived before October

        try BudgetService.arm(food, now: d(2026, 10, 5), in: context)
        try PaymentProcessor.process(amountText: "R 1 000,00", merchant: "Spar", card: "C", source: .shortcut, now: d(2026, 10, 5), in: context, calendar: cal)
        try PaymentProcessor.process(amountText: "R 99.99", merchant: "Takealot", card: "C", source: .shortcut, now: d(2026, 10, 20), in: context, calendar: cal)  // unassigned
        try PaymentProcessor.process(amountText: "R 5.00", merchant: "Next month", card: "C", source: .shortcut, now: d(2026, 11, 1), in: context, calendar: cal)

        let budgets = try context.fetch(FetchDescriptor<Budget>())
        let payments = try context.fetch(FetchDescriptor<Payment>())
        let october = MonthEnd.summary(budgets: budgets, payments: payments, month: d(2026, 10, 15), calendar: cal)
        XCTAssertEqual(october.lines, [MonthEndLine(name: "Food", monthlyCents: 300_000, spentCents: 100_000)])
        XCTAssertEqual(october.unassignedCents, 9_999)
        XCTAssertEqual(october.toSaveCents, 190_001)
    }

    func testClosingAMonthAddsToSavingsRecordsReplacementFundsAndIsIdempotent() throws {
        let container = try Persistence.inMemory()
        let context = container.mainContext
        try FundService.setSavingsBalance(1_000_000, in: context)
        let phone = try FundService.addBelonging(
            name: "Phone", category: .phone, purchasedOn: d(2026, 10, 1), priceCents: 2_400_000,
            replacementCostCents: nil, customLifespanMonths: 48, previousLifespanMonths: nil,
            alreadySavedCents: 0, in: context
        )
        let summary = MonthEnd.summary(lines: [MonthEndLine(name: "Food", monthlyCents: 300_000, spentCents: 100_000)], unassigned: [])

        let close = try BudgetService.closeMonth(d(2026, 10, 1), summary: summary, movedCents: 200_000, belongings: [phone], now: d(2026, 11, 1), in: context, calendar: cal)
        XCTAssertEqual(close.monthKey, "2026-10")
        XCTAssertEqual(close.toSaveCents, 200_000)
        XCTAssertEqual(close.replacementCents, 50_000)
        XCTAssertEqual(close.lines, summary.lines)
        XCTAssertEqual(phone.fundBalanceCents, 50_000)
        XCTAssertEqual(SavingsAccount.current(in: context).balanceCents, 1_200_000)
        // True savings grew by what was moved minus what went to the phone fund.
        XCTAssertEqual(SavingsSplit.trueSavings(totalCents: 1_200_000, setAsideCents: phone.fundBalanceCents), 1_150_000)

        let again = try BudgetService.closeMonth(d(2026, 10, 20), summary: summary, movedCents: 200_000, belongings: [phone], in: context, calendar: cal)
        XCTAssertEqual(again.closedAt, close.closedAt)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<MonthClose>()), 1)
        XCTAssertEqual(SavingsAccount.current(in: context).balanceCents, 1_200_000, "not added twice")
        XCTAssertEqual(phone.fundBalanceCents, 50_000)
    }
}
