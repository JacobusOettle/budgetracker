import Foundation
import SwiftData

/// Asks an LLM which budget an unassigned payment belongs to, using your past
/// payments (and your corrections) as context. Only used when you've turned
/// it on in Settings and added a provider.
@MainActor
enum AutoCategorizer {
    /// Below this the payment stays Unassigned for you to sort.
    static let confidenceThreshold = 0.6
    nonisolated static let historyLimit = 80

    struct Suggestion: Equatable {
        let budgetName: String
        let confidence: Double
        let reason: String
    }

    enum Result {
        case assigned(Budget, Suggestion)
        /// The model wasn't sure enough, or picked nothing.
        case unsure
        case failed(String)
    }

    /// A client from your saved settings, or nil if AI is off or incomplete.
    static func clientFromSettings() -> LLMCompleting? {
        let config = AIConfig.load()
        guard config.enabled else { return nil }
        if config.resolvedCategorizer(appleAvailable: OnDeviceAI.isAvailable) == .appleOnDevice {
            return OnDeviceAI.makeClient()
        }
        guard config.cloudIsConfigured else { return nil }
        let key = KeychainStore.get(AIConfig.keychainAccount) ?? ""
        if AIPreset.named(config.presetID).needsKey && key.isEmpty { return nil }
        return HTTPLLMClient(config: config, apiKey: key)
    }

    /// Why there's no client, for a message on screen.
    static func clientUnavailableMessage() -> String {
        let config = AIConfig.load()
        guard config.enabled else { return "Turn on auto-categorise in Settings → Auto-categorise with AI." }
        if config.resolvedCategorizer(appleAvailable: OnDeviceAI.isAvailable) == .appleOnDevice {
            return OnDeviceAI.unavailableReason ?? "Apple Intelligence isn't available right now."
        }
        if config.categorizer == .automatic {
            return "Apple Intelligence isn't available on this iPhone (\(OnDeviceAI.unavailableReason ?? "unavailable")). Set up a cloud AI provider and API key in Settings instead."
        }
        return "Set up an AI provider and API key in Settings first."
    }

    // MARK: Prompt

    static let systemPrompt = """
    You sort card payments into a person's monthly budgets for Spaar, a budgeting app in South Africa (amounts in rand).
    Pick the single budget the payment most likely belongs to.
    Use how this person sorted the same or similar merchants before; their corrections of earlier AI guesses matter most.
    If nothing fits well, or you are unsure, answer with an empty budget.
    Reply with only a JSON object, no other text:
    {"budget": "<one budget name exactly as listed, or empty string>", "confidence": <number 0 to 1>, "reason": "<at most 12 words>"}
    """

