import XCTest
import SwiftData
@testable import Envelope

private final class ScriptedClient: LLMJSONCompleting {
    var replies: [Result<String, Error>]
    var requests: [LLMRequest] = []
    init(_ replies: [Result<String, Error>]) { self.replies = replies }
    func completeJSON(_ request: LLMRequest) async throws -> String {
        requests.append(request)
        guard !replies.isEmpty else { throw LLMError.emptyResponse }
        return try replies.removeFirst().get()
    }
}

@MainActor
final class StatementImportTests: XCTestCase {
    private let cal = TestCalendar.utc
    private func d(_ y: Int, _ m: Int, _ day: Int) -> Date { TestCalendar.date(y, m, day) }

    private func tx(_ date: Date, _ desc: String, _ cents: Int, _ kind: StatementImport.Kind = .spend, _ category: String = "Groceries", file: String = "fnb.csv") -> StatementImport.Transaction {
        .init(date: date, description: desc, cents: cents, kind: kind, category: category, rawAmount: Money.plain(cents: cents), fileName: file)
    }

    // MARK: CSV

    func testChunksRepeatHeaderAndHandleBOMCRLFAndBlankLines() throws {
        let rows = (1...5).map { "2026-10-0\($0),Shop \($0),-10.00" }
        let text = "\u{FEFF}Date,Description,Amount\r\n\r\n" + rows.joined(separator: "\r\n") + "\r\n"
        let chunks = try StatementImport.chunks(fileName: "a.csv", text: text, rowsPerChunk: 2)
        XCTAssertEqual(chunks.count, 3)
        XCTAssertEqual(chunks.map(\.rows.count), [2, 2, 1])
        XCTAssertTrue(chunks.allSatisfy { $0.header == "Date,Description,Amount" })
        XCTAssertEqual(chunks[2].text, "Date,Description,Amount\n2026-10-05,Shop 5,-10.00")
        XCTAssertEqual(chunks.map(\.index), [0, 1, 2])
    }

    func testEmptyAndHeaderOnlyFilesAreRejected() {
        XCTAssertThrowsError(try StatementImport.chunks(fileName: "a", text: "\n\n"))
        XCTAssertThrowsError(try StatementImport.chunks(fileName: "a", text: "Date,Amount\n"))
    }

    func testHugeFilesAreRejected() {
        let text = "h\n" + Array(repeating: "x", count: StatementImport.maxRows + 1).joined(separator: "\n")
        XCTAssertThrowsError(try StatementImport.chunks(fileName: "a", text: text)) { error in
            XCTAssertEqual(error as? StatementImport.ImportError, .tooLarge(StatementImport.maxRows + 1))
        }
    }

    func testExtractionRequestSendsTheCSVAndAsksForJSON() throws {
        let chunk = try StatementImport.chunks(fileName: "fnb.csv", text: "Date,Desc,Amount\n2026-10-01,KFC,-100.70")[0]
        let request = StatementImport.extractionRequest(chunk)
        XCTAssertTrue(request.user.contains("2026-10-01,KFC,-100.70"))
        XCTAssertTrue(request.user.contains("Date,Desc,Amount"))
        XCTAssertTrue(request.system.contains("extract transactions"))
        XCTAssertNotNil(request.schema)
        XCTAssertEqual(request.maxTokens, 16000)
    }

    // MARK: Parsing

