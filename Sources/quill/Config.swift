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
///         "prompts_dir": "~/.config/quill/prompts",
///         "modules": {
///           "summary": { "prompt": "summary.md" },
///           "action_items": { "enabled": false },
///           "risks": {
///             "title": "Risks & Blockers",
///             "filename": "Risks",
///             "prompt": "risks.md"
///           }
///         }
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

    /// Directory where prompt Markdown files live. Default
    /// `~/.config/quill/prompts`. Each module's `prompt` field is a
    /// relative path inside this dir.
    static func analysisPromptsDir() -> URL {
        let raw = analysis()?["prompts_dir"] as? String
            ?? "~/.config/quill/prompts"
        return URL(
            fileURLWithPath: (raw as NSString).expandingTildeInPath,
            isDirectory: true
        )
    }

    /// Resolve the configured modules. If `analysis.modules` is present,
    /// merge built-in defaults with config overrides and add custom
    /// modules; drop `enabled: false` entries. If absent, return all six
    /// built-ins.
    static func analysisModules() -> [AnalysisModule] {
        guard let modules = analysis()?["modules"] as? [String: Any],
              !modules.isEmpty else {
            return AnalysisModule.Builtins.all
        }
        let promptsDir = analysisPromptsDir()
        var result: [AnalysisModule] = []
        for (id, cfg) in modules {
            guard let dict = cfg as? [String: Any] else { continue }
            if dict["enabled"] as? Bool == false { continue }
            result.append(resolveModule(id: id, dict: dict, promptsDir: promptsDir))
        }
        // Preserve built-in order for known IDs; custom modules appended
        // in config order after.
        let builtinOrder = AnalysisModule.Builtins.all.map { $0.id }
        result.sort { a, b in
            let ai = builtinOrder.firstIndex(of: a.id) ?? Int.max
            let bi = builtinOrder.firstIndex(of: b.id) ?? Int.max
            return ai == bi ? a.id < b.id : ai < bi
        }
        return result
    }

    /// Merge a built-in (if the ID matches one) with config overrides, or
    /// build a custom module from scratch. `prompt` is loaded from disk if
    /// set; otherwise the built-in prompt is used.
    private static func resolveModule(
        id: String, dict: [String: Any], promptsDir: URL
    ) -> AnalysisModule {
        let builtin = AnalysisModule.Builtins.find(id)
        let title = dict["title"] as? String ?? builtin?.title ?? id.replacingOccurrences(of: "_", with: " ").capitalized
        let filename = dict["filename"] as? String ?? builtin?.filename ?? id.replacingOccurrences(of: " ", with: "_").capitalized
        let systemPrompt = dict["system_prompt"] as? String ?? builtin?.systemPrompt ?? AnalysisModule.Builtins.systemPrompt

        var prompt = builtin?.prompt ?? ""
        if let promptFile = dict["prompt"] as? String, !promptFile.isEmpty {
            do {
                prompt = try Prompts.loadPromptFile(promptFile, promptsDir: promptsDir)
            } catch {
                FileHandle.standardError.write(Data(
                    "warning: \(error) — using built-in prompt for \"\(id)\"\n".utf8
                ))
            }
        }
        return AnalysisModule(
            id: id,
            title: title,
            filename: filename,
            prompt: prompt,
            systemPrompt: systemPrompt
        )
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

    /// Apple voice processing (acoustic echo cancellation) on the mic.
    /// No longer honoured: it lives on `AVAudioEngine`, which `MicRecorder`
    /// abandoned because it cannot open an input device that isn't backed by
    /// the default output (rca-002). Still read so a config that sets it gets
    /// a warning instead of silently different behaviour.
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
