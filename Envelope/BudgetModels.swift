import Foundation
import SwiftData

/// A monthly spending budget, e.g. Food R3 000.
@Model
final class Budget {
    var id: UUID
    var name: String
    var monthlyCents: Int
    var sortOrder: Int
    var createdAt: Date
    /// Removed by the user. Kept so past payments and months still add up.
    var archivedAt: Date?
    /// When it was armed. It stays armed for `Arming.duration` from then,
    /// or until a payment is logged to it.
    var armedAt: Date?

    @Relationship(deleteRule: .nullify, inverse: \Payment.budget)
    var payments: [Payment] = []

    init(name: String, monthlyCents: Int, sortOrder: Int = 0, createdAt: Date = .now) {
        self.id = UUID()
        self.name = name
        self.monthlyCents = monthlyCents
        self.sortOrder = sortOrder
        self.createdAt = createdAt
    }

    func spentCents(in interval: DateInterval) -> Int {
        payments
            .filter { MonthMath.contains(interval, $0.date) }
            .reduce(0) { $0 + $1.amountCents }
    }

    func leftCents(now: Date = .now, calendar: Calendar = .current) -> Int {
        monthlyCents - spentCents(in: MonthMath.interval(containing: now, calendar: calendar))
    }
}

enum PaymentSource: String, Codable {
    /// Logged by the Shortcuts Wallet automation.
    case shortcut
    /// Typed in by you.
    case manual
    /// "Send a test payment" in Settings.
    case test
}

/// A card payment. `budget == nil` means Unassigned.
@Model
final class Payment {
    var id: UUID
    /// Always positive: money spent.
    var amountCents: Int
    var merchant: String
    var card: String
    var date: Date
    var sourceRaw: String
    /// The amount exactly as Shortcuts sent it (e.g. "R 100.70").
    var rawAmount: String
    var note: String
    /// The amount couldn't be read or wasn't in rand. Check and fix it.
    var needsReview: Bool
    var budget: Budget?

    init(
        amountCents: Int,
        merchant: String,
        card: String,
        date: Date,
        source: PaymentSource,
        rawAmount: String = "",
        note: String = "",
        needsReview: Bool = false
    ) {
        self.id = UUID()
        self.amountCents = amountCents
        self.merchant = merchant
        self.card = card
        self.date = date
        self.sourceRaw = source.rawValue
        self.rawAmount = rawAmount
        self.note = note
        self.needsReview = needsReview
    }

    var source: PaymentSource { PaymentSource(rawValue: sourceRaw) ?? .manual }
    var displayMerchant: String { merchant.isEmpty ? "Payment" : merchant }
}

/// A month you closed on the month-end screen.
@Model
final class MonthClose {
    var monthKey: String
    var closedAt: Date
    var totalLeftCents: Int
    var unassignedCents: Int
    var toSaveCents: Int
    /// What you said you actually moved to savings.
    var movedCents: Int
    /// Part of the move that went to belonging replacement funds.
    var replacementCents: Int
    /// JSON array of MonthEndLine: what each budget had left that month.
    var linesJSON: String

    init(monthKey: String, closedAt: Date, summary: MonthEndSummary, movedCents: Int, replacementCents: Int) {
        self.monthKey = monthKey
        self.closedAt = closedAt
        self.totalLeftCents = summary.totalLeftCents
        self.unassignedCents = summary.unassignedCents
        self.toSaveCents = summary.toSaveCents
        self.movedCents = movedCents
        self.replacementCents = replacementCents
        let data = (try? JSONEncoder().encode(summary.lines)) ?? Data("[]".utf8)
        self.linesJSON = String(decoding: data, as: UTF8.self)
    }

    var lines: [MonthEndLine] {
        (try? JSONDecoder().decode([MonthEndLine].self, from: Data(linesJSON.utf8))) ?? []
    }
}
