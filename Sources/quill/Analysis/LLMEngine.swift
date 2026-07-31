import Foundation

/// A large-language-model backend for the analyzer. Implementations are
/// prepared lazily (connection setup) when the analysis queue has work and
/// released when it drains — mirroring `TranscriptionEngine` so quill never
/// idles holding open connections or loaded weights.
///
/// Today only `OpenAIEngine` ships (any OpenAI-compatible endpoint: Ollama,
/// OpenRouter, OpenAI itself). The protocol exists so future backends — a
/// native Ollama `/api/chat` client, an MLX-local model, Anthropic — can slot
/// in without touching the analyzer.
protocol LLMEngine: Sendable {
    /// Short engine identifier recorded in analysis provenance.
    var name: String { get }
    func prepare() async throws
    /// Send a prompt with an optional system instruction and return the
    /// model's text response (already cleaned of chat-template artifacts).
    func complete(_ prompt: String, systemPrompt: String) async throws -> String
    func release() async
}
