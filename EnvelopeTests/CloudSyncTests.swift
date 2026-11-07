import XCTest
import SwiftData
@testable import Envelope

final class CloudSyncConfigTests: XCTestCase {
    func testContainerOnlyFromARealValue() {
        XCTAssertEqual(CloudSync.validContainer("iCloud.com.jacobusoettle.envelope"), "iCloud.com.jacobusoettle.envelope")
        XCTAssertNil(CloudSync.validContainer(nil))
        XCTAssertNil(CloudSync.validContainer(""), "unsigned / test builds blank it")
        XCTAssertNil(CloudSync.validContainer("iCloud.$(PRODUCT_BUNDLE_IDENTIFIER)"), "unexpanded build setting")
        XCTAssertNil(CloudSync.validContainer("iCloud."))
        XCTAssertNil(CloudSync.validContainer("com.example"))
    }

    func testSyncsOnlyWhenBuildHasItAndUserWantsIt() {
        XCTAssertEqual(CloudSync.syncContainer(containerID: "iCloud.x", userWantsSync: true), "iCloud.x")
        XCTAssertNil(CloudSync.syncContainer(containerID: "iCloud.x", userWantsSync: false))
        XCTAssertNil(CloudSync.syncContainer(containerID: nil, userWantsSync: true))
    }

    func testEverySyncedModelCanBeCreatedWithDefaults() throws {
        // CloudKit needs a default for every attribute; this also proves the
        // schema still loads after making relationships optional.
        let container = try Persistence.inMemory()
        let context = ModelContext(container)
        let budget = Budget(name: "Food", monthlyCents: 100)
        context.insert(budget)
        XCTAssertTrue((budget.payments ?? []).isEmpty)
        let belonging = Belonging(name: "Phone", category: .phone)
        context.insert(belonging)
        XCTAssertTrue(belonging.allOwnerships.isEmpty)
        XCTAssertTrue(belonging.allFundEntries.isEmpty)
        XCTAssertEqual(belonging.fundBalanceCents, 0)
        try context.save()
    }
}

