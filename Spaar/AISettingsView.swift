import SwiftUI

/// Two things, set up separately:
/// - What sorts unarmed payments into budgets: Apple Intelligence by default
///   when this iPhone supports it (no key, nothing leaves the phone), or a
///   cloud provider.
/// - The cloud provider (Claude, OpenAI, OpenRouter, Gemini, a local model,
///   or anything OpenAI-compatible), used for statement imports and for
///   sorting when Apple Intelligence isn't used.
struct AISettingsView: View {
    @State private var config = AIConfig.load()
    @State private var apiKey = KeychainStore.get(AIConfig.keychainAccount) ?? ""
    @State private var testing = false
    @State private var testResult: String?
    @State private var cloudTesting = false
    @State private var cloudTestResult: String?

    private var preset: AIPreset { AIPreset.named(config.presetID) }
    private var appleReason: String? { OnDeviceAI.unavailableReason }
    private var resolved: Categorizer { config.resolvedCategorizer(appleAvailable: appleReason == nil) }

    var body: some View {
        Form {
            Section {
                Toggle("Auto-categorise payments", isOn: $config.enabled)
                if config.enabled {
                    Picker("Sort with", selection: $config.categorizer) {
                        Text("Automatic").tag(Categorizer.automatic)
                        Text("Apple Intelligence").tag(Categorizer.appleOnDevice)
                        Text("Cloud provider").tag(Categorizer.cloud)
                    }
                    status
                    Button(testing ? "Testing…" : "Test with a sample payment") {
                        Task { await testCategorising() }
                    }
                    .disabled(testing)
                    if let testResult {
                        Text(testResult).font(.footnote)
                    }
                }
            } header: {
                Text("Auto-categorise")
            } footer: {
                Text("When a payment arrives and no budget is armed, the AI picks the budget. It's marked **Auto** so you can check it, and it learns from your corrections. If it isn't sure, the payment stays Unassigned. **Automatic** uses Apple Intelligence on this iPhone when available (free, private), otherwise your cloud provider.")
            }

            Section {
                Picker("Provider", selection: Binding(
                    get: { config.presetID },
                    set: { id in
                        config.apply(AIPreset.named(id))
                        cloudTestResult = nil
                    }
                )) {
                    ForEach(AIPreset.all) { Text($0.name).tag($0.id) }
                }
                if config.presetID == "custom" {
                    Picker("API format", selection: $config.style) {
                        ForEach(AIAPIStyle.httpStyles) { Text($0.displayName).tag($0) }
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Base URL").font(.caption).foregroundStyle(.secondary)
                    TextField("https://…", text: $config.baseURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Model").font(.caption).foregroundStyle(.secondary)
                    TextField(preset.modelHint, text: $config.model)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(preset.needsKey ? "API key" : "API key (optional)").font(.caption).foregroundStyle(.secondary)
                    SecureField("Paste your key", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Button(cloudTesting ? "Testing…" : "Test cloud provider") {
                    Task { await testCloud() }
                }
                .disabled(cloudTesting || config.model.trimmingCharacters(in: .whitespaces).isEmpty)
                if let cloudTestResult {
                    Text(cloudTestResult).font(.footnote)
                }
            } header: {
                Text(resolved == .cloud && config.enabled ? "Cloud provider (imports and sorting)" : "Cloud provider (statement imports)")
            } footer: {
                Text("Needed to import bank statements, which are too big for Apple's on-device model. The key is stored in this iPhone's Keychain and only sent to the base URL above. For a model on your own computer, use its local IP address (e.g. http://192.168.1.10:11434/v1) on the same Wi-Fi.")
            }

            Section("What gets sent") {
                if config.enabled && resolved == .appleOnDevice {
                    Text("Sorting payments: nothing. Apple Intelligence runs on this iPhone, so your payments never leave it.")
                } else if config.enabled {
                    Text("Sorting payments: the merchant name, amount and time; your budget names with what's left; and up to 80 of your recent payments (merchant, amount, date, budget) plus your corrections. Card names, savings and belongings are never sent.")
                }
                Text("Importing a statement: the whole statement goes to your cloud provider. Its own privacy terms apply.")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .navigationTitle("AI")
        .onChange(of: config) { _, newValue in newValue.save() }
        .onChange(of: apiKey) { _, newValue in
            KeychainStore.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), for: AIConfig.keychainAccount)
        }
    }

    @ViewBuilder
    private var status: some View {
        switch resolved {
        case .appleOnDevice:
            if let appleReason {
                Label(appleReason, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).font(.subheadline)
            } else {
                Label("Using Apple Intelligence on this iPhone: free, and nothing is sent anywhere.", systemImage: "checkmark.shield.fill")
                    .foregroundStyle(.green).font(.subheadline)
            }
        default:
            if config.cloudIsConfigured && (!preset.needsKey || !apiKey.isEmpty) {
                Label("Using \(preset.name)\(config.categorizer == .automatic ? " (Apple Intelligence isn't available here)" : "").", systemImage: "cloud")
                    .font(.subheadline)
            } else {
                Label(config.categorizer == .automatic
                      ? "Apple Intelligence isn't available here (\(appleReason ?? "unavailable")). Set up a cloud provider below."
                      : "Set up the cloud provider below.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).font(.subheadline)
            }
        }
    }

    private static let sampleBudgets = ["Food", "Fuel", "Fun", "Home"]
    private static let samplePrompt = CategorizationPrompt(
        system: AutoCategorizer.systemPrompt,
        user: """
        Budgets (name: amount left this month of monthly amount):
        - Food: 2000.00 of 3000.00
        - Fuel: 1500.00 of 2000.00
        - Fun: 400.00 of 800.00
        - Home: 900.00 of 1000.00

        New payment to sort:
        - Merchant: Engen Sandton
        - Amount: R650.00
        """,
        budgetNames: sampleBudgets
    )

    private func run(_ client: LLMCompleting) async -> String {
        do {
            let text = try await client.complete(Self.samplePrompt)
            if let s = AutoCategorizer.parse(text, budgetNames: Self.sampleBudgets) {
                return "✅ Works. Sample \"Engen Sandton R650\" → \(s.budgetName) (\(Int(s.confidence * 100))% sure). \(s.reason)"
            }
            return "⚠️ Connected, but the reply wasn't usable: \(text.prefix(200))"
        } catch {
            return "❌ \(error.localizedDescription)"
        }
    }

    private func cloudClient() -> HTTPLLMClient {
        HTTPLLMClient(config: config, apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func testCategorising() async {
        testing = true
        defer { testing = false }
        if resolved == .appleOnDevice {
            guard let client = OnDeviceAI.makeClient() else {
                testResult = "❌ \(appleReason ?? "Apple Intelligence isn't available.")"
                return
            }
            testResult = await run(client)
        } else {
            testResult = await run(cloudClient())
        }
    }

    private func testCloud() async {
        cloudTesting = true
        defer { cloudTesting = false }
        cloudTestResult = await run(cloudClient())
    }
}
