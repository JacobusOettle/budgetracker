import Foundation
import SwiftData

/// A monthly spending budget, e.g. Food R3 000.
@Model
final class Budget {
    // Every stored property has a default and every relationship is optional:
    // CloudKit sync (iCloud) requires it.
    var id: UUID = UUID()
    var name: String = ""
    var monthlyCents: Int = 0
    var sortOrder: Int = 0
    var createdAt: Date = Date.now
    /// Removed by the user. Kept so past payments and months still add up.
    var archivedAt: Date?
    /// When it was armed. It stays armed for `Arming.duration` from then,
    /// or until a payment is logged to it.
    var armedAt: Date?
    /// Tile colour (a BudgetPalette key). Empty = picked automatically.
    var colorName: String = ""

    @Relationship(deleteRule: .nullify, inverse: \Payment.budget)
    var payments: [Payment]? = []

    init(name: String, monthlyCents: Int, sortOrder: Int = 0, createdAt: Date = .now) {
        self.id = UUID()
        self.name = name
        self.monthlyCents = monthlyCents
        self.sortOrder = sortOrder
        self.createdAt = createdAt
    }

    func spentCents(in interval: DateInterval) -> Int {
        (payments ?? [])
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
    /// Imported from a bank statement (CSV).
    case statement = "import"
}

/// A card payment. `budget == nil` means Unassigned.
@Model
final class Payment {
    var id: UUID = UUID()
    /// Always positive: money spent.
    var amountCents: Int = 0
    var merchant: String = ""
    var card: String = ""
    var date: Date = Date.now
    var sourceRaw: String = PaymentSource.manual.rawValue
    /// The amount exactly as Shortcuts sent it (e.g. "R 100.70").
    var rawAmount: String = ""
    var note: String = ""
    /// The amount couldn't be read or wasn't in rand. Check and fix it.
    var needsReview: Bool = false
    var budget: Budget?
    /// How it got its budget: see `Assignment`. Default for older rows: "".
    var assignmentRaw: String = ""
    /// Why the AI picked this budget (shown to you).
    var aiReason: String = ""
    /// The AI has already been asked about this payment.
    var aiAttempted: Bool = false
    /// If you corrected the AI: the budget it had picked. Sent back to the AI
    /// as a correction so it learns.
    var aiOriginalBudgetName: String = ""
    /// Seen on a bank statement (imported from one, or matched to one).
    var statementMatched: Bool = false

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

    var assignment: Assignment {
        get {
            if let a = Assignment(rawValue: assignmentRaw), a != .unassigned { return a }
            return budget == nil ? .unassigned : .manual
        }
        set { assignmentRaw = newValue.rawValue }
    }
    var displayMerchant: String { merchant.isEmpty ? "Payment" : merchant }
}

/// How a payment got its budget.
enum Assignment: String, Codable {
    case unassigned = ""
    /// You armed the budget before paying.
    case armed
    /// You picked it.
    case manual
    /// The AI picked it and you haven't checked it yet.
    case ai
    /// The AI picked it and you confirmed it.
    case aiConfirmed
    /// Sorted by the AI during a bank statement import you reviewed.
    case imported

    var isAI: Bool { self == .ai || self == .aiConfirmed }
}

/// A month you closed on the month-end screen.
@Model
final class MonthClose {
    var monthKey: String = ""
    var closedAt: Date = Date.now
    var totalLeftCents: Int = 0
    var unassignedCents: Int = 0
    var toSaveCents: Int = 0
    /// What you said you actually moved to savings.
    var movedCents: Int = 0
    /// Part of the move that went to belonging replacement funds.
    var replacementCents: Int = 0
    /// JSON array of MonthEndLine: what each budget had left that month.
    var linesJSON: String = "[]"

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
