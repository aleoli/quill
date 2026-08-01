import Foundation

/// The analysis sections quill can generate from a transcript. Each maps
/// to a prompt, a human-readable title, and a filename for the Obsidian
/// output folder. Ported from the notetaker's `analyzer.py`.
enum AnalysisSection: String, CaseIterable, Sendable {
    case summary
    case actionItems = "action_items"
    case decisions
    case topics
    case qa
    case keywords

    /// Parse a comma-separated string of section names, returning nil if
    /// any are invalid.
    static func parse(_ raw: String) -> [AnalysisSection]? {
        let names = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        var sections: [AnalysisSection] = []
        for name in names {
            guard let section = AnalysisSection(rawValue: name) else { return nil }
            sections.append(section)
        }
        return sections.isEmpty ? nil : sections
    }
}

enum Prompts {
    /// System prompt shared across all sections — keeps the model focused on
    /// extraction and stops it from narrating or continuing the transcript.
    static let system = """
    You are a helpful assistant that extracts structured information from \
    meeting transcripts. Be concise and accurate. Provide only the requested \
    output, nothing else.
    """

    // MARK: - Per-section prompts

    static let summaryPrompt = """
    You are given a transcript of a meeting or lecture with speaker labels like **SPEAKER_00**. \
    Provide a concise but informative summary. Focus on the main discussion, \
    key concepts, and overall purpose. Write 3-5 paragraphs. \
    Use the same language as the transcript. \
    Do NOT continue the transcript text. Do NOT output filler like repeated 'Grazie'. \
    Output ONLY the summary, then stop.

    ---
    {text}
    ---

    SUMMARY:
    """

    static let actionItemsPrompt = """
    You are given a transcript of a meeting or lecture with speaker labels like **SPEAKER_00**. \
    Extract all action items, tasks, and follow-ups. For each item, include: \
    the task, who is responsible (if mentioned), and any deadline. \
    Format as a Markdown list. If an item is not clear, note it. \
    Use the same language as the transcript. \
    Do NOT continue the transcript text. Output ONLY the action items, then stop.

    ---
    {text}
    ---

    ACTION ITEMS:
    """

    static let decisionsPrompt = """
    You are given a transcript of a meeting or lecture with speaker labels like **SPEAKER_00**. \
    Identify all decisions, agreements, and conclusions reached. \
    Format as a Markdown list. Use the same language as the transcript. \
    Do NOT continue the transcript text. Output ONLY the decisions, then stop.

    ---
    {text}
    ---

    KEY DECISIONS:
    """

    static let topicsPrompt = """
    You are given a transcript of a meeting or lecture with speaker labels like **SPEAKER_00**. \
    Create a structured outline of the topics covered. \
    Use nested bullet points with section headers. \
    Use the same language as the transcript. \
    Do NOT continue the transcript text. Output ONLY the outline, then stop.

    ---
    {text}
    ---

    TOPICS OUTLINE:
    """

    static let qaPrompt = """
    You are given a transcript of a meeting or lecture with speaker labels like **SPEAKER_00**. \
    Extract questions raised and answers given. \
    Format as a Markdown list with 'Q:' and 'A:' labels. \
    Use the same language as the transcript. \
    Do NOT continue the transcript text. Output ONLY the Q&A, then stop.

    ---
    {text}
    ---

    QUESTIONS & ANSWERS:
    """

    static let keywordsPrompt = """
    You are given a transcript of a meeting or lecture with speaker labels like **SPEAKER_00**. \
    Extract the most important keywords, concepts, tools, and entities mentioned. \
    Format as a comma-separated list, then as a short Markdown bullet list. \
    Use the same language as the transcript. \
    Do NOT continue the transcript text. Output ONLY the keywords, then stop.

    ---
    {text}
    ---

    KEYWORDS:
    """

    /// Per-section user prompts. `{text}` is replaced with the formatted
    /// transcript before sending.
    static let prompts: [AnalysisSection: String] = [
        .summary: summaryPrompt,
        .actionItems: actionItemsPrompt,
        .decisions: decisionsPrompt,
        .topics: topicsPrompt,
        .qa: qaPrompt,
        .keywords: keywordsPrompt,
    ]

    /// Human-readable section titles for the Obsidian overview note.
    static let titles: [AnalysisSection: String] = [
        .summary: "AI Summary",
        .actionItems: "Action Items",
        .decisions: "Key Decisions",
        .topics: "Topics Outline",
        .qa: "Questions & Answers",
        .keywords: "Keywords",
    ]

    /// Filenames (without extension) for each section's Markdown file.
    static let filenames: [AnalysisSection: String] = [
        .summary: "AI_Summary",
        .actionItems: "Action_Items",
        .decisions: "Key_Decisions",
        .topics: "Topics_Outline",
        .qa: "Questions_and_Answers",
        .keywords: "Keywords",
    ]
}
