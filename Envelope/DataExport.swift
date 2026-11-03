import Foundation
import SwiftData

/// Exports everything in one JSON file meant to be read by people and LLMs.
/// - Money is an exact decimal string in rand ("24000.00"), never a float.
/// - Derived values (monthly contribution, months left…) are included, so a
///   reader doesn't have to recompute them.
/// - An "about" block explains every section and field.
@MainActor
enum DataExport {
    static let schemaVersion = 1

    static func makeJSON(context: ModelContext, now: Date = .now, calendar: Calendar = .current) throws -> Data {
        let document = try buildDocument(context: context, now: now, calendar: calendar)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return try encoder.encode(document)
    }

    /// Writes the export to a temporary file and returns its URL for sharing.
    static func writeFile(context: ModelContext, now: Date = .now) throws -> URL {
        let data = try makeJSON(context: context, now: now)
        let name = "envelope-export-\(dayString(now, calendar: .current)).json"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        return url
    }

    // MARK: - Document

    struct Document: Encodable {
        let about: [String: String]
        let app: String
        let schemaVersion: Int
        let exportedAt: String
        let currency: String
        let savings: SavingsDTO
        let belongings: [BelongingDTO]
        let paymentsDebugLog: [PaymentDTO]
    }

    struct SavingsDTO: Encodable {
        let totalZar: String
        let setAsideForReplacementsZar: String
        let trueSavingsZar: String
        let monthlySetAsideZar: String
        let totalBalanceUpdatedAt: String?
    }

    struct BelongingDTO: Encodable {
        let name: String
        let category: String
        let status: String
        let previousLifespanMonths: Int?
        let fundBalanceZar: String
        let current: CurrentDTO?
        let ownershipHistory: [OwnershipDTO]
        let fundLedger: [FundEntryDTO]
    }

    struct CurrentDTO: Encodable {
        let purchasedOn: String
        let pricePaidZar: String
        let replacementTargetZar: String
        let lifespanMonths: Int
        let lifespanSource: String
        let expectedReplacementDate: String
        let monthsOwnedSoFar: Int
        let monthsOfContributionsLeft: Int
        let monthlyContributionZar: String
        let shortfallZar: String
        let planStatus: String
        let pastExpectedLife: Bool
    }

    struct OwnershipDTO: Encodable {
        let purchasedOn: String
        let pricePaidZar: String
        let retiredOn: String?
        let retiredReason: String?
        let lastedMonths: Int?
        let customLifespanMonths: Int?
    }

    struct FundEntryDTO: Encodable {
        let date: String
        let kind: String
        let amountZar: String
        let month: String?
        let note: String?
    }

    struct PaymentDTO: Encodable {
        let receivedAt: String
        let source: String
        let rawAmount: String
        let amountZar: String?
        let currency: String?
        let merchant: String
        let card: String
        let possibleDuplicate: Bool
    }

    static let about: [String: String] = [
        "purpose": "Export from Envelope, a personal budgeting app for an iPhone user in South Africa. All data was entered on the device. Nothing comes from a bank.",
        "money": "All *_zar fields are exact decimal strings in South African rand (ZAR), e.g. \"24000.00\". Negative means money out.",
        "dates": "Fields named *_on and *_date are local calendar dates (YYYY-MM-DD). *_at fields are ISO 8601 timestamps.",
        "savings": "total_zar is the user's savings balance as last entered by hand. set_aside_for_replacements_zar is the sum of all belonging funds. true_savings_zar = total_zar - set_aside_for_replacements_zar, the money not earmarked for anything. monthly_set_aside_zar is what the user should move into savings this month for replacements.",
        "belongings": "Things the user owns and plans to replace. The user saves monthly into a fund per belonging so the replacement is paid for when it wears out.",
        "belongings.current": "The unit owned now. lifespan_source: custom = user's estimate, previous = how long the previous unit actually lasted, typical = built-in rough category average. monthly_contribution_zar = (replacement_target_zar - fund balance) / months_of_contributions_left, rounded up to the cent. plan_status: saving | funded | due (expected date reached but fund short).",
        "belongings.ownership_history": "Every unit owned, newest first. lasted_months is filled in once the unit was replaced or retired.",
        "belongings.fund_ledger": "Movements in or out of the fund, newest first. kind: opening (already saved when added), contribution (monthly), spent (paid for the replacement), released (leftover moved to true savings), adjustment (manual correction).",
        "status": "active = still owned. retired = got rid of it without a replacement.",
        "payments_debug_log": "Raw card payments received from the iOS Shortcuts Transaction automation during testing. Not yet linked to budgets.",
    ]

