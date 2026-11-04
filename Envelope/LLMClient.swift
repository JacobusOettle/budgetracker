import Foundation

/// What we send to a model to categorise one payment: a system prompt, a user
/// message, and the exact budget names it may answer with.
struct CategorizationPrompt: Equatable {
    let system: String
    let user: String
    let budgetNames: [String]
}

/// A general request for a JSON answer (used by the statement import).
struct LLMRequest {
    let system: String
    let user: String
    /// JSON schema for structured output (Claude). Other providers get the
    /// format described in the prompt instead.
    let schema: [String: Any]?
    var maxTokens: Int = 1024
    /// Claude effort level: "low" for mechanical tasks.
    var effort: String = "low"
}

enum LLMError: LocalizedError, Equatable {
    case badURL
    case http(Int, String)
    case refused
    case emptyResponse
    /// The answer hit the output limit and was cut off.
    case truncated

    var errorDescription: String? {
        switch self {
        case .badURL: "The base URL isn't valid."
        case .http(let code, let body): "The AI provider returned \(code): \(body)"
        case .refused: "The model declined to answer."
        case .emptyResponse: "The AI provider returned no text."
        case .truncated: "The AI's answer was cut off because it was too long."
        }
    }
}

protocol LLMCompleting {
    func complete(_ prompt: CategorizationPrompt) async throws -> String
}

protocol LLMJSONCompleting {
    func completeJSON(_ request: LLMRequest) async throws -> String
}

/// Talks to any provider over HTTPS: the Anthropic Messages API, or the
/// OpenAI-style /chat/completions format that almost every other provider
/// (and local servers like Ollama) supports.
struct HTTPLLMClient: LLMCompleting, LLMJSONCompleting {
    let config: AIConfig
    let apiKey: String
    var timeout: TimeInterval = 15
    var session: URLSession = .shared

    static let anthropicVersion = "2026-10-21"

    func complete(_ prompt: CategorizationPrompt) async throws -> String {
        try await completeJSON(Self.request(for: prompt))
    }

    func completeJSON(_ request: LLMRequest) async throws -> String {
        do {
            return try await send(Self.makeRequest(config: config, apiKey: apiKey, request: request, timeout: timeout, structured: true))
        } catch LLMError.http(400, _) where config.style == .anthropic {
            // Older Claude models may reject effort/structured output: retry plain.
            return try await send(Self.makeRequest(config: config, apiKey: apiKey, request: request, timeout: timeout, structured: false))
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

    static func request(for prompt: CategorizationPrompt) -> LLMRequest {
        LLMRequest(system: prompt.system, user: prompt.user, schema: schema(budgetNames: prompt.budgetNames), maxTokens: 1024, effort: "low")
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
        try makeRequest(config: config, apiKey: apiKey, request: request(for: prompt), timeout: timeout, structured: structured)
    }

    static func makeRequest(config: AIConfig, apiKey: String, request llm: LLMRequest,
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
                "max_tokens": llm.maxTokens,
                "system": llm.system,
                "messages": [["role": "user", "content": llm.user]],
            ]
            if structured {
                var output: [String: Any] = ["effort": llm.effort]
                if let schema = llm.schema {
                    output["format"] = ["type": "json_schema", "schema": schema]
                }
                b["output_config"] = output
            }
            body = b
        case .openAICompatible:
            if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
            body = [
                "model": model,
                "messages": [
                    ["role": "system", "content": llm.system],
                    ["role": "user", "content": llm.user],
                ],
            ]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }

    /// JSON schema for a categorisation answer. `budget` must be one of your
    /// budget names, or "" when unsure.
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
            let stop = json["stop_reason"] as? String
            if stop == "refusal" { throw LLMError.refused }
            if stop == "max_tokens" { throw LLMError.truncated }
            let blocks = json["content"] as? [[String: Any]] ?? []
            let text = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
            guard !text.isEmpty else { throw LLMError.emptyResponse }
            return text
        case .openAICompatible:
            let choices = json["choices"] as? [[String: Any]] ?? []
            if choices.first?["finish_reason"] as? String == "length" { throw LLMError.truncated }
            let message = choices.first?["message"] as? [String: Any]
            guard let text = message?["content"] as? String, !text.isEmpty else { throw LLMError.emptyResponse }
            return text
        }
    }
}
