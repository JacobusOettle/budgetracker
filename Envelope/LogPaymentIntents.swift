import AppIntents
import Foundation

// Two variants on purpose: we don't yet know which parameter type the
// Transaction trigger's "Amount" maps onto reliably. Add BOTH actions to the
// test automation; each logs its own row, tagged by `source`.

/// Variant A: amount as text. Accepts whatever Shortcuts passes and parses it
/// ourselves. Most forgiving mapping.
struct LogPaymentIntent: AppIntent {
    static var title: LocalizedStringResource = "Log Payment"
    static var description = IntentDescription(
        "Records a card payment in Envelope. Use it in a Shortcuts Transaction automation: set Amount, Merchant and Card from Shortcut Input."
    )
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Amount", description: "Shortcut Input › Amount")
    var amount: String

    @Parameter(title: "Merchant", description: "Shortcut Input › Merchant")
    var merchant: String?

    @Parameter(title: "Card", description: "Shortcut Input › Card or Pass")
    var card: String?

    @Parameter(title: "Raw Input", description: "Optional, for debugging: pass Shortcut Input itself")
    var rawInput: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Log \(\.$amount) at \(\.$merchant)") {
            \.$card
            \.$rawInput
        }
    }

    var sourceTag: String = "text"

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let parsed = AmountParser.parse(amount)
        let entry = try PaymentLogger.log(
            source: sourceTag,
            rawAmount: amount,
            cents: parsed?.cents,
            currencyCode: parsed?.currencyCode,
            merchant: merchant,
            card: card,
            rawInput: rawInput,
            in: Persistence.shared.mainContext
        )
        let summary = entry.summaryLine
        await Notifier.post(title: "Envelope logged (text)", body: summary)
        return .result(dialog: "\(summary)")
    }
}

/// Variant B: amount as a typed currency amount (Decimal + ISO code).
struct LogPaymentCurrencyIntent: AppIntent {
    static var title: LocalizedStringResource = "Log Payment (Currency Amount)"
    static var description = IntentDescription(
        "Spike variant: same as Log Payment, but the Amount parameter is a currency amount instead of text."
    )
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Amount", description: "Shortcut Input › Amount")
    var amount: IntentCurrencyAmount

    @Parameter(title: "Merchant", description: "Shortcut Input › Merchant")
    var merchant: String?

    @Parameter(title: "Card", description: "Shortcut Input › Card or Pass")
    var card: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Log \(\.$amount) at \(\.$merchant)") {
            \.$card
        }
    }

    var sourceTag: String = "currency"

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let entry = try PaymentLogger.log(
            source: sourceTag,
            rawAmount: "\(amount.amount) \(amount.currencyCode)",
            cents: Money.cents(from: amount.amount),
            currencyCode: amount.currencyCode,
            merchant: merchant,
            card: card,
            rawInput: nil,
            in: Persistence.shared.mainContext
        )
        let summary = entry.summaryLine
        await Notifier.post(title: "Envelope logged (currency)", body: summary)
        return .result(dialog: "\(summary)")
    }
}
