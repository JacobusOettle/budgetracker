import Foundation
import SwiftData

/// Bank statement import: the CSV is sent to your AI provider, which extracts
/// the transactions and then proposes budgets from your spending. You review
/// everything before it's saved.
///
/// Large statements are sent in parts (with the header row each time) so each
/// answer stays well under the model's output limit.
enum StatementImport {
    static let rowsPerChunk = 120
    /// Roughly two years of busy card use. Bigger files are refused up front.
    static let maxRows = 6000

    // MARK: Types

    enum Kind: String, Codable, CaseIterable {
        /// Purchases, debit orders, fees, cash withdrawals: counts as spending.
        case spend
        case income
        /// Between your own accounts, to savings, credit card repayments.
        case transfer
        case refund
    }

    struct Transaction: Equatable {
        let date: Date
        let description: String
        let cents: Int
        let kind: Kind
        let category: String
        let rawAmount: String
        let fileName: String
    }

    struct ProposedBudget: Equatable, Identifiable {
        var id: String { name.lowercased() }
        var name: String
        var monthlyCents: Int
        var categories: [String]
    }

    struct CategorySummary: Equatable {
        let category: String
        let totalCents: Int
        let count: Int
        let monthlyAverageCents: Int
        let topMerchants: [String]
    }

    struct SpendingSummary: Equatable {
        let months: Int
        let firstDate: Date?
        let lastDate: Date?
        let categories: [CategorySummary]
    }

    struct Chunk: Equatable {
        let fileName: String
        let header: String
        let rows: [String]
        let index: Int
        let count: Int

        var text: String { ([header] + rows).joined(separator: "\n") }
    }

    enum ImportError: LocalizedError, Equatable {
        case empty
        case tooLarge(Int)
        case nothingExtracted

        var errorDescription: String? {
            switch self {
            case .empty: "The file is empty."
            case .tooLarge(let rows): "The file has \(rows) rows. Import at most \(StatementImport.maxRows) at a time, e.g. one year per file."
            case .nothingExtracted: "The AI couldn't find any transactions in this file. Check it's a transaction export (CSV), not a summary."
            }
        }
    }

    // MARK: CSV

    /// Splits a CSV into parts of `rowsPerChunk` rows, each with the header row.
    /// The header is the first non-empty line. Handles a byte-order mark, CRLF
    /// line endings and blank lines.
    static func chunks(fileName: String, text: String, rowsPerChunk: Int = rowsPerChunk) throws -> [Chunk] {
        var clean = text
        if clean.hasPrefix("\u{FEFF}") { clean.removeFirst() }
        let lines = clean
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let header = lines.first else { throw ImportError.empty }
        let rows = Array(lines.dropFirst())
        guard !rows.isEmpty else { throw ImportError.empty }
        guard rows.count <= maxRows else { throw ImportError.tooLarge(rows.count) }
        let size = max(1, rowsPerChunk)
        let groups = stride(from: 0, to: rows.count, by: size).map { Array(rows[$0..<min($0 + size, rows.count)]) }
        return groups.enumerated().map { Chunk(fileName: fileName, header: header, rows: $1, index: $0, count: groups.count) }
    }

    // MARK: Extraction

    static let extractionSystem = """
    You extract transactions from a South African bank statement export (CSV) for Tally, a personal budgeting app. Amounts are in rand.
    Return every real transaction row in the part you are given, in order. Skip headers, opening/closing balance lines and summary rows.
    For each transaction:
    - date: YYYY-MM-DD.
    - description: the merchant or payee, cleaned up for a person to read (e.g. "POS PURCHASE WOOLWORTHS MENLYN 4567*1234 12 OCT" becomes "Woolworths Menlyn").
    - amount: a positive amount with two decimals, as text, e.g. "1234.50". Never include a sign or currency symbol.
    - kind: "spend" for card purchases, debit orders, subscriptions, bank fees and cash withdrawals; "income" for salary, deposits and interest received; "transfer" for moves between the person's own accounts, to savings, or credit card repayments; "refund" for refunds and reversals.
    - category: a short spending category such as Groceries, Eating out, Fuel, Transport, Rent, Utilities, Airtime & data, Insurance, Medical, Shopping, Clothing, Entertainment, Subscriptions, Personal care, Education, Gifts, Cash, Bank fees, Home, Travel or Other. Use the same name for the same kind of spending every time.
    Reply with only a JSON object: {"transactions": [{"date": "...", "description": "...", "amount": "...", "kind": "...", "category": "..."}]}
    """

