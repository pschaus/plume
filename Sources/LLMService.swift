import Foundation

enum LLMError: LocalizedError {
    case missingAPIKey(LLMProvider)
    case invalidURL
    case httpError(Int, String)
    case emptyResponse
    case decodingError(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey(let provider):
            return "Missing API key for \(provider.rawValue). Open Settings (⌘,) to enter your key or switch to Ollama (Local)."
        case .invalidURL:
            return "Invalid API endpoint URL."
        case .httpError(let code, let body):
            return "HTTP \(code): \(body.prefix(240))"
        case .emptyResponse:
            return "Model returned an empty response."
        case .decodingError(let details):
            return "Failed to parse JSON response: \(details)"
        }
    }
}

final class LLMService: Sendable {
    static let shared = LLMService()

    private let systemInstruction = """
    You are Plume, a precise, multilingual spell, grammar, and style checker integrated into Apple Mail.
    Analyze the user's email text carefully:
    1. Automatically detect the primary language of the text (e.g. "French", "English", "Spanish", "German", "Dutch") and provide its 2-letter ISO code or flag emoji in `languageFlag`.
    2. Identify EVERY:
       - "spelling": typos, misspellings, wrong verb conjugations (e.g. "envoyerai" -> "enverrai", "beaucoups" -> "beaucoup", "recieve" -> "receive").
       - "grammar": plural/singular agreement, gender agreement, missing articles, wrong prepositions, punctuation errors (e.g. "les document" -> "les documents", "a apple" -> "an apple").
       - "style": awkward phrasing or clarity improvements (only when clearly helpful).
    3. CRITICAL RULES:
       - `original` MUST be an EXACT substring copied verbatim from the user's input text. Include 1-2 surrounding words if needed to disambiguate (for example, "les document" -> "les documents").
       - `suggestion` MUST be the exact replacement for `original`.
       - `explanation` MUST be concise (1 short sentence) written in the same language as the detected text.
       - Never include an issue where `original` and `suggestion` are identical.
       - Respond ONLY with valid JSON matching the schema.
    """

