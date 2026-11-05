import SwiftUI

/// Pick any LLM provider: Claude, OpenAI, OpenRouter, Gemini, a local
/// Ollama/LM Studio, or anything else that speaks the OpenAI format.
struct AISettingsView: View {
    @State private var config = AIConfig.load()
    @State private var apiKey = KeychainStore.get(AIConfig.keychainAccount) ?? ""
    @State private var testing = false
    @State private var testResult: String?

    private var preset: AIPreset { AIPreset.named(config.presetID) }

    var body: some View {
        Form {
            Section {
                Toggle("Auto-categorise payments", isOn: $config.enabled)
            } footer: {
                Text("When a payment arrives and no budget is armed, Tally asks the AI which budget it belongs to. It's marked **Auto** so you can check it, and the AI learns from your corrections. If the AI isn't sure, the payment stays Unassigned.")
            }

            Section {
                Picker("Provider", selection: Binding(
                    get: { config.presetID },
                    set: { id in
                        config.apply(AIPreset.named(id))
                        testResult = nil
                    }
                )) {
                    ForEach(AIPreset.all) { Text($0.name).tag($0.id) }
                }
                if config.isOnDevice {
                    if let reason = OnDeviceAI.unavailableReason {
                        Label(reason, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.subheadline)
                    } else {
                        Label("Ready. Runs on this iPhone: no key, no cost, nothing sent anywhere.", systemImage: "checkmark.shield.fill")
                            .foregroundStyle(.green)
                            .font(.subheadline)
                    }
                }
                if config.presetID == "custom" {
                    Picker("API format", selection: $config.style) {
                        ForEach(AIAPIStyle.httpStyles) { Text($0.displayName).tag($0) }
                    }
                }
                if !config.isOnDevice {
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
                }
            } header: {
                Text("Provider")
            } footer: {
                if config.isOnDevice {
                    Text("Apple's on-device model is small, so it sees your last 25 sorted payments plus your corrections. If the phone is busy when a payment arrives in the background, Apple may hold the model back: the payment stays Unassigned and is sorted when you open Tally. Importing bank statements needs a cloud provider such as Claude.")
                } else {
                Text("The key is stored in this iPhone's Keychain and is only sent to the base URL above. For a model on your own computer, use its local IP address (e.g. http://192.168.1.10:11434/v1) and keep the phone on the same Wi-Fi.")
                }
            }

            Section {
                Button(testing ? "Testing…" : "Test with a sample payment") {
                    Task { await test() }
                }
                .disabled(testing || (!config.isOnDevice && config.model.trimmingCharacters(in: .whitespaces).isEmpty))
                if let testResult {
                    Text(testResult).font(.footnote)
                }
            }

            Section("What gets sent") {
                if config.isOnDevice {
                    Text("Nothing. Apple Intelligence runs on this iPhone, so your payments never leave it.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                Text("For each payment the AI sorts: the merchant name, amount and time; your budget names with what's left in them; and up to 80 of your recent payments (merchant, amount, date and budget) plus your corrections. Card names, savings and belongings are never sent. Your provider's own privacy terms apply.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("AI categorisation")
        .onChange(of: config) { _, newValue in newValue.save() }
        .onChange(of: apiKey) { _, newValue in
            KeychainStore.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), for: AIConfig.keychainAccount)
        }
    }

    private func test() async {
        testing = true
        defer { testing = false }
        let client: LLMCompleting
        if config.isOnDevice {
            guard let onDevice = OnDeviceAI.makeClient() else {
                testResult = "❌ \(OnDeviceAI.unavailableReason ?? "Apple Intelligence isn't available.")"
                return
            }
            client = onDevice
        } else {
            client = HTTPLLMClient(config: config, apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let budgets = ["Food", "Fuel", "Fun", "Home"]
        let prompt = CategorizationPrompt(
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
            budgetNames: budgets
        )
        do {
            let text = try await client.complete(prompt)
            if let s = AutoCategorizer.parse(text, budgetNames: budgets) {
                testResult = "✅ Works. Sample \"Engen Sandton R650\" → \(s.budgetName) (\(Int(s.confidence * 100))% sure). \(s.reason)"
            } else {
                testResult = "⚠️ Connected, but the reply wasn't usable JSON: \(text.prefix(200))"
            }
        } catch {
            testResult = "❌ \(error.localizedDescription)"
        }
    }
}