    static let extractionSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "transactions": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "date": ["type": "string"],
                        "description": ["type": "string"],
                        "amount": ["type": "string"],
                        "kind": ["type": "string", "enum": Kind.allCases.map(\.rawValue)],
                        "category": ["type": "string"],
                    ],
                    "required": ["date", "description", "amount", "kind", "category"],
                    "additionalProperties": false,
                ],
            ],
        ],
        "required": ["transactions"],
        "additionalProperties": false,
    ]

    static func extractionRequest(_ chunk: Chunk) -> LLMRequest {
        let user = """
        Statement file: \(chunk.fileName)
        Part \(chunk.index + 1) of \(chunk.count) (the first line is the CSV header):

        \(chunk.text)
        """
        return LLMRequest(system: extractionSystem, user: user, schema: extractionSchema, maxTokens: 16000, effort: "low")
    }

    /// Reads the model's JSON. Rows with an unreadable date or amount are skipped.
    static func parseExtraction(_ text: String, fileName: String, calendar: Calendar = .current) -> [Transaction]? {
        guard let object = jsonObject(in: text) else { return nil }
        let rows: [[String: Any]]
        if let dict = object as? [String: Any], let list = dict["transactions"] as? [[String: Any]] {
            rows = list
        } else if let list = object as? [[String: Any]] {
            rows = list
        } else {
            return nil
        }
        return rows.compactMap { row in
            guard let dateText = row["date"] as? String, let date = parseDate(dateText, calendar: calendar) else { return nil }
            let rawAmount: String
            if let s = row["amount"] as? String { rawAmount = s }
            else if let n = row["amount"] as? NSNumber { rawAmount = n.stringValue }
            else { return nil }
            guard let parsed = AmountParser.parse(rawAmount), parsed.cents != 0 else { return nil }
            let kind = Kind(rawValue: (row["kind"] as? String ?? "").lowercased()) ?? .spend
            let description = (row["description"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let category = (row["category"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return Transaction(
                date: date,
                description: description,
                cents: abs(parsed.cents),
                kind: kind,
                category: category.isEmpty ? "Other" : category,
                rawAmount: rawAmount,
                fileName: fileName
            )
        }
    }

    /// "2026-10-31" at midday local time (midday avoids time zone edge cases).
    static func parseDate(_ text: String, calendar: Calendar = .current) -> Date? {
        let parts = text.trimmingCharacters(in: .whitespaces).prefix(10).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...12).contains(parts[1]), (1...31).contains(parts[2]), parts[0] > 1900 else { return nil }
        var components = DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12)
        components.calendar = calendar
        guard let date = calendar.date(from: components),
              calendar.component(.day, from: date) == parts[2] else { return nil }
        return date
    }

    // MARK: Budgets

    static func summarize(_ transactions: [Transaction], calendar: Calendar = .current) -> SpendingSummary {
        let spend = transactions.filter { $0.kind == .spend }
        let dates = spend.map(\.date)
        guard let first = dates.min(), let last = dates.max() else {
            return SpendingSummary(months: 0, firstDate: nil, lastDate: nil, categories: [])
        }
        let months = max(1, ReplacementPlanner.monthsBetween(first, last, calendar: calendar) + 1)
        let grouped = Dictionary(grouping: spend) { $0.category }
        let categories = grouped.map { category, items -> CategorySummary in
            let total = items.reduce(0) { $0 + $1.cents }
            let merchantCounts = Dictionary(grouping: items) { $0.description }.mapValues(\.count)
            let top = merchantCounts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(5).map(\.key)
            return CategorySummary(category: category, totalCents: total, count: items.count,
                                   monthlyAverageCents: total / months, topMerchants: top)
        }
        .sorted { $0.totalCents != $1.totalCents ? $0.totalCents > $1.totalCents : $0.category < $1.category }
        return SpendingSummary(months: months, firstDate: first, lastDate: last, categories: categories)
    }

    static let budgetSystem = """
    You set up monthly budgets for a person in South Africa (amounts in rand) in Tally, a budgeting app, based on their past spending.
    Propose between 4 and 10 budgets with short, friendly names (one or two words, e.g. Groceries, Eating out, Fuel, Bills, Fun).
    Group small or related categories together. Every spending category you are given must belong to exactly one budget.
    monthly_amount: what they typically spend on it per month, ignoring rare one-off large purchases, rounded up to the nearest 50, as text with two decimals (e.g. "3250.00").
    If the person already has budgets, reuse those exact names where they fit.
    Reply with only a JSON object: {"budgets": [{"name": "...", "monthly_amount": "...", "categories": ["..."]}]}
    """

    static let budgetSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "budgets": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "name": ["type": "string"],
                        "monthly_amount": ["type": "string"],
                        "categories": ["type": "array", "items": ["type": "string"]],
                    ],
                    "required": ["name", "monthly_amount", "categories"],
                    "additionalProperties": false,
                ],
            ],
        ],
        "required": ["budgets"],
        "additionalProperties": false,
    ]

    static func budgetRequest(_ summary: SpendingSummary, existingBudgetNames: [String], calendar: Calendar = .current) -> LLMRequest {
        var lines: [String] = []
        let first = summary.firstDate.map { DataExport.dayString($0, calendar: calendar) } ?? "?"
        let last = summary.lastDate.map { DataExport.dayString($0, calendar: calendar) } ?? "?"
        lines.append("Spending from \(first) to \(last) (\(summary.months) month\(summary.months == 1 ? "" : "s")).")
        if !existingBudgetNames.isEmpty {
            lines.append("Existing budgets: \(existingBudgetNames.joined(separator: ", ")).")
        }
        lines.append("")
        lines.append("Spending categories (category | total | average per month | number of payments | most frequent merchants):")
        for c in summary.categories {
            lines.append("- \(c.category) | \(Money.plain(cents: c.totalCents)) | \(Money.plain(cents: c.monthlyAverageCents)) | \(c.count) | \(c.topMerchants.joined(separator: ", "))")
        }
        return LLMRequest(system: budgetSystem, user: lines.joined(separator: "\n"), schema: budgetSchema, maxTokens: 4000, effort: "medium")
    }

    static func parseBudgets(_ text: String) -> [ProposedBudget]? {
        guard let dict = jsonObject(in: text) as? [String: Any], let list = dict["budgets"] as? [[String: Any]] else { return nil }
        var seen = Set<String>()
        var result: [ProposedBudget] = []
        for row in list {
            let name = (row["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !seen.contains(name.lowercased()) else { continue }
            let amountText: String
            if let s = row["monthly_amount"] as? String { amountText = s }
            else if let n = row["monthly_amount"] as? NSNumber { amountText = n.stringValue }
            else { amountText = "0" }
            let cents = abs(AmountParser.parse(amountText)?.cents ?? 0)
            let categories = (row["categories"] as? [String] ?? []).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            seen.insert(name.lowercased())
            result.append(ProposedBudget(name: name, monthlyCents: cents, categories: categories))
        }
        return result.isEmpty ? nil : result
    }

    // MARK: Plan

    struct PlannedPayment: Equatable {
        let transaction: Transaction
        /// Lowercased name of the proposed budget, or nil if no budget fits.
        let budgetKey: String?
    }

    struct Plan: Equatable {
        var budgets: [ProposedBudget]
        let payments: [PlannedPayment]
        let summary: SpendingSummary
        /// Income, transfers and refunds: not imported.
        let skippedNotSpending: Int
        /// Already in Tally (same day and amount), or repeated across files.
        let skippedDuplicates: Int

        func payments(for budget: ProposedBudget) -> [PlannedPayment] {
            payments.filter { $0.budgetKey == budget.id }
        }

        var unmatched: [PlannedPayment] { payments.filter { $0.budgetKey == nil } }
    }

    /// Matches each spending transaction to a proposed budget by category and
    /// drops duplicates (within the files, and against payments already in
    /// Tally on the same day for the same amount).
    static func plan(
        transactions: [Transaction],
        budgets: [ProposedBudget],
        existing: [(date: Date, cents: Int)],
        calendar: Calendar = .current
    ) -> Plan {
        func dayKey(_ date: Date) -> String { DataExport.dayString(date, calendar: calendar) }

        var categoryToBudget: [String: String] = [:]
        for budget in budgets {
            for category in budget.categories where categoryToBudget[category.lowercased()] == nil {
                categoryToBudget[category.lowercased()] = budget.id
            }
        }

        let existingKeys = Set(existing.map { "\(dayKey($0.date))|\($0.cents)" })
        var seen = Set<String>()
        var planned: [PlannedPayment] = []
        var notSpending = 0
        var duplicates = 0

        for t in transactions {
            guard t.kind == .spend else { notSpending += 1; continue }
            let key = "\(dayKey(t.date))|\(t.cents)|\(t.description.lowercased())"
            if seen.contains(key) || existingKeys.contains("\(dayKey(t.date))|\(t.cents)") {
                duplicates += 1
                continue
            }
            seen.insert(key)
            let budgetKey = categoryToBudget[t.category.lowercased()]
                ?? budgets.first { $0.name.compare(t.category, options: .caseInsensitive) == .orderedSame }?.id
            planned.append(PlannedPayment(transaction: t, budgetKey: budgetKey))
        }

        return Plan(
            budgets: budgets,
            payments: planned,
            summary: summarize(transactions, calendar: calendar),
            skippedNotSpending: notSpending,
            skippedDuplicates: duplicates
        )
    }

    // MARK: Save

    struct Result: Equatable {
        let budgetsCreated: Int
        let budgetsReused: Int
        let paymentsImported: Int
        let unassignedImported: Int
    }

    /// Saves the reviewed plan.
    /// - `included`: ids of the budgets you kept. Budgets you switched off
    ///   aren't created, and their payments aren't imported.
    /// - `importUnmatched`: also import payments that fit no budget, as
    ///   Unassigned (they're not sent to the AI again automatically).
    /// An existing budget with the same name is reused, keeping its amount.
    @MainActor
    @discardableResult
    static func apply(_ plan: Plan, included: Set<String>, importUnmatched: Bool, now: Date = .now, in context: ModelContext) throws -> Result {
        let active = try BudgetService.activeBudgets(in: context)
        var budgetByKey: [String: Budget] = [:]
        var created = 0
        var reused = 0
        var order = (active.map(\.sortOrder).max() ?? -1) + 1

        for proposal in plan.budgets where included.contains(proposal.id) {
            if let match = active.first(where: { $0.name.compare(proposal.name, options: .caseInsensitive) == .orderedSame }) {
                budgetByKey[proposal.id] = match
                reused += 1
            } else {
                let budget = Budget(name: proposal.name, monthlyCents: proposal.monthlyCents, sortOrder: order, createdAt: now)
                order += 1
                context.insert(budget)
                budgetByKey[proposal.id] = budget
                created += 1
            }
        }

        var imported = 0
        var unassigned = 0
        for item in plan.payments {
            let budget = item.budgetKey.flatMap { budgetByKey[$0] }
            if budget == nil {
                // Either no budget fits, or you switched its budget off.
                guard item.budgetKey == nil, importUnmatched else { continue }
            }
            let t = item.transaction
            let payment = Payment(
                amountCents: t.cents,
                merchant: t.description,
                card: "",
                date: t.date,
                source: .statement,
                rawAmount: t.rawAmount,
                note: "Imported from \(t.fileName) · \(t.category)"
            )
            context.insert(payment)
            payment.budget = budget
            payment.assignment = budget == nil ? .unassigned : .imported
            payment.aiAttempted = true
            imported += 1
            if budget == nil { unassigned += 1 }
        }

        try context.save()
        return Result(budgetsCreated: created, budgetsReused: reused, paymentsImported: imported, unassignedImported: unassigned)
    }

    // MARK: Helpers

    /// The outermost JSON object or array in the text, ignoring code fences
    /// or prose around it.
    static func jsonObject(in text: String) -> Any? {
        let candidates: [(Character, Character)] = [("{", "}"), ("[", "]")]
        for (open, close) in candidates {
            guard let start = text.firstIndex(of: open), let end = text.lastIndex(of: close), start < end else { continue }
            if let data = String(text[start...end]).data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) {
                return object
            }
        }
        return nil
    }
}