    private static func buildDocument(context: ModelContext, now: Date, calendar: Calendar) throws -> Document {
        let belongings = try context.fetch(FetchDescriptor<Belonging>(sortBy: [SortDescriptor(\.name)]))
        let account = try context.fetch(FetchDescriptor<SavingsAccount>()).first
        let payments = try context.fetch(FetchDescriptor<DebugPayment>(sortBy: [SortDescriptor(\.receivedAt, order: .reverse)]))

        let active = belongings.filter { !$0.archived }
        let setAside = belongings.reduce(0) { $0 + $1.fundBalanceCents }
        let monthly = active.compactMap { $0.plan(today: now, calendar: calendar)?.monthlyCents }.reduce(0, +)
        let total = account?.balanceCents ?? 0

        let savings = SavingsDTO(
            totalZar: Money.plain(cents: total),
            setAsideForReplacementsZar: Money.plain(cents: setAside),
            trueSavingsZar: Money.plain(cents: SavingsSplit.trueSavings(totalCents: total, setAsideCents: setAside)),
            monthlySetAsideZar: Money.plain(cents: monthly),
            totalBalanceUpdatedAt: account.map { timestamp($0.updatedAt) }
        )

        return Document(
            about: about,
            app: "Envelope",
            schemaVersion: schemaVersion,
            exportedAt: timestamp(now),
            currency: "ZAR",
            savings: savings,
            belongings: belongings.map { belongingDTO($0, now: now, calendar: calendar) },
            paymentsDebugLog: payments.map(paymentDTO)
        )
    }

    private static func belongingDTO(_ b: Belonging, now: Date, calendar: Calendar) -> BelongingDTO {
        var current: CurrentDTO?
        if let ownership = b.currentOwnership, let plan = b.plan(today: now, calendar: calendar) {
            current = CurrentDTO(
                purchasedOn: dayString(ownership.purchasedOn, calendar: calendar),
                pricePaidZar: Money.plain(cents: ownership.priceCents),
                replacementTargetZar: Money.plain(cents: plan.targetCents),
                lifespanMonths: plan.lifespan.months,
                lifespanSource: plan.lifespan.source.rawValue,
                expectedReplacementDate: dayString(plan.expectedReplacementDate, calendar: calendar),
                monthsOwnedSoFar: max(0, calendar.dateComponents([.month], from: ownership.purchasedOn, to: now).month ?? 0),
                monthsOfContributionsLeft: plan.remainingMonths,
                monthlyContributionZar: Money.plain(cents: plan.monthlyCents),
                shortfallZar: Money.plain(cents: plan.shortfallCents),
                planStatus: statusName(plan.status),
                pastExpectedLife: plan.isPastExpectedLife
            )
        }

        let history = b.sortedOwnerships.map { o in
            OwnershipDTO(
                purchasedOn: dayString(o.purchasedOn, calendar: calendar),
                pricePaidZar: Money.plain(cents: o.priceCents),
                retiredOn: o.retiredOn.map { dayString($0, calendar: calendar) },
                retiredReason: o.retiredReason,
                lastedMonths: o.retiredOn.map {
                    ReplacementPlanner.actualLifespanMonths(purchasedOn: o.purchasedOn, retiredOn: $0, calendar: calendar)
                },
                customLifespanMonths: o.customLifespanMonths
            )
        }

        let ledger = b.sortedFundEntries.map { e in
            FundEntryDTO(
                date: dayString(e.date, calendar: calendar),
                kind: e.kind.rawValue,
                amountZar: Money.plain(cents: e.cents),
                month: e.monthKey,
                note: e.note.isEmpty ? nil : e.note
            )
        }

        return BelongingDTO(
            name: b.name,
            category: b.category.rawValue,
            status: b.archived ? "retired" : "active",
            previousLifespanMonths: b.previousLifespanMonths,
            fundBalanceZar: Money.plain(cents: b.fundBalanceCents),
            current: current,
            ownershipHistory: history,
            fundLedger: ledger
        )
    }

    private static func paymentDTO(_ p: DebugPayment) -> PaymentDTO {
        PaymentDTO(
            receivedAt: timestamp(p.receivedAt),
            source: p.source,
            rawAmount: p.rawAmount,
            amountZar: p.amountCents.map { Money.plain(cents: $0) },
            currency: p.currencyCode,
            merchant: p.merchant,
            card: p.card,
            possibleDuplicate: p.possibleDuplicate
        )
    }

    private static func statusName(_ status: ReplacementPlan.Status) -> String {
        switch status {
        case .saving: "saving"
        case .funded: "funded"
        case .due: "due"
        }
    }

    private static func timestamp(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .current
        return f.string(from: date)
    }

    static func dayString(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        func pad(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }
        return "\(c.year ?? 0)-\(pad(c.month ?? 0))-\(pad(c.day ?? 0))"
    }
}
