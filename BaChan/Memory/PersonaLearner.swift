import Foundation

/// Heuristic persona learning (SPEC §6, "rewritten by living together"). Spots when
/// the owner says something *about Ba-Chan* and records it as a persona memory. To
/// honor §1.4 (never present fabricated history as fact) the engine only ever keeps
/// the owner's own stated words — it never invents — and the owner can edit or delete
/// anything on the memory page.
///
/// Foundation-only so it also compiles in the acceptance harness. When a real
/// on-device LLM is loaded, the Conductor prefers an `PersonaExtracting` brain pass
/// over this; this is the dependency-free fallback.
enum PersonaLearner {
    /// Words that signal the owner is talking about Ba-Chan (English + common Chinese
    /// terms of endearment for an elder), or addressing Ba-Chan about the past.
    private static let subjectCues = [
        "grandma", "grandmother", "granny", "nana", "ba-chan", "bachan", "ba chan",
        "奶奶", "嬢嬢", "孃孃", "婆婆", "外婆", "姥姥", "阿嬷", "阿嫲", "嫲嫲",
    ]
    private static let aboutHerCues = [
        "you used to", "you always", "you would", "you loved", "you liked", "you made",
        "你以前", "你小时候", "你总是", "你最爱", "你最喜欢", "你会做", "你常",
    ]

    /// Candidate persona memories from one user turn — verbatim sentences (the owner's
    /// own words), filtered to statements that mention Ba-Chan. Empty when no match.
    static func suggestions(from userText: String) -> [String] {
        let sentences = userText
            .split(whereSeparator: { "。！？!?\n.".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 4 }

        var out: [String] = []
        for sentence in sentences {
            let lower = sentence.lowercased()
            // Skip questions — we want statements about Ba-Chan, not queries.
            if sentence.hasSuffix("吗") || lower.hasPrefix("do you") || lower.hasPrefix("are you") {
                continue
            }
            let mentionsHer = subjectCues.contains { lower.contains($0) }
            let aboutHerPast = aboutHerCues.contains { lower.contains($0) }
            if mentionsHer || aboutHerPast {
                out.append(sentence)
            }
        }
        return out
    }

    /// Fast pre-check: could this turn plausibly state something about Ba-Chan?
    /// Liberal on purpose — a false positive only costs one LLM generation (the
    /// prior status quo), a false negative silently falls back to the heuristic.
    /// The Conductor uses this to gate the expensive LLM persona extractor so an
    /// ordinary chat turn doesn't pay for a second full decode.
    static func mightContainPersonaFact(_ text: String) -> Bool {
        let lower = text.lowercased()
        return subjectCues.contains { lower.contains($0) }
            || aboutHerCues.contains { lower.contains($0) }
    }
}

/// A brain that can extract persona facts the user stated about Ba-Chan, used when a
/// real on-device LLM is loaded (richer than the heuristic). Implementations must
/// return only facts the user *explicitly stated* — never inferred or invented. The
/// model decides what's worth keeping; results are kept directly and the owner can
/// edit/delete them on the memory page.
protocol PersonaExtracting {
    func extractPersonaFacts(from userText: String) async -> [String]
}

extension PersonaLearner {
    /// The instruction handed to an extraction-capable brain. Tightly bounded to the
    /// user's explicit statements (no inference/invention), so kept facts are the
    /// owner's own words, not fabrication (SPEC §1.4).
    static func extractionPrompt(for userText: String) -> String {
        // NB: this prompt must not *describe* Ba-Chan ("a companion they hold
        // dear" used to live here) — a small model parrots any such framing back
        // as extracted "facts" the user never said (verified: "Ba-Chan is a
        // companion." landed in the memory store). State the task, nothing else.
        """
        The user is talking with Ba-Chan. From the user's message below, list any \
        NEW facts the user EXPLICITLY STATED about Ba-Chan — Ba-Chan's life, \
        habits, sayings, things Ba-Chan liked or did, how Ba-Chan relates to the \
        user. Only what the user actually said. Do NOT infer, guess, or invent. \
        If there are none, reply with exactly: NONE. Otherwise one short fact \
        per line about Ba-Chan.

        User: \(userText)
        """
    }

    /// Parse an extraction model's reply into clean candidate lines (drops bullets,
    /// numbering, and any "no facts" sentinel; caps the count). Pass `groundedIn`
    /// (the user's own words / the transcript) to also drop prompt echo.
    static func parseExtractedLines(_ raw: String, groundedIn source: String? = nil) -> [String] {
        // If the whole reply is a "nothing to keep" sentinel, keep nothing — this
        // catches a bare `NONE` and a model that wraps it in a sentence ("There are
        // none." / "No new facts.") that the old exact `!= "NONE"` check let through.
        if isNoFactsSentinel(raw) { return [] }
        return raw.split(separator: "\n")
            .map { line -> String in
                var s = String(line).trimmingCharacters(in: .whitespaces)
                while let f = s.first, "-*•‣·0123456789.)（）(".contains(f) { s.removeFirst() }
                return s.trimmingCharacters(in: .whitespaces)
            }
            .filter { $0.count >= 4 && !isNoFactsSentinel($0) }
            .filter { line in
                guard let source else { return true }
                return !isPromptEcho(line, absentFrom: source)
            }
            .prefix(5)
            .map { $0 }
    }

    /// A "fact" that restates the harness's own framing of Ba-Chan rather than
    /// anything the user said — kept only when the user actually used the words.
    /// Belt-and-braces on top of the de-framed prompt: even a task description
    /// can get echoed by a 4B ("Ba-Chan is held dear by the user." was stored).
    static func isPromptEcho(_ line: String, absentFrom source: String) -> Bool {
        let l = line.lowercased(), s = source.lowercased()
        let framings = ["companion", "held dear", "hold dear", "holds dear", "beloved"]
        return framings.contains { l.contains($0) && !s.contains($0) }
    }

    /// True when a line/reply is the model's way of saying "no new facts" rather than a
    /// fact — `NONE`, `None.`, `no new facts`, `there are none`, `没有`, … Compared on
    /// letters only so trailing punctuation or a parenthetical can't slip a `NONE.` past.
    static func isNoFactsSentinel(_ text: String) -> Bool {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let lettersOnly = String(lower.unicodeScalars.filter { CharacterSet.letters.contains($0) })
        if lettersOnly == "none" || lettersOnly == "nonefound" || lettersOnly == "nothing" {
            return true
        }
        let phrases = ["no new fact", "no facts", "there are none", "there is none",
                       "none found", "nothing new", "nothing to add", "n/a",
                       "没有", "沒有", "无新"]
        return phrases.contains { lower.contains($0) }
    }
}
