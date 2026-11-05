import XCTest
import SwiftData
@testable import Envelope

private struct ThrowingClient: LLMCompleting {
    let error: Error
    func complete(_ prompt: CategorizationPrompt) async throws -> String { throw error }
}

private struct SmallModelClient: LLMCompleting {
    var maxHistory: Int { 25 }
    func complete(_ prompt: CategorizationPrompt) async throws -> String { "{}" }
}

@MainActor
final class OnDeviceAITests: XCTestCase {
    private let cal = TestCalendar.utc
    private var savedConfig: Data?

    override func setUp() async throws {
        savedConfig = UserDefaults.standard.data(forKey: AIConfig.defaultsKey)
    }

    override func tearDown() async throws {
        if let savedConfig {
            UserDefaults.standard.set(savedConfig, forKey: AIConfig.defaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: AIConfig.defaultsKey)
        }
    }

    func testAppleIntelligenceIsTheDefaultWhenAvailable() {
        let config = AIConfig()
        XCTAssertTrue(config.enabled, "on by default: works with no setup on Apple Intelligence iPhones")
        XCTAssertEqual(config.categorizer, .automatic)
        XCTAssertEqual(config.resolvedCategorizer(appleAvailable: true), .appleOnDevice)
        XCTAssertEqual(config.resolvedCategorizer(appleAvailable: false), .cloud)
        var cloud = config
        cloud.categorizer = .cloud
        XCTAssertEqual(cloud.resolvedCategorizer(appleAvailable: true), .cloud, "your explicit choice wins")
        XCTAssertEqual(config.isOnDevice, OnDeviceAI.isAvailable)
    }

    func testSettingsFromEarlierVersionsUseAppleAutomaticallyAndKeepTheCloudProvider() throws {
        let old = #"{"enabled":true,"presetID":"openrouter","style":"openAICompatible","baseURL":"https://openrouter.ai/api/v1","model":"anthropic/claude-opus-5-5"}"#
        let config = try JSONDecoder().decode(AIConfig.self, from: Data(old.utf8))
        XCTAssertEqual(config.categorizer, .automatic)
        XCTAssertEqual(config.presetID, "openrouter")
        XCTAssertEqual(config.model, "anthropic/claude-opus-5-5")
        XCTAssertTrue(config.enabled)
    }

    func testAppleAsAProviderFromYesterdaysBuildIsMovedOver() throws {
        let old = #"{"enabled":true,"presetID":"apple","style":"appleOnDevice","baseURL":"","model":""}"#
        let config = try JSONDecoder().decode(AIConfig.self, from: Data(old.utf8))
        XCTAssertEqual(config.categorizer, .appleOnDevice)
        XCTAssertEqual(config.presetID, "anthropic", "cloud provider reset to Claude for imports")
        XCTAssertEqual(config.style, .anthropic)
        XCTAssertTrue(config.cloudIsConfigured)
    }

    func testUnknownPresetFallsBackToClaude() {
        XCTAssertEqual(AIPreset.named("nope").id, "anthropic")
        XCTAssertFalse(AIPreset.all.contains { $0.style == .appleOnDevice }, "Apple is chosen separately, not as a cloud provider")
        XCTAssertFalse(AIAPIStyle.httpStyles.contains(.appleOnDevice))
    }

    func testOnDeviceIsNeverSentOverHTTP() {
        var config = AIConfig()
        config.style = .appleOnDevice
        let prompt = CategorizationPrompt(system: "s", user: "u", budgetNames: ["Food"])
        XCTAssertThrowsError(try HTTPLLMClient.makeRequest(config: config, apiKey: "", prompt: prompt, timeout: 5, structured: true))
    }

    func testAvailabilityCheckDoesNotCrash() {
        // The CI simulator may or may not have Apple Intelligence; either way
        // the check must answer, and a client exists exactly when it's available.
        let reason = OnDeviceAI.unavailableReason
        XCTAssertEqual(OnDeviceAI.makeClient() == nil, reason != nil)
    }

    func testStatementImportUsesTheCloudProviderEvenWhenAppleSorts() {
        var config = AIConfig()
        config.categorizer = .appleOnDevice
        config.apply(AIPreset.named("local"))   // needs no key
        config.model = "llama3.2"
        config.save()
        XCTAssertNotNil(StatementImporter.fromSettings())
        config.model = ""
        config.save()
        XCTAssertNil(StatementImporter.fromSettings(), "no cloud model set up")
    }

