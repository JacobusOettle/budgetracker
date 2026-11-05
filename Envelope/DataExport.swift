import Foundation
import SwiftData

/// Exports everything in one JSON file meant to be read by people and LLMs.
/// - Money is an exact decimal string in rand ("24000.00"), never a float.
/// - Derived values (monthly contribution, months left…) are included, so a
///   reader doesn't have to recompute them.
/// - An "about" block explains every section and field.
@MainActor
enum DataExport {
    static let schemaVersion = 2

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
        let name = "tally-export-\(dayString(now, calendar: .current)).json"
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
        let budgets: [BudgetDTO]
        let payments: [PaymentDTO]
        let monthCloses: [MonthCloseDTO]
        let belongings: [BelongingDTO]
        let spikeTestLog: [SpikePaymentDTO]
    }

    struct BudgetDTO: Encodable {
        let name: String
        let monthlyZar: String
        let spentThisMonthZar: String
        let leftThisMonthZar: String
        let createdOn: String
        let removedOn: String?
    }

    struct PaymentDTO: Encodable {
        let date: String
        let amountZar: String
        let merchant: String
        let budget: String?
        let card: String?
        let source: String
        let note: String?
        let needsReview: Bool
        let assignedBy: String
        let aiReason: String?
        let aiOriginalBudget: String?
        let statementMatched: Bool
    }

    struct MonthCloseDTO: Encodable {
        let month: String
        let closedOn: String
        let budgets: [MonthCloseLineDTO]
        let unassignedZar: String
        let totalLeftZar: String
        let toSaveZar: String
        let movedToSavingsZar: String
        let toReplacementFundsZar: String
    }

    struct MonthCloseLineDTO: Encodable {
        let name: String
        let monthlyZar: String
        let spentZar: String
        let leftZar: String
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

    struct SpikePaymentDTO: Encodable {
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
        "purpose": "Export from Tally, a personal budgeting app for an iPhone user in South Africa. The user arms a budget before paying with Apple Pay; the payment is then logged to it. No bank connection: payments come from Apple Pay via iOS Shortcuts or are entered by hand.",
        "money": "All *_zar fields are exact decimal strings in South African rand (ZAR), e.g. \"24000.00\". Negative means money out.",
        "dates": "Fields named *_on and *_date are local calendar dates (YYYY-MM-DD). *_at fields are ISO 8601 timestamps.",
        "savings": "total_zar is the user's savings balance as last entered by hand. set_aside_for_replacements_zar is the sum of all belonging funds. true_savings_zar = total_zar - set_aside_for_replacements_zar, the money not earmarked for anything. monthly_set_aside_zar is what the user should move into savings this month for replacements.",
        "budgets": "Monthly spending budgets. left_this_month_zar = monthly_zar - spent_this_month_zar (negative = over budget). removed_on is set if the user removed the budget; its payments are kept.",
        "payments": "Every card payment, newest first. budget null = Unassigned (not yet given a budget). source: shortcut = logged automatically from Apple Pay via the iOS Shortcuts Wallet automation, manual = typed in by the user (online purchases, missed payments), test = test payment, import = imported from a bank statement CSV. needs_review = the amount couldn't be read or wasn't in rand. assigned_by: armed = the user armed the budget before paying, manual = the user chose it, ai = an AI model chose it and the user hasn't checked it, aiConfirmed = AI choice confirmed by the user, imported = sorted by AI during a bank statement import the user reviewed, none = unassigned. ai_original_budget = the AI's wrong guess that the user corrected. statement_matched = the payment also appears on an imported bank statement.",
        "month_closes": "Months the user closed. For each budget: what was left. to_save_zar = max(0, total_left_zar - unassigned_zar), the suggested amount to move to savings. moved_to_savings_zar = what the user said they actually moved. to_replacement_funds_zar = the part of that set aside for belongings; the rest is true savings.",
        "belongings": "Things the user owns and plans to replace. The user saves monthly into a fund per belonging so the replacement is paid for when it wears out.",
        "belongings.current": "The unit owned now. lifespan_source: custom = user's estimate, previous = how long the previous unit actually lasted, typical = built-in rough category average. monthly_contribution_zar = (replacement_target_zar - fund balance) / months_of_contributions_left, rounded up to the cent. plan_status: saving | funded | due (expected date reached but fund short).",
        "belongings.ownership_history": "Every unit owned, newest first. lasted_months is filled in once the unit was replaced or retired.",
        "belongings.fund_ledger": "Movements in or out of the fund, newest first. kind: opening (already saved when added), contribution (monthly), spent (paid for the replacement), released (leftover moved to true savings), adjustment (manual correction).",
        "status": "active = still owned. retired = got rid of it without a replacement.",
        "spike_test_log": "Raw payments received while the Shortcuts automation was first being tested. Not linked to budgets; ignore for spending analysis.",
    ]

    private static func buildDocument(context: ModelContext, now: Date, calendar: Calendar) throws -> Document {
        let belongings = try context.fetch(FetchDescriptor<Belonging>(sortBy: [SortDescriptor(\.name)]))
        let account = try context.fetch(FetchDescriptor<SavingsAccount>()).first
        let spikeLog = try context.fetch(FetchDescriptor<DebugPayment>(sortBy: [SortDescriptor(\.receivedAt, order: .reverse)]))
        let budgets = try context.fetch(FetchDescriptor<Budget>(sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.name)]))
        let payments = try context.fetch(FetchDescriptor<Payment>(sortBy: [SortDescriptor(\.date, order: .reverse)]))
        let closes = try context.fetch(FetchDescriptor<MonthClose>(sortBy: [SortDescriptor(\.monthKey, order: .reverse)]))
        let monthInterval = MonthMath.interval(containing: now, calendar: calendar)

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
            app: "Tally",
            schemaVersion: schemaVersion,
            exportedAt: timestamp(now),
            currency: "ZAR",
            savings: savings,
            budgets: budgets.map { b in
                let spent = b.spentCents(in: monthInterval)
                return BudgetDTO(
                    name: b.name,
                    monthlyZar: Money.plain(cents: b.monthlyCents),
                    spentThisMonthZar: Money.plain(cents: spent),
                    leftThisMonthZar: Money.plain(cents: b.monthlyCents - spent),
                    createdOn: dayString(b.createdAt, calendar: calendar),
                    removedOn: b.archivedAt.map { dayString($0, calendar: calendar) }
                )
            },
            payments: payments.map { p in
                PaymentDTO(
                    date: timestamp(p.date),
                    amountZar: Money.plain(cents: p.amountCents),
                    merchant: p.merchant,
                    budget: p.budget?.name,
                    card: p.card.isEmpty ? nil : p.card,
                    source: p.source.rawValue,
                    note: p.note.isEmpty ? nil : p.note,
                    needsReview: p.needsReview,
                    assignedBy: p.assignment == .unassigned ? "none" : p.assignment.rawValue,
                    aiReason: p.aiReason.isEmpty ? nil : p.aiReason,
                    aiOriginalBudget: p.aiOriginalBudgetName.isEmpty ? nil : p.aiOriginalBudgetName,
                    statementMatched: p.statementMatched
                )
            },
            monthCloses: closes.map { c in
                MonthCloseDTO(
                    month: c.monthKey,
                    closedOn: dayString(c.closedAt, calendar: calendar),
                    budgets: c.lines.map {
                        MonthCloseLineDTO(
                            name: $0.name,
                            monthlyZar: Money.plain(cents: $0.monthlyCents),
                            spentZar: Money.plain(cents: $0.spentCents),
                            leftZar: Money.plain(cents: $0.leftCents)
                        )
                    },
                    unassignedZar: Money.plain(cents: c.unassignedCents),
                    totalLeftZar: Money.plain(cents: c.totalLeftCents),
                    toSaveZar: Money.plain(cents: c.toSaveCents),
                    movedToSavingsZar: Money.plain(cents: c.movedCents),
                    toReplacementFundsZar: Money.plain(cents: c.replacementCents)
                )
            },
            belongings: belongings.map { belongingDTO($0, now: now, calendar: calendar) },
            spikeTestLog: spikeLog.map(spikeDTO)
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

    private static func spikeDTO(_ p: DebugPayment) -> SpikePaymentDTO {
        SpikePaymentDTO(
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

    nonisolated static func dayString(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        func pad(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }
        return "\(c.year ?? 0)-\(pad(c.month ?? 0))-\(pad(c.day ?? 0))"
    }
}
