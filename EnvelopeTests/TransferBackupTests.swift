import XCTest
import SwiftData
@testable import Envelope

// TEMPORARY: remove with TransferBackup.swift.
@MainActor
final class TransferBackupTests: XCTestCase {
    private func d(_ y: Int, _ m: Int, _ day: Int) -> Date { TestCalendar.date(y, m, day) }

    func testEverythingSurvivesTheRoundTrip() throws {
        let source = try Persistence.inMemory()
        let ctx = source.mainContext
        let food = Budget(name: "Food", monthlyCents: 300_000, sortOrder: 1, createdAt: d(2026, 1, 1))
        food.colorName = "teal"
        ctx.insert(food)
        let p = Payment(amountCents: 12_345, merchant: "Checkers", card: "FNB", date: d(2026, 11, 3), source: .shortcut, rawAmount: "R 123.45")
        ctx.insert(p)
        p.budget = food
        p.assignment = .ai
        p.aiReason = "groceries"
        let unassigned = Payment(amountCents: 500, merchant: "Parking", card: "", date: d(2026, 11, 4), source: .manual)
        ctx.insert(unassigned)
        let phone = try FundService.addBelonging(
            name: "Phone", category: .phone, purchasedOn: d(2026, 1, 3), priceCents: 2_400_000,
            replacementCostCents: 2_600_000, customLifespanMonths: 36, previousLifespanMonths: 30,
            alreadySavedCents: 100_000, in: ctx
        )
        SavingsAccount.current(in: ctx).set(to: 5_000_000, at: d(2026, 11, 1))
        ctx.insert(MonthClose(monthKey: "2026-10", closedAt: d(2026, 11, 1),
                              summary: MonthEndSummary(lines: [MonthEndLine(name: "Food", monthlyCents: 300_000, spentCents: 250_000)], unassignedCents: 0, unassignedCount: 0),
                              movedCents: 50_000, replacementCents: 10_000))
        try ctx.save()

        let suite = UserDefaults(suiteName: "spaar.test.transfer.\(UUID().uuidString)")!
        suite.set(Data("{\"enabled\":true}".utf8), forKey: "ai.config")
        suite.set(false, forKey: "reminder.enabled")
        suite.set(21, forKey: "reminder.hour")
        let backup = try TransferBackup.make(context: ctx, includeAPIKey: false, defaults: suite)
        let data = try TransferBackup.encode(backup)
        let decoded = try TransferBackup.decode(data)

        let target = try Persistence.inMemory()
        let tctx = target.mainContext
        tctx.insert(Budget(name: "Leftover", monthlyCents: 1))   // replaced, not mixed
        try tctx.save()
        let targetDefaults = UserDefaults(suiteName: "spaar.test.transfer.t.\(UUID().uuidString)")!
        let summary = try TransferBackup.restore(decoded, into: tctx, defaults: targetDefaults)

        XCTAssertEqual(summary.budgets, 1)
        XCTAssertEqual(summary.payments, 2)
        let budgets = try tctx.fetch(FetchDescriptor<Budget>())
        XCTAssertEqual(budgets.map(\.name), ["Food"])
        XCTAssertEqual(budgets.first?.id, food.id)
        XCTAssertEqual(budgets.first?.colorName, "teal")
        let payments = try tctx.fetch(FetchDescriptor<Payment>())
        let checkers = try XCTUnwrap(payments.first { $0.merchant == "Checkers" })
        XCTAssertEqual(checkers.amountCents, 12_345)
        XCTAssertEqual(checkers.budget?.name, "Food")
        XCTAssertEqual(checkers.assignment, .ai)
        XCTAssertEqual(checkers.aiReason, "groceries")
        XCTAssertEqual(checkers.rawAmount, "R 123.45")
        XCTAssertNil(payments.first { $0.merchant == "Parking" }?.budget)
        let belonging = try XCTUnwrap(try tctx.fetch(FetchDescriptor<Belonging>()).first)
        XCTAssertEqual(belonging.id, phone.id)
        XCTAssertEqual(belonging.previousLifespanMonths, 30)
        XCTAssertEqual(belonging.fundBalanceCents, 100_000)
        XCTAssertEqual(belonging.currentOwnership?.replacementCostCents, 2_600_000)
        XCTAssertEqual(belonging.currentOwnership?.customLifespanMonths, 36)
        XCTAssertEqual(SavingsAccount.current(in: tctx).balanceCents, 5_000_000)
        let close = try XCTUnwrap(try tctx.fetch(FetchDescriptor<MonthClose>()).first)
        XCTAssertEqual(close.movedCents, 50_000)
        XCTAssertEqual(close.lines.first?.spentCents, 250_000)
        XCTAssertEqual(targetDefaults.data(forKey: "ai.config"), Data("{\"enabled\":true}".utf8))
        XCTAssertEqual(targetDefaults.object(forKey: "reminder.enabled") as? Bool, false)
        XCTAssertEqual(targetDefaults.object(forKey: "reminder.hour") as? Int, 21)

        // Restoring the same file again doesn't duplicate anything.
        try TransferBackup.restore(decoded, into: tctx, defaults: targetDefaults)
        XCTAssertEqual(try tctx.fetch(FetchDescriptor<Payment>()).count, 2)
    }

    func testRejectsTheAIExportFile() {
        XCTAssertThrowsError(try TransferBackup.decode(Data("{\"about\":{}}".utf8)))
    }
}