    func testSmallModelsGetAShorterHistory() throws {
        let container = try Persistence.inMemory()
        let context = container.mainContext
        let food = try BudgetService.addBudget(name: "Food", monthlyCents: 300_000, in: context)
        var history: [Payment] = []
        for i in 0..<40 {
            let p = Payment(amountCents: 1_000 + i, merchant: "Shop \(i)", card: "", date: TestCalendar.date(2026, 10, 1), source: .manual)
            context.insert(p)
            p.budget = food
            history.append(p)
        }
        let new = Payment(amountCents: 500, merchant: "Spar", card: "", date: TestCalendar.date(2026, 10, 2), source: .shortcut)
        let prompt = AutoCategorizer.buildPrompt(payment: new, budgets: [food], history: history,
                                                 historyLimit: SmallModelClient().maxHistory, calendar: cal)
        let lines = prompt.user.split(separator: "\n").filter { $0.contains(" | Food") }
        XCTAssertEqual(lines.count, 25)
        XCTAssertEqual(ThrowingClient(error: LLMError.refused).maxHistory, 80, "cloud models keep the long history")
    }

    func testBusyModelIsRetriedLaterButAWrongKeyIsNot() async throws {
        let container = try Persistence.inMemory()
        let context = container.mainContext
        _ = try BudgetService.addBudget(name: "Food", monthlyCents: 300_000, in: context)

        let busy = try PaymentProcessor.process(amountText: "R 10.00", merchant: "Spar", card: "", source: .shortcut,
                                                now: TestCalendar.date(2026, 10, 1), in: context, calendar: cal).payment
        _ = await AutoCategorizer.categorize(busy, client: ThrowingClient(error: LLMError.temporarilyUnavailable("busy")), in: context, calendar: cal)
        XCTAssertFalse(busy.aiAttempted, "throttled in the background: retried when Tally opens")

        let badKey = try PaymentProcessor.process(amountText: "R 20.00", merchant: "Engen", card: "", source: .shortcut,
                                                  now: TestCalendar.date(2026, 10, 2), in: context, calendar: cal).payment
        _ = await AutoCategorizer.categorize(badKey, client: ThrowingClient(error: LLMError.http(401, "bad key")), in: context, calendar: cal)
        XCTAssertTrue(badKey.aiAttempted)

        XCTAssertTrue(AutoCategorizer.isTransient(LLMError.http(529, "overloaded")))
        XCTAssertTrue(AutoCategorizer.isTransient(URLError(.notConnectedToInternet)))
        XCTAssertFalse(AutoCategorizer.isTransient(LLMError.refused))
    }
}

private final class BusyClient: LLMCompleting {
    var calls = 0
    func complete(_ prompt: CategorizationPrompt) async throws -> String {
        calls += 1
        throw LLMError.temporarilyUnavailable("busy")
    }
}

@MainActor
final class OnDeviceMessagesTests: XCTestCase {
    func testMessageNamesTheRealProblem() {
        let saved = UserDefaults.standard.data(forKey: AIConfig.defaultsKey)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: AIConfig.defaultsKey) }
            else { UserDefaults.standard.removeObject(forKey: AIConfig.defaultsKey) }
        }
        var config = AIConfig()
        config.categorizer = .appleOnDevice
        config.save()
        XCTAssertFalse(AutoCategorizer.clientUnavailableMessage().contains("API key"))
        config.categorizer = .cloud
        config.save()
        XCTAssertTrue(AutoCategorizer.clientUnavailableMessage().contains("API key"))
        config.enabled = false
        config.save()
        XCTAssertTrue(AutoCategorizer.clientUnavailableMessage().contains("Turn on"))
    }

    func testBatchStopsWhenTheModelIsBusy() async throws {
        let container = try Persistence.inMemory()
        let context = container.mainContext
        _ = try BudgetService.addBudget(name: "Food", monthlyCents: 1, in: context)
        for i in 0..<3 {
            _ = try PaymentProcessor.process(amountText: "R \(i + 1).00", merchant: "Shop \(i)", card: "", source: .shortcut,
                                             now: TestCalendar.date(2026, 10, 1 + i), in: context)
        }
        let busy = BusyClient()
        let assigned = await AutoCategorizer.categorizePending(client: busy, in: context)
        XCTAssertEqual(assigned, 0)
        XCTAssertEqual(busy.calls, 1, "stops after the first busy answer")
    }
}
