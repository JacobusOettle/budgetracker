import Foundation
import SwiftData

/// Spike logger: records every incoming payment. It does NOT drop duplicates
/// (we want to see whether Shortcuts fires twice); it only flags them.
@MainActor
enum PaymentLogger {
    static let duplicateWindow: TimeInterval = 120

    @discardableResult
    static func log(
        source: String,
        rawAmount: String,
        cents: Int?,
        currencyCode: String?,
        merchant: String?,
        card: String?,
        rawInput: String?,
        at date: Date = .now,
        in context: ModelContext
    ) throws -> DebugPayment {
        let merchantName = (merchant ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let cardName = (card ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        let cutoff = date.addingTimeInterval(-duplicateWindow)
        let sourceName = source
        let descriptor = FetchDescriptor<DebugPayment>(
            predicate: #Predicate { $0.receivedAt >= cutoff && $0.source == sourceName }
        )
        let recent = try context.fetch(descriptor)
        let duplicate = recent.contains {
            $0.amountCents == cents && $0.merchant == merchantName && $0.card == cardName
        }

        let payment = DebugPayment(
            receivedAt: date,
            source: source,
            rawAmount: rawAmount,
            amountCents: cents,
            currencyCode: currencyCode,
            merchant: merchantName,
            card: cardName,
            rawInput: rawInput ?? "",
            possibleDuplicate: duplicate
        )
        context.insert(payment)
        try context.save()
        return payment
    }
}
