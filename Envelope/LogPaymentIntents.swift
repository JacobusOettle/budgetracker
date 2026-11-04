import AppIntents
import Foundation

/// Called by the Shortcuts Wallet automation after an Apple Pay payment.
/// The spike showed the amount arrives reliably as text (e.g. "R 100.70"),
/// so it's a String parameter that we parse ourselves. The Currency Amount
/// variant failed on device and was removed.
///
/// Keep this type's name and parameter names unchanged: existing
/// automations refer to them.
struct LogPaymentIntent: AppIntent {
    static var title: LocalizedStringResource = "Log Payment"
    static var description = IntentDescription(
        "Logs a card payment to the budget you armed in Tally, or (if AI is set up) to the budget the AI picks, otherwise as Unassigned. Use it in a Shortcuts Wallet automation: set Amount, Merchant and Card from Shortcut Input."
    )
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Amount", description: "Shortcut Input › Amount")
    var amount: String

    @Parameter(title: "Merchant", description: "Shortcut Input › Merchant")
    var merchant: String?

    @Parameter(title: "Card", description: "Shortcut Input › Card or Pass")
    var card: String?

    @Parameter(title: "Raw Input", description: "Not needed. Kept so automations from the test build still work.")
    var rawInput: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Log \(\.$amount) at \(\.$merchant)") {
            \.$card
            \.$rawInput
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let context = Persistence.shared.mainContext
        let outcome = try PaymentProcessor.process(
            amountText: amount,
            merchant: merchant,
            card: card,
            source: .shortcut,
            in: context
        )
        var note = PaymentProcessor.notification(for: outcome)

        // Nothing armed: let the AI try, if you've set it up. It's saved as
        // Unassigned first, so a slow or failed AI call loses nothing.
        if case .unassigned(let payment) = outcome, let client = AutoCategorizer.clientFromSettings() {
            let result = await AutoCategorizer.categorize(payment, client: client, in: context)
            if case .assigned(let budget, _) = result {
                note = PaymentProcessor.autoNotification(payment: payment, budget: budget)
            }
        }

        if let note {
            await Notifier.post(title: note.title, body: note.body)
        }
        // No dialog: nothing pops up at the till. The notification confirms it.
        return .result()
    }
}
