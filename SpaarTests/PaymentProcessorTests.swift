import XCTest
import SwiftData
@testable import Spaar

@MainActor
final class PaymentProcessorTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext { container.mainContext }
    private let cal = TestCalendar.utc
    private var t0: Date { TestCalendar.date(2026, 11, 4) }

    override func setUp() async throws {
        container = try Persistence.inMemory()
    }

    private func pay(_ amount: String, merchant: String = "KFC Wierda Park", card: String = "FNB", at date: Date) throws -> PaymentProcessor.Outcome {
        try PaymentProcessor.process(amountText: amount, merchant: merchant, card: card, source: .shortcut, now: date, in: context, calendar: cal)
    }

    private func count() throws -> Int { try context.fetchCount(FetchDescriptor<Payment>()) }

    // MARK: Arming and deductions

    func testArmedBudgetGetsThePaymentAndDisarms() throws {
        let food = try BudgetService.addBudget(name: "Food", monthlyCents: 300_000, now: t0, in: context)
        try BudgetService.arm(food, now: t0, in: context)

        let outcome = try pay("R 100.70", at: t0.addingTimeInterval(60))
        guard case let .assigned(payment, budget, left) = outcome else { return XCTFail("expected assigned, got \(outcome)") }
        XCTAssertEqual(budget.id, food.id)
        XCTAssertEqual(payment.amountCents, 10_070)
        XCTAssertEqual(left, 289_930)
        XCTAssertEqual(food.leftCents(now: t0, calendar: cal), 289_930)
        XCTAssertNil(food.armedAt, "disarmed after one payment")

        // The next payment isn't armed any more.
        guard case .unassigned = try pay("R 50.00", merchant: "Spar", at: t0.addingTimeInterval(120)) else { return XCTFail() }
        XCTAssertEqual(food.leftCents(now: t0, calendar: cal), 289_930)
    }

    func testArmExpiresAfterTenMinutes() throws {
        let food = try BudgetService.addBudget(name: "Food", monthlyCents: 300_000, now: t0, in: context)
        try BudgetService.arm(food, now: t0, in: context)
        guard case .unassigned = try pay("R 20.00", at: t0.addingTimeInterval(601)) else { return XCTFail() }
        XCTAssertEqual(food.leftCents(now: t0, calendar: cal), 300_000)
        XCTAssertNil(food.armedAt, "expired arm is cleared")
    }

    func testArmingOneBudgetDisarmsTheOthers() throws {
        let food = try BudgetService.addBudget(name: "Food", monthlyCents: 300_000, now: t0, in: context)
        let fuel = try BudgetService.addBudget(name: "Fuel", monthlyCents: 200_000, now: t0, in: context)
        try BudgetService.arm(food, now: t0, in: context)
        try BudgetService.arm(fuel, now: t0.addingTimeInterval(5), in: context)
        XCTAssertNil(food.armedAt)
        guard case let .assigned(_, budget, _) = try pay("R 500.00", merchant: "Engen", at: t0.addingTimeInterval(10)) else { return XCTFail() }
        XCTAssertEqual(budget.name, "Fuel")
    }

    func testOverspendingGoesNegative() throws {
        let fun = try BudgetService.addBudget(name: "Fun", monthlyCents: 10_000, now: t0, in: context)
        try BudgetService.arm(fun, now: t0, in: context)
        guard case let .assigned(_, _, left) = try pay("R 150.00", at: t0) else { return XCTFail() }
        XCTAssertEqual(left, -5_000)
        XCTAssertEqual(BudgetWarning.level(leftCents: left, monthlyCents: 10_000), .empty)
    }

    func testOnlyThisMonthsPaymentsCount() throws {
        let food = try BudgetService.addBudget(name: "Food", monthlyCents: 300_000, now: TestCalendar.date(2026, 10, 1), in: context)
        try BudgetService.arm(food, now: TestCalendar.date(2026, 10, 31), in: context)
        _ = try pay("R 1000.00", at: TestCalendar.date(2026, 10, 31))
        XCTAssertEqual(food.leftCents(now: TestCalendar.date(2026, 10, 31), calendar: cal), 200_000)
        XCTAssertEqual(food.leftCents(now: TestCalendar.date(2026, 11, 1), calendar: cal), 300_000, "resets for the new month")
    }

    // MARK: Unassigned

    func testNothingArmedSavesAsUnassigned() throws {
        _ = try BudgetService.addBudget(name: "Food", monthlyCents: 300_000, now: t0, in: context)
        let outcome = try pay("R 100.70", at: t0)
        guard case let .unassigned(payment) = outcome else { return XCTFail() }
        XCTAssertNil(payment.budget)
        XCTAssertEqual(payment.amountCents, 10_070)
        let note = try XCTUnwrap(PaymentProcessor.notification(for: outcome))
        XCTAssertTrue(note.title.contains("Assign"))
        XCTAssertTrue(note.title.contains("R100.70"))
    }

    func testUnassignedWithNoBudgetsAtAll() throws {
        guard case .unassigned = try pay("R 10.00", at: t0) else { return XCTFail() }
    }

    // MARK: Duplicates (idempotency)

    func testRepeatedShortcutRunDoesNotDeductTwice() throws {
        let food = try BudgetService.addBudget(name: "Food", monthlyCents: 300_000, now: t0, in: context)
        try BudgetService.arm(food, now: t0, in: context)
        _ = try pay("R 100.70", at: t0.addingTimeInterval(10))
        let again = try pay("R 100.70", at: t0.addingTimeInterval(40))
        guard case .duplicate = again else { return XCTFail("expected duplicate") }
        XCTAssertNil(PaymentProcessor.notification(for: again))
        XCTAssertEqual(try count(), 1)
        XCTAssertEqual(food.leftCents(now: t0, calendar: cal), 289_930)
    }

    func testDuplicateWhileStillUnassigned() throws {
        _ = try pay("R 100.70", at: t0)
        guard case .duplicate = try pay("R100.70", at: t0.addingTimeInterval(5)) else { return XCTFail() }
        XCTAssertEqual(try count(), 1)
    }

    func testSamePurchaseAfterWindowIsANewPayment() throws {
        _ = try pay("R 25.00", at: t0)
        guard case .unassigned = try pay("R 25.00", at: t0.addingTimeInterval(PaymentProcessor.duplicateWindow + 1)) else { return XCTFail() }
        XCTAssertEqual(try count(), 2)
    }

    func testDifferentAmountMerchantOrCardIsNotADuplicate() throws {
        _ = try pay("R 25.00", at: t0)
        _ = try pay("R 25.01", at: t0.addingTimeInterval(1))
        _ = try pay("R 25.00", merchant: "Spar", at: t0.addingTimeInterval(2))
        _ = try pay("R 25.00", card: "Capitec Debit", at: t0.addingTimeInterval(3))
        XCTAssertEqual(try count(), 4)
    }

    func testManualEntryIsNeverTreatedAsDuplicateSource() throws {
        let manual = Payment(amountCents: 2_500, merchant: "KFC Wierda Park", card: "FNB", date: t0, source: .manual)
        context.insert(manual)
        try context.save()
        guard case .unassigned = try pay("R 25.00", at: t0.addingTimeInterval(10)) else { return XCTFail() }
    }

    // MARK: Unreadable / foreign

    func testUnreadableAmountIsSavedForReview() throws {
        let food = try BudgetService.addBudget(name: "Food", monthlyCents: 300_000, now: t0, in: context)
        try BudgetService.arm(food, now: t0, in: context)
        let outcome = try pay("", at: t0)
        XCTAssertTrue(outcome.payment.needsReview)
        XCTAssertEqual(outcome.payment.amountCents, 0)
        XCTAssertTrue(PaymentProcessor.notification(for: outcome)?.title.contains("Check") ?? false)
    }

    func testForeignCurrencyIsFlagged() throws {
        let outcome = try pay("$5.00", merchant: "Apple", at: t0)
        XCTAssertTrue(outcome.payment.needsReview)
        XCTAssertEqual(outcome.payment.amountCents, 500)
        XCTAssertTrue(outcome.payment.note.contains("USD"))
    }

    func testNegativeTextIsStoredAsPositiveSpend() throws {
        let outcome = try pay("-R 30.00", at: t0)
        XCTAssertEqual(outcome.payment.amountCents, 3_000)
    }

    // MARK: Removing budgets

    func testRemovingBudgetWithPaymentsArchivesIt() throws {
        let food = try BudgetService.addBudget(name: "Food", monthlyCents: 300_000, now: t0, in: context)
        try BudgetService.arm(food, now: t0, in: context)
        _ = try pay("R 10.00", at: t0)
        try BudgetService.remove(food, now: t0, in: context)
        XCTAssertNotNil(food.archivedAt)
        XCTAssertTrue(try BudgetService.activeBudgets(in: context).isEmpty)
        let payment = try XCTUnwrap(try context.fetch(FetchDescriptor<Payment>()).first)
        XCTAssertEqual(payment.budget?.name, "Food", "payments keep their budget")
    }

    func testRemovingEmptyBudgetDeletesIt() throws {
        let food = try BudgetService.addBudget(name: "Food", monthlyCents: 300_000, now: t0, in: context)
        try BudgetService.remove(food, in: context)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Budget>()), 0)
    }
}