    private var jsonSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "detectedLanguage": [
                    "type": "string",
                    "description": "Name of the detected language (e.g. French, English)."
                ],
                "languageFlag": [
                    "type": "string",
                    "description": "Flag emoji or 2-letter ISO code (e.g. 🇫🇷, 🇬🇧, fr, en)."
                ],
                "issues": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "original": [
                                "type": "string",
                                "description": "Exact verbatim substring from the input text containing the error."
                            ],
                            "suggestion": [
                                "type": "string",
                                "description": "Exact replacement string for `original`."
                            ],
                            "type": [
                                "type": "string",
                                "enum": ["spelling", "grammar", "style"]
                            ],
                            "explanation": [
                                "type": "string",
                                "description": "Brief 1-sentence explanation of the correction."
                            ]
                        ],
                        "required": ["original", "suggestion", "type", "explanation"]
                    ]
                ]
            ],
            "required": ["detectedLanguage", "languageFlag", "issues"]
        ]
    }

    func checkText(
        _ text: String,
        provider: LLMProvider,
        model: String,
        apiKey: String,
        ollamaEndpoint: String = "http://localhost:11434"
    ) async throws -> SpellCheckResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .empty
        }

        if provider.requiresAPIKey && apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw LLMError.missingAPIKey(provider)
        }

        let rawJSON: String
        switch provider {
        case .gemini:
            rawJSON = try await callGeminiInteractions(text: text, model: model, apiKey: apiKey)
        case .anthropic:
            rawJSON = try await callAnthropic(text: text, model: model, apiKey: apiKey)
        case .openai:
            rawJSON = try await callOpenAICompatible(
                endpoint: "https://api.openai.com/v1/chat/completions",
                text: text,
                model: model,
                apiKey: apiKey,
                extraHeaders: [:]
            )
        case .openrouter:
            rawJSON = try await callOpenAICompatible(
                endpoint: "https://openrouter.ai/api/v1/chat/completions",
                text: text,
                model: model,
                apiKey: apiKey,
                extraHeaders: [
                    "HTTP-Referer": "https://github.com/pschaus/plume",
                    "X-Title": "Plume"
                ]
            )
        case .ollama:
            rawJSON = try await callOllama(text: text, model: model, endpoint: ollamaEndpoint)
        }

        let cleanedJSON = extractJSONObject(from: rawJSON)
        guard let data = cleanedJSON.data(using: .utf8) else {
            throw LLMError.decodingError("Invalid UTF-8 in response")
        }

        do {
            var result = try JSONDecoder().decode(SpellCheckResult.self, from: data)
            // Keep only genuine issues whose `original` exists in `text` (matching smart quotes/spaces) and differs from `suggestion`
            var matchedIssues: [SpellIssue] = []
            for var issue in result.issues {
                guard !issue.original.isEmpty, issue.original != issue.suggestion else { continue }
                if let range = MailHTMLPreserver.findBestMatchRange(of: issue.original, in: text) {
                    let exactOriginal = String(text[range])
                    guard exactOriginal != issue.suggestion else { continue }
                    issue.original = exactOriginal
                    matchedIssues.append(issue)
                }
            }
            result.issues = matchedIssues
            return result
        } catch {
            throw LLMError.decodingError("\(error.localizedDescription) — Raw: \(cleanedJSON.prefix(200))")
        }
    }

    // MARK: - 1. Google Gemini (Interactions API v1beta/interactions)

    private func callGeminiInteractions(text: String, model: String, apiKey: String) async throws -> String {
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/interactions") else {
            throw LLMError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2026-05-20", forHTTPHeaderField: "Api-Revision")

        let body: [String: Any] = [
            "model": model,
            "system_instruction": systemInstruction,
            "input": "Check the following email text and return JSON:\n\n\(text)",
            "store": false,
            "response_format": [
                "type": "text",
                "mime_type": "application/json",
                "schema": jsonSchema
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw LLMError.emptyResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let errBody = String(data: data, encoding: .utf8) ?? ""
            throw LLMError.httpError(http.statusCode, errBody)
        }

        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMError.emptyResponse
        }

        // Parse Interactions API `steps` array -> trailing `model_output` step -> `content[0].text`
        if let steps = root["steps"] as? [[String: Any]] {
            for step in steps.reversed() {
                if (step["type"] as? String) == "model_output",
                   let content = step["content"] as? [[String: Any]] {
                    let combined = content.compactMap { $0["text"] as? String }.joined()
                    if !combined.isEmpty {
                        return combined
                    }
                }
            }
        }

        if let outputText = root["output_text"] as? String, !outputText.isEmpty {
            return outputText
        }

        throw LLMError.emptyResponse
    }

    // MARK: - 2. Anthropic Claude (/v1/messages)

    private func callAnthropic(text: String, model: String, apiKey: String) async throws -> String {
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            throw LLMError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let schemaString: String
        if let schemaData = try? JSONSerialization.data(withJSONObject: jsonSchema),
           let str = String(data: schemaData, encoding: .utf8) {
            schemaString = str
        } else {
            schemaString = "{}"
        }

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 2048,
            "system": "\(systemInstruction)\n\nJSON Schema:\n\(schemaString)",
            "messages": [
                [
                    "role": "user",
                    "content": "Check this email text and return ONLY the JSON object:\n\n\(text)"
                ]
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw LLMError.emptyResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let errBody = String(data: data, encoding: .utf8) ?? ""
            throw LLMError.httpError(http.statusCode, errBody)
        }

        if let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let content = root["content"] as? [[String: Any]],
           let firstText = content.first(where: { ($0["type"] as? String) == "text" })?["text"] as? String {
            return firstText
        }

        throw LLMError.emptyResponse
    }

    // MARK: - 3. OpenAI & OpenRouter (/v1/chat/completions)

    private func callOpenAICompatible(
        endpoint: String,
        text: String,
        model: String,
        apiKey: String,
        extraHeaders: [String: String]
    ) async throws -> String {
        guard let url = URL(string: endpoint) else {
            throw LLMError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in extraHeaders {
            request.setValue(v, forHTTPHeaderField: k)
        }

        let schemaString: String
        if let schemaData = try? JSONSerialization.data(withJSONObject: jsonSchema),
           let str = String(data: schemaData, encoding: .utf8) {
            schemaString = str
        } else {
            schemaString = "{}"
        }

        let body: [String: Any] = [
            "model": model,
            "response_format": ["type": "json_object"],
            "messages": [
                [
                    "role": "system",
                    "content": "\(systemInstruction)\n\nRequired JSON Schema:\n\(schemaString)"
                ],
                [
                    "role": "user",
                    "content": text
                ]
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw LLMError.emptyResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let errBody = String(data: data, encoding: .utf8) ?? ""
            throw LLMError.httpError(http.statusCode, errBody)
        }

        if let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let choices = root["choices"] as? [[String: Any]],
           let message = choices.first?["message"] as? [String: Any],
           let content = message["content"] as? String {
            return content
        }

        throw LLMError.emptyResponse
    }

    // MARK: - 4. Ollama Local (/api/chat)

    private func callOllama(text: String, model: String, endpoint: String) async throws -> String {
        let base = endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(base)/api/chat") else {
            throw LLMError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let clippedText = text.count > 4000 ? String(text.prefix(4000)) : text
        let body: [String: Any] = [
            "model": model,
            "stream": false,
            "think": false,
            "format": jsonSchema,
            "options": [
                "temperature": 0.0,
                "num_predict": 1024
            ],
            "messages": [
                [
                    "role": "system",
                    "content": systemInstruction
                ],
                [
                    "role": "user",
                    "content": clippedText
                ]
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw LLMError.emptyResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let errBody = String(data: data, encoding: .utf8) ?? ""
            throw LLMError.httpError(http.statusCode, errBody)
        }

        if let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let message = root["message"] as? [String: Any],
           let content = message["content"] as? String {
            return content
        }

        throw LLMError.emptyResponse
    }

    // MARK: - Helper to strip markdown code fences if present

    private func extractJSONObject(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let firstBrace = trimmed.firstIndex(of: "{"),
           let lastBrace = trimmed.lastIndex(of: "}") {
            return String(trimmed[firstBrace...lastBrace])
        }
        return trimmed
    }
}
