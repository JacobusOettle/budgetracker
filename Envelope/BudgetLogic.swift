import Foundation

/// Arming: tapping a budget arms it for 10 minutes. The next payment in that
/// time is logged to it, then it disarms.
enum Arming {
    static let duration: TimeInterval = 10 * 60

    static func remaining(armedAt: Date?, now: Date) -> TimeInterval {
        guard let armedAt else { return 0 }
        let left = armedAt.addingTimeInterval(duration).timeIntervalSince(now)
        return max(0, min(duration, left))
    }

    static func isArmed(armedAt: Date?, now: Date) -> Bool {
        remaining(armedAt: armedAt, now: now) > 0
    }

    /// "9:05"
    static func countdown(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded(.up))
        let rest = s % 60
        return "\(s / 60):\(rest < 10 ? "0" : "")\(rest)"
    }
}

enum BudgetWarning: Equatable {
    case none
    /// 20% or less of the monthly amount left.
    case low
    /// Nothing left, or over budget.
    case empty

    static func level(leftCents: Int, monthlyCents: Int) -> BudgetWarning {
        if leftCents <= 0 { return .empty }
        if monthlyCents > 0 && leftCents * 5 <= monthlyCents { return .low }
        return .none
    }
}

enum MonthMath {
    static func interval(containing date: Date, calendar: Calendar = .current) -> DateInterval {
        calendar.dateInterval(of: .month, for: date) ?? DateInterval(start: date, duration: 0)
    }

    /// Start inclusive, end exclusive, so midnight on the 1st belongs to the new month.
    static func contains(_ interval: DateInterval, _ date: Date) -> Bool {
        date >= interval.start && date < interval.end
    }

    static func startOfMonth(_ date: Date, calendar: Calendar = .current) -> Date {
        interval(containing: date, calendar: calendar).start
    }

    static func name(_ date: Date, calendar: Calendar = .current) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = "MMMM yyyy"
        return f.string(from: date)
    }
}

/// What a budget had left at month end.
struct MonthEndLine: Codable, Equatable {
    let name: String
    let monthlyCents: Int
    let spentCents: Int
    var leftCents: Int { monthlyCents - spentCents }
}

struct MonthEndSummary: Equatable {
    let lines: [MonthEndLine]
    let unassignedCents: Int
    let unassignedCount: Int

    /// Sum of what's left in every budget. Overspending in one budget eats
    /// into what's left in the others.
    var totalLeftCents: Int { lines.reduce(0) { $0 + $1.leftCents } }

    /// What to move to savings. Unassigned spending is real money spent, so
    /// it's taken off too. Never negative.
    var toSaveCents: Int { max(0, totalLeftCents - unassignedCents) }
}

/// The month you started using Spaar. Month End only reminds you about
/// months from then on, so importing a past statement (which backdates
/// budgets) doesn't ask you to close a year of old months.
enum UsageStart {
    static let key = "tally.usageStart"

    /// Saved the first time it's asked for: the earliest budget, or now.
    static func date(budgets: [Budget], now: Date = .now, defaults: UserDefaults = .standard) -> Date {
        if let saved = defaults.object(forKey: key) as? Date { return saved }
        let start = min(now, budgets.map(\.createdAt).min() ?? now)
        defaults.set(start, forKey: key)
        return start
    }
}

enum MonthEnd {
    static func summary(lines: [MonthEndLine], unassigned: [Int]) -> MonthEndSummary {
        MonthEndSummary(lines: lines, unassignedCents: unassigned.reduce(0, +), unassignedCount: unassigned.count)
    }

    /// Builds the month's summary from your budgets and payments. Includes
    /// budgets that existed during the month.
    static func summary(budgets: [Budget], payments: [Payment], month: Date, calendar: Calendar = .current) -> MonthEndSummary {
        let interval = MonthMath.interval(containing: month, calendar: calendar)
        let lines = budgets
            .filter { $0.mergedIntoID == nil }  // iCloud duplicates merged into another budget
            .filter { $0.createdAt < interval.end && ($0.archivedAt.map { $0 >= interval.start } ?? true) }
            .sorted { ($0.sortOrder, $0.name) < ($1.sortOrder, $1.name) }
            .map { MonthEndLine(name: $0.name, monthlyCents: $0.monthlyCents, spentCents: $0.spentCents(in: interval)) }
        let unassigned = payments
            .filter { $0.budget == nil && MonthMath.contains(interval, $0.date) }
            .map(\.amountCents)
        return summary(lines: lines, unassigned: unassigned)
    }

    /// Past months, from the month you started, that haven't been closed yet.
    static func unclosedMonths(firstUse: Date?, closedKeys: Set<String>, now: Date, calendar: Calendar = .current) -> [Date] {
        guard let firstUse else { return [] }
        var month = MonthMath.startOfMonth(firstUse, calendar: calendar)
        let current = MonthMath.startOfMonth(now, calendar: calendar)
        var result: [Date] = []
        while month < current {
            if !closedKeys.contains(ReplacementPlanner.monthKey(for: month, calendar: calendar)) {
                result.append(month)
            }
            guard let next = calendar.date(byAdding: .month, value: 1, to: month) else { break }
            month = next
        }
        return result
    }
}
