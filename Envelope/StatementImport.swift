import Foundation
import PDFKit
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
    static let pagesPerChunk = 3
    static let maxPages = 200

    /// How PDFs reach the model.
    enum PDFMode: Equatable {
        /// The pages themselves (Claude reads PDFs, including scanned ones).
        case native
        /// Text extracted on the phone (any provider; needs a text-based PDF).
        case text
    }

    /// A file picked for import.
    enum File {
        case csv(name: String, text: String)
        case pdf(name: String, document: PDFDocument)

        var name: String {
            switch self {
            case .csv(let name, _), .pdf(let name, _): name
            }
        }
    }

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

    /// One part of a file sent in one request. For CSV, `rows` are lines. For
    /// a PDF, each row is one page: its extracted text, or (native mode) just a
    /// label, with `pages` holding the page indexes to attach.
    struct Chunk: Equatable {
        let fileName: String
        let header: String
        let rows: [String]
        let index: Int
        let count: Int
        var pdf: PDFDocument? = nil
        var pages: [Int] = []

        var text: String { ([header] + rows).joined(separator: "\n") }

        /// The first or second half, for retrying an answer that was too long.
        func half(_ first: Bool) -> Chunk {
            let mid = rows.count / 2
            let range = first ? 0..<mid : mid..<rows.count
            var part = Chunk(fileName: fileName, header: header, rows: Array(rows[range]), index: index, count: count)
            part.pdf = pdf
            part.pages = pages.count == rows.count ? Array(pages[range]) : []
            return part
        }
    }

    enum ImportError: LocalizedError, Equatable {
        case empty
        case tooLarge(Int)
        case nothingExtracted
        case tooManyPages(Int)
        case locked(String)
        case scannedPDF(String)
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .empty: "The file is empty."
            case .tooLarge(let rows): "The file has \(rows) rows. Import at most \(StatementImport.maxRows) at a time, e.g. one year per file."
            case .nothingExtracted: "The AI couldn't find any transactions. Check the file is a statement or transaction history, not a summary."
            case .tooManyPages(let pages): "The PDF has \(pages) pages. Import at most \(StatementImport.maxPages) pages at a time."
            case .locked(let name): "\(name) is password protected. Enter its password to import it."
            case .scannedPDF(let name): "\(name) has no readable text (it may be a scan). Use Claude as your AI provider, which can read scanned pages, or download a CSV instead."
            case .unreadable(let name): "Couldn't open \(name) as a PDF."
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

    // MARK: PDF

    /// Splits a PDF into parts of `pagesPerChunk` pages. The document must
    /// already be unlocked if it has a password.
    static func pdfChunks(fileName: String, document: PDFDocument, mode: PDFMode, pagesPerChunk: Int = pagesPerChunk) throws -> [Chunk] {
        guard !document.isLocked else { throw ImportError.locked(fileName) }
        let pageCount = document.pageCount
        guard pageCount > 0 else { throw ImportError.empty }
        guard pageCount <= maxPages else { throw ImportError.tooManyPages(pageCount) }

        let rows: [String]
        let header: String
        switch mode {
        case .native:
            header = "The pages are attached as a PDF."
            rows = (0..<pageCount).map { "(page \($0 + 1) of \(pageCount))" }
        case .text:
            let texts = (0..<pageCount).map { (document.page(at: $0)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
            guard texts.contains(where: { !$0.isEmpty }) else { throw ImportError.scannedPDF(fileName) }
            header = "Text extracted from a PDF statement (columns may be out of line):"
            rows = texts.enumerated().map { "--- Page \($0.offset + 1) of \(pageCount) ---\n\($0.element)" }
        }

        let size = max(1, pagesPerChunk)
        let starts = Array(stride(from: 0, to: pageCount, by: size))
        return starts.enumerated().map { (i: Int, start: Int) -> Chunk in
            let range = start..<min(start + size, pageCount)
            var chunk = Chunk(fileName: fileName, header: header, rows: Array(rows[range]), index: i, count: starts.count)
            if mode == .native {
                chunk.pdf = document
                chunk.pages = Array(range)
            }
            return chunk
        }
    }

    /// A new, unencrypted PDF with just the chunk's pages. Built by copying
    /// pages, so a password-protected statement unlocked on the phone is sent
    /// without its password.
    static func pdfData(for chunk: Chunk) -> Data? {
        guard let source = chunk.pdf, !chunk.pages.isEmpty else { return nil }
        let part = PDFDocument()
        for (n, index) in chunk.pages.enumerated() {
            guard let page = source.page(at: index)?.copy() as? PDFPage else { continue }
            part.insert(page, at: n)
        }
        guard part.pageCount > 0 else { return nil }
        return part.dataRepresentation()
    }

    static func chunks(for file: File, pdfMode: PDFMode) throws -> [Chunk] {
        switch file {
        case let .csv(name, text):
            return try chunks(fileName: name, text: text)
        case let .pdf(name, document):
            return try pdfChunks(fileName: name, document: document, mode: pdfMode)
        }
    }

    // MARK: Extraction

    static let extractionSystem = """
    You extract transactions from a South African bank statement (a CSV export or a PDF statement) for Tally, a personal budgeting app. Amounts are in rand.
    Return every real transaction in the part you are given, in order, each exactly once. Skip headers, opening/closing balance lines, running balance columns, summaries, fee and interest tables, and adverts.
    In a PDF, use the debit/credit columns or signs to tell money out from money in. A transaction that continues onto the next page is only listed once.
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
        if chunk.pdf != nil {
            let pages = chunk.pages.map { String($0 + 1) }.joined(separator: ", ")
            let user = """
            Statement file: \(chunk.fileName)
            The attached PDF holds page(s) \(pages) of the statement. Extract the transactions on these pages.
            """
            return LLMRequest(system: extractionSystem, user: user, schema: extractionSchema, maxTokens: 16000, effort: "low", pdfData: pdfData(for: chunk))
        }
        let intro = chunk.header.hasPrefix("Text extracted from a PDF")
            ? "Part \(chunk.index + 1) of \(chunk.count):"
            : "Part \(chunk.index + 1) of \(chunk.count) (the first line is the CSV header):"
        let user = """
        Statement file: \(chunk.fileName)
        \(intro)

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
        // Months covered, from the actual span (a statement from 15 Aug to
        // 14 Oct is 2 months, not the 3 calendar months it touches).
        let days = calendar.dateComponents([.day], from: first, to: last).day ?? 0
        let months = max(1, Int((Double(days + 1) / 30.44).rounded()))
        let grouped = Dictionary(grouping: spend) { $0.category }
        let categories = grouped.map { category, items -> CategorySummary in
            let total = items.reduce(0) { $0 + $1.cents }
            let merchantCounts = Dictionary(grouping: items) { $0.description }.mapValues(\.count)
            let top = merchantCounts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(5).map(\.key)
            return CategorySummary(category: category, totalCents: total, count: items.count,
                                   monthlyAverageCents: (total + months / 2) / months, topMerchants: top)
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
        // The JSON is small; the headroom is for the model's thinking.
        return LLMRequest(system: budgetSystem, user: lines.joined(separator: "\n"), schema: budgetSchema, maxTokens: 16000, effort: "medium")
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

    /// A payment already in Tally, as the matcher sees it.
    struct ExistingPayment: Equatable {
        let id: UUID
        let date: Date
        let cents: Int
        let merchant: String
        let hasBudget: Bool
        /// Already on an earlier statement (imported from or matched to one).
        /// Such payments only match by the strict rule (same amount and shop),
        /// so a different purchase at the same shop next month isn't merged in.
        var fromStatement: Bool = false
    }

    struct PlannedPayment: Equatable {
        let transaction: Transaction
        /// Lowercased name of the proposed budget, or nil if no budget fits.
        let budgetKey: String?
    }

    /// A statement row that is the same payment as one already in Tally
    /// (logged by Apple Pay, typed in, or from an earlier import). It's merged
    /// into that payment instead of being added again.
    struct PlannedMerge: Equatable, Identifiable {
        enum Kind: Equatable {
            /// Same amount, within a few days: merged automatically.
            case exact
            /// Same shop on about the same day but a different amount (fuel
            /// pre-authorisation, tip, or an amount Apple Pay couldn't read).
            /// Shown for you to confirm (merged by default); merging takes the
            /// statement's amount.
            case possible
            /// Same amount on about the same day but clearly different shop
            /// names, e.g. a payment on your other card. Shown for you to
            /// confirm, kept separate by default.
            case uncertain
        }

        let transaction: Transaction
        let existing: ExistingPayment
        let kind: Kind
        let budgetKey: String?

        var id: String { existing.id.uuidString }
        /// The existing payment has no budget and the statement suggests one.
        var fillsInBudget: Bool { !existing.hasBudget && budgetKey != nil }
        /// You decide on the review screen whether this is the same payment.
        var needsReview: Bool { kind != .exact }
        /// Merged unless you switch it off.
        var mergedByDefault: Bool { kind != .uncertain }
    }

    struct Plan: Equatable {
        var budgets: [ProposedBudget]
        /// New payments to add.
        let payments: [PlannedPayment]
        /// Rows that are payments you already have.
        let merges: [PlannedMerge]
        let summary: SpendingSummary
        /// Income, transfers and refunds: not imported.
        let skippedNotSpending: Int
        /// The same row repeated in overlapping files (e.g. a CSV and a PDF of
        /// the same month).
        let skippedDuplicates: Int

        func payments(for budget: ProposedBudget) -> [PlannedPayment] {
            payments.filter { $0.budgetKey == budget.id }
        }

        var unmatched: [PlannedPayment] { payments.filter { $0.budgetKey == nil } }
        var exactMerges: [PlannedMerge] { merges.filter { $0.kind == .exact } }
        /// Matches for you to confirm on the review screen.
        var possibleMerges: [PlannedMerge] { merges.filter(\.needsReview) }
    }

    /// Builds the import plan:
    /// 1. Keeps spending only, and drops rows repeated across overlapping files
    ///    (a row counts as many times as it appears in any one file, so two
    ///    identical coffees on one day in one statement are both kept).
    /// 2. Matches rows to payments already in Tally, one to one (see
    ///    `matchExisting`). Matched rows are merged, never added again, so
    ///    importing the same statement twice, or a statement covering months
    ///    Apple Pay already logged, creates no duplicates.
    /// 3. Gives each remaining row a proposed budget by its category.
    static func plan(
        transactions: [Transaction],
        budgets: [ProposedBudget],
        existing: [ExistingPayment],
        calendar: Calendar = .current
    ) -> Plan {
        func dayKey(_ date: Date) -> String { DataExport.dayString(date, calendar: calendar) }

        var categoryToBudget: [String: String] = [:]
        for budget in budgets {
            for category in budget.categories where categoryToBudget[category.lowercased()] == nil {
                categoryToBudget[category.lowercased()] = budget.id
            }
        }
        func budgetKey(for t: Transaction) -> String? {
            categoryToBudget[t.category.lowercased()]
                ?? budgets.first { $0.name.compare(t.category, options: .caseInsensitive) == .orderedSame }?.id
        }

        // Spending only, grouped by file in the order you picked them.
        var notSpending = 0
        var fileOrder: [String] = []
        var byFile: [String: [Transaction]] = [:]
        for t in transactions {
            guard t.kind == .spend else { notSpending += 1; continue }
            if byFile[t.fileName] == nil { fileOrder.append(t.fileName) }
            byFile[t.fileName, default: []].append(t)
        }

        // Overlapping files (a CSV and a PDF of the same month, or two
        // exports that overlap): each file's rows are matched against the
        // rows already kept from earlier files with the same rules as for
        // payments in Tally, and exact matches are dropped. Rows within one
        // file are never compared, so two identical coffees are both kept.
        // Only the strict rules apply here (same amount and shop within 3
        // days, or same amount on the same day when a name is cryptic), and
        // only where the files' dates overlap, so two different accounts'
        // purchases of the same amount on nearby days are both kept.
        var rows: [Transaction] = []
        var duplicates = 0
        for name in fileOrder {
            let fileRows = byFile[name] ?? []
            guard let fileStart = fileRows.map(\.date).min(), let fileEnd = fileRows.map(\.date).max(),
                  let keptStart = rows.map(\.date).min(), let keptEnd = rows.map(\.date).max(),
                  fileStart <= keptEnd.addingTimeInterval(3 * 86_400),
                  fileEnd >= keptStart.addingTimeInterval(-3 * 86_400)
            else { rows += fileRows; continue }
            let kept = rows.map { ExistingPayment(id: UUID(), date: $0.date, cents: $0.cents, merchant: $0.description, hasBudget: false) }
            let matches = matchExisting(fileRows, kept, strictOnly: true, calendar: calendar)
            for (i, t) in fileRows.enumerated() {
                if let match = matches[i], match.1 == .exact {
                    duplicates += 1
                } else {
                    rows.append(t)
                }
            }
        }

        let matches = matchExisting(rows, existing, calendar: calendar)
        var planned: [PlannedPayment] = []
        var merges: [PlannedMerge] = []
        for (i, t) in rows.enumerated() {
            if let match = matches[i] {
                merges.append(PlannedMerge(transaction: t, existing: existing[match.0], kind: match.1, budgetKey: budgetKey(for: t)))
            } else {
                planned.append(PlannedPayment(transaction: t, budgetKey: budgetKey(for: t)))
            }
        }

        return Plan(
            budgets: budgets,
            payments: planned,
            merges: merges,
            summary: summarize(transactions, calendar: calendar),
            skippedNotSpending: notSpending,
            skippedDuplicates: duplicates
        )
    }

    /// Pairs statement rows with existing payments, each used at most once.
    /// Bank statements often show the date the bank processed a payment, 1–3
    /// days after the tap, so dates are compared with some slack:
    /// - A: same amount, same shop, within 3 days (closest dates first).
    /// - B: same amount, within 1 day, when a description is too cryptic to
    ///   compare (e.g. "POS 4567*1234 CPT") or the names share a word.
    /// - C (possible): same shop within 2 days but a different amount, within
    ///   half to double, or the existing payment's amount was unreadable.
    /// - D (uncertain): same amount within 1 day, clearly different names.
    /// Payments already on an earlier statement only match by A or B (never
    /// by a changed amount or a different name).
    /// Returns statement row index → (existing payment index, kind).
    /// `strictOnly` (used between files of one import): only A, and B on the
    /// same day.
    static func matchExisting(_ rows: [Transaction], _ existing: [ExistingPayment], strictOnly: Bool = false, calendar: Calendar = .current) -> [Int: (Int, PlannedMerge.Kind)] {
        guard !rows.isEmpty, !existing.isEmpty else { return [:] }

        func dayNumber(_ date: Date) -> Int {
            let comps = calendar.dateComponents([.year, .month, .day], from: date)
            var utc = Calendar(identifier: .gregorian)
            utc.timeZone = TimeZone(identifier: "UTC")!
            let day = utc.date(from: DateComponents(year: comps.year, month: comps.month, day: comps.day)) ?? date
            return Int((day.timeIntervalSinceReferenceDate / 86_400).rounded())
        }
        let rowDays = rows.map { dayNumber($0.date) }
        let existingDays = existing.map { dayNumber($0.date) }
        let rowTokens = rows.map { merchantTokens($0.description) }
        let existingTokens = existing.map { merchantTokens($0.merchant) }

        var byDay: [Int: [Int]] = [:]
        for (e, day) in existingDays.enumerated() { byDay[day, default: []].append(e) }
        func nearby(_ row: Int, within days: Int) -> [Int] {
            (-days...days).flatMap { byDay[rowDays[row] + $0] ?? [] }
        }

        var rowTaken = [Bool](repeating: false, count: rows.count)
        var existingTaken = [Bool](repeating: false, count: existing.count)
        var result: [Int: (Int, PlannedMerge.Kind)] = [:]

        struct Candidate {
            let row: Int
            let existing: Int
            let days: Int
            let similarity: Double
        }
        func assign(_ candidates: [Candidate], as kind: PlannedMerge.Kind) {
            let ordered = candidates.sorted {
                ($0.days, -$0.similarity, $0.row, $0.existing) < ($1.days, -$1.similarity, $1.row, $1.existing)
            }
            for c in ordered where !rowTaken[c.row] && !existingTaken[c.existing] {
                rowTaken[c.row] = true
                existingTaken[c.existing] = true
                result[c.row] = (c.existing, kind)
            }
        }
        func candidates(within days: Int, _ accept: (Int, Int, Double) -> Bool) -> [Candidate] {
            var list: [Candidate] = []
            for r in rows.indices where !rowTaken[r] {
                for e in nearby(r, within: days) where !existingTaken[e] {
                    let similarity = merchantSimilarity(rowTokens[r], existingTokens[e])
                    if accept(r, e, similarity) {
                        list.append(Candidate(row: r, existing: e, days: abs(rowDays[r] - existingDays[e]), similarity: similarity))
                    }
                }
            }
            return list
        }

        // A name is comparable when it has a real word (4+ letters); short
        // codes like "CPT" or "JHB" on their own don't count.
        func informative(_ tokens: Set<String>) -> Bool { tokens.contains { $0.count >= 4 } }
        let rowNamed = rowTokens.map(informative)
        let existingNamed = existingTokens.map(informative)
        func named(_ r: Int, _ e: Int) -> Bool { rowNamed[r] && existingNamed[e] }

        // A: same amount, same shop, within 3 days.
        assign(candidates(within: 3) { r, e, sim in rows[r].cents == existing[e].cents && sim >= 0.5 }, as: .exact)
        // B: same amount within 1 day where a name is too cryptic to compare.
        // Also for payments from an earlier statement: the 1-day window keeps
        // next month's purchase out, and re-imports must still merge.
        assign(candidates(within: strictOnly ? 0 : 1) { r, e, sim in
            rows[r].cents == existing[e].cents && (sim > 0 || !named(r, e))
        }, as: .exact)
        guard !strictOnly else { return result }
        // C: same shop, different amount (pre-auth, tip, unreadable amount).
        assign(candidates(within: 2) { r, e, sim in
            guard sim >= 0.5, !existing[e].fromStatement else { return false }
            let a = Double(rows[r].cents), b = Double(existing[e].cents)
            return b == 0 || (a >= b * 0.5 && a <= b * 2)
        }, as: .possible)
        // D: same amount within 1 day but clearly different names (another
        // card?): you decide, kept separate by default.
        assign(candidates(within: 1) { r, e, sim in
            rows[r].cents == existing[e].cents && !existing[e].fromStatement && sim == 0 && named(r, e)
        }, as: .uncertain)
        return result
    }

    static let merchantStopwords: Set<String> = [
        "pos", "purchase", "purch", "card", "debit", "credit", "payment", "the", "and", "pty", "ltd",
        "int", "online", "www", "com", "zaf", "rsa", "store", "shop", "tap", "pay", "apple",
    ]

    /// Words that identify a merchant: lowercased, 3+ letters, no card or
    /// reference numbers, no filler like "POS PURCHASE".
    static func merchantTokens(_ text: String) -> Set<String> {
        Set(text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 3 && !merchantStopwords.contains($0) && !$0.allSatisfy(\.isNumber) })
    }

    /// Share of the shorter name's words found in the other name (a word
    /// also matches if one is a prefix of the other, e.g. "woolworth").
    /// "KFC Wierda Park" vs "KFC" = 1.0; "Engen" vs "Spar" = 0.
    static func merchantSimilarity(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        let (small, large) = a.count <= b.count ? (a, b) : (b, a)
        let shared = small.filter { word in
            large.contains { other in
                word == other || (min(word.count, other.count) >= 4 && (word.hasPrefix(other) || other.hasPrefix(word)))
            }
        }
        return Double(shared.count) / Double(small.count)
    }

    static func merchantSimilarity(_ a: String, _ b: String) -> Double {
        merchantSimilarity(merchantTokens(a), merchantTokens(b))
    }

    // MARK: Save

    struct Result: Equatable {
        var budgetsCreated = 0
        var budgetsReused = 0
        /// New payments added.
        var paymentsImported = 0
        /// New payments added without a budget.
        var unassignedImported = 0
        /// Statement rows merged into payments you already had.
        var merged = 0
        /// Merged payments that had no budget and now have one.
        var budgetsFilledIn = 0
        /// Merged payments whose amount was corrected from the statement.
        var amountsUpdated = 0
    }

    /// Saves the reviewed plan.
    /// - `included`: ids of the budgets you kept. Budgets you switched off
    ///   aren't created, and their new payments aren't imported.
    /// - `importUnmatched`: also import payments that fit no budget, as
    ///   Unassigned (they're not sent to the AI again automatically).
    /// - `rejectedMerges`: matches you said are different payments; they're
    ///   imported as new payments instead (even if no budget fits).
    /// Merged rows never create a payment: the existing one is kept (with its
    /// budget and exact time), marked as confirmed by the statement, given a
    /// budget if it had none, and for a confirmed possible match, given the
    /// statement's amount.
    /// An existing budget with the same name is reused, keeping its amount.
    /// Budgets start from the month of their earliest imported payment, so
    /// past months add up in Month End.
    @MainActor
    @discardableResult
    static func apply(
        _ plan: Plan,
        included: Set<String>,
        importUnmatched: Bool,
        rejectedMerges: Set<String> = [],
        now: Date = .now,
        in context: ModelContext
    ) throws -> Result {
        let active = try BudgetService.activeBudgets(in: context)
        // Fix your start month before budgets are backdated (see UsageStart).
        _ = UsageStart.date(budgets: try context.fetch(FetchDescriptor<Budget>()), now: now)
        var budgetByKey: [String: Budget] = [:]
        var result = Result()
        var order = (active.map(\.sortOrder).max() ?? -1) + 1

        for proposal in plan.budgets where included.contains(proposal.id) {
            // Only rows that will really land in this budget.
            let dates = plan.payments(for: proposal).map(\.transaction.date)
                + plan.merges.filter { merge in
                    merge.budgetKey == proposal.id
                        && (merge.fillsInBudget || (merge.needsReview && rejectedMerges.contains(merge.id)))
                }.map(\.transaction.date)
            let start = dates.min().map { min(now, MonthMath.startOfMonth($0)) } ?? now
            if let match = active.first(where: { $0.name.compare(proposal.name, options: .caseInsensitive) == .orderedSame }) {
                budgetByKey[proposal.id] = match
                if match.createdAt > start { match.createdAt = start }
                result.budgetsReused += 1
            } else {
                let budget = Budget(name: proposal.name, monthlyCents: proposal.monthlyCents, sortOrder: order, createdAt: start)
                order += 1
                context.insert(budget)
                budgetByKey[proposal.id] = budget
                result.budgetsCreated += 1
            }
        }

        /// `force`: you said this row is a separate payment, so it's added even
        /// without a budget.
        func insertNew(_ t: Transaction, budgetKey: String?, force: Bool = false) {
            let budget = budgetKey.flatMap { budgetByKey[$0] }
            if budget == nil && !force {
                // Either no budget fits, or you switched its budget off.
                guard budgetKey == nil, importUnmatched else { return }
            }
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
            payment.statementMatched = true
            result.paymentsImported += 1
            if budget == nil { result.unassignedImported += 1 }
        }

        for item in plan.payments {
            insertNew(item.transaction, budgetKey: item.budgetKey)
        }

        let current = try context.fetch(FetchDescriptor<Payment>())
        let byID = Dictionary(current.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for merge in plan.merges {
            let t = merge.transaction
            if merge.needsReview && rejectedMerges.contains(merge.id) {
                insertNew(t, budgetKey: merge.budgetKey, force: true)
                continue
            }
            guard let payment = byID[merge.existing.id] else {
                // Deleted since the plan was made: add it as a new payment.
                insertNew(t, budgetKey: merge.budgetKey, force: true)
                continue
            }
            payment.statementMatched = true
            if merge.needsReview && payment.amountCents != t.cents {
                let was = payment.amountCents
                payment.amountCents = t.cents
                payment.needsReview = false
                let line = "Amount from bank statement: \(Money.format(cents: t.cents)) (was \(Money.format(cents: was)))."
                payment.note = payment.note.isEmpty ? line : payment.note + " " + line
                result.amountsUpdated += 1
            }
            if payment.budget == nil, let budget = merge.budgetKey.flatMap({ budgetByKey[$0] }) {
                payment.budget = budget
                payment.assignment = .imported
                result.budgetsFilledIn += 1
            }
            result.merged += 1
        }

        try context.save()
        return result
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
    let pdfMode: StatementImport.PDFMode

    init(client: LLMJSONCompleting, pdfMode: StatementImport.PDFMode = .native, calendar: Calendar = .current) {
        self.client = client
        self.pdfMode = pdfMode
        self.calendar = calendar
    }

    /// Builds a client with a long timeout from your AI settings.
    static func fromSettings() -> StatementImporter? {
        let config = AIConfig.load()
        // Always the cloud provider: Apple's on-device model is far too small
        // for whole statements (it can still sort your everyday payments).
        guard config.cloudIsConfigured else { return nil }
        let key = KeychainStore.get(AIConfig.keychainAccount) ?? ""
        if AIPreset.named(config.presetID).needsKey && key.isEmpty { return nil }
        // Claude reads PDFs directly; other providers get the PDF's text.
        let mode: StatementImport.PDFMode = config.style == .anthropic ? .native : .text
        return StatementImporter(client: HTTPLLMClient(config: config, apiKey: key, timeout: 600, retries: 3), pdfMode: mode)
    }

    /// Extracts transactions from the files, asks for budgets, and builds the
    /// plan for review.
    func run(files: [(name: String, text: String)], in context: ModelContext) async {
        await run(files: files.map { StatementImport.File.csv(name: $0.name, text: $0.text) }, in: context)
    }

    func run(files: [StatementImport.File], in context: ModelContext) async {
        do {
            var chunks: [StatementImport.Chunk] = []
            for file in files {
                chunks += try StatementImport.chunks(for: file, pdfMode: pdfMode)
            }
            var transactions: [StatementImport.Transaction] = []
            for (i, chunk) in chunks.enumerated() {
                try Task.checkCancellation()
                stage = .reading(part: i + 1, of: chunks.count, found: transactions.count)
                transactions += try await extract(chunk, splitsLeft: 2)
            }
            guard transactions.contains(where: { $0.kind == .spend }) else {
                throw StatementImport.ImportError.nothingExtracted
            }

            try Task.checkCancellation()
            stage = .proposing
            let existingBudgets = try BudgetService.activeBudgets(in: context)
            let summary = StatementImport.summarize(transactions, calendar: calendar)
            let request = StatementImport.budgetRequest(summary, existingBudgetNames: existingBudgets.map(\.name), calendar: calendar)
            let reply = try await client.completeJSON(request)
            guard let budgets = StatementImport.parseBudgets(reply) else {
                throw LLMError.emptyResponse
            }

            let existing = try context.fetch(FetchDescriptor<Payment>())
                .filter { $0.source != .test }
                .map {
                    StatementImport.ExistingPayment(
                        id: $0.id, date: $0.date, cents: $0.amountCents, merchant: $0.merchant,
                        hasBudget: $0.budget != nil, fromStatement: $0.statementMatched || $0.source == .statement
                    )
                }
            plan = StatementImport.plan(transactions: transactions, budgets: budgets, existing: existing, calendar: calendar)
            stage = .review
        } catch is CancellationError {
            stage = .idle
        } catch let error as URLError where error.code == .cancelled {
            stage = .idle
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
            let first = chunk.half(true)
            let second = chunk.half(false)
            return try await extract(first, splitsLeft: splitsLeft - 1) + extract(second, splitsLeft: splitsLeft - 1)
        }
    }

    func apply(included: Set<String>, importUnmatched: Bool, rejectedMerges: Set<String> = [], in context: ModelContext) {
        guard let plan else { return }
        do {
            let result = try StatementImport.apply(plan, included: included, importUnmatched: importUnmatched, rejectedMerges: rejectedMerges, in: context)
            stage = .done(result)
        } catch {
            stage = .failed(error.localizedDescription)
        }
    }
}
