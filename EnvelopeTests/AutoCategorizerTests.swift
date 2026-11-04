import XCTest
import SwiftData
@testable import Envelope

private struct FakeClient: LLMCompleting {
    var reply: String = ""
    var error: Error?
    func complete(_ prompt: CategorizationPrompt) async throws -> String {
        if let error { throw error }
        return reply
    }
}

private final class RecordingClient: LLMCompleting {
    var prompts: [CategorizationPrompt] = []
    let reply: String
    init(reply: String) { self.reply = reply }
    func complete(_ prompt: CategorizationPrompt) async throws -> String {
        prompts.append(prompt)
        return reply
    }
}

@MainActor
final class AutoCategorizerTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext { container.mainContext }
    private let cal = TestCalendar.utc
    private var t0: Date { TestCalendar.date(2026, 11, 4) }

    override func setUp() async throws {
        container = try Persistence.inMemory()
    }

    private func unassigned(_ merchant: String = "Engen Sandton", _ amount: String = "R 650.00", at date: Date? = nil) throws -> Payment {
        try PaymentProcessor.process(amountText: amount, merchant: merchant, card: "FNB", source: .shortcut, now: date ?? t0, in: context, calendar: cal).payment
    }

    // MARK: Parsing

    func testParsePlainJSON() {
        let s = AutoCategorizer.parse(#"{"budget":"Fuel","confidence":0.92,"reason":"Petrol station"}"#, budgetNames: ["Food", "Fuel"])
        XCTAssertEqual(s, .init(budgetName: "Fuel", confidence: 0.92, reason: "Petrol station"))
    }

    func testParseToleratesFencesProseAndCase() {
        let text = "Sure!\n```json\n{\"budget\": \"fuel\", \"confidence\": \"0.8\", \"reason\": \"x\"}\n```"
        XCTAssertEqual(AutoCategorizer.parse(text, budgetNames: ["Food", "Fuel"])?.budgetName, "Fuel")
    }

    func testParseRejectsUnknownEmptyOrGarbage() {
        XCTAssertNil(AutoCategorizer.parse(#"{"budget":"Groceries","confidence":0.9}"#, budgetNames: ["Food"]))
        XCTAssertNil(AutoCategorizer.parse(#"{"budget":"","confidence":0.9}"#, budgetNames: ["Food"]))
        XCTAssertNil(AutoCategorizer.parse("no idea", budgetNames: ["Food"]))
    }

    // MARK: Categorising

    func testConfidentAnswerAssignsAndMarksAsAuto() async throws {
        let fuel = try BudgetService.addBudget(name: "Fuel", monthlyCents: 200_000, now: t0, in: context)
        _ = try BudgetService.addBudget(name: "Food", monthlyCents: 300_000, now: t0, in: context)
        let payment = try unassigned()

        let result = await AutoCategorizer.categorize(payment, client: FakeClient(reply: #"{"budget":"Fuel","confidence":0.9,"reason":"Petrol station"}"#), in: context, now: t0, calendar: cal)
        guard case let .assigned(budget, _) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(budget.id, fuel.id)
        XCTAssertEqual(payment.budget?.id, fuel.id)
        XCTAssertEqual(payment.assignment, .ai)
        XCTAssertEqual(payment.aiReason, "Petrol station")
        XCTAssertTrue(payment.aiAttempted)
        XCTAssertEqual(fuel.leftCents(now: t0, calendar: cal), 135_000)
    }

    func testLowConfidenceStaysUnassigned() async throws {
        _ = try BudgetService.addBudget(name: "Fuel", monthlyCents: 200_000, now: t0, in: context)
        let payment = try unassigned()
        let result = await AutoCategorizer.categorize(payment, client: FakeClient(reply: #"{"budget":"Fuel","confidence":0.4,"reason":"?"}"#), in: context, now: t0, calendar: cal)
        guard case .unsure = result else { return XCTFail() }
        XCTAssertNil(payment.budget)
        XCTAssertTrue(payment.aiAttempted)
    }

    func testFailureLeavesPaymentUnassigned() async throws {
        _ = try BudgetService.addBudget(name: "Fuel", monthlyCents: 200_000, now: t0, in: context)
        let payment = try unassigned()
        let result = await AutoCategorizer.categorize(payment, client: FakeClient(error: LLMError.http(401, "bad key")), in: context, now: t0, calendar: cal)
        guard case .failed = result else { return XCTFail() }
        XCTAssertNil(payment.budget)
    }

    func testArmedPaymentsAreNeverSentToTheAI() async throws {
        let food = try BudgetService.addBudget(name: "Food", monthlyCents: 300_000, now: t0, in: context)
        try BudgetService.arm(food, now: t0, in: context)
        let payment = try unassigned()
        XCTAssertEqual(payment.assignment, .armed)
        let client = RecordingClient(reply: #"{"budget":"Food","confidence":1,"reason":""}"#)
        guard case .unsure = await AutoCategorizer.categorize(payment, client: client, in: context, now: t0, calendar: cal) else { return XCTFail() }
        XCTAssertTrue(client.prompts.isEmpty)
    }

    func testPendingRunSkipsAlreadyAttemptedUnlessRetryingAll() async throws {
        _ = try BudgetService.addBudget(name: "Fuel", monthlyCents: 200_000, now: t0, in: context)
        let first = try unassigned("Engen", "R 100.00", at: t0)
        first.aiAttempted = true
        _ = try unassigned("Shell", "R 200.00", at: t0.addingTimeInterval(300))
        let client = RecordingClient(reply: #"{"budget":"Fuel","confidence":0.9,"reason":""}"#)
        let n = await AutoCategorizer.categorizePending(client: client, in: context)
        XCTAssertEqual(n, 1)
        XCTAssertEqual(client.prompts.count, 1)
        let all = await AutoCategorizer.categorizePending(retryAll: true, client: client, in: context)
        XCTAssertEqual(all, 1, "the attempted one is retried")
        XCTAssertNotNil(first.budget)
    }

    // MARK: Context

    func testPromptIncludesBudgetsHistoryAndCorrectionsButNotUncheckedAIGuesses() throws {
        let food = try BudgetService.addBudget(name: "Food", monthlyCents: 300_000, now: t0, in: context)
        let fun = try BudgetService.addBudget(name: "Fun", monthlyCents: 80_000, now: t0, in: context)
        let kfc = Payment(amountCents: 10_070, merchant: "KFC Wierda Park", card: "", date: t0, source: .shortcut)
        context.insert(kfc); kfc.budget = food; kfc.assignment = .armed
        let guess = Payment(amountCents: 5_000, merchant: "Ster-Kinekor", card: "", date: t0, source: .shortcut)
        context.insert(guess); guess.budget = fun; guess.assignment = .ai
        let corrected = Payment(amountCents: 9_000, merchant: "Woolworths Cafe", card: "", date: t0, source: .shortcut)
        context.insert(corrected); corrected.budget = fun; corrected.assignment = .ai
        PaymentAssignment.assign(corrected, to: food)
        try context.save()

        let new = Payment(amountCents: 12_000, merchant: "Nando's", card: "Secret Card", date: t0, source: .shortcut)
        let prompt = AutoCategorizer.buildPrompt(payment: new, budgets: [food, fun], history: [kfc, guess, corrected], now: t0, calendar: cal)

        XCTAssertEqual(prompt.budgetNames, ["Food", "Fun"])
        XCTAssertTrue(prompt.user.contains("- Food: 2809.30 of 3000.00"))
        XCTAssertTrue(prompt.user.contains("KFC Wierda Park | 100.70 | Food"))
        XCTAssertTrue(prompt.user.contains("Woolworths Cafe: AI said Fun, correct is Food"))
        XCTAssertFalse(prompt.user.contains("Ster-Kinekor"), "unchecked AI guesses aren't fed back as truth")
        XCTAssertTrue(prompt.user.contains("Merchant: Nando's"))
        XCTAssertTrue(prompt.user.contains("Amount: R120.00"))
        XCTAssertFalse(prompt.user.contains("Secret Card"), "card names are never sent")
    }

    // MARK: Corrections

    func testCorrectingAnAIChoiceRecordsIt() throws {
        let food = try BudgetService.addBudget(name: "Food", monthlyCents: 300_000, now: t0, in: context)
        let fun = try BudgetService.addBudget(name: "Fun", monthlyCents: 80_000, now: t0, in: context)
        let p = try unassigned("Mugg & Bean", "R 80.00")
        p.budget = fun; p.assignment = .ai
        PaymentAssignment.assign(p, to: food)
        XCTAssertEqual(p.assignment, .manual)
        XCTAssertEqual(p.aiOriginalBudgetName, "Fun")
    }

    func testConfirmingKeepsTheAutoMark() throws {
        let fun = try BudgetService.addBudget(name: "Fun", monthlyCents: 80_000, now: t0, in: context)
        let p = try unassigned("Ster-Kinekor", "R 120.00")
        p.budget = fun; p.assignment = .ai
        PaymentAssignment.confirmAI(p)
        XCTAssertEqual(p.assignment, .aiConfirmed)
        XCTAssertTrue(p.assignment.isAI)
        PaymentAssignment.assign(p, to: fun)
        XCTAssertEqual(p.assignment, .aiConfirmed, "re-picking the same budget changes nothing")
    }

    func testOldRowsWithoutAssignmentInferIt() {
        let p = Payment(amountCents: 100, merchant: "x", card: "", date: t0, source: .manual)
        XCTAssertEqual(p.assignment, .unassigned)
    }
}

final class HTTPLLMClientTests: XCTestCase {
    private let prompt = CategorizationPrompt(system: "sys", user: "usr", budgetNames: ["Food", "Fuel"])

    func testAnthropicRequest() throws {
        var config = AIConfig()
        config.apply(AIPreset.named("anthropic"))
        let request = try HTTPLLMClient.makeRequest(config: config, apiKey: "sk-test", prompt: prompt, timeout: 10, structured: true)
        XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "sk-test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2026-10-21")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "claude-opus-5-5")
        XCTAssertEqual(body["system"] as? String, "sys")
        XCTAssertNil(body["temperature"])
        let output = try XCTUnwrap(body["output_config"] as? [String: Any])
        XCTAssertEqual(output["effort"] as? String, "low")
        let format = try XCTUnwrap(output["format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "json_schema")
        let schema = try XCTUnwrap(format["schema"] as? [String: Any])
        let budget = try XCTUnwrap((schema["properties"] as? [String: Any])?["budget"] as? [String: Any])
        XCTAssertEqual(budget["enum"] as? [String], ["Food", "Fuel", ""])

        let plain = try HTTPLLMClient.makeRequest(config: config, apiKey: "k", prompt: prompt, timeout: 10, structured: false)
        let plainBody = try XCTUnwrap(JSONSerialization.jsonObject(with: plain.httpBody!) as? [String: Any])
        XCTAssertNil(plainBody["output_config"])
    }

    func testOpenAICompatibleRequest() throws {
        var config = AIConfig()
        config.apply(AIPreset.named("openrouter"))
        config.model = "anthropic/claude-opus-5-5"
        let request = try HTTPLLMClient.makeRequest(config: config, apiKey: "or-key", prompt: prompt, timeout: 10, structured: true)
        XCTAssertEqual(request.url?.absoluteString, "https://openrouter.ai/api/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer or-key")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        XCTAssertEqual(messages.map { $0["role"] }, ["system", "user"])
    }

    func testLocalServerWithoutKeySendsNoAuthHeader() throws {
        var config = AIConfig()
        config.apply(AIPreset.named("local"))
        config.baseURL = "http://192.168.1.5:11434/v1/"
        config.model = "llama3.2"
        let request = try HTTPLLMClient.makeRequest(config: config, apiKey: "", prompt: prompt, timeout: 10, structured: true)
        XCTAssertEqual(request.url?.absoluteString, "http://192.168.1.5:11434/v1/chat/completions")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testAnthropicBaseURLWithV1IsNotDoubled() throws {
        var config = AIConfig()
        config.baseURL = "https://proxy.example.com/v1"
        XCTAssertEqual(try HTTPLLMClient.endpoint(for: config).absoluteString, "https://proxy.example.com/v1/messages")
    }

    func testExtractText() throws {
        let anthropic = #"{"content":[{"type":"thinking","thinking":""},{"type":"text","text":"{\"budget\":\"Food\"}"}],"stop_reason":"end_turn"}"#
        XCTAssertEqual(try HTTPLLMClient.extractText(style: .anthropic, data: Data(anthropic.utf8)), #"{"budget":"Food"}"#)
        let refusal = #"{"content":[],"stop_reason":"refusal"}"#
        XCTAssertThrowsError(try HTTPLLMClient.extractText(style: .anthropic, data: Data(refusal.utf8)))
        let openai = #"{"choices":[{"message":{"role":"assistant","content":"{\"budget\":\"Fuel\"}"}}]}"#
        XCTAssertEqual(try HTTPLLMClient.extractText(style: .openAICompatible, data: Data(openai.utf8)), #"{"budget":"Fuel"}"#)
    }
}
