import Foundation

/// Post-transcription analysis pipeline: a serial queue of session folders
/// to analyze. After a transcript is written, the coordinator runs the
/// configured `LLMEngine` over each requested section and writes an
/// Obsidian-style folder of Markdown notes. Mirrors
/// `TranscriptionCoordinator`: the engine is prepared lazily and released
/// when the queue drains, so quill never idles holding open connections.
actor AnalysisCoordinator {
    enum Status: Sendable {
        case idle
        case analyzing(session: String, section: String)
        case failed(session: String)
    }

    private var queue: [URL] = []
    private var draining = false
    private var engine: LLMEngine?
    private var statusHandler: (@Sendable (Status) -> Void)?

    func setStatusHandler(_ handler: @escaping @Sendable (Status) -> Void) {
        statusHandler = handler
    }

    /// Queue a session for analysis. No-op if analysis is disabled in config.
    func enqueue(_ sessionDir: URL) {
        guard Config.analysisEnabled() else { return }
        guard FileManager.default.fileExists(
            atPath: sessionDir.appendingPathComponent("transcript.json").path
        ) else { return }
        queue.append(sessionDir)
        drainIfIdle()
    }

    /// Analyze a single session synchronously (used by the `quill analyze`
    /// CLI subcommand). Bypasses the queue and the `analysis.enabled` check
    /// — the user asked for it explicitly.
    func analyzeSession(_ dir: URL, modules: [AnalysisModule]) async throws {
        let engine = try await preparedEngine()
        let analyzer = Analyzer(engine: engine)
        let results = try await analyzer.analyze(
            sessionDir: dir,
            modules: modules,
            onModule: { [weak self] module in
                guard let self else { return }
                await self.publish(.analyzing(session: dir.lastPathComponent, section: module.id))
                await self.log(dir, "analyzing \(module.id)")
            }
        )
        try analyzer.writeAnalysisFolder(sessionDir: dir, modules: modules, results: results)
        log(dir, "done — \(results.count) modules")
        await engine.release()
        self.engine = nil
    }

    // MARK: -

    private func drainIfIdle() {
        guard !draining, !queue.isEmpty else { return }
        draining = true
        Task { await drain() }
    }

    private func drain() async {
        while !queue.isEmpty {
            let dir = queue.removeFirst()
            do {
                try await analyze(dir)
                notifyUser(title: "quill — analysis ready", body: dir.lastPathComponent)
            } catch {
                log(dir, "analysis failed: \(error)")
                publish(.failed(session: dir.lastPathComponent))
                notifyUser(
                    title: "quill — analysis failed",
                    body: "\(dir.lastPathComponent) — see analysis.log"
                )
            }
        }
        await engine?.release()
        engine = nil
        publish(.idle)
        draining = false
        drainIfIdle()
    }

    private func analyze(_ dir: URL) async throws {
        let engine = try await preparedEngine()
        let modules = Config.analysisModules()
        let analyzer = Analyzer(engine: engine)
        let results = try await analyzer.analyze(
            sessionDir: dir,
            modules: modules,
            onModule: { [weak self] module in
                guard let self else { return }
                await self.publish(.analyzing(session: dir.lastPathComponent, section: module.id))
                await self.log(dir, "analyzing \(module.id)")
            }
        )
        try analyzer.writeAnalysisFolder(sessionDir: dir, modules: modules, results: results)
        log(dir, "done — \(results.count) modules")
    }

    private func preparedEngine() async throws -> LLMEngine {
        if let engine { return engine }
        let configured = Config.llmEngine()
        let engine: LLMEngine
        switch configured {
        case "openai":
            engine = OpenAIEngine(
                baseURL: Config.llmBaseURL(),
                apiKey: Config.llmAPIKey(),
                model: Config.llmModel(),
                temperature: Config.llmTemperature(),
                maxTokens: Config.llmMaxTokens()
            )
        default:
            FileHandle.standardError.write(Data(
                "warning: unknown llm engine \"\(configured)\" — using openai\n".utf8
            ))
            engine = OpenAIEngine(
                baseURL: Config.llmBaseURL(),
                apiKey: Config.llmAPIKey(),
                model: Config.llmModel(),
                temperature: Config.llmTemperature(),
                maxTokens: Config.llmMaxTokens()
            )
        }
        self.engine = engine
        return engine
    }

    private func log(_ dir: URL, _ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        let url = dir.appendingPathComponent("analysis.log")
        if let handle = FileHandle(forWritingAtPath: url.path) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    private func publish(_ status: Status) {
        statusHandler?(status)
    }
}