/// Runs an import step by step for the import screen.
@MainActor
final class StatementImporter: ObservableObject {
    enum Stage: Equatable {
        case idle
        case reading(part: Int, of: Int, found: Int)
        case proposing
        case review
        case done(StatementImport.Result)
        case failed(String)
    }

    @Published var stage: Stage = .idle
    @Published var plan: StatementImport.Plan?

    private let client: LLMJSONCompleting
    private let calendar: Calendar

    init(client: LLMJSONCompleting, calendar: Calendar = .current) {
        self.client = client
        self.calendar = calendar
    }

    /// Builds a client with a long timeout from your AI settings.
    static func fromSettings() -> StatementImporter? {
        let config = AIConfig.load()
        guard !config.model.trimmingCharacters(in: .whitespaces).isEmpty, URL(string: config.baseURL) != nil else { return nil }
        let key = KeychainStore.get(AIConfig.keychainAccount) ?? ""
        if AIPreset.named(config.presetID).needsKey && key.isEmpty { return nil }
        return StatementImporter(client: HTTPLLMClient(config: config, apiKey: key, timeout: 300))
    }

    /// Extracts transactions from the files, asks for budgets, and builds the
    /// plan for review.
    func run(files: [(name: String, text: String)], in context: ModelContext) async {
        do {
            var chunks: [StatementImport.Chunk] = []
            for file in files {
                chunks += try StatementImport.chunks(fileName: file.name, text: file.text)
            }
            var transactions: [StatementImport.Transaction] = []
            for (i, chunk) in chunks.enumerated() {
                stage = .reading(part: i + 1, of: chunks.count, found: transactions.count)
                transactions += try await extract(chunk, splitsLeft: 2)
            }
            guard transactions.contains(where: { $0.kind == .spend }) else {
                throw StatementImport.ImportError.nothingExtracted
            }

            stage = .proposing
            let existingBudgets = try BudgetService.activeBudgets(in: context)
            let summary = StatementImport.summarize(transactions, calendar: calendar)
            let request = StatementImport.budgetRequest(summary, existingBudgetNames: existingBudgets.map(\.name), calendar: calendar)
            let reply = try await client.completeJSON(request)
            guard let budgets = StatementImport.parseBudgets(reply) else {
                throw LLMError.emptyResponse
            }

            let existing = try context.fetch(FetchDescriptor<Payment>()).map { (date: $0.date, cents: $0.amountCents) }
            plan = StatementImport.plan(transactions: transactions, budgets: budgets, existing: existing, calendar: calendar)
            stage = .review
        } catch {
            stage = .failed(error.localizedDescription)
        }
    }