    static func buildPrompt(
        payment: Payment,
        budgets: [Budget],
        history: [Payment],
        historyLimit: Int = AutoCategorizer.historyLimit,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> CategorizationPrompt {
        var lines: [String] = []
        lines.append("Budgets (name: amount left this month of monthly amount):")
        for b in budgets {
            lines.append("- \(b.name): \(Money.plain(cents: b.leftCents(now: now, calendar: calendar))) of \(Money.plain(cents: b.monthlyCents))")
        }

        let corrections = history.filter { !$0.aiOriginalBudgetName.isEmpty && $0.budget != nil }
        if !corrections.isEmpty {
            lines.append("")
            lines.append("Corrections (the AI guessed wrong, the person chose):")
            for p in corrections.prefix(min(20, historyLimit)) {
                lines.append("- \(p.displayMerchant): AI said \(p.aiOriginalBudgetName), correct is \(p.budget?.name ?? "")")
            }
        }

        let trusted = history.filter { $0.budget != nil && $0.assignment != .ai }
        if !trusted.isEmpty {
            lines.append("")
            lines.append("Recent payments sorted by the person (date | merchant | amount | budget):")
            for p in trusted.prefix(max(0, historyLimit)) {
                lines.append("- \(DataExport.dayString(p.date, calendar: calendar)) | \(p.displayMerchant) | \(Money.plain(cents: p.amountCents)) | \(p.budget?.name ?? "")")
            }
        }

        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_ZA")
        formatter.dateFormat = "EEEE d MMMM yyyy, HH:mm"

        lines.append("")
        lines.append("New payment to sort:")
        lines.append("- Merchant: \(payment.displayMerchant)")
        lines.append("- Amount: R\(Money.plain(cents: payment.amountCents))")
        lines.append("- When: \(formatter.string(from: payment.date))")

        return CategorizationPrompt(system: systemPrompt, user: lines.joined(separator: "\n"), budgetNames: budgets.map(\.name))
    }

    // MARK: Parse

    /// Reads the model's JSON, tolerating code fences or text around it.
    /// Returns nil if it's unusable or names a budget that doesn't exist.
    static func parse(_ text: String, budgetNames: [String]) -> Suggestion? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else { return nil }
        let json = String(text[start...end])
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return nil }
        let raw = (object["budget"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty,
              let name = budgetNames.first(where: { $0.compare(raw, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame })
        else { return nil }
        let confidence: Double
        if let d = object["confidence"] as? Double { confidence = d }
        else if let s = object["confidence"] as? String, let d = Double(s) { confidence = d }
        else { confidence = 0 }
        return Suggestion(budgetName: name, confidence: min(1, max(0, confidence)), reason: object["reason"] as? String ?? "")
    }

    // MARK: Run

    /// Asks the model about one unassigned payment and assigns it if confident.
    @discardableResult
    static func categorize(
        _ payment: Payment,
        client: LLMCompleting,
        in context: ModelContext,
        now: Date = .now,
        calendar: Calendar = .current
    ) async -> Result {
        guard payment.budget == nil else { return .unsure }
        let budgets: [Budget]
        let history: [Payment]
        do {
            budgets = try BudgetService.activeBudgets(in: context)
            let paymentID = payment.id
            var descriptor = FetchDescriptor<Payment>(
                predicate: #Predicate { $0.id != paymentID },
                sortBy: [SortDescriptor(\.date, order: .reverse)]
            )
            descriptor.fetchLimit = 300
            history = try context.fetch(descriptor).filter { $0.budget != nil }
        } catch {
            return .failed(error.localizedDescription)
        }
        guard !budgets.isEmpty else { return .unsure }

        let prompt = buildPrompt(payment: payment, budgets: budgets, history: history, historyLimit: client.maxHistory, now: now, calendar: calendar)
        payment.aiAttempted = true
        let text: String
        do {
            text = try await client.complete(prompt)
        } catch {
            // Busy, throttled or offline: try again next time the app opens.
            if isTransient(error) { payment.aiAttempted = false }
            try? context.save()
            return .failed(error.localizedDescription)
        }

        // You may have assigned it yourself while we waited.
        guard payment.budget == nil,
              let suggestion = parse(text, budgetNames: prompt.budgetNames),
              suggestion.confidence >= confidenceThreshold,
              let budget = budgets.first(where: { $0.name == suggestion.budgetName })
        else {
            try? context.save()
            return .unsure
        }

        payment.budget = budget
        payment.assignment = .ai
        payment.aiReason = suggestion.reason
        try? context.save()
        return .assigned(budget, suggestion)
    }

    static func isTransient(_ error: Error) -> Bool {
        if let error = error as? LLMError {
            switch error {
            case .temporarilyUnavailable: return true
            case .http(let status, _): return HTTPLLMClient.isRetryable(status: status)
            default: return false
            }
        }
        if let error = error as? URLError { return HTTPLLMClient.isRetryable(error) }
        return false
    }

    /// Tries every unassigned payment not yet sent to the AI (or all
    /// unassigned ones if `retryAll`). Returns how many got a budget.
    @discardableResult
    static func categorizePending(retryAll: Bool = false, client: LLMCompleting? = nil, in context: ModelContext) async -> Int {
        guard let client = client ?? clientFromSettings() else { return 0 }
        let descriptor = FetchDescriptor<Payment>(sortBy: [SortDescriptor(\.date, order: .reverse)])
        let pending = ((try? context.fetch(descriptor)) ?? [])
            .filter { $0.budget == nil && (retryAll || !$0.aiAttempted) }
        var assigned = 0
        for payment in pending.prefix(50) {
            let result = await categorize(payment, client: client, in: context)
            if case .assigned = result { assigned += 1 }
            // Busy or offline: stop here and leave the rest for next time.
            if case .failed = result, !payment.aiAttempted { break }
        }
        return assigned
    }
}

/// Changing a payment's budget by hand. Keeps track of AI corrections.
@MainActor
enum PaymentAssignment {
    static func assign(_ payment: Payment, to budget: Budget?) {
        guard payment.budget?.id != budget?.id else { return }
        if payment.assignment.isAI || payment.assignment == .imported, let old = payment.budget {
            payment.aiOriginalBudgetName = old.name
        }
        payment.budget = budget
        payment.assignment = budget == nil ? .unassigned : .manual
    }

    /// "Looks right": keeps the AI's choice and marks it as checked by you.
    static func confirmAI(_ payment: Payment) {
        if payment.assignment == .ai { payment.assignment = .aiConfirmed }
    }
}
