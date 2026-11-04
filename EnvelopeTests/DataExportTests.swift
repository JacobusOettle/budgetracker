import XCTest
import SwiftData
@testable import Envelope

@MainActor
final class DataExportTests: XCTestCase {
    func testExportIsSelfDescribingJSONWithExactAmounts() throws {
        let container = try Persistence.inMemory()
        let context = container.mainContext
        let cal = TestCalendar.utc
        let today = TestCalendar.date(2026, 11, 3)

        try FundService.addBelonging(
            name: "Phone", category: .phone, purchasedOn: today, priceCents: 2_400_000,
            replacementCostCents: nil, customLifespanMonths: 48, previousLifespanMonths: nil,
            alreadySavedCents: 0, in: context
        )
        try FundService.setSavingsBalance(5_000_000, in: context)
        let food = try BudgetService.addBudget(name: "Food", monthlyCents: 300_000, now: today, in: context)
        try BudgetService.arm(food, now: today, in: context)
        try PaymentProcessor.process(amountText: "R 100.70", merchant: "KFC", card: "FNB", source: .shortcut, now: today, in: context, calendar: cal)

        let data = try DataExport.makeJSON(context: context, now: today, calendar: cal)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertNotNil(json["about"] as? [String: String])
        XCTAssertEqual(json["currency"] as? String, "ZAR")
        XCTAssertEqual(json["schema_version"] as? Int, 2)

        let savings = try XCTUnwrap(json["savings"] as? [String: Any])
        XCTAssertEqual(savings["total_zar"] as? String, "50000.00")
        XCTAssertEqual(savings["true_savings_zar"] as? String, "50000.00")
        XCTAssertEqual(savings["monthly_set_aside_zar"] as? String, "500.00")

        let belongings = try XCTUnwrap(json["belongings"] as? [[String: Any]])
        let current = try XCTUnwrap(belongings.first?["current"] as? [String: Any])
        XCTAssertEqual(current["monthly_contribution_zar"] as? String, "500.00")
        XCTAssertEqual(current["lifespan_source"] as? String, "custom")
        XCTAssertEqual(current["expected_replacement_date"] as? String, "2030-11-03")
        XCTAssertEqual(current["purchased_on"] as? String, "2026-11-03")
        XCTAssertNotNil(json["spike_test_log"] as? [Any])

        let budgets = try XCTUnwrap(json["budgets"] as? [[String: Any]])
        XCTAssertEqual(budgets.first?["left_this_month_zar"] as? String, "2899.30")
        let payments = try XCTUnwrap(json["payments"] as? [[String: Any]])
        XCTAssertEqual(payments.first?["amount_zar"] as? String, "100.70")
        XCTAssertEqual(payments.first?["budget"] as? String, "Food")
        XCTAssertEqual(payments.first?["source"] as? String, "shortcut")
        XCTAssertNotNil(json["month_closes"] as? [Any])
    }
}
