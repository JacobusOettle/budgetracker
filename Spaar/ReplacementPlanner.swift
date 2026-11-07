import Foundation

enum LifespanSource: String, Codable, Equatable {
    /// You entered how long this one will last.
    case custom
    /// How long the previous one actually lasted.
    case previous
    /// Built-in typical lifespan for the category.
    case typical
}

struct Lifespan: Equatable {
    let months: Int
    let source: LifespanSource

    /// "4 years", "1 year 6 months", "8 months".
    static func describe(months: Int) -> String {
        let years = months / 12
        let rest = months % 12
        var parts: [String] = []
        if years > 0 { parts.append(years == 1 ? "1 year" : "\(years) years") }
        if rest > 0 || years == 0 { parts.append(rest == 1 ? "1 month" : "\(rest) months") }
        return parts.joined(separator: " ")
    }

    var sourceDescription: String {
        switch source {
        case .custom: "your estimate"
        case .previous: "how long your last one lasted"
        case .typical: "typical lifespan, a rough estimate"
        }
    }
}

struct ReplacementPlan: Equatable {
    enum Status: Equatable {
        /// Still saving towards the target.
        case saving
        /// The fund already covers the target. Nothing more needed.
        case funded
        /// The expected replacement date has arrived but the fund is short.
        case due
    }

    let lifespan: Lifespan
    let expectedReplacementDate: Date
    let targetCents: Int
    let savedCents: Int
    /// Monthly contributions still to make, starting this month (or next
    /// month if this month's contribution is already recorded).
    let remainingMonths: Int
    let monthlyCents: Int
    let status: Status
    let isPastExpectedLife: Bool

    var shortfallCents: Int { max(0, targetCents - savedCents) }
}

struct ReplacementSettlement: Equatable {
    /// Taken out of the item's fund to pay for the new one.
    let spentFromFundCents: Int
    /// Left over in the fund. It stops being set aside and counts as true savings.
    let releasedToTrueSavingsCents: Int
    /// The new one cost more than the fund. This part comes out of true savings.
    let shortfallFromTrueSavingsCents: Int
}

enum ReplacementPlanner {
    /// Which lifespan to use: your custom period, else how long the previous
    /// one lasted, else the category's typical lifespan.
    static func resolveLifespan(customMonths: Int?, previousMonths: Int?, category: BelongingCategory) -> Lifespan {
        if let customMonths, customMonths > 0 { return Lifespan(months: customMonths, source: .custom) }
        if let previousMonths, previousMonths > 0 { return Lifespan(months: previousMonths, source: .previous) }
        return Lifespan(months: category.typicalLifespanMonths, source: .typical)
    }

    /// Monthly amount = what's still missing ÷ months left, rounded UP to the
    /// cent so the fund always reaches the target on time.
    ///
    /// For a new item with nothing saved this is simply price ÷ lifespan
    /// (R24 000 over 4 years = R500/month). An item added mid-life, or a fund
    /// that fell behind, catches up over the time that's left.
    static func plan(
        purchasedOn: Date,
        targetCents: Int,
        savedCents: Int,
        lifespan: Lifespan,
        contributedThisMonth: Bool,
        today: Date,
        calendar: Calendar = .current
    ) -> ReplacementPlan {
        let end = calendar.date(byAdding: .month, value: lifespan.months, to: purchasedOn) ?? purchasedOn
        let firstMonth = contributedThisMonth
            ? (calendar.date(byAdding: .month, value: 1, to: today) ?? today)
            : today
        let remaining = max(0, monthsBetween(firstMonth, end, calendar: calendar))
        let shortfall = max(0, targetCents - savedCents)
        let pastEnd = today >= end

        let status: ReplacementPlan.Status
        let monthly: Int
        if shortfall == 0 {
            status = .funded
            monthly = 0
        } else if remaining == 0 {
            status = .due
            monthly = 0
        } else {
            status = .saving
            monthly = ceilDiv(shortfall, remaining)
        }

        return ReplacementPlan(
            lifespan: lifespan,
            expectedReplacementDate: end,
            targetCents: targetCents,
            savedCents: savedCents,
            remainingMonths: remaining,
            monthlyCents: monthly,
            status: status,
            isPastExpectedLife: pastEnd
        )
    }

    /// What happens to the fund when the item is replaced (newPriceCents set)
    /// or retired without a replacement (newPriceCents nil).
    static func settle(fundCents: Int, newPriceCents: Int?) -> ReplacementSettlement {
        let fund = max(0, fundCents)
        guard let price = newPriceCents else {
            return ReplacementSettlement(spentFromFundCents: 0, releasedToTrueSavingsCents: fund, shortfallFromTrueSavingsCents: 0)
        }
        let price0 = max(0, price)
        return ReplacementSettlement(
            spentFromFundCents: min(fund, price0),
            releasedToTrueSavingsCents: max(0, fund - price0),
            shortfallFromTrueSavingsCents: max(0, price0 - fund)
        )
    }

    /// Whole months the item actually lasted, at least 1.
    static func actualLifespanMonths(purchasedOn: Date, retiredOn: Date, calendar: Calendar = .current) -> Int {
        let months = calendar.dateComponents([.month], from: purchasedOn, to: retiredOn).month ?? 0
        return max(1, months)
    }

    /// Calendar months from the month of `from` to the month of `to`
    /// (Nov 2026 → Nov 2030 = 48). Negative if `to` is earlier.
    static func monthsBetween(_ from: Date, _ to: Date, calendar: Calendar = .current) -> Int {
        let a = calendar.dateComponents([.year, .month], from: from)
        let b = calendar.dateComponents([.year, .month], from: to)
        return ((b.year ?? 0) - (a.year ?? 0)) * 12 + ((b.month ?? 0) - (a.month ?? 0))
    }

    static func monthKey(for date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month], from: date)
        let month = c.month ?? 0
        return "\(c.year ?? 0)-\(month < 10 ? "0" : "")\(month)"
    }

    private static func ceilDiv(_ a: Int, _ b: Int) -> Int {
        precondition(b > 0)
        return (a + b - 1) / b
    }
}

enum SavingsSplit {
    /// Your total savings minus what's set aside for replacements. Can go
    /// negative, meaning the savings balance doesn't cover the funds.
    static func trueSavings(totalCents: Int, setAsideCents: Int) -> Int {
        totalCents - setAsideCents
    }
}
