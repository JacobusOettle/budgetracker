import XCTest
import SwiftData
@testable import Envelope

private final class CannedClient: LLMJSONCompleting {
    var replies: [String]
    init(_ replies: [String]) { self.replies = replies }
    func completeJSON(_ request: LLMRequest) async throws -> String {
        guard !replies.isEmpty else { throw LLMError.emptyResponse }
        return replies.removeFirst()
    }
}

/// Importing statements on top of payments Spaar already has (from Apple
/// Pay, typed in, or an earlier import): merged, never duplicated.
@MainActor
final class StatementMergeTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext { container.mainContext }
    private let cal = TestCalendar.utc
    private func d(_ y: Int, _ m: Int, _ day: Int, hour: Int = 12) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: day, hour: hour))!
    }

    override func setUp() async throws {
        container = try Persistence.inMemory()
    }

    private let budgets: [StatementImport.ProposedBudget] = [
        .init(name: "Food", monthlyCents: 400_000, categories: ["Groceries", "Eating out"]),
        .init(name: "Fuel", monthlyCents: 200_000, categories: ["Fuel"]),
    ]
    private var allBudgets: Set<String> { Set(budgets.map(\.id)) }

    private func tx(_ date: Date, _ desc: String, _ cents: Int, _ category: String = "Groceries", file: String = "fnb.pdf") -> StatementImport.Transaction {
        .init(date: date, description: desc, cents: cents, kind: .spend, category: category, rawAmount: Money.plain(cents: cents), fileName: file)
    }

    @discardableResult
    private func walletPayment(_ merchant: String, _ cents: Int, at date: Date, budget: Budget? = nil) -> Payment {
        let p = Payment(amountCents: cents, merchant: merchant, card: "New FNB Fusion Virtual Premier25", date: date, source: .shortcut, rawAmount: Money.format(cents: cents))
        context.insert(p)
        p.budget = budget
        p.assignment = budget == nil ? .unassigned : .armed
        try? context.save()
        return p
    }

    private func existing() throws -> [StatementImport.ExistingPayment] {
        try context.fetch(FetchDescriptor<Payment>()).map {
            .init(id: $0.id, date: $0.date, cents: $0.amountCents, merchant: $0.merchant, hasBudget: $0.budget != nil,
                  fromStatement: $0.statementMatched || $0.source == .statement)
        }
    }

    private func importPlan(_ transactions: [StatementImport.Transaction]) throws -> StatementImport.Plan {
        StatementImport.plan(transactions: transactions, budgets: budgets, existing: try existing(), calendar: cal)
    }

    private func count() throws -> Int { try context.fetchCount(FetchDescriptor<Payment>()) }

    // MARK: Importing twice

    func testImportingTheSameStatementTwiceAddsNothingTheSecondTime() throws {
        let rows = [
            tx(d(2026, 10, 1), "Checkers Hyper", 85_000),
            tx(d(2026, 10, 1), "Checkers Hyper", 85_000),   // two real identical purchases
            tx(d(2026, 10, 3), "Engen Sandton", 60_000, "Fuel"),
        ]
        let first = try StatementImport.apply(importPlan(rows), included: allBudgets, importUnmatched: false, now: d(2026, 11, 5), in: context)
        XCTAssertEqual(first.paymentsImported, 3)

        let second = try importPlan(rows)
        XCTAssertTrue(second.payments.isEmpty)
        XCTAssertEqual(second.exactMerges.count, 3)
        let result = try StatementImport.apply(second, included: allBudgets, importUnmatched: false, now: d(2026, 11, 5), in: context)
        XCTAssertEqual(result.paymentsImported, 0)
        XCTAssertEqual(result.merged, 3)
        XCTAssertEqual(try count(), 3, "no duplicates")
    }

    func testOverlappingStatementOnlyAddsTheNewMonths() throws {
        try StatementImport.apply(importPlan([tx(d(2026, 9, 10), "Spar", 20_000)]), included: allBudgets, importUnmatched: false, now: d(2026, 11, 5), in: context)
        let plan = try importPlan([tx(d(2026, 9, 10), "SPAR", 20_000), tx(d(2026, 10, 10), "Spar", 30_000)])
        XCTAssertEqual(plan.exactMerges.count, 1)
        XCTAssertEqual(plan.payments.map(\.transaction.cents), [30_000])
    }

    // MARK: Apple Pay payments already logged

    func testWalletPaymentIsMergedAndKeepsItsArmedBudgetAndTime() throws {
        let fun = try BudgetService.addBudget(name: "Fun", monthlyCents: 80_000, in: context)
        let tap = walletPayment("KFC Wierda Park", 10_070, at: d(2026, 10, 2, hour: 9), budget: fun)
        let plan = try importPlan([tx(d(2026, 10, 2), "KFC Wierda Park", 10_070, "Eating out")])
        XCTAssertEqual(plan.exactMerges.count, 1)

        let result = try StatementImport.apply(plan, included: allBudgets, importUnmatched: false, now: d(2026, 11, 5), in: context)
        XCTAssertEqual(result.merged, 1)
        XCTAssertEqual(result.paymentsImported, 0)
        XCTAssertEqual(try count(), 1)
        XCTAssertEqual(tap.budget?.id, fun.id, "your armed choice wins over the statement's category")
        XCTAssertEqual(tap.assignment, .armed)
        XCTAssertEqual(tap.date, d(2026, 10, 2, hour: 9), "keeps the exact tap time")
        XCTAssertTrue(tap.statementMatched)
    }

    func testUnassignedWalletPaymentGetsTheStatementsBudget() throws {
        let tap = walletPayment("Engen Sandton", 60_000, at: d(2026, 10, 3))
        let plan = try importPlan([tx(d(2026, 10, 4), "ENGEN SANDTON", 60_000, "Fuel")])   // bank posted it a day later
        XCTAssertTrue(plan.exactMerges.first?.fillsInBudget ?? false)

        let result = try StatementImport.apply(plan, included: allBudgets, importUnmatched: false, now: d(2026, 11, 5), in: context)
        XCTAssertEqual(result.budgetsFilledIn, 1)
        XCTAssertEqual(tap.budget?.name, "Fuel")
        XCTAssertEqual(tap.assignment, .imported)
        XCTAssertEqual(try count(), 1)
    }

    func testPostingDelayOfUpToThreeDaysWithTheSameShop() throws {
        walletPayment("Woolworths Food Menlyn", 25_000, at: d(2026, 10, 1))
        XCTAssertEqual(try importPlan([tx(d(2026, 10, 4), "WOOLWORTHS MENLYN", 25_000)]).exactMerges.count, 1)
        XCTAssertEqual(try importPlan([tx(d(2026, 10, 5), "WOOLWORTHS MENLYN", 25_000)]).merges.count, 0, "4 days apart is a different payment")
    }

    func testSameShopAndClosestDateWinWhenAmountsCollide() throws {
        let engen = walletPayment("Engen", 10_000, at: d(2026, 10, 2))
        let plan = try importPlan([
            tx(d(2026, 10, 2), "Spar Hatfield", 10_000),
            tx(d(2026, 10, 3), "Engen Lynnwood", 10_000, "Fuel"),
        ])
        XCTAssertEqual(plan.exactMerges.map(\.transaction.description), ["Engen Lynnwood"])
        XCTAssertEqual(plan.exactMerges.first?.existing.id, engen.id)
        XCTAssertEqual(plan.payments.map(\.transaction.description), ["Spar Hatfield"])
    }

    func testEachExistingPaymentAbsorbsOnlyOneRow() throws {
        walletPayment("Vida e Caffe", 3_500, at: d(2026, 10, 6))
        let plan = try importPlan([
            tx(d(2026, 10, 6), "Vida e Caffe", 3_500, "Eating out"),
            tx(d(2026, 10, 6), "Vida e Caffe", 3_500, "Eating out"),
        ])
        XCTAssertEqual(plan.merges.count, 1)
        XCTAssertEqual(plan.payments.count, 1, "the second coffee is a real, unlogged purchase")
    }

    func testCrypticDescriptionStillMatchesSameAmountSameDay() throws {
        walletPayment("Takealot", 49_900, at: d(2026, 10, 8))
        let plan = try importPlan([tx(d(2026, 10, 8), "POS 4567*1234 CPT", 49_900, "Shopping")])
        XCTAssertEqual(plan.exactMerges.count, 1, "a short city code isn't a shop name")
        let farther = try importPlan([tx(d(2026, 10, 10), "POS 4567*1234 CPT", 49_900, "Shopping")])
        XCTAssertEqual(farther.merges.count, 0, "without a matching name, only within 1 day")
    }

    func testReimportingCrypticRowsStillMerges() throws {
        let rows = [tx(d(2026, 10, 8), "POS 4567*1234", 49_900, "Shopping")]
        try StatementImport.apply(importPlan(rows), included: allBudgets, importUnmatched: true, now: d(2026, 11, 5), in: context)
        XCTAssertEqual(try count(), 1)
        let again = try importPlan(rows)
        XCTAssertEqual(again.exactMerges.count, 1)
        XCTAssertTrue(again.payments.isEmpty)
    }

    func testReimportAfterACrypticMergeAddsNothing() throws {
        walletPayment("", 49_900, at: d(2026, 10, 8))   // Apple Pay sent no merchant
        let rows = [tx(d(2026, 10, 8), "POS 4567*1234 CPT", 49_900, "Shopping")]
        try StatementImport.apply(importPlan(rows), included: allBudgets, importUnmatched: false, now: d(2026, 11, 5), in: context)
        XCTAssertEqual(try count(), 1)
        let again = try importPlan(rows)
        XCTAssertTrue(again.payments.isEmpty)
        XCTAssertEqual(again.merges.count, 1)
    }

    func testTwoAccountsSameAmountOnNearbyDaysAreBothKept() throws {
        let plan = try importPlan([
            tx(d(2026, 10, 2), "Spar Hatfield", 10_000, file: "fnb.pdf"),
            tx(d(2026, 10, 3), "Engen Lynnwood", 10_000, "Fuel", file: "capitec.pdf"),
            tx(d(2026, 10, 3), "POS 9999", 5_000, file: "capitec.pdf"),
            tx(d(2026, 10, 4), "POS 1111", 5_000, file: "fnb.pdf"),
        ])
        XCTAssertEqual(plan.skippedDuplicates, 0)
        XCTAssertEqual(plan.payments.count, 4)
    }

    func testDifferentNamesSameAmountIsUncertainAndKeptSeparateByDefault() throws {
        walletPayment("Engen", 10_000, at: d(2026, 10, 2))   // maybe paid with the other card
        let plan = try importPlan([tx(d(2026, 10, 2), "Spar Hatfield", 10_000)])
        let merge = try XCTUnwrap(plan.possibleMerges.first)
        XCTAssertEqual(merge.kind, .uncertain)
        XCTAssertFalse(merge.mergedByDefault)
        let defaults = Set(plan.possibleMerges.filter { !$0.mergedByDefault }.map(\.id))
        try StatementImport.apply(plan, included: allBudgets, importUnmatched: false, rejectedMerges: defaults, now: d(2026, 11, 5), in: context)
        XCTAssertEqual(try count(), 2)
    }

    func testCSVAndPDFOfTheSameMonthInOneImportAreNotDoubled() throws {
        let plan = try importPlan([
            tx(d(2026, 10, 1), "Woolworths Menlyn", 25_000, file: "october.csv"),
            tx(d(2026, 10, 1), "Woolworths Menlyn", 25_000, file: "october.csv"),
            tx(d(2026, 10, 2), "WOOLWORTHS FOOD MENLYN", 25_000, file: "october.pdf"),   // PDF shows the posting date
            tx(d(2026, 10, 2), "WOOLWORTHS FOOD MENLYN", 25_000, file: "october.pdf"),
            tx(d(2026, 10, 9), "Engen", 60_000, "Fuel", file: "october.pdf"),           // only in the PDF
        ])
        XCTAssertEqual(plan.skippedDuplicates, 2)
        XCTAssertEqual(plan.payments.count, 3, "two real Woolworths visits plus Engen")
    }

    func testNextMonthsPurchaseAtTheSameShopIsNotMergedIntoLastMonthsImport() throws {
        try StatementImport.apply(importPlan([tx(d(2026, 9, 30), "Spar Brooklyn", 20_000, file: "sep.pdf")]),
                                  included: allBudgets, importUnmatched: false, now: d(2026, 11, 5), in: context)
        let plan = try importPlan([tx(d(2026, 10, 1), "Spar Brooklyn", 25_000, file: "oct.pdf")])
        XCTAssertTrue(plan.merges.isEmpty, "an earlier statement's payment only matches the same amount")
        XCTAssertEqual(plan.payments.count, 1)
    }

    func testRejectedMatchIsAddedEvenWithoutABudget() throws {
        walletPayment("Netflix", 19_900, at: d(2026, 10, 5))
        let plan = try importPlan([tx(d(2026, 10, 5), "NETFLIX.COM", 21_900, "Subscriptions")])   // no budget fits
        let merge = try XCTUnwrap(plan.possibleMerges.first)
        let result = try StatementImport.apply(plan, included: allBudgets, importUnmatched: false, rejectedMerges: [merge.id], now: d(2026, 11, 5), in: context)
        XCTAssertEqual(result.paymentsImported, 1)
        XCTAssertEqual(try count(), 2)
    }

    func testBudgetsAreNotBackdatedByMergesThatDontJoinThem() throws {
        let fun = try BudgetService.addBudget(name: "Fun", monthlyCents: 80_000, now: d(2026, 9, 1), in: context)
        walletPayment("KFC Wierda Park", 10_070, at: d(2026, 9, 2), budget: fun)
        let plan = try importPlan([tx(d(2026, 9, 2), "KFC Wierda Park", 10_070, "Eating out")])
        try StatementImport.apply(plan, included: allBudgets, importUnmatched: false, now: d(2026, 11, 5), in: context)
        let food = try XCTUnwrap(try BudgetService.activeBudgets(in: context).first { $0.name == "Food" })
        XCTAssertEqual(food.createdAt, d(2026, 11, 5), "the KFC payment stays in Fun, so Food starts now")
    }

    // MARK: Different amounts

    func testFuelPreAuthorisationIsAPossibleMatchAndTakesTheBanksAmount() throws {
        let tap = walletPayment("Engen Sandton", 60_000, at: d(2026, 10, 3))
        let plan = try importPlan([tx(d(2026, 10, 3), "ENGEN SANDTON", 61_240, "Fuel")])
        XCTAssertEqual(plan.possibleMerges.count, 1)
        XCTAssertTrue(plan.payments.isEmpty)

        let result = try StatementImport.apply(plan, included: allBudgets, importUnmatched: false, now: d(2026, 11, 5), in: context)
        XCTAssertEqual(result.amountsUpdated, 1)
        XCTAssertEqual(tap.amountCents, 61_240)
        XCTAssertTrue(tap.note.contains("was R600.00"))
        XCTAssertEqual(try count(), 1)
    }

    func testRejectedPossibleMatchIsAddedSeparately() throws {
        let tap = walletPayment("Engen Sandton", 60_000, at: d(2026, 10, 3))
        let plan = try importPlan([tx(d(2026, 10, 3), "ENGEN SANDTON", 61_240, "Fuel")])
        let merge = try XCTUnwrap(plan.possibleMerges.first)
        let result = try StatementImport.apply(plan, included: allBudgets, importUnmatched: false, rejectedMerges: [merge.id], now: d(2026, 11, 5), in: context)
        XCTAssertEqual(result.paymentsImported, 1)
        XCTAssertEqual(tap.amountCents, 60_000)
        XCTAssertEqual(try count(), 2)
    }

    func testUnreadableApplePayAmountIsFilledInFromTheStatement() throws {
        let tap = walletPayment("Spar Brooklyn", 0, at: d(2026, 10, 7))
        tap.needsReview = true
        let plan = try importPlan([tx(d(2026, 10, 7), "SPAR BROOKLYN", 8_500)])
        XCTAssertEqual(plan.possibleMerges.count, 1)
        try StatementImport.apply(plan, included: allBudgets, importUnmatched: false, now: d(2026, 11, 5), in: context)
        XCTAssertEqual(tap.amountCents, 8_500)
        XCTAssertFalse(tap.needsReview)
    }

    func testDifferentShopAndAmountIsNotMatched() throws {
        walletPayment("Engen", 60_000, at: d(2026, 10, 3))
        let plan = try importPlan([tx(d(2026, 10, 3), "Clicks Menlyn", 45_000)])
        XCTAssertTrue(plan.merges.isEmpty)
        XCTAssertEqual(plan.payments.count, 1)
    }

    func testWildlyDifferentAmountAtTheSameShopIsNotMatched() throws {
        walletPayment("Checkers", 5_000, at: d(2026, 10, 3))
        XCTAssertTrue(try importPlan([tx(d(2026, 10, 3), "Checkers", 120_000)]).merges.isEmpty)
    }

    // MARK: Whole flow

    func testImporterIgnoresTestPaymentsWhenMatching() async throws {
        let test = Payment(amountCents: 1_234, merchant: "Test payment", card: "Test", date: d(2026, 10, 9), source: .test)
        context.insert(test)
        try context.save()
        let client = CannedClient([
            #"{"transactions":[{"date":"2026-10-09","description":"Spar","amount":"12.34","kind":"spend","category":"Groceries"}]}"#,
            #"{"budgets":[{"name":"Food","monthly_amount":"100.00","categories":["Groceries"]}]}"#,
        ])
        let importer = StatementImporter(client: client, calendar: cal)
        await importer.run(files: [(name: "a.csv", text: "Date,Desc,Amount\n2026-10-09,SPAR,-12.34")], in: context)
        XCTAssertEqual(importer.plan?.payments.count, 1)
        XCTAssertEqual(importer.plan?.merges.count, 0)
    }

    // MARK: Merchant names

    func testMerchantSimilarity() {
        XCTAssertEqual(StatementImport.merchantSimilarity("KFC Wierda Park", "KFC"), 1)
        XCTAssertEqual(StatementImport.merchantSimilarity("POS PURCHASE WOOLWORTHS 4567*1234", "Woolworths Food"), 1)
        XCTAssertEqual(StatementImport.merchantSimilarity("Woolworth Menlyn", "WOOLWORTHS"), 1)
        XCTAssertEqual(StatementImport.merchantSimilarity("Engen", "Spar"), 0)
        XCTAssertEqual(StatementImport.merchantSimilarity("", "Spar"), 0)
        XCTAssertEqual(StatementImport.merchantSimilarity("POS 1234", "Spar"), 0)
    }
}
