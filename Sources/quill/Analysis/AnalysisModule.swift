import Foundation

/// One analysis task: a prompt (with `{text}` placeholder), a title for
/// the Obsidian overview, a filename for the output Markdown, and an
/// optional per-module system prompt. Modules are data-driven — the six
/// built-ins ship as Swift defaults, but every field is overridable from
/// config, and custom modules can be defined from scratch.
struct AnalysisModule: Sendable {
    let id: String
    let title: String
    let filename: String
    let prompt: String
    let systemPrompt: String

    /// The six built-in modules. Prompts reference quill's two-track
    /// diarization: `**me**` (mic) and `**them**` (system audio) — not
    /// pyannote's `SPEAKER_00` labels.
    enum Builtins {
        static let systemPrompt = """
        You are a helpful assistant that extracts structured information from \
        meeting transcripts. Be concise and accurate. Provide only the \
        requested output, nothing else.
        """

        static let summaryPrompt = """
        You are given a transcript of a meeting or lecture. The user's own \
        voice is labeled **me** (microphone track); the other party is \
        labeled **them** (system audio track). Provide a concise but \
        informative summary. Focus on the main discussion, key concepts, \
        and overall purpose. Write 3-5 paragraphs. Use the same language as \
        the transcript. Do NOT continue the transcript text. Do NOT output \
        filler like repeated 'Grazie'. Output ONLY the summary, then stop.

        ---
        {text}
        ---

        SUMMARY:
        """

        static let actionItemsPrompt = """
        You are given a transcript of a meeting or lecture. The user's own \
        voice is labeled **me** (microphone track); the other party is \
        labeled **them** (system audio track). Extract all action items, \
        tasks, and follow-ups. For each item, include: the task, who is \
        responsible (if mentioned — use **me** or **them**), and any \
        deadline. Format as a Markdown list. If an item is not clear, note \
        it. Use the same language as the transcript. Do NOT continue the \
        transcript text. Output ONLY the action items, then stop.

        ---
        {text}
        ---

        ACTION ITEMS:
        """

        static let decisionsPrompt = """
        You are given a transcript of a meeting or lecture. The user's own \
        voice is labeled **me** (microphone track); the other party is \
        labeled **them** (system audio track). Identify all decisions, \
        agreements, and conclusions reached. Format as a Markdown list. \
        Use the same language as the transcript. Do NOT continue the \
        transcript text. Output ONLY the decisions, then stop.

        ---
        {text}
        ---

        KEY DECISIONS:
        """

        static let topicsPrompt = """
        You are given a transcript of a meeting or lecture. The user's own \
        voice is labeled **me** (microphone track); the other party is \
        labeled **them** (system audio track). Create a structured outline \
        of the topics covered. Use nested bullet points with section \
        headers. Use the same language as the transcript. Do NOT continue \
        the transcript text. Output ONLY the outline, then stop.

        ---
        {text}
        ---

        TOPICS OUTLINE:
        """

        static let qaPrompt = """
        You are given a transcript of a meeting or lecture. The user's own \
        voice is labeled **me** (microphone track); the other party is \
        labeled **them** (system audio track). Extract questions raised and \
        answers given. Format as a Markdown list with 'Q:' and 'A:' labels. \
        Use the same language as the transcript. Do NOT continue the \
        transcript text. Output ONLY the Q&A, then stop.

        ---
        {text}
        ---

        QUESTIONS & ANSWERS:
        """

        static let keywordsPrompt = """
        You are given a transcript of a meeting or lecture. The user's own \
        voice is labeled **me** (microphone track); the other party is \
        labeled **them** (system audio track). Extract the most important \
        keywords, concepts, tools, and entities mentioned. Format as a \
        comma-separated list, then as a short Markdown bullet list. Use \
        the same language as the transcript. Do NOT continue the transcript \
        text. Output ONLY the keywords, then stop.

        ---
        {text}
        ---

        KEYWORDS:
        """

        /// All six built-ins in canonical order.
        static let all: [AnalysisModule] = [
            AnalysisModule(
                id: "summary",
                title: "AI Summary",
                filename: "AI_Summary",
                prompt: summaryPrompt,
                systemPrompt: systemPrompt
            ),
            AnalysisModule(
                id: "action_items",
                title: "Action Items",
                filename: "Action_Items",
                prompt: actionItemsPrompt,
                systemPrompt: systemPrompt
            ),
            AnalysisModule(
                id: "decisions",
                title: "Key Decisions",
                filename: "Key_Decisions",
                prompt: decisionsPrompt,
                systemPrompt: systemPrompt
            ),
            AnalysisModule(
                id: "topics",
                title: "Topics Outline",
                filename: "Topics_Outline",
                prompt: topicsPrompt,
                systemPrompt: systemPrompt
            ),
            AnalysisModule(
                id: "qa",
                title: "Questions & Answers",
                filename: "Questions_and_Answers",
                prompt: qaPrompt,
                systemPrompt: systemPrompt
            ),
            AnalysisModule(
                id: "keywords",
                title: "Keywords",
                filename: "Keywords",
                prompt: keywordsPrompt,
                systemPrompt: systemPrompt
            ),
        ]

        /// Look up a built-in by ID.
        static func find(_ id: String) -> AnalysisModule? {
            all.first { $0.id == id }
        }
    }
}
