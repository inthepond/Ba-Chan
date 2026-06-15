import Foundation

/// A brain that can distill a day's conversation transcript into durable
/// third-person facts about the user — the LLM upgrade over `MemoryStore`'s
/// regex extractor. Returns `nil` on a model error (so the day is retried next
/// launch) and `[]` when there was genuinely nothing worth keeping.
protocol MemoryDistilling {
    func distillMemories(from transcript: String, dayLabel: String) async -> [String]?
}

/// The "nightly summarization" pass (SPEC's "LLM-based memory extraction +
/// reflection" upgrade): once per calendar day, each not-yet-processed past day
/// in the `ConversationLog` is rendered to a transcript, handed to the loaded
/// model, and the resulting facts join the layered store as deep records dated
/// to that day. Prompt and parsing live here so every brain shares one
/// tightly-bounded contract (no inference, no invention — SPEC §1.4).
enum MemoryDistiller {
    /// How many past days the backlog sweep looks at (a long-idle machine
    /// shouldn't replay weeks of log through the model on one launch).
    static let backlogDays = 7

    static func prompt(transcript: String, dayLabel: String) -> String {
        """
        Below is the transcript of a conversation from \(dayLabel) between Ba-Chan \
        (a beloved companion) and the person Ba-Chan lives with. Pull out up to 5 facts \
        worth holding onto long-term about the person and their life — names, people, \
        places, plans, events, preferences, worries, joys. Only what was actually \
        said; never infer or invent. Skip small talk, fleeting states, and anything \
        about Ba-Chan herself. Write each as one short third-person sentence about \
        them ("They …"), in the language they spoke. One fact per line, nothing else. \
        If nothing is worth keeping, reply with exactly: NONE.

        \(transcript)
        """
    }

    /// Shares PersonaLearner's line cleaner (bullets/numbering/NONE sentinels)
    /// and its prompt-echo guard — the prompt above calls Ba-Chan "a beloved
    /// companion", and a small model can hand that framing back as a "fact"
    /// unless the words actually appear in the transcript.
    static func parse(_ raw: String, transcript: String) -> [String] {
        PersonaLearner.parseExtractedLines(raw, groundedIn: transcript)
    }

    /// Render a day's turns for the prompt. Budgeted from the end (the newest
    /// part of a very long day wins) so the prompt can't blow up a small model.
    static func transcriptText(_ turns: [ConversationLog.LoggedTurn],
                               maxChars: Int = 4000) -> String {
        var lines: [String] = []
        var used = 0
        for turn in turns.reversed() {
            let line = "Them: \(turn.user)\nBa-Chan: \(turn.bachan)"
            if used + line.count > maxChars { break }
            used += line.count
            lines.append(line)
        }
        return lines.reversed().joined(separator: "\n")
    }
}
