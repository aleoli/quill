import Foundation

/// Helpers for loading prompt files from disk. Built-in prompt strings
/// live in `AnalysisModule.Builtins`; this enum handles the file-override
/// path only.
enum Prompts {
    /// Read a Markdown file relative to `promptsDir`, strip YAML front
    /// matter, and return the body. The body is the prompt — `{text}` is
    /// replaced by the caller before sending to the LLM.
    ///
    /// Front matter is optional: a file starting with `---\n` and ending
    /// the block with a line of just `---` is stripped. Files without
    /// front matter are returned verbatim (trimmed).
    static func loadPromptFile(_ relativePath: String, promptsDir: URL) throws -> String {
        let url = promptsDir.appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PromptError.fileNotFound(url)
        }
        let raw = try String(contentsOf: url, encoding: .utf8)
        return stripFrontMatter(raw).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    enum PromptError: Error, CustomStringConvertible {
        case fileNotFound(URL)

        var description: String {
            switch self {
            case .fileNotFound(let url):
                return "prompt file not found: \(url.path)"
            }
        }
    }

    /// Remove a leading YAML front matter block (`---\n...\n---\n`) if
    /// present. Everything after the closing `---` is the prompt body.
    static func stripFrontMatter(_ raw: String) -> String {
        guard raw.hasPrefix("---\n") else { return raw }
        // Search for the closing delimiter on its own line.
        let after = raw.dropFirst(4) // skip opening "---\n"
        let lines = after.split(separator: "\n", omittingEmptySubsequences: false)
        for (i, line) in lines.enumerated() {
            if line.trimmingCharacters(in: .whitespaces) == "---" {
                // Body starts after this line.
                let bodyStart = lines.index(lines.startIndex, offsetBy: i + 1)
                return lines[bodyStart...].joined(separator: "\n")
            }
        }
        // No closing delimiter — treat the whole file as the prompt.
        return raw
    }
}
