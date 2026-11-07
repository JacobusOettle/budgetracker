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

    func testSyncIsOnForNewInstallsButOptInWhenThePhoneHasData() {
        let fresh = UserDefaults(suiteName: "spaar.test.fresh.\(UUID().uuidString)")!
        CloudSync.decideDefault(storeExists: false, defaults: fresh)
        XCTAssertEqual(fresh.object(forKey: CloudSync.enabledKey) as? Bool, true)

        let existing = UserDefaults(suiteName: "spaar.test.existing.\(UUID().uuidString)")!
        CloudSync.decideDefault(storeExists: true, defaults: existing)
        XCTAssertEqual(existing.object(forKey: CloudSync.enabledKey) as? Bool, false)

        // A choice already made is never overwritten.
        existing.set(true, forKey: CloudSync.enabledKey)
        CloudSync.decideDefault(storeExists: true, defaults: existing)
        XCTAssertEqual(existing.object(forKey: CloudSync.enabledKey) as? Bool, true)
    }

    func testBackupBeforeFirstSyncAndRestore() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appending(path: "spaar-backup-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let defaults = UserDefaults(suiteName: "spaar.test.backup.\(UUID().uuidString)")!
        let store = dir.appending(path: "default.store")
        try Data("original".utf8).write(to: store)
        try Data("wal".utf8).write(to: URL(fileURLWithPath: store.path + "-wal"))

        XCTAssertTrue(CloudSync.backUpBeforeFirstSync(store: store, defaults: defaults))
        let backup = try XCTUnwrap(CloudSync.backupFolder(store: store, defaults: defaults))
        XCTAssertFalse(defaults.string(forKey: CloudSync.backupPathKey)!.hasPrefix("/"), "kept relative to survive container moves")
        XCTAssertEqual(try String(contentsOf: backup.appending(path: "default.store"), encoding: .utf8), "original")
        XCTAssertTrue(fm.fileExists(atPath: backup.appending(path: "default.store-wal").path))

        // Only once.
        try Data("changed".utf8).write(to: store)
        XCTAssertTrue(CloudSync.backUpBeforeFirstSync(store: store, defaults: defaults))
        XCTAssertEqual(try String(contentsOf: backup.appending(path: "default.store"), encoding: .utf8), "original")

        // Restore replaces the store and turns sync off.
        defaults.set(true, forKey: CloudSync.enabledKey)
        try Data("shm".utf8).write(to: URL(fileURLWithPath: store.path + "-shm"))
        defaults.set(true, forKey: CloudSync.pendingRestoreKey)
        CloudSync.restoreIfRequested(store: store, defaults: defaults)
        XCTAssertEqual(try String(contentsOf: store, encoding: .utf8), "original")
        XCTAssertTrue(fm.fileExists(atPath: store.path + "-wal"))
        XCTAssertFalse(fm.fileExists(atPath: store.path + "-shm"), "stale side files removed")
        XCTAssertEqual(defaults.object(forKey: CloudSync.enabledKey) as? Bool, false)
        XCTAssertFalse(defaults.bool(forKey: CloudSync.pendingRestoreKey))
        XCTAssertFalse(defaults.bool(forKey: CloudSync.backupDoneKey), "a fresh backup before syncing again")
        XCTAssertTrue(defaults.bool(forKey: CloudSync.restoredLocalKey))
        XCTAssertNotNil(CloudSync.backupFolder(store: store, defaults: defaults), "backup kept")
    }

    func testNothingToBackUpOnAFreshInstall() {
        let defaults = UserDefaults(suiteName: "spaar.test.nobackup.\(UUID().uuidString)")!
        let store = FileManager.default.temporaryDirectory.appending(path: "missing-\(UUID().uuidString).store")
        XCTAssertTrue(CloudSync.backUpBeforeFirstSync(store: store, defaults: defaults))
        XCTAssertNil(CloudSync.backupFolder(store: store, defaults: defaults))
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

    private func budget(_ name: String, device: String, inserted: Date, color: String = "") -> Budget {
        let b = Budget(name: name, monthlyCents: 300_000, createdAt: inserted)
        b.insertedAt = inserted
        b.originDevice = device
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

    private func active() throws -> [Budget] {
        try context.fetch(FetchDescriptor<Budget>()).filter { $0.archivedAt == nil }
    }

    func testSameNamedBudgetsFromTwoPhonesMergeIntoTheFirstWithAllPayments() throws {
        let original = budget("Food", device: "", inserted: d(2026, 1, 1))   // made before sync existed
        let fromNewPhone = budget(" food ", device: "phone-B", inserted: d(2026, 11, 1), color: "teal")
        let other = budget("Fuel", device: "", inserted: d(2026, 1, 2))
        let a = payment(10_000, to: original)
        let b = payment(20_000, to: fromNewPhone)
        _ = payment(5_000, to: other)
        try context.save()

        let report = SyncDeduplicator.run(in: context)

        XCTAssertEqual(report.budgets, 1)
        XCTAssertEqual(Set(try active().map(\.name)), ["Food", "Fuel"])
        XCTAssertTrue(a.budget === original)
        XCTAssertTrue(b.budget === original, "payments move, never deleted")
        XCTAssertEqual(original.colorName, "teal", "keeps a colour if the original had none")
        XCTAssertEqual(fromNewPhone.mergedIntoID, original.id, "archived as merged, not deleted")
        XCTAssertNotNil(fromNewPhone.archivedAt)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Payment>()).count, 3)
    }

    func testSameNamedBudgetsMadeOnOnePhoneAreLeftAlone() throws {
        _ = budget("Food", device: "", inserted: d(2025, 1, 1))
        _ = budget("Food", device: "", inserted: d(2026, 1, 1))
        _ = budget("Kids", device: "phone-A", inserted: d(2026, 2, 1))
        _ = budget("Kids", device: "phone-A", inserted: d(2026, 3, 1))
        try context.save()
        XCTAssertEqual(SyncDeduplicator.run(in: context).budgets, 0)
        XCTAssertEqual(try active().count, 4)
    }

    func testDeliberateSameNamesOnOnePhoneBlockMergingTheGroup() throws {
        _ = budget("Food", device: "phone-B", inserted: d(2026, 1, 1))
        _ = budget("Food", device: "phone-A", inserted: d(2026, 2, 1))
        _ = budget("Food", device: "phone-A", inserted: d(2026, 3, 1))
        try context.save()
        XCTAssertEqual(SyncDeduplicator.run(in: context).budgets, 0)
        XCTAssertEqual(try active().count, 3)
    }

    func testABudgetFromBeforeSyncStaysEvenIfItsDateIsTheUpdateDay() throws {
        // insertedAt of old budgets is filled in on the update day, which can
        // be later than a new phone's budget.
        let legacy = budget("Food", device: "", inserted: d(2026, 11, 7))
        legacy.monthlyCents = 450_000
        let newPhone = budget("Food", device: "phone-B", inserted: d(2026, 11, 6))
        try context.save()
        SyncDeduplicator.run(in: context)
        XCTAssertEqual(newPhone.mergedIntoID, legacy.id)
        XCTAssertNil(legacy.mergedIntoID)
        XCTAssertEqual(legacy.monthlyCents, 450_000, "your real allowance is kept")
    }

    func testAPaymentThatSyncsInLaterFollowsTheMergedBudget() throws {
        let keep = budget("Food", device: "phone-A", inserted: d(2026, 1, 1))
        let dup = budget("Food", device: "phone-B", inserted: d(2026, 11, 1))
        try context.save()
        SyncDeduplicator.run(in: context)
        // Later, a payment made on phone B before it saw the merge arrives.
        let late = payment(7_500, to: dup)
        try context.save()
        let report = SyncDeduplicator.run(in: context)
        XCTAssertEqual(report.paymentsMoved, 1)
        XCTAssertTrue(late.budget === keep)
    }

    func testStatementImportBackdatingDoesNotChangeWhichBudgetStays() throws {
        let keep = budget("Food", device: "phone-A", inserted: d(2026, 1, 1))
        let dup = budget("Food", device: "phone-B", inserted: d(2026, 11, 1))
        dup.createdAt = d(2025, 6, 1)   // an import on phone B moved its start back
        try context.save()
        SyncDeduplicator.run(in: context)
        XCTAssertEqual(dup.mergedIntoID, keep.id)
        XCTAssertEqual(keep.createdAt, d(2025, 6, 1), "past months still add up")
    }

    func testBothPhonesKeepTheSameBudget() throws {
        let t = d(2026, 1, 1)
        let x = budget("Food", device: "phone-A", inserted: t)
        let y = budget("Food", device: "phone-B", inserted: t)
        try context.save()
        let expected = x.id.uuidString < y.id.uuidString ? x.id : y.id
        SyncDeduplicator.run(in: context)
        XCTAssertEqual(try active().map(\.id), [expected])
    }

    func testMergedDuplicateIsNotOnTheMonthEnd() throws {
        _ = budget("Food", device: "phone-A", inserted: d(2026, 1, 1))
        _ = budget("Food", device: "phone-B", inserted: d(2026, 11, 1))
        try context.save()
        SyncDeduplicator.run(in: context)
        let all = try context.fetch(FetchDescriptor<Budget>())
        let summary = MonthEnd.summary(budgets: all, payments: [], month: Date.now)
        XCTAssertEqual(summary.lines.count, 1, "the merged copy's allowance mustn't count as money left")
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

    func testANewPhonesProvisionalAccountOnlyAddsItsChanges() throws {
        // Phone A's real balance, set weeks ago.
        let real = SavingsAccount(balanceCents: 10_000_000, updatedAt: d(2026, 10, 1))
        context.insert(real)
        // Phone B, before A's data arrived, closed a month moving R500.
        let stub = SavingsAccount(balanceCents: 0, updatedAt: d(2026, 11, 5))
        stub.isProvisional = true
        stub.adjust(by: 50_000, at: d(2026, 11, 5))
        context.insert(stub)
        try context.save()

        XCTAssertEqual(SavingsAccount.effectiveBalance([real, stub]), 10_050_000, "shown right even before merging")
        XCTAssertEqual(SyncDeduplicator.run(in: context).savingsAccounts, 1)
        let left = try context.fetch(FetchDescriptor<SavingsAccount>())
        XCTAssertEqual(left.count, 1)
        XCTAssertEqual(left.first?.balanceCents, 10_050_000)
        XCTAssertEqual(left.first?.isProvisional, false)
    }

    func testABalanceTypedInAfterwardsAlreadyIncludesTheNewPhonesChanges() throws {
        let stub = SavingsAccount(balanceCents: 0, updatedAt: d(2026, 11, 5))
        stub.isProvisional = true
        stub.adjust(by: 50_000, at: d(2026, 11, 5))
        context.insert(stub)
        let real = SavingsAccount(balanceCents: 0, updatedAt: d(2026, 1, 1))
        context.insert(real)
        real.set(to: 10_050_000, at: d(2026, 11, 6))   // typed in on phone A later
        try context.save()
        SyncDeduplicator.run(in: context)
        XCTAssertEqual(try context.fetch(FetchDescriptor<SavingsAccount>()).map(\.balanceCents), [10_050_000])
    }

    func testChangesGoToTheRealBalanceOnceItArrives() throws {
        let stub = SavingsAccount(balanceCents: 0, updatedAt: d(2026, 11, 7))
        stub.isProvisional = true
        context.insert(stub)
        let real = SavingsAccount(balanceCents: 900, updatedAt: d(2026, 10, 1))
        context.insert(real)
        try context.save()
        XCTAssertTrue(SavingsAccount.current(in: context) === real)
    }

    func testTwoRealBalancesKeepTheLatest() throws {
        context.insert(SavingsAccount(balanceCents: 1_000_000, updatedAt: d(2026, 11, 1)))
        context.insert(SavingsAccount(balanceCents: 1_200_000, updatedAt: d(2026, 11, 4)))
        try context.save()
        XCTAssertEqual(SyncDeduplicator.run(in: context).savingsAccounts, 1)
        XCTAssertEqual(SavingsAccount.current(in: context).balanceCents, 1_200_000)
    }

    func testAccountCreatedByAChangeIsProvisionalUntilYouSetIt() throws {
        let account = SavingsAccount.current(in: context)
        XCTAssertTrue(account.isProvisional)
        account.adjust(by: 2_000)
        XCTAssertEqual(account.deltaCents, 2_000)
        account.set(to: 90_000)
        XCTAssertFalse(account.isProvisional)
        XCTAssertEqual(account.deltaCents, 0)
        XCTAssertEqual(account.balanceCents, 90_000)
    }

    func testRunsOnlyAfterADownload() throws {
        SyncDeduplicator.needsRun = false
        XCTAssertNil(SyncDeduplicator.runIfNeeded(in: context))
        SyncDeduplicator.needsRun = true
        XCTAssertNotNil(SyncDeduplicator.runIfNeeded(in: context))
        XCTAssertFalse(SyncDeduplicator.needsRun)
    }

    func testNothingToMergeChangesNothing() throws {
        _ = budget("Food", device: "phone-A", inserted: d(2026, 1, 1))
        _ = budget("Fuel", device: "phone-B", inserted: d(2026, 1, 1))
        context.insert(SavingsAccount(balanceCents: 5, updatedAt: d(2026, 1, 1)))
        try context.save()
        XCTAssertEqual(SyncDeduplicator.run(in: context), SyncDeduplicator.Report())
    }

    func testNameNormalisation() {
        XCTAssertEqual(SyncDeduplicator.normalizedName("  Café   Treats "), "cafe treats")
        XCTAssertEqual(SyncDeduplicator.normalizedName("FOOD"), SyncDeduplicator.normalizedName("food"))
    }
}
