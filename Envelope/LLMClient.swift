import Foundation

/// What we send to a model: a system prompt, a user message, and the exact
/// budget names it may answer with.
struct CategorizationPrompt: Equatable {
    let system: String
    let user: String
    let budgetNames: [String]
}

enum LLMError: LocalizedError {
    case badURL
    case http(Int, String)
    case refused
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .badURL: "The base URL isn't valid."
        case .http(let code, let body): "The AI provider returned \(code): \(body)"
        case .refused: "The model declined to answer."
        case .emptyResponse: "The AI provider returned no text."
        }
    }
}

protocol LLMCompleting {
    func complete(_ prompt: CategorizationPrompt) async throws -> String
}

/// Talks to any provider over HTTPS: the Anthropic Messages API, or the
/// OpenAI-style /chat/completions format that almost every other provider
/// (and local servers like Ollama) supports.
struct HTTPLLMClient: LLMCompleting {
    let config: AIConfig
    let apiKey: String
    var timeout: TimeInterval = 15
    var session: URLSession = .shared

    static let anthropicVersion = "2026-10-21"

    func complete(_ prompt: CategorizationPrompt) async throws -> String {
        do {
            return try await send(Self.makeRequest(config: config, apiKey: apiKey, prompt: prompt, timeout: timeout, structured: true))
        } catch LLMError.http(400, _) where config.style == .anthropic {
            // Older Claude models may reject effort/structured output: retry plain.
            return try await send(Self.makeRequest(config: config, apiKey: apiKey, prompt: prompt, timeout: timeout, structured: false))
        }
    }

    private func send(_ request: URLRequest) async throws -> String {
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let body = String(decoding: data.prefix(300), as: UTF8.self)
            throw LLMError.http(status, body)
        }
        return try Self.extractText(style: config.style, data: data)
    }

    static func endpoint(for config: AIConfig) throws -> URL {
        var base = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        let path: String
        switch config.style {
        case .anthropic: path = base.hasSuffix("/v1") ? "/messages" : "/v1/messages"
        case .openAICompatible: path = "/chat/completions"
        }
        guard let url = URL(string: base + path), url.scheme == "https" || url.scheme == "http" else {
            throw LLMError.badURL
        }
        return url
    }

    static func makeRequest(config: AIConfig, apiKey: String, prompt: CategorizationPrompt,
                            timeout: TimeInterval, structured: Bool) throws -> URLRequest {
        var request = URLRequest(url: try endpoint(for: config), timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        let model = config.model.trimmingCharacters(in: .whitespaces)
        let body: [String: Any]

        switch config.style {
        case .anthropic:
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
            var b: [String: Any] = [
                "model": model,
                "max_tokens": 1024,
                "system": prompt.system,
                "messages": [["role": "user", "content": prompt.user]],
            ]
            if structured {
                b["output_config"] = [
                    "effort": "low",
                    "format": ["type": "json_schema", "schema": schema(budgetNames: prompt.budgetNames)],
                ]
            }
            body = b
        case .openAICompatible:
            if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
            body = [
                "model": model,
                "messages": [
                    ["role": "system", "content": prompt.system],
                    ["role": "user", "content": prompt.user],
                ],
            ]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }

    /// JSON schema for the answer. `budget` must be one of your budget names,
    /// or "" when unsure.
    static func schema(budgetNames: [String]) -> [String: Any] {
        [
            "type": "object",
            "properties": [
                "budget": ["type": "string", "enum": budgetNames + [""]],
                "confidence": ["type": "number"],
                "reason": ["type": "string"],
            ],
            "required": ["budget", "confidence", "reason"],
            "additionalProperties": false,
        ]
    }

    static func extractText(style: AIAPIStyle, data: Data) throws -> String {
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        switch style {
        case .anthropic:
            if json["stop_reason"] as? String == "refusal" { throw LLMError.refused }
            let blocks = json["content"] as? [[String: Any]] ?? []
            let text = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
            guard !text.isEmpty else { throw LLMError.emptyResponse }
            return text
        case .openAICompatible:
            let choices = json["choices"] as? [[String: Any]] ?? []
            let message = choices.first?["message"] as? [String: Any]
            guard let text = message?["content"] as? String, !text.isEmpty else { throw LLMError.emptyResponse }
            return text
        }
    }
}
