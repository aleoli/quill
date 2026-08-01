import Foundation
import OpenAI

/// OpenAI-compatible LLM backend (Ollama, OpenRouter, OpenAI itself) via the
/// `macpaw/OpenAI` Swift SDK. The base URL, model, and credentials come from
/// `Config.llm*`. Token is nil for local Ollama (no auth needed).
actor OpenAIEngine: LLMEngine {
    enum EngineError: Error, CustomStringConvertible {
        case notPrepared
        case emptyResponse
        case invalidBaseURL(String)

        var description: String {
            switch self {
            case .notPrepared: return "openai engine used before prepare()"
            case .emptyResponse: return "LLM returned an empty response"
            case .invalidBaseURL(let url):
                return "can't parse llm.base_url \"\(url)\" — expected http(s)://host[:port][/path]"
            }
        }
    }

    nonisolated let name = "openai"

    private let baseURL: String
    private let apiKey: String?
    private let model: String
    private let temperature: Double
    private let maxTokens: Int

    private var client: OpenAI?

    init(baseURL: String, apiKey: String?, model: String, temperature: Double, maxTokens: Int) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.temperature = temperature
        self.maxTokens = maxTokens
    }

    func prepare() async throws {
        guard client == nil else { return }
        let parsed = try Self.parseBaseURL(baseURL)
        let config = OpenAI.Configuration(
            token: apiKey,
            host: parsed.host,
            port: parsed.port,
            scheme: parsed.scheme,
            basePath: parsed.path,
            // Local models (Ollama with qwen3.6:35b) can be slow on long
            // transcripts — generous timeout like the notetaker's 600s.
            timeoutInterval: 600.0
        )
        client = OpenAI(configuration: config)
    }

    func complete(_ prompt: String, systemPrompt: String) async throws -> String {
        guard let client else { throw EngineError.notPrepared }

        let messages: [ChatQuery.ChatCompletionMessageParam] = [
            .system(.init(content: .textContent(systemPrompt))),
            .user(.init(content: .string(prompt))),
        ]
        let query = ChatQuery(
            messages: messages,
            model: Model(model),
            maxCompletionTokens: maxTokens,
            temperature: temperature
        )

        let result = try await client.chats(query: query)
        guard let content = result.choices.first?.message.content, !content.isEmpty else {
            throw EngineError.emptyResponse
        }
        return Self.clean(content)
    }

    func release() async {
        client = nil
    }

    // MARK: - URL parsing

    private struct ParsedURL {
        let scheme: String
        let host: String
        let port: Int
        let path: String
    }

    /// Parse a base URL like `http://localhost:11434/v1` into the pieces
    /// `OpenAI.Configuration` wants. Defaults: scheme https, port 443,
    /// basePath /v1 — matching the OpenAI default.
    private static func parseBaseURL(_ raw: String) throws -> ParsedURL {
        guard let url = URL(string: raw), let host = url.host else {
            throw EngineError.invalidBaseURL(raw)
        }
        let scheme = url.scheme ?? "https"
        let port = url.port ?? (scheme == "https" ? 443 : 80)
        // url.path may be empty (e.g. `http://host:11434`); default to /v1.
        let path = url.path.isEmpty ? "/v1" : url.path
        return ParsedURL(scheme: scheme, host: host, port: port, path: path)
    }

    // MARK: - Output cleaning

    /// Strip chat-template artifacts and continuations that local models
    /// (Ollama, vLLM) often emit. Ported from the notetaker's
    /// `Analyzer._clean_response`.
    private static func clean(_ text: String) -> String {
        let artifacts = [
            "<|im_start|>",
            "",
            "<|eot_id|>",
            "",
            "",
            "",
            "<|bot|>",
            "<|end|>",
            "<s>",
            "</s>",
            "Here is a summary of the transcript provided:",
        ]
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for artifact in artifacts {
            result = result.replacingOccurrences(of: artifact, with: "")
        }

        // Some models emit a multi-turn chat continuation after the answer.
        // Cut at the first role label.
        let rolePattern = try? NSRegularExpression(
            pattern: #"(?:\n|\A|\s)\s*(user|assistant|system|bot)\s*(?:\n|$)"#,
            options: .caseInsensitive
        )
        if let pattern = rolePattern {
            let range = NSRange(result.startIndex..., in: result)
            if let match = pattern.firstMatch(in: result, range: range),
               let r = Range(match.range, in: result) {
                result = String(result[..<r.lowerBound]).trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
            }
        }

        // Cut at obvious continuation markers.
        let stopPhrases = [
            "If you have a clearer version",
            "If you can provide a clearer version",
            "Please provide a clearer text",
            "I apologize for the confusion",
            "Based on the fragmented",
            "The transcript provided appears to be",
            "# Instructions:",
            "## Instructions:",
            "1. **Analyze the text**",
        ]
        for phrase in stopPhrases {
            if let idx = result.range(of: phrase) {
                result = String(result[..<idx.lowerBound]).trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
            }
        }
        return result
    }
}
