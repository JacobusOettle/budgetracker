import Foundation
import SwiftData

/// Changes to belongings and their replacement funds. Shared by the UI and
/// the tests (and later by the month-end screen).
@MainActor
enum FundService {
    struct PendingContribution {
        let belonging: Belonging
        let cents: Int
    }

    @discardableResult
    static func addBelonging(
        name: String,
        category: BelongingCategory,
        purchasedOn: Date,
        priceCents: Int,
        replacementCostCents: Int?,
        customLifespanMonths: Int?,
        previousLifespanMonths: Int?,
        alreadySavedCents: Int,
        in context: ModelContext
    ) throws -> Belonging {
        let belonging = Belonging(name: name, category: category, previousLifespanMonths: previousLifespanMonths)
        context.insert(belonging)
        let ownership = Ownership(
            purchasedOn: purchasedOn,
            priceCents: priceCents,
            replacementCostCents: replacementCostCents,
            customLifespanMonths: customLifespanMonths
        )
        context.insert(ownership)
        ownership.belonging = belonging
        if alreadySavedCents != 0 {
            let entry = FundEntry(date: .now, kind: .opening, cents: alreadySavedCents)
            context.insert(entry)
            entry.belonging = belonging
        }
        try context.save()
        return belonging
    }

    /// The contributions that haven't been recorded yet for the month of `month`.
    static func pendingContributions(
        belongings: [Belonging],
        month: Date,
        calendar: Calendar = .current
    ) -> [PendingContribution] {
        let key = ReplacementPlanner.monthKey(for: month, calendar: calendar)
        return belongings.compactMap { belonging in
            guard !belonging.archived,
                  !belonging.hasContribution(forMonthKey: key),
                  let plan = belonging.plan(today: month, calendar: calendar),
                  plan.monthlyCents > 0
            else { return nil }
            return PendingContribution(belonging: belonging, cents: plan.monthlyCents)
        }
    }

    /// Records this month's contribution for every item that doesn't have one
    /// yet. Running it again in the same month does nothing (idempotent).
    /// If `addToSavingsBalance`, the total savings balance goes up by the same
    /// amount (you moved that money into savings).
    @discardableResult
    static func recordContributions(
        belongings: [Belonging],
        month: Date,
        addToSavingsBalance: Bool,
        in context: ModelContext,
        calendar: Calendar = .current
    ) throws -> Int {
        let key = ReplacementPlanner.monthKey(for: month, calendar: calendar)
        let pending = pendingContributions(belongings: belongings, month: month, calendar: calendar)
        var total = 0
        for item in pending {
            let entry = FundEntry(date: month, kind: .contribution, cents: item.cents, monthKey: key)
            context.insert(entry)
            entry.belonging = item.belonging
            total += item.cents
        }
        if addToSavingsBalance && total > 0 {
            let account = SavingsAccount.current(in: context)
            account.balanceCents += total
            account.updatedAt = .now
        }
        try context.save()
        return total
    }

    /// Replaces the current unit (`newPriceCents` set) or retires it without a
    /// replacement (`newPriceCents` nil).
    /// - The months it actually lasted become the prediction for the next one.
    /// - The fund pays for the new one. Any leftover moves to true savings.
    /// - If `paidFromSavings`, the total savings balance drops by the new price,
    ///   so a shortfall comes out of true savings.
    @discardableResult
    static func replace(
        _ belonging: Belonging,
        on date: Date,
        reason: String,
        newPriceCents: Int?,
        newReplacementCostCents: Int? = nil,
        newCustomLifespanMonths: Int? = nil,
        paidFromSavings: Bool,
        in context: ModelContext,
        calendar: Calendar = .current
    ) throws -> ReplacementSettlement {
        let settlement = ReplacementPlanner.settle(fundCents: belonging.fundBalanceCents, newPriceCents: newPriceCents)

        if let current = belonging.currentOwnership {
            current.retiredOn = date
            current.retiredReason = reason.isEmpty ? nil : reason
            belonging.previousLifespanMonths = ReplacementPlanner.actualLifespanMonths(
                purchasedOn: current.purchasedOn, retiredOn: date, calendar: calendar
            )
        }

        if settlement.spentFromFundCents > 0 {
            let entry = FundEntry(date: date, kind: .spent, cents: -settlement.spentFromFundCents)
            context.insert(entry)
            entry.belonging = belonging
        }
        if settlement.releasedToTrueSavingsCents > 0 {
            let entry = FundEntry(date: date, kind: .released, cents: -settlement.releasedToTrueSavingsCents)
            context.insert(entry)
            entry.belonging = belonging
        }

        if let newPriceCents {
            let next = Ownership(
                purchasedOn: date,
                priceCents: newPriceCents,
                replacementCostCents: newReplacementCostCents,
                customLifespanMonths: newCustomLifespanMonths
            )
            context.insert(next)
            next.belonging = belonging
            if paidFromSavings {
                let account = SavingsAccount.current(in: context)
                account.balanceCents -= newPriceCents
                account.updatedAt = .now
            }
        } else {
            belonging.archived = true
        }

        try context.save()
        return settlement
    }

    /// Sets the fund to an exact amount by adding an adjustment entry.
    static func setFundBalance(_ belonging: Belonging, to cents: Int, in context: ModelContext) throws {
        let delta = cents - belonging.fundBalanceCents
        guard delta != 0 else { return }
        let entry = FundEntry(date: .now, kind: .adjustment, cents: delta)
        context.insert(entry)
        entry.belonging = belonging
        try context.save()
    }

    static func setSavingsBalance(_ cents: Int, in context: ModelContext) throws {
        let account = SavingsAccount.current(in: context)
        account.balanceCents = cents
        account.updatedAt = .now
        try context.save()
    }
}
