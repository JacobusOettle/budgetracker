import Foundation
import SwiftData

/// Something you own and plan to replace one day (phone, fridge, tyres…).
@Model
final class Belonging {
    var id: UUID = UUID()
    var name: String = ""
    var categoryRaw: String = BelongingCategory.other.rawValue
    var createdAt: Date = Date.now
    /// How long the previous one lasted, in months. Entered when adding the
    /// item, or set automatically when you replace it.
    var previousLifespanMonths: Int?
    /// Retired without a replacement. Kept for history.
    var archived: Bool = false

    @Relationship(deleteRule: .cascade, inverse: \Ownership.belonging)
    var ownerships: [Ownership]? = []

    @Relationship(deleteRule: .cascade, inverse: \FundEntry.belonging)
    var fundEntries: [FundEntry]? = []

    /// Non-optional views of the relationships (optional only for CloudKit).
    var allOwnerships: [Ownership] { ownerships ?? [] }
    var allFundEntries: [FundEntry] { fundEntries ?? [] }

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
        allOwnerships.filter { $0.retiredOn == nil }.max { $0.purchasedOn < $1.purchasedOn }
    }

    var sortedOwnerships: [Ownership] {
        allOwnerships.sorted { $0.purchasedOn > $1.purchasedOn }
    }

    var sortedFundEntries: [FundEntry] {
        allFundEntries.sorted { $0.date > $1.date }
    }

    /// Money currently set aside to replace this item.
    var fundBalanceCents: Int {
        allFundEntries.reduce(0) { $0 + $1.cents }
    }

    func hasContribution(forMonthKey key: String) -> Bool {
        allFundEntries.contains { $0.kind == .contribution && $0.monthKey == key }
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
    var id: UUID = UUID()
    var purchasedOn: Date = Date.now
    var priceCents: Int = 0
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
    var id: UUID = UUID()
    var date: Date = Date.now
    var kindRaw: String = FundEntryKind.adjustment.rawValue
    var cents: Int = 0
    /// "2026-11" for monthly contributions. Stops a month being counted twice.
    var monthKey: String?
    var note: String = ""
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
    var balanceCents: Int = 0
    var updatedAt: Date = Date.now
    /// Made by an add/subtract (e.g. a month end) when this phone had no
    /// account yet, typically a new phone before iCloud data arrived. Its
    /// real starting balance is unknown, so only its changes (`deltaCents`)
    /// count; they're folded into the real balance when that arrives.
    var isProvisional: Bool = false
    /// Sum of the adds/subtracts made to a provisional account.
    var deltaCents: Int = 0
    /// When you last typed in the exact balance.
    var balanceSetAt: Date?

    init(balanceCents: Int = 0, updatedAt: Date = .now) {
        self.balanceCents = balanceCents
        self.updatedAt = updatedAt
    }

    @MainActor
    static func current(in context: ModelContext) -> SavingsAccount {
        // Newest first: after iCloud sync there can briefly be two (one per
        // device) until SyncDeduplicator merges them.
        // Once a real balance is here, changes go to it, never to a
        // provisional one this phone made before its data arrived.
        let newest = FetchDescriptor<SavingsAccount>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        let accounts = (try? context.fetch(newest)) ?? []
        if let existing = accounts.first(where: { !$0.isProvisional }) ?? accounts.first {
            return existing
        }
        let account = SavingsAccount()
        account.isProvisional = true
        context.insert(account)
        return account
    }

    /// Adds (or with a negative amount subtracts) money.
    func adjust(by cents: Int, at date: Date = .now) {
        balanceCents += cents
        if isProvisional { deltaCents += cents }
        updatedAt = date
    }

    /// Sets the exact balance you entered: it's no longer provisional.
    func set(to cents: Int, at date: Date = .now) {
        balanceCents = cents
        isProvisional = false
        deltaCents = 0
        balanceSetAt = date
        updatedAt = date
    }

    /// The balance to show while iCloud duplicates haven't been merged yet:
    /// the newest real balance plus changes made on provisional accounts.
    static func effectiveBalance(_ accounts: [SavingsAccount]) -> Int {
        let real = accounts.filter { !$0.isProvisional }.max { ($0.updatedAt, $0.balanceCents) < ($1.updatedAt, $1.balanceCents) }
        let provisional = accounts.filter(\.isProvisional)
        guard let real else { return provisional.reduce(0) { $0 + $1.balanceCents } }
        return real.balanceCents + provisional.reduce(0) { $0 + $1.deltaCents }
    }
}
