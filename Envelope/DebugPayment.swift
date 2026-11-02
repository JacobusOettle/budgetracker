import Foundation
import SwiftData

/// Spike-only record of every payment the App Intent receives, exactly as it
/// arrived from Shortcuts, so we can see how the Transaction trigger's
/// Shortcut Input actually maps onto our parameters.
@Model
final class DebugPayment {
    var id: UUID
    var receivedAt: Date
    /// Which intent variant logged it: "text", "currency" or "simulated-…".
    var source: String
    /// The amount exactly as received, before parsing.
    var rawAmount: String
    /// Parsed amount in cents (never Double). nil if parsing failed.
    var amountCents: Int?
    var currencyCode: String?
    var merchant: String
    var card: String
    /// Optional: whatever Shortcut Input looks like when coerced to text.
    var rawInput: String
    /// Same source, amount, merchant and card within the duplicate window.
    var possibleDuplicate: Bool

    init(
        receivedAt: Date,
        source: String,
        rawAmount: String,
        amountCents: Int?,
        currencyCode: String?,
        merchant: String,
        card: String,
        rawInput: String,
        possibleDuplicate: Bool
    ) {
        self.id = UUID()
        self.receivedAt = receivedAt
        self.source = source
        self.rawAmount = rawAmount
        self.amountCents = amountCents
        self.currencyCode = currencyCode
        self.merchant = merchant
        self.card = card
        self.rawInput = rawInput
        self.possibleDuplicate = possibleDuplicate
    }

    var formattedAmount: String {
        guard let amountCents else { return "Unparsed: \"\(rawAmount)\"" }
        let money = Money.format(cents: amountCents)
        if let currencyCode, currencyCode != "ZAR" { return "\(money) (\(currencyCode)?)" }
        return money
    }

    var summaryLine: String {
        let at = merchant.isEmpty ? "unknown merchant" : merchant
        let on = card.isEmpty ? "unknown card" : card
        return "\(formattedAmount) at \(at) on \(on)"
    }

    /// Plain-text dump used by "Share log" so results can be pasted back.
    var debugDescriptionLine: String {
        let iso = ISO8601DateFormatter().string(from: receivedAt)
        return [
            iso,
            "source=\(source)",
            "raw=\"\(rawAmount)\"",
            "cents=\(amountCents.map(String.init) ?? "nil")",
            "currency=\(currencyCode ?? "nil")",
            "merchant=\"\(merchant)\"",
            "card=\"\(card)\"",
            "rawInput=\"\(rawInput)\"",
            "dup=\(possibleDuplicate)",
        ].joined(separator: " | ")
    }
}
