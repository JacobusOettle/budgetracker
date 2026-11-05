import Foundation
import SwiftData

/// Handles a payment from the Shortcuts automation (or a test/simulated one):
/// 1. Reads the amount ("R 100.70" -> 10070 cents).
/// 2. Ignores a repeat of the same payment within 2 minutes (a re-run of the
///    Shortcut must not deduct twice).
/// 3. Logs it to the armed budget and disarms it, or saves it as Unassigned.
@MainActor
enum PaymentProcessor {
    static let duplicateWindow: TimeInterval = 120

    enum Outcome {
        case assigned(Payment, budget: Budget, leftCents: Int)
        case unassigned(Payment)
        /// Same amount, merchant and card within the window. Nothing saved.
        case duplicate(Payment)

        var payment: Payment {
            switch self {
            case .assigned(let p, _, _), .unassigned(let p), .duplicate(let p): p
            }
        }
    }

    @discardableResult
    static func process(
        amountText: String,
        merchant: String?,
        card: String?,
        source: PaymentSource,
        now: Date = .now,
        in context: ModelContext,
        calendar: Calendar = .current
    ) throws -> Outcome {
        let merchantName = (merchant ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let cardName = (card ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed = AmountParser.parse(amountText)
        let cents = parsed.map { abs($0.cents) } ?? 0
        let foreignCode = parsed?.currencyCode.flatMap { $0 == "ZAR" ? nil : $0 }

        if parsed != nil {
            let cutoff = now.addingTimeInterval(-duplicateWindow)
            let manual = PaymentSource.manual.rawValue
            let recent = try context.fetch(FetchDescriptor<Payment>(
                predicate: #Predicate { $0.date >= cutoff && $0.sourceRaw != manual }
            ))
            if let existing = recent.first(where: {
                $0.amountCents == cents && $0.merchant == merchantName && $0.card == cardName && $0.date <= now
            }) {
                return .duplicate(existing)
            }
        }

        var note = ""
        if parsed == nil {
            note = "Couldn't read the amount \"\(amountText)\"."
        } else if let foreignCode {
            note = "Paid in \(foreignCode), not rand. Check the amount."
        }

        let payment = Payment(
            amountCents: cents,
            merchant: merchantName,
            card: cardName,
            date: now,
            source: source,
            rawAmount: amountText,
            note: note,
            needsReview: parsed == nil || foreignCode != nil
        )
        context.insert(payment)

        if let budget = try BudgetService.armedBudget(now: now, in: context) {
            let interval = MonthMath.interval(containing: now, calendar: calendar)
            let spentBefore = budget.payments
                .filter { $0.id != payment.id && MonthMath.contains(interval, $0.date) }
                .reduce(0) { $0 + $1.amountCents }
            payment.budget = budget
            payment.assignment = .armed
            budget.armedAt = nil
            try context.save()
            return .assigned(payment, budget: budget, leftCents: budget.monthlyCents - spentBefore - cents)
        }

        try context.save()
        return .unassigned(payment)
    }

    /// Notification after the AI assigned a payment that wasn't armed.
    static func autoNotification(payment: Payment, budget: Budget, now: Date = .now) -> (title: String, body: String) {
        let left = budget.leftCents(now: now)
        let status = left >= 0
            ? "\(Money.format(cents: left)) left."
            : "\(Money.format(cents: -left)) over budget."
        return ("\(Money.format(cents: payment.amountCents)) → \(budget.name) (auto)",
                "\(payment.displayMerchant). \(status) Wrong? Change it in Spaar.")
    }

    /// The notification to show for an outcome. nil for duplicates.
    static func notification(for outcome: Outcome) -> (title: String, body: String)? {
        switch outcome {
        case .duplicate:
            return nil
        case let .assigned(payment, budget, left):
            if payment.needsReview {
                return ("Check payment in \(budget.name)", "\(payment.displayMerchant): \(payment.note) Open Spaar to fix it.")
            }
            let status = left >= 0
                ? "\(Money.format(cents: left)) left in \(budget.name) this month."
                : "\(budget.name) is \(Money.format(cents: -left)) over budget."
            return ("\(Money.format(cents: payment.amountCents)) → \(budget.name)", "\(payment.displayMerchant). \(status)")
        case let .unassigned(payment):
            if payment.needsReview {
                return ("Check a payment", "\(payment.displayMerchant): \(payment.note) Open Spaar to fix and assign it.")
            }
            return ("Assign \(Money.format(cents: payment.amountCents))", "\(payment.displayMerchant). No budget was armed. Open Spaar to assign it.")
        }
    }
}
