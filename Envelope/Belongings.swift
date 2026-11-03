import Foundation
import SwiftData

/// Something you own and plan to replace one day (phone, fridge, tyres…).
@Model
final class Belonging {
    var id: UUID
    var name: String
    var categoryRaw: String
    var createdAt: Date
    /// How long the previous one lasted, in months. Entered when adding the
    /// item, or set automatically when you replace it.
    var previousLifespanMonths: Int?
    /// Retired without a replacement. Kept for history.
    var archived: Bool

    @Relationship(deleteRule: .cascade, inverse: \Ownership.belonging)
    var ownerships: [Ownership] = []

    @Relationship(deleteRule: .cascade, inverse: \FundEntry.belonging)
    var fundEntries: [FundEntry] = []

    init(name: String, category: BelongingCategory, previousLifespanMonths: Int? = nil, createdAt: Date = .now) {
        self.id = UUID()
        self.name = name
        self.categoryRaw = category.rawValue
        self.createdAt = createdAt
        self.previousLifespanMonths = previousLifespanMonths
        self.archived = false
    }

    var category: BelongingCategory {
        get { BelongingCategory(rawValue: categoryRaw) ?? .other }
        set { categoryRaw = newValue.rawValue }
    }

    /// The one you own now.
    var currentOwnership: Ownership? {
        ownerships.filter { $0.retiredOn == nil }.max { $0.purchasedOn < $1.purchasedOn }
    }

    var sortedOwnerships: [Ownership] {
        ownerships.sorted { $0.purchasedOn > $1.purchasedOn }
    }

    var sortedFundEntries: [FundEntry] {
        fundEntries.sorted { $0.date > $1.date }
    }

    /// Money currently set aside to replace this item.
    var fundBalanceCents: Int {
        fundEntries.reduce(0) { $0 + $1.cents }
    }

    func hasContribution(forMonthKey key: String) -> Bool {
        fundEntries.contains { $0.kind == .contribution && $0.monthKey == key }
    }

    func lifespan() -> Lifespan? {
        guard let current = currentOwnership else { return nil }
        return ReplacementPlanner.resolveLifespan(
            customMonths: current.customLifespanMonths,
            previousMonths: previousLifespanMonths,
            category: category
        )
    }

    func plan(today: Date = .now, calendar: Calendar = .current) -> ReplacementPlan? {
        guard let current = currentOwnership, let lifespan = lifespan() else { return nil }
        return ReplacementPlanner.plan(
            purchasedOn: current.purchasedOn,
            targetCents: current.targetCents,
            savedCents: fundBalanceCents,
            lifespan: lifespan,
            contributedThisMonth: hasContribution(forMonthKey: ReplacementPlanner.monthKey(for: today, calendar: calendar)),
            today: today,
            calendar: calendar
        )
    }
}

/// One period of owning one unit of a belonging: from purchase until it's
/// replaced or retired.
@Model
final class Ownership {
    var id: UUID
    var purchasedOn: Date
    var priceCents: Int
    /// Expected price of the next one. nil means "same as I paid".
    var replacementCostCents: Int?
    /// Your own estimate of how long this one will last, in months.
    var customLifespanMonths: Int?
    var retiredOn: Date?
    var retiredReason: String?
    var belonging: Belonging?

    init(purchasedOn: Date, priceCents: Int, replacementCostCents: Int? = nil, customLifespanMonths: Int? = nil) {
        self.id = UUID()
        self.purchasedOn = purchasedOn
        self.priceCents = priceCents
        self.replacementCostCents = replacementCostCents
        self.customLifespanMonths = customLifespanMonths
    }

    /// What we're saving towards.
    var targetCents: Int { replacementCostCents ?? priceCents }
}

enum FundEntryKind: String, Codable, CaseIterable {
    /// Already saved when the item was added.
    case opening
    /// The monthly amount set aside.
    case contribution
    /// Used to pay for the replacement.
    case spent
    /// Left over after replacing or retiring. It moves to true savings.
    case released
    /// Manual correction.
    case adjustment

    var displayName: String {
        switch self {
        case .opening: "Already saved"
        case .contribution: "Monthly contribution"
        case .spent: "Spent on replacement"
        case .released: "Moved to true savings"
        case .adjustment: "Adjustment"
        }
    }
}

/// A movement in or out of a belonging's replacement fund. Positive cents go
/// into the fund, negative cents come out.
@Model
final class FundEntry {
    var id: UUID
    var date: Date
    var kindRaw: String
    var cents: Int
    /// "2026-11" for monthly contributions. Stops a month being counted twice.
    var monthKey: String?
    var note: String
    var belonging: Belonging?

    init(date: Date, kind: FundEntryKind, cents: Int, monthKey: String? = nil, note: String = "") {
        self.id = UUID()
        self.date = date
        self.kindRaw = kind.rawValue
        self.cents = cents
        self.monthKey = monthKey
        self.note = note
    }

    var kind: FundEntryKind { FundEntryKind(rawValue: kindRaw) ?? .adjustment }
}

/// Your total savings balance, entered by you since the app can't see your
/// bank. True savings = this minus everything set aside for replacements.
@Model
final class SavingsAccount {
    var balanceCents: Int
    var updatedAt: Date

    init(balanceCents: Int = 0, updatedAt: Date = .now) {
        self.balanceCents = balanceCents
        self.updatedAt = updatedAt
    }

    @MainActor
    static func current(in context: ModelContext) -> SavingsAccount {
        if let existing = try? context.fetch(FetchDescriptor<SavingsAccount>()).first {
            return existing
        }
        let account = SavingsAccount()
        context.insert(account)
        return account
    }
}