    /// One part. If the answer is cut off or unreadable, the part is split in
    /// half and retried (up to twice).
    private func extract(_ chunk: StatementImport.Chunk, splitsLeft: Int) async throws -> [StatementImport.Transaction] {
        do {
            let reply = try await client.completeJSON(StatementImport.extractionRequest(chunk))
            if let rows = StatementImport.parseExtraction(reply, fileName: chunk.fileName, calendar: calendar) {
                return rows
            }
            throw LLMError.emptyResponse
        } catch let error as LLMError where (error == .truncated || error == .emptyResponse) && splitsLeft > 0 && chunk.rows.count > 1 {
            let mid = chunk.rows.count / 2
            let first = StatementImport.Chunk(fileName: chunk.fileName, header: chunk.header, rows: Array(chunk.rows[..<mid]), index: chunk.index, count: chunk.count)
            let second = StatementImport.Chunk(fileName: chunk.fileName, header: chunk.header, rows: Array(chunk.rows[mid...]), index: chunk.index, count: chunk.count)
            return try await extract(first, splitsLeft: splitsLeft - 1) + extract(second, splitsLeft: splitsLeft - 1)
        }
    }

    func apply(included: Set<String>, importUnmatched: Bool, in context: ModelContext) {
        guard let plan else { return }
        do {
            let result = try StatementImport.apply(plan, included: included, importUnmatched: importUnmatched, in: context)
            stage = .done(result)
        } catch {
            stage = .failed(error.localizedDescription)
        }
    }
}
