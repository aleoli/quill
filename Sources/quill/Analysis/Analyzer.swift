import Foundation

/// Reads a transcript, runs each analysis section through an `LLMEngine`,
/// and writes an Obsidian-style folder of Markdown notes (overview with
/// wiki-links, transcript, one file per section). The analyzer is agnostic
/// to the LLM backend — it receives an `LLMEngine` and doesn't know whether
/// it's talking to Ollama, OpenAI, or something else.
struct Analyzer {
    enum AnalyzerError: Error, CustomStringConvertible {
        case noTranscript(URL)
        case unreadableTranscript(URL)
        case noText

        var description: String {
            switch self {
            case .noTranscript(let dir):
                return "no transcript.json in \(dir.lastPathComponent)"
            case .unreadableTranscript(let url):
                return "can't parse \(url.lastPathComponent)"
            case .noText:
                return "transcript has no text to analyze"
            }
        }
    }

    /// The slice of transcript.json the analyzer needs.
    private struct Transcript: Codable {
        struct Segment: Codable {
            let speaker: String
            let start_ms: Int
            let end_ms: Int
            let text: String
        }
        let engine: String
        let model: String
        let segments: [Segment]
    }

    let engine: LLMEngine

    init(engine: LLMEngine) {
        self.engine = engine
    }

    // MARK: - Analysis

    /// Run the requested modules on a session's transcript, returning one
    /// cleaned string per module (keyed by module ID). `onModule`, if set,
    /// is awaited immediately before each module is sent to the LLM — used by
    /// the coordinator to publish per-module progress as each module actually
    /// starts, rather than all up front.
    func analyze(
        sessionDir: URL,
        modules: [AnalysisModule],
        onModule: (@Sendable (AnalysisModule) async -> Void)? = nil
    ) async throws -> [String: String] {
        let text = try extractText(from: sessionDir)
        try await engine.prepare()
        var results: [String: String] = [:]
        for module in modules {
            if let onModule { await onModule(module) }
            let prompt = module.prompt.replacingOccurrences(of: "{text}", with: text)
            let result = try await engine.complete(prompt, systemPrompt: module.systemPrompt)
            results[module.id] = result
        }
        return results
    }

    // MARK: - Output

    /// Write the analysis results into a subfolder of the session directory,
    /// mirroring the notetaker's Obsidian layout:
    ///
    ///     <session-name>/
    ///       <session-name>.md              overview with wiki-links
    ///       <session-name>_Transcript.md   transcript with timestamps
    ///       AI_Summary.md, Action_Items.md, ...
    func writeAnalysisFolder(
        sessionDir: URL,
        modules: [AnalysisModule],
        results: [String: String]
    ) throws {
        let name = sessionDir.lastPathComponent
        let folder = sessionDir.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let title = name.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ").capitalized

        // One Markdown file per module.
        var moduleFiles: [(module: AnalysisModule, filename: String)] = []
        for module in modules {
            guard let content = results[module.id] else { continue }
            let filename = "\(module.filename).md"
            let path = folder.appendingPathComponent(filename)
            try writeMarkdownFile(
                at: path,
                title: "\(title) - \(module.title)",
                body: content,
                tags: ["ai-analysis", module.id]
            )
            moduleFiles.append((module, filename))
        }

        // Transcript rendered with timestamps + speakers.
        let transcriptFile = try writeTranscriptMarkdown(
            sessionDir: sessionDir, folder: folder, name: name, title: title
        )

        // Overview note with Obsidian wiki-links.
        let overviewPath = folder.appendingPathComponent("\(name).md")
        try writeOverview(
            at: overviewPath,
            title: title,
            transcriptFile: transcriptFile,
            moduleFiles: moduleFiles
        )
    }

    // MARK: - Text extraction

    /// Read transcript.json from a session directory and format it as
    /// `**speaker**: text` lines, collapsing repeated filler ("Grazie" etc.)
    /// to avoid confusing the LLM and wasting tokens.
    private func extractText(from sessionDir: URL) throws -> String {
        let url = sessionDir.appendingPathComponent("transcript.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AnalyzerError.noTranscript(sessionDir)
        }
        guard
            let data = try? Data(contentsOf: url),
            let transcript = try? JSONDecoder().decode(Transcript.self, from: data)
        else { throw AnalyzerError.unreadableTranscript(url) }

        let fillers: Set<String> = ["grazie", "grazie.", "thanks", "thank you", "ok", "okay"]
        var lines: [String] = []
        var prevLower: String?
        var fillerRun = 0
        for seg in transcript.segments {
            let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let lower = text.lowercased()
            // Collapse consecutive identical filler lines to at most 3.
            if fillers.contains(lower) && lower == prevLower {
                fillerRun += 1
                if fillerRun >= 3 { continue }
            } else {
                fillerRun = 0
            }
            lines.append("**\(seg.speaker)**: \(text)")
            prevLower = lower
        }
        let joined = lines.joined(separator: "\n")
        guard !joined.isEmpty else { throw AnalyzerError.noText }
        return joined
    }

    // MARK: - Markdown writers

    private func writeMarkdownFile(
        at path: URL, title: String, body: String, tags: [String]
    ) throws {
        let now = ISO8601DateFormatter().string(from: Date())
        var lines = ["---", "title: \(title)", "date: \(now)", "tags:"]
        for tag in tags { lines.append("  - \(tag)") }
        lines += ["---", "", "# \(title)", "", body.trimmingCharacters(in: .whitespacesAndNewlines), ""]
        try Data(lines.joined(separator: "\n").utf8).write(to: path, options: .atomic)
    }

    private func writeTranscriptMarkdown(
        sessionDir: URL, folder: URL, name: String, title: String
    ) throws -> String {
        let filename = "\(name)_Transcript.md"
        let path = folder.appendingPathComponent(filename)

        let url = sessionDir.appendingPathComponent("transcript.json")
        var body = ""
        if let data = try? Data(contentsOf: url),
           let transcript = try? JSONDecoder().decode(Transcript.self, from: data) {
            for seg in transcript.segments {
                let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let start = Self.clock(seg.start_ms)
                body += "**\(seg.speaker)** [\(start)]: \(text)\n\n"
            }
        }

        let now = ISO8601DateFormatter().string(from: Date())
        let lines = [
            "---", "title: \(title) - Transcript", "date: \(now)",
            "tags:", "  - transcript", "  - ai-analysis", "---", "",
            "# \(title) - Transcript", "", body,
        ]
        try Data(lines.joined(separator: "\n").utf8).write(to: path, options: .atomic)
        return filename
    }

    private func writeOverview(
        at path: URL, title: String,
        transcriptFile: String,
        moduleFiles: [(module: AnalysisModule, filename: String)]
    ) throws {
        let now = ISO8601DateFormatter().string(from: Date())
        var lines = [
            "---", "title: \(title) - Overview", "date: \(now)",
            "tags:", "  - ai-analysis", "  - overview", "---", "",
            "# \(title) - Overview", "",
            "## Transcript",
            "- [[\(transcriptFile.dropLast(3))|Transcript]]",
            "",
            "## Analysis Sections", "",
        ]
        for entry in moduleFiles {
            let link = entry.filename.dropLast(3) // strip .md
            lines.append("- [[\(link)|\(entry.module.title)]]")
        }
        lines.append("")
        try Data(lines.joined(separator: "\n").utf8).write(to: path, options: .atomic)
    }

    private static func clock(_ ms: Int) -> String {
        let total = ms / 1000
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}
