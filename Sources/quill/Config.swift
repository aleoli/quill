import Foundation

/// Optional user config at ~/.config/quill/config.json:
///
///     {
///       "recordings_dir": "~/Recordings",
///       "transcription": {
///         "enabled": true,
///         "engine": "parakeet",          // or "whisper"
///         "model": "large-v3-v20240930_turbo",  // whisper only
///         "language": "it"                // whisper only; omit for auto-detect
///       },
///       "analysis": {
///         "enabled": true,
///         "sections": ["summary","action_items","decisions","topics","qa","keywords"]
///       },
///       "llm": {
///         "engine": "openai",
///         "base_url": "http://localhost:11434/v1",
///         "api_key": "",
///         "model": "qwen3.6:35b",
///         "temperature": 0.2,
///         "max_tokens": 64000
///       },
///       "mic_voice_processing": true,
///       "on_stop": "my-hook"
///     }
///
/// Resolution order for the recordings root: --out flag > config file >
/// ~/Recordings. `on_stop` is a shell command spawned with the session
/// directory as its argument — after the transcript is written, or right
/// after recording when transcription is disabled.
enum Config {
    static let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/quill/config.json")

    static let defaultRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Recordings", isDirectory: true)

    /// The configured recordings root, or nil if no config file / no key.
    static func recordingsDir() -> URL? {
        guard let dir = load()?["recordings_dir"] as? String, !dir.isEmpty else { return nil }
        return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// Shell command to spawn after each session's transcript is written (or
    /// after recording, if transcription is disabled), or nil.
    static func onStop() -> String? {
        guard let cmd = load()?["on_stop"] as? String, !cmd.isEmpty else { return nil }
        return cmd
    }

    /// Whether finished recordings are transcribed automatically. Default on.
    static func transcriptionEnabled() -> Bool {
        transcription()?["enabled"] as? Bool ?? true
    }

    /// Configured engine name. "parakeet" ships as the default; "whisper"
    /// (WhisperKit / Core ML) is the multilingual fallback. Anything else
    /// warns and falls back to parakeet.
    static func transcriptionEngine() -> String {
        transcription()?["engine"] as? String ?? "parakeet"
    }

    /// WhisperKit model name (only used when engine == "whisper"). Defaults
    /// to large-v3-turbo — the best speed/accuracy balance on macOS per
    /// Argmax's recommendation. Any HuggingFace model in the
    /// `argmaxinc/whisperkit-coreml*` family works.
    static func whisperModel() -> String {
        transcription()?["model"] as? String ?? "large-v3-v20240930_turbo"
    }

    /// Optional ISO 639-1 language code (e.g. "it", "en", "fr") to force for
    /// the whisper engine. nil → Whisper auto-detects per file. Ignored by
    /// parakeet (English-only).
    static func whisperLanguage() -> String? {
        guard let lang = transcription()?["language"] as? String, !lang.isEmpty else { return nil }
        return lang
    }

    private static func transcription() -> [String: Any]? {
        load()?["transcription"] as? [String: Any]
    }

    // MARK: - Analysis

    /// Whether AI analysis runs automatically after each transcript is
    /// written. Default on — set `analysis.enabled: false` to skip.
    static func analysisEnabled() -> Bool {
        analysis()?["enabled"] as? Bool ?? true
    }

    /// Which analysis sections to generate. Defaults to all six. Values must
    /// match `AnalysisSection` raw values.
    static func llmSections() -> [AnalysisSection] {
        guard let raw = analysis()?["sections"] as? [String], !raw.isEmpty else {
            return AnalysisSection.allCases
        }
        return raw.compactMap { AnalysisSection(rawValue: $0) }
    }

    private static func analysis() -> [String: Any]? {
        load()?["analysis"] as? [String: Any]
    }

    // MARK: - LLM

    /// Configured LLM engine name. "openai" ships today (any
    /// OpenAI-compatible endpoint: Ollama, OpenRouter, OpenAI). Unknown
    /// values warn and fall back to openai.
    static func llmEngine() -> String {
        llm()?["engine"] as? String ?? "openai"
    }

    /// OpenAI-compatible base URL. Default is a local Ollama server.
    static func llmBaseURL() -> String {
        llm()?["base_url"] as? String ?? "http://localhost:11434/v1"
    }

    /// API key. nil for local Ollama (no auth needed).
    static func llmAPIKey() -> String? {
        guard let key = llm()?["api_key"] as? String, !key.isEmpty else { return nil }
        return key
    }

    /// Model name. Any string the endpoint accepts — Ollama model tags
    /// (`qwen3.6:35b`), OpenAI model IDs (`gpt-4o`), etc.
    static func llmModel() -> String {
        llm()?["model"] as? String ?? "llama3"
    }

    static func llmTemperature() -> Double {
        llm()?["temperature"] as? Double ?? 0.3
    }

    static func llmMaxTokens() -> Int {
        llm()?["max_tokens"] as? Int ?? 4096
    }

    private static func llm() -> [String: Any]? {
        load()?["llm"] as? [String: Any]
    }

    /// Apple voice processing (acoustic echo cancellation) on the mic, so
    /// speaker playback doesn't bleed into the mic track and get transcribed
    /// as "me". Default off — the live voice unit ducks all other playback,
    /// and on headphones there's no echo to cancel anyway. Set true when
    /// recording meetings through the speakers.
    static func micVoiceProcessing() -> Bool {
        load()?["mic_voice_processing"] as? Bool ?? false
    }

    /// Parse the config file. A malformed config is reported on stderr rather
    /// than silently ignored — recordings landing in an unexpected place is
    /// worse than a warning.
    private static func load() -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        guard
            let data = try? Data(contentsOf: path),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            FileHandle.standardError.write(Data(
                "warning: \(path.path) is not valid JSON — ignoring config\n".utf8
            ))
            return nil
        }
        return json
    }

    /// Resolve the recordings root from an optional CLI override.
    static func resolveRoot(cliOverride: String?) -> URL {
        if let cliOverride {
            return URL(
                fileURLWithPath: (cliOverride as NSString).expandingTildeInPath,
                isDirectory: true
            )
        }
        return recordingsDir() ?? defaultRoot
    }
}