@MainActor
final class SyncDeduplicatorTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext { container.mainContext }
    private func d(_ y: Int, _ m: Int, _ day: Int) -> Date { TestCalendar.date(y, m, day) }

    override func setUp() async throws {
        container = try Persistence.inMemory()
    }

    private func budget(_ name: String, created: Date, color: String = "") -> Budget {
        let b = Budget(name: name, monthlyCents: 300_000, createdAt: created)
        b.colorName = color
        context.insert(b)
        return b
    }

    private func payment(_ cents: Int, to budget: Budget?) -> Payment {
        let p = Payment(amountCents: cents, merchant: "Shop", card: "", date: d(2026, 11, 5), source: .manual)
        context.insert(p)
        p.budget = budget
        return p
    }

    func testSameNamedBudgetsMergeIntoTheOldestWithAllPayments() throws {
        let original = budget("Food", created: d(2026, 1, 1))
        let fromNewPhone = budget(" food ", created: d(2026, 11, 1), color: "teal")
        let other = budget("Fuel", created: d(2026, 1, 2))
        let a = payment(10_000, to: original)
        let b = payment(20_000, to: fromNewPhone)
        _ = payment(5_000, to: other)
        try context.save()

        let report = SyncDeduplicator.run(in: context)

        XCTAssertEqual(report.budgets, 1)
        let budgets = try context.fetch(FetchDescriptor<Budget>())
        XCTAssertEqual(Set(budgets.map(\.name)), ["Food", "Fuel"])
        XCTAssertTrue(a.budget === original)
        XCTAssertTrue(b.budget === original, "payments move, never deleted")
        XCTAssertEqual(original.colorName, "teal", "keeps a colour if the original had none")
        XCTAssertEqual(try context.fetch(FetchDescriptor<Payment>()).count, 3)
    }

    func testArchivedBudgetsAreNotMerged() throws {
        let old = budget("Food", created: d(2025, 1, 1))
        old.archivedAt = d(2025, 6, 1)
        _ = budget("Food", created: d(2026, 1, 1))
        try context.save()
        XCTAssertEqual(SyncDeduplicator.run(in: context).budgets, 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Budget>()).count, 2)
    }

    func testBothPhonesKeepTheSameBudget() throws {
        // Same creation time: the tie-break is the id, so every phone agrees.
        let t = d(2026, 1, 1)
        let x = budget("Food", created: t)
        let y = budget("Food", created: t)
        try context.save()
        let expected = x.id.uuidString < y.id.uuidString ? x.id : y.id
        SyncDeduplicator.run(in: context)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Budget>()).map(\.id), [expected])
    }

    func testAMonthClosedOnTwoPhonesKeepsTheFirstClose() throws {
        let summary = MonthEndSummary(lines: [], unassignedCents: 0, unassignedCount: 0)
        let first = MonthClose(monthKey: "2026-10", closedAt: d(2026, 11, 1), summary: summary, movedCents: 50_000, replacementCents: 0)
        let second = MonthClose(monthKey: "2026-10", closedAt: d(2026, 11, 2), summary: summary, movedCents: 70_000, replacementCents: 0)
        let september = MonthClose(monthKey: "2026-09", closedAt: d(2026, 10, 1), summary: summary, movedCents: 0, replacementCents: 0)
        for close in [first, second, september] { context.insert(close) }
        try context.save()

        XCTAssertEqual(SyncDeduplicator.run(in: context).monthCloses, 1)
        let closes = try context.fetch(FetchDescriptor<MonthClose>())
        XCTAssertEqual(closes.count, 2)
        XCTAssertEqual(closes.first { $0.monthKey == "2026-10" }?.movedCents, 50_000)
    }

    func testAContributionRecordedOnTwoPhonesCountsOnce() throws {
        let phone = try FundService.addBelonging(
            name: "Phone", category: .phone, purchasedOn: d(2026, 1, 3), priceCents: 2_400_000,
            replacementCostCents: nil, customLifespanMonths: 48, previousLifespanMonths: nil,
            alreadySavedCents: 0, in: context
        )
        for day in [5, 6] {
            let entry = FundEntry(date: d(2026, 11, day), kind: .contribution, cents: 50_000, monthKey: "2026-11")
            context.insert(entry)
            entry.belonging = phone
        }
        let october = FundEntry(date: d(2026, 10, 5), kind: .contribution, cents: 50_000, monthKey: "2026-10")
        context.insert(october)
        october.belonging = phone
        try context.save()

        XCTAssertEqual(SyncDeduplicator.run(in: context).contributions, 1)
        XCTAssertEqual(phone.fundBalanceCents, 100_000)
    }

    func testOneSavingsBalanceKeepsTheLatest() throws {
        context.insert(SavingsAccount(balanceCents: 1_000_000, updatedAt: d(2026, 11, 1)))
        context.insert(SavingsAccount(balanceCents: 1_200_000, updatedAt: d(2026, 11, 4)))
        try context.save()
        XCTAssertEqual(SyncDeduplicator.run(in: context).savingsAccounts, 1)
        XCTAssertEqual(SavingsAccount.current(in: context).balanceCents, 1_200_000)
    }

    func testNothingToMergeChangesNothing() throws {
        _ = budget("Food", created: d(2026, 1, 1))
        _ = budget("Fuel", created: d(2026, 1, 1))
        context.insert(SavingsAccount(balanceCents: 5, updatedAt: d(2026, 1, 1)))
        try context.save()
        XCTAssertEqual(SyncDeduplicator.run(in: context), SyncDeduplicator.Report())
    }

    func testNameNormalisation() {
        XCTAssertEqual(SyncDeduplicator.normalizedName("  Café   Treats "), "cafe treats")
        XCTAssertEqual(SyncDeduplicator.normalizedName("FOOD"), SyncDeduplicator.normalizedName("food"))
    }
}
