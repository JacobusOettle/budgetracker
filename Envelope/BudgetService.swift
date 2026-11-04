import Foundation
import SwiftData

/// Changes to budgets: create, arm, archive, month-end.
@MainActor
enum BudgetService {
    static func activeBudgets(in context: ModelContext) throws -> [Budget] {
        let descriptor = FetchDescriptor<Budget>(
            predicate: #Predicate { $0.archivedAt == nil },
            sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.name)]
        )
        return try context.fetch(descriptor)
    }

    @discardableResult
    static func addBudget(name: String, monthlyCents: Int, now: Date = .now, in context: ModelContext) throws -> Budget {
        let order = (try activeBudgets(in: context).map(\.sortOrder).max() ?? -1) + 1
        let budget = Budget(name: name, monthlyCents: monthlyCents, sortOrder: order, createdAt: now)
        context.insert(budget)
        try context.save()
        return budget
    }

    /// Arms `budget` for 10 minutes and disarms every other budget.
    static func arm(_ budget: Budget, now: Date = .now, in context: ModelContext) throws {
        for other in try context.fetch(FetchDescriptor<Budget>()) where other.id != budget.id {
            other.armedAt = nil
        }
        budget.armedAt = now
        try context.save()
    }

    static func disarm(_ budget: Budget, in context: ModelContext) throws {
        budget.armedAt = nil
        try context.save()
    }

    /// The budget armed right now, if any. Clears expired arms as a side effect.
    static func armedBudget(now: Date = .now, in context: ModelContext) throws -> Budget? {
        var armed: Budget?
        for budget in try context.fetch(FetchDescriptor<Budget>()) where budget.armedAt != nil {
            if budget.archivedAt == nil, Arming.isArmed(armedAt: budget.armedAt, now: now) {
                if let current = armed, (current.armedAt ?? .distantPast) > (budget.armedAt ?? .distantPast) {
                    budget.armedAt = nil
                } else {
                    armed?.armedAt = nil
                    armed = budget
                }
            } else {
                budget.armedAt = nil
            }
        }
        return armed
    }

    /// Deletes a budget with no payments. One with payments is archived
    /// instead, so history and past months still add up.
    static func remove(_ budget: Budget, now: Date = .now, in context: ModelContext) throws {
        if budget.payments.isEmpty {
            context.delete(budget)
        } else {
            budget.archivedAt = now
            budget.armedAt = nil
        }
        try context.save()
    }

    /// Records a month as closed.
    /// - Your total savings balance goes up by `movedCents`.
    /// - That month's belonging replacement contributions are recorded (part
    ///   of what you moved is now set aside for replacements).
    /// - Closing the same month twice does nothing and returns the first close.
    @discardableResult
    static func closeMonth(
        _ month: Date,
        summary: MonthEndSummary,
        movedCents: Int,
        belongings: [Belonging],
        now: Date = .now,
        in context: ModelContext,
        calendar: Calendar = .current
    ) throws -> MonthClose {
        let monthStart = MonthMath.startOfMonth(month, calendar: calendar)
        let key = ReplacementPlanner.monthKey(for: monthStart, calendar: calendar)
        let existing = try context.fetch(FetchDescriptor<MonthClose>(predicate: #Predicate { $0.monthKey == key }))
        if let first = existing.first { return first }

        let replacement = try FundService.recordContributions(
            belongings: belongings, month: monthStart, addToSavingsBalance: false, in: context, calendar: calendar
        )
        let close = MonthClose(monthKey: key, closedAt: now, summary: summary, movedCents: movedCents, replacementCents: replacement)
        context.insert(close)
        if movedCents != 0 {
            let account = SavingsAccount.current(in: context)
            account.balanceCents += movedCents
            account.updatedAt = now
        }
        try context.save()
        return close
    }
}