    func testParseExtraction() throws {
        let reply = """
        ```json
        {"transactions": [
          {"date": "2026-10-03", "description": "Woolworths Menlyn", "amount": "1 234,50", "kind": "spend", "category": "Groceries"},
          {"date": "2026-10-25", "description": "Salary", "amount": "-25000.00", "kind": "income", "category": "Income"},
          {"date": "2026-13-40", "description": "Bad date", "amount": "10.00", "kind": "spend", "category": "Other"},
          {"date": "2026-10-04", "description": "Zero", "amount": "0.00", "kind": "spend", "category": "Other"},
          {"date": "2026-10-05", "description": "Engen", "amount": 650.5, "kind": "SPEND", "category": ""}
        ]}
        ```
        """
        let rows = try XCTUnwrap(StatementImport.parseExtraction(reply, fileName: "fnb.csv", calendar: cal))
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[0].cents, 123_450)
        XCTAssertEqual(rows[0].date, d(2026, 10, 3))
        XCTAssertEqual(rows[1].kind, .income)
        XCTAssertEqual(rows[1].cents, 2_500_000, "amounts are always positive")
        XCTAssertEqual(rows[2].cents, 65_050)
        XCTAssertEqual(rows[2].kind, .spend)
        XCTAssertEqual(rows[2].category, "Other")
        XCTAssertNil(StatementImport.parseExtraction("sorry, no", fileName: "x"))
    }

    func testParseDateRejectsImpossibleDates() {
        XCTAssertNil(StatementImport.parseDate("2026-02-30", calendar: cal))
        XCTAssertNil(StatementImport.parseDate("31/10/2026", calendar: cal))
        XCTAssertEqual(StatementImport.parseDate("2026-10-31T08:00:00", calendar: cal), d(2026, 10, 31))
    }

    func testParseBudgetsDedupesAndReadsAmounts() throws {
        let reply = #"{"budgets":[{"name":"Groceries","monthly_amount":"3250.00","categories":["Groceries"]},{"name":"groceries","monthly_amount":"1.00","categories":[]},{"name":"Fuel","monthly_amount":1500,"categories":["Fuel","Transport"]},{"name":"","monthly_amount":"5","categories":[]}]}"#
        let budgets = try XCTUnwrap(StatementImport.parseBudgets(reply))
        XCTAssertEqual(budgets, [
            .init(name: "Groceries", monthlyCents: 325_000, categories: ["Groceries"]),
            .init(name: "Fuel", monthlyCents: 150_000, categories: ["Fuel", "Transport"]),
        ])
    }

    // MARK: Summary and plan

    func testSummaryCountsMonthsAndAverages() {
        let summary = StatementImport.summarize([
            tx(d(2026, 8, 5), "Checkers", 300_000),
            tx(d(2026, 10, 20), "Checkers", 300_000),
            tx(d(2026, 9, 1), "Pick n Pay", 300_000),
            tx(d(2026, 9, 2), "Engen", 90_000, .spend, "Fuel"),
            tx(d(2026, 9, 25), "Salary", 5_000_000, .income, "Income"),
        ], calendar: cal)
        XCTAssertEqual(summary.months, 3)
        XCTAssertEqual(summary.categories.map(\.category), ["Groceries", "Fuel"])
        XCTAssertEqual(summary.categories[0].monthlyAverageCents, 300_000)
        XCTAssertEqual(summary.categories[0].topMerchants, ["Checkers", "Pick n Pay"])
        XCTAssertEqual(summary.categories[1].count, 1)
    }

    func testPlanMapsCategoriesSkipsNonSpendingAndDuplicates() {
        let budgets: [StatementImport.ProposedBudget] = [
            .init(name: "Food", monthlyCents: 400_000, categories: ["Groceries", "Eating out"]),
            .init(name: "Fuel", monthlyCents: 150_000, categories: ["fuel"]),
        ]
        let plan = StatementImport.plan(
            transactions: [
                tx(d(2026, 10, 1), "Checkers", 50_000),
                tx(d(2026, 10, 1), "Checkers", 50_000, file: "fnb-overlap.csv"),  // same row in an overlapping export
                tx(d(2026, 10, 2), "KFC", 10_070, .spend, "Eating out"),  // already logged by Apple Pay
                tx(d(2026, 10, 3), "Engen", 60_000, .spend, "Fuel"),
                tx(d(2026, 10, 4), "Netflix", 19_900, .spend, "Subscriptions"),
                tx(d(2026, 10, 25), "Salary", 5_000_000, .income, "Income"),
                tx(d(2026, 10, 26), "To savings", 100_000, .transfer, "Transfer"),
            ],
            budgets: budgets,
            existing: [(date: d(2026, 10, 2).addingTimeInterval(3600 * 7), cents: 10_070)],
            calendar: cal
        )
        XCTAssertEqual(plan.skippedNotSpending, 2)
        XCTAssertEqual(plan.skippedDuplicates, 2)
        XCTAssertEqual(plan.payments.count, 3)
        XCTAssertEqual(plan.payments(for: budgets[0]).map(\.transaction.description), ["Checkers"])
        XCTAssertEqual(plan.payments(for: budgets[1]).map(\.transaction.description), ["Engen"])
        XCTAssertEqual(plan.unmatched.map(\.transaction.description), ["Netflix"])
    }

    func testIdenticalRowsInOneStatementAreAllKept() {
        let plan = StatementImport.plan(
            transactions: [
                tx(d(2026, 10, 1), "Vida e Caffe", 3_500, .spend, "Eating out"),
                tx(d(2026, 10, 1), "Vida e Caffe", 3_500, .spend, "Eating out"),
                // The overlapping second export has the same two coffees: no extra copies.
                tx(d(2026, 10, 1), "Vida e Caffe", 3_500, .spend, "Eating out", file: "b.csv"),
                tx(d(2026, 10, 1), "Vida e Caffe", 3_500, .spend, "Eating out", file: "b.csv"),
            ],
            budgets: [], existing: [], calendar: cal
        )
        XCTAssertEqual(plan.payments.count, 2)
        XCTAssertEqual(plan.skippedDuplicates, 2)
    }

    func testEachExistingPaymentCancelsOnlyOneRow() {
        let plan = StatementImport.plan(
            transactions: [
                tx(d(2026, 10, 2), "Coffee", 5_000, .spend, "Eating out"),
                tx(d(2026, 10, 2), "Parking", 5_000, .spend, "Transport"),
            ],
            budgets: [],
            existing: [(date: d(2026, 10, 2), cents: 5_000)],
            calendar: cal
        )
        XCTAssertEqual(plan.skippedDuplicates, 1, "only the one already logged by Apple Pay")
        XCTAssertEqual(plan.payments.map(\.transaction.description), ["Parking"])
    }

    func testMonthsAreTheSpanCoveredNotCalendarMonthsTouched() {
        let summary = StatementImport.summarize([
            tx(d(2026, 8, 15), "A", 100_000),
            tx(d(2026, 10, 14), "B", 100_000),
        ], calendar: cal)
        XCTAssertEqual(summary.months, 2)
        XCTAssertEqual(summary.categories[0].monthlyAverageCents, 100_000)
    }

    func testRetryHelpers() {
        XCTAssertTrue(HTTPLLMClient.isRetryable(status: 429))
        XCTAssertTrue(HTTPLLMClient.isRetryable(status: 529))
        XCTAssertTrue(HTTPLLMClient.isRetryable(status: 503))
        XCTAssertFalse(HTTPLLMClient.isRetryable(status: 401))
        XCTAssertFalse(HTTPLLMClient.isRetryable(status: 400))
        XCTAssertEqual(HTTPLLMClient.delay(attempt: 1, retryAfter: nil), 2_000_000_000)
        XCTAssertEqual(HTTPLLMClient.delay(attempt: 2, retryAfter: "5"), 5_000_000_000)
        XCTAssertEqual(HTTPLLMClient.delay(attempt: 9, retryAfter: nil), 30_000_000_000)
    }

    // MARK: Saving

    func testApplyCreatesBudgetsReusesExistingAndMarksPaymentsImported() throws {
        let container = try Persistence.inMemory()
        let context = container.mainContext
        let existingFood = try BudgetService.addBudget(name: "food", monthlyCents: 999_900, in: context)
        let budgets: [StatementImport.ProposedBudget] = [
            .init(name: "Food", monthlyCents: 400_000, categories: ["Groceries"]),
            .init(name: "Fuel", monthlyCents: 150_000, categories: ["Fuel"]),
            .init(name: "Fun", monthlyCents: 80_000, categories: ["Entertainment"]),
        ]
        let plan = StatementImport.plan(
            transactions: [
                tx(d(2026, 10, 1), "Checkers", 50_000),
                tx(d(2026, 10, 3), "Engen", 60_000, .spend, "Fuel"),
                tx(d(2026, 10, 4), "Ster-Kinekor", 12_000, .spend, "Entertainment"),
                tx(d(2026, 10, 5), "Netflix", 19_900, .spend, "Subscriptions"),
            ],
            budgets: budgets, existing: [], calendar: cal
        )

        let result = try StatementImport.apply(plan, included: ["food", "fuel"], importUnmatched: false, now: d(2026, 11, 4), in: context)
        XCTAssertEqual(result, .init(budgetsCreated: 1, budgetsReused: 1, paymentsImported: 2, unassignedImported: 0))

        let active = try BudgetService.activeBudgets(in: context)
        XCTAssertEqual(Set(active.map(\.name)), ["food", "Fuel"], "Fun was switched off")
        XCTAssertEqual(existingFood.monthlyCents, 999_900, "an existing budget keeps its amount")
        let payments = try context.fetch(FetchDescriptor<Payment>())
        XCTAssertEqual(payments.count, 2)
        XCTAssertTrue(payments.allSatisfy { $0.source == .statement && $0.assignment == .imported && $0.aiAttempted })
        XCTAssertEqual(payments.first { $0.merchant == "Checkers" }?.budget?.id, existingFood.id)
        let fuel = try XCTUnwrap(active.first { $0.name == "Fuel" })
        XCTAssertEqual(fuel.createdAt, MonthMath.startOfMonth(d(2026, 10, 3)), "starts in the month of its first imported payment")
        XCTAssertLessThanOrEqual(existingFood.createdAt, MonthMath.startOfMonth(d(2026, 10, 1)), "an existing budget is backdated too")
    }

    func testApplyCanImportUnmatchedAsUnassigned() throws {
        let container = try Persistence.inMemory()
        let context = container.mainContext
        let plan = StatementImport.plan(
            transactions: [tx(d(2026, 10, 5), "Netflix", 19_900, .spend, "Subscriptions")],
            budgets: [.init(name: "Food", monthlyCents: 1, categories: ["Groceries"])],
            existing: [], calendar: cal
        )
        let result = try StatementImport.apply(plan, included: ["food"], importUnmatched: true, in: context)
        XCTAssertEqual(result.unassignedImported, 1)
        let payment = try XCTUnwrap(try context.fetch(FetchDescriptor<Payment>()).first)
        XCTAssertNil(payment.budget)
        XCTAssertTrue(payment.aiAttempted, "not sent to the AI again automatically")
    }

    func testCorrectingAnImportedPaymentIsRecorded() throws {
        let container = try Persistence.inMemory()
        let context = container.mainContext
        let food = try BudgetService.addBudget(name: "Food", monthlyCents: 1, in: context)
        let fun = try BudgetService.addBudget(name: "Fun", monthlyCents: 1, in: context)
        let p = Payment(amountCents: 100, merchant: "Spur", card: "", date: d(2026, 10, 1), source: .statement)
        context.insert(p); p.budget = fun; p.assignment = .imported
        PaymentAssignment.assign(p, to: food)
        XCTAssertEqual(p.aiOriginalBudgetName, "Fun")
        XCTAssertEqual(p.assignment, .manual)
    }

    // MARK: End to end with a scripted AI

    func testImporterExtractsProposesAndPlans() async throws {
        let container = try Persistence.inMemory()
        let context = container.mainContext
        let csv = "Date,Description,Amount\n2026-10-01,POS WOOLWORTHS,-500.00\n2026-10-02,ENGEN,-600.00\n2026-10-25,SALARY,25000.00"
        let client = ScriptedClient([
            .success(#"{"transactions":[{"date":"2026-10-01","description":"Woolworths","amount":"500.00","kind":"spend","category":"Groceries"},{"date":"2026-10-02","description":"Engen","amount":"600.00","kind":"spend","category":"Fuel"},{"date":"2026-10-25","description":"Salary","amount":"25000.00","kind":"income","category":"Income"}]}"#),
            .success(#"{"budgets":[{"name":"Groceries","monthly_amount":"500.00","categories":["Groceries"]},{"name":"Fuel","monthly_amount":"600.00","categories":["Fuel"]}]}"#),
        ])
        let importer = StatementImporter(client: client, calendar: cal)
        await importer.run(files: [(name: "fnb.csv", text: csv)], in: context)

        XCTAssertEqual(importer.stage, .review)
        let plan = try XCTUnwrap(importer.plan)
        XCTAssertEqual(plan.payments.count, 2)
        XCTAssertEqual(plan.skippedNotSpending, 1)
        XCTAssertEqual(client.requests.count, 2)
        XCTAssertTrue(client.requests[0].user.contains("POS WOOLWORTHS"), "the CSV itself is sent")
        XCTAssertTrue(client.requests[1].user.contains("Groceries | 500.00"))

        importer.apply(included: Set(plan.budgets.map(\.id)), importUnmatched: false, in: context)
        guard case .done(let result) = importer.stage else { return XCTFail("\(importer.stage)") }
        XCTAssertEqual(result.paymentsImported, 2)
        XCTAssertEqual(result.budgetsCreated, 2)
    }

    func testTruncatedPartIsSplitAndRetried() async throws {
        let container = try Persistence.inMemory()
        let context = container.mainContext
        let csv = "Date,Description,Amount\n2026-10-01,A,-1.00\n2026-10-02,B,-2.00"
        let client = ScriptedClient([
            .failure(LLMError.truncated),
            .success(#"{"transactions":[{"date":"2026-10-01","description":"A","amount":"1.00","kind":"spend","category":"Other"}]}"#),
            .success(#"{"transactions":[{"date":"2026-10-02","description":"B","amount":"2.00","kind":"spend","category":"Other"}]}"#),
            .success(#"{"budgets":[{"name":"Other","monthly_amount":"3.00","categories":["Other"]}]}"#),
        ])
        let importer = StatementImporter(client: client, calendar: cal)
        await importer.run(files: [(name: "a.csv", text: csv)], in: context)
        XCTAssertEqual(importer.stage, .review)
        XCTAssertEqual(importer.plan?.payments.count, 2)
        XCTAssertTrue(client.requests[1].user.contains("2026-10-01,A") && !client.requests[1].user.contains("2026-10-02,B"))
    }

    func testFailureIsReported() async throws {
        let container = try Persistence.inMemory()
        let client = ScriptedClient([.failure(LLMError.http(401, "invalid x-api-key"))])
        let importer = StatementImporter(client: client, calendar: cal)
        await importer.run(files: [(name: "a.csv", text: "Date,Amount\n2026-10-01,-1.00")], in: container.mainContext)
        guard case .failed(let message) = importer.stage else { return XCTFail() }
        XCTAssertTrue(message.contains("401"))
    }

    func testTruncationIsDetectedInBothFormats() {
        let anthropic = #"{"content":[{"type":"text","text":"{\"transactions\":["}],"stop_reason":"max_tokens"}"#
        XCTAssertThrowsError(try HTTPLLMClient.extractText(style: .anthropic, data: Data(anthropic.utf8))) {
            XCTAssertEqual($0 as? LLMError, .truncated)
        }
        let openai = #"{"choices":[{"finish_reason":"length","message":{"content":"{\"tra"}}]}"#
        XCTAssertThrowsError(try HTTPLLMClient.extractText(style: .openAICompatible, data: Data(openai.utf8))) {
            XCTAssertEqual($0 as? LLMError, .truncated)
        }
    }
}
