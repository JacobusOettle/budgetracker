import XCTest
import SwiftData
@testable import Spaar

@MainActor
final class FundServiceTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext { container.mainContext }
    private let cal = TestCalendar.utc
    private func d(_ y: Int, _ m: Int, _ day: Int) -> Date { TestCalendar.date(y, m, day) }

    override func setUp() async throws {
        container = try Persistence.inMemory()
    }

    private func addPhone(bought: Date, price: Int = 2_400_000, custom: Int? = 48, previous: Int? = nil, saved: Int = 0) throws -> Belonging {
        try FundService.addBelonging(
            name: "Phone", category: .phone, purchasedOn: bought, priceCents: price,
            replacementCostCents: nil, customLifespanMonths: custom, previousLifespanMonths: previous,
            alreadySavedCents: saved, in: context
        )
    }

    func testMonthlyContributionsAreIdempotentPerMonth() throws {
        let phone = try addPhone(bought: d(2026, 11, 3))
        let first = try FundService.recordContributions(belongings: [phone], month: d(2026, 11, 5), addToSavingsBalance: true, in: context, calendar: cal)
        let again = try FundService.recordContributions(belongings: [phone], month: d(2026, 11, 28), addToSavingsBalance: true, in: context, calendar: cal)
        XCTAssertEqual(first, 50_000)
        XCTAssertEqual(again, 0)
        XCTAssertEqual(phone.fundBalanceCents, 50_000)
        XCTAssertEqual(SavingsAccount.current(in: context).balanceCents, 50_000)

        let december = try FundService.recordContributions(belongings: [phone], month: d(2026, 12, 1), addToSavingsBalance: false, in: context, calendar: cal)
        XCTAssertEqual(december, 50_000)
        XCTAssertEqual(phone.fundBalanceCents, 100_000)
        XCTAssertEqual(SavingsAccount.current(in: context).balanceCents, 50_000, "earmark only, balance unchanged")
    }

    func testOpeningBalanceReducesMonthly() throws {
        let phone = try addPhone(bought: d(2026, 11, 3), saved: 1_200_000)
        XCTAssertEqual(phone.plan(today: d(2026, 11, 3), calendar: cal)?.monthlyCents, 25_000)
    }

    func testReplacingUsesHowLongItLastedForTheNextOne() throws {
        let phone = try addPhone(bought: d(2022, 1, 15), custom: nil)
        try FundService.setFundBalance(phone, to: 2_400_000, in: context)
        try FundService.setSavingsBalance(5_000_000, in: context)

        let settlement = try FundService.replace(
            phone, on: d(2026, 7, 15), reason: "battery", newPriceCents: 2_000_000,
            paidFromSavings: true, in: context, calendar: cal
        )

        XCTAssertEqual(settlement.releasedToTrueSavingsCents, 400_000)
        XCTAssertEqual(phone.previousLifespanMonths, 54)
        XCTAssertEqual(phone.fundBalanceCents, 0)
        XCTAssertEqual(phone.allOwnerships.count, 2)
        XCTAssertEqual(phone.currentOwnership?.priceCents, 2_000_000)
        XCTAssertEqual(phone.lifespan(), Lifespan(months: 54, source: .previous))
        XCTAssertEqual(SavingsAccount.current(in: context).balanceCents, 3_000_000)
        // True savings: R30 000 total - R0 set aside. Was R50 000 - R24 000 = R26 000,
        // so the R4 000 left over moved to true savings.
        XCTAssertEqual(SavingsSplit.trueSavings(totalCents: 3_000_000, setAsideCents: phone.fundBalanceCents), 3_000_000)
    }

    func testEarlyFailureShortfallComesOutOfTrueSavings() throws {
        let phone = try addPhone(bought: d(2025, 1, 1))
        try FundService.setFundBalance(phone, to: 1_000_000, in: context)
        try FundService.setSavingsBalance(5_000_000, in: context)
        // True savings before: 5 000 000 - 1 000 000 = 4 000 000

        let s = try FundService.replace(phone, on: d(2026, 6, 1), reason: "", newPriceCents: 2_400_000, paidFromSavings: true, in: context, calendar: cal)
        XCTAssertEqual(s.shortfallFromTrueSavingsCents, 1_400_000)
        let total = SavingsAccount.current(in: context).balanceCents
        XCTAssertEqual(SavingsSplit.trueSavings(totalCents: total, setAsideCents: phone.fundBalanceCents), 4_000_000 - 1_400_000)
    }

    func testRetireWithoutReplacingArchivesAndReleasesFund() throws {
        let phone = try addPhone(bought: d(2024, 1, 1))
        try FundService.setFundBalance(phone, to: 300_000, in: context)
        try FundService.replace(phone, on: d(2026, 1, 1), reason: "sold", newPriceCents: nil, paidFromSavings: true, in: context, calendar: cal)
        XCTAssertTrue(phone.archived)
        XCTAssertNil(phone.currentOwnership)
        XCTAssertNil(phone.plan(today: d(2026, 2, 1), calendar: cal))
        XCTAssertEqual(phone.fundBalanceCents, 0)
        XCTAssertTrue(FundService.pendingContributions(belongings: [phone], month: d(2026, 2, 1), calendar: cal).isEmpty)
    }

    func testDeletingBelongingCascades() throws {
        let phone = try addPhone(bought: d(2026, 1, 1), saved: 1000)
        context.delete(phone)
        try context.save()
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Ownership>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<FundEntry>()), 0)
    }
}
