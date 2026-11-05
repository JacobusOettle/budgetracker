import Foundation
import Security

/// Which wire format the provider speaks.
enum AIAPIStyle: String, Codable, CaseIterable, Identifiable {
    /// Anthropic Messages API (Claude).
    case anthropic
    /// OpenAI-style /chat/completions. Used by OpenAI, OpenRouter, Google
    /// Gemini's compatible endpoint, Groq, Mistral, Ollama, LM Studio and most others.
    case openAICompatible
    /// Apple's on-device model (Apple Intelligence, iOS 26+). No key, no
    /// network: nothing leaves the phone.
    case appleOnDevice

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .anthropic: "Anthropic (Claude)"
        case .openAICompatible: "OpenAI-compatible"
        case .appleOnDevice: "Apple Intelligence (on device)"
        }
    }

    /// Formats you can pick for a custom provider.
    static let httpStyles: [AIAPIStyle] = [.anthropic, .openAICompatible]
}

struct AIPreset: Identifiable, Equatable {
    let id: String
    let name: String
    let style: AIAPIStyle
    let baseURL: String
    let model: String
    let modelHint: String
    let needsKey: Bool

    static let all: [AIPreset] = [
        AIPreset(id: "anthropic", name: "Claude (Anthropic)", style: .anthropic,
                 baseURL: "https://api.anthropic.com", model: "claude-opus-5-5",
                 modelHint: "e.g. claude-opus-5-5, or claude-haiku-5-5 for cheaper", needsKey: true),
        AIPreset(id: "openai", name: "OpenAI", style: .openAICompatible,
                 baseURL: "https://api.openai.com/v1", model: "",
                 modelHint: "A model name from your OpenAI account", needsKey: true),
        AIPreset(id: "openrouter", name: "OpenRouter (any model)", style: .openAICompatible,
                 baseURL: "https://openrouter.ai/api/v1", model: "",
                 modelHint: "e.g. anthropic/claude-opus-5-5", needsKey: true),
        AIPreset(id: "gemini", name: "Google Gemini", style: .openAICompatible,
                 baseURL: "https://generativelanguage.googleapis.com/v1beta/openai", model: "",
                 modelHint: "A Gemini model name", needsKey: true),
        AIPreset(id: "local", name: "Ollama / LM Studio (your computer)", style: .openAICompatible,
                 baseURL: "http://192.168.1.10:11434/v1", model: "",
                 modelHint: "The model you pulled, e.g. llama3.2", needsKey: false),
        AIPreset(id: "custom", name: "Other (custom)", style: .openAICompatible,
                 baseURL: "", model: "", modelHint: "Model name", needsKey: false),
    ]

    static func named(_ id: String) -> AIPreset { all.first { $0.id == id } ?? all[0] }
}

/// Non-secret AI settings, stored in UserDefaults. The API key is in the Keychain.
/// Which model sorts unarmed payments into budgets.
enum Categorizer: String, Codable, CaseIterable, Identifiable {
    /// Apple Intelligence when this iPhone supports it, otherwise the cloud
    /// provider. The default.
    case automatic
    case appleOnDevice
    case cloud

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .automatic: "Automatic"
        case .appleOnDevice: "Apple Intelligence"
        case .cloud: "Cloud provider"
        }
    }
}

/// AI settings, stored in UserDefaults (the API key is in the Keychain).
/// - Categorising payments: `enabled` + `categorizer`. By default Apple
///   Intelligence is used when available (no key needed, nothing leaves the
///   phone), else the cloud provider.
/// - The cloud provider (`presetID`, `style`, `baseURL`, `model`) is used for
///   statement imports, and for categorising when Apple Intelligence isn't
///   used.
struct AIConfig: Codable, Equatable {
    /// Auto-categorise unarmed payments. On by default: with Apple
    /// Intelligence it works with no setup; without it, nothing happens until
    /// a cloud provider is set up.
    var enabled = true
    var categorizer: Categorizer = .automatic
    var presetID = "anthropic"
    var style: AIAPIStyle = .anthropic
    var baseURL = "https://api.anthropic.com"
    var model = "claude-opus-5-5"

    static let defaultsKey = "ai.config"
    static let keychainAccount = "ai.apiKey"

    init() {}

    private enum CodingKeys: String, CodingKey {
        case enabled, categorizer, presetID, style, baseURL, model
    }

    /// Reads settings saved by any earlier version.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AIConfig()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? defaults.enabled
        presetID = try c.decodeIfPresent(String.self, forKey: .presetID) ?? defaults.presetID
        style = (try? c.decodeIfPresent(AIAPIStyle.self, forKey: .style)) ?? defaults.style
        baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL) ?? defaults.baseURL
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? defaults.model
        // Saved before Apple Intelligence was the default (auto-categorise
        // was off by default then). Keeps the cloud provider for imports;
        // your later choices stick.
        if let saved = try? c.decodeIfPresent(Categorizer.self, forKey: .categorizer) {
            categorizer = saved
        } else if enabled {
            // Was already sorting with the cloud provider: Apple first now.
            categorizer = .automatic
        } else {
            // Was off: only turn on the private on-device model, never start
            // sending payments to a cloud provider you hadn't switched on.
            categorizer = .appleOnDevice
            enabled = true
        }
        // A build where Apple Intelligence was a "provider": move it over.
        if presetID == "apple" || style == .appleOnDevice {
            categorizer = .appleOnDevice
            let claude = AIPreset.named("anthropic")
            presetID = claude.id
            style = claude.style
            baseURL = claude.baseURL
            model = claude.model
        }
    }

    static func load(_ defaults: UserDefaults = .standard) -> AIConfig {
        guard let data = defaults.data(forKey: defaultsKey),
              let config = try? JSONDecoder().decode(AIConfig.self, from: data) else { return AIConfig() }
        return config
    }

    func save(_ defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
    }

    mutating func apply(_ preset: AIPreset) {
        presetID = preset.id
        style = preset.style
        baseURL = preset.baseURL
        model = preset.model
    }

    /// What actually sorts payments, given whether Apple Intelligence is ready.
    func resolvedCategorizer(appleAvailable: Bool) -> Categorizer {
        switch categorizer {
        case .automatic: appleAvailable ? .appleOnDevice : .cloud
        case .appleOnDevice, .cloud: categorizer
        }
    }

    /// Categorising runs on Apple Intelligence right now.
    var isOnDevice: Bool {
        enabled && resolvedCategorizer(appleAvailable: OnDeviceAI.isAvailable) == .appleOnDevice
    }

    /// The cloud provider has what it needs, apart from the key.
    var cloudIsConfigured: Bool {
        style != .appleOnDevice
            && !model.trimmingCharacters(in: .whitespaces).isEmpty
            && URL(string: baseURL) != nil
    }

    /// Kept for callers that check the cloud provider (e.g. statement import).
    var isUsable: Bool { enabled && cloudIsConfigured }

    var cloudProviderName: String { AIPreset.named(presetID).name }
}

/// Minimal Keychain wrapper for the API key. The item stays readable after the
/// first unlock, so payments logged while the phone is locked can still use AI.
/// It never leaves this device (no iCloud sync).
enum KeychainStore {
    static let service = "com.jacobusoettle.tally"

    static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func set(_ value: String, for account: String) -> Bool {
        delete(account)
        guard !value.isEmpty else { return true }
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: Data(value.utf8),
        ]
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func delete(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
