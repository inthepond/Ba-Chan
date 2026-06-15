import Foundation

/// Catches a reply naming people or pets that exist nowhere in the conversation
/// or Ba-Chan's notes — the classic small-model hallucination ("Did you see
/// Mrs. Higgins' cat again?"). The persona forbids it, but a 4B model slips, so
/// this is the mechanical backstop: any sentence that names a stranger is
/// dropped; if nothing survives, the Conductor regenerates with a corrective.
///
/// Deliberately HIGH-PRECISION: only honorific+name pairs ("Mrs. Higgins") and
/// mid-sentence possessive names ("Tom's house") count as names — never bare
/// capitalized words — so legitimate sentences are essentially never lost.
/// Foundation-only, host-testable.
enum Fabrication {
    /// Names in `text` that appear nowhere in `known` (case-insensitive).
    static func namedStrangers(in text: String, known: String) -> [String] {
        let corpus = known.lowercased()
        var strangers: [String] = []
        let patterns = [
            // "Mrs. Higgins", "Uncle Bert" — an honorific makes it a name for sure.
            #"\b(?:Mr|Mrs|Ms|Miss|Dr|Aunt|Auntie|Uncle|Grandma|Grandpa)\.?\s+([A-Z][a-z]+)"#,
            // "Tom's house", "Higgins' cat" — possessive name, mid-sentence only
            // (the lookbehind requires a preceding lowercase word, so a
            // sentence-opening "Life's funny" can't false-positive).
            #"(?<=[a-z,] )([A-Z][a-z]{2,})['’]s?\s"#,
        ]
        for pattern in patterns {
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard match.numberOfRanges > 1,
                      let range = Range(match.range(at: 1), in: text) else { continue }
                let name = String(text[range])
                guard !commonWords.contains(name.lowercased()),
                      !corpus.contains(name.lowercased()),
                      !strangers.contains(name) else { continue }
                strangers.append(name)
            }
        }
        return strangers
    }

    /// Drop every sentence that mentions a named stranger. Returns what's left
    /// and whether anything was removed.
    static func scrub(_ text: String, known: String) -> (text: String, dropped: Bool) {
        let strangers = namedStrangers(in: text, known: known)
        guard !strangers.isEmpty else { return (text, false) }

        var sentences: [String] = []
        var current = ""
        for ch in text {
            current.append(ch)
            if ".!?。！？\n".contains(ch) {
                // An honorific abbreviation's period ("Mrs.") doesn't end a sentence.
                if ch == ".", current.range(of: #"\b(?:Mr|Mrs|Ms|Dr)\.$"#,
                                            options: .regularExpression) != nil { continue }
                sentences.append(current); current = ""
            }
        }
        if !current.isEmpty { sentences.append(current) }

        // Drop stranger sentences — and any immediate follow-on that leans on them
        // with a dangling pronoun ("Did you see X's cat? It always lurks around.").
        var kept: [String] = []
        var previousDropped = false
        for sentence in sentences {
            let mentionsStranger = strangers.contains { sentence.contains($0) }
            let leansOnDropped = previousDropped && sentence
                .trimmingCharacters(in: .whitespaces)
                .range(of: #"^(?:It|He|She|They|That|His|Her|Their)\b"#,
                       options: .regularExpression) != nil
            if mentionsStranger || leansOnDropped {
                previousDropped = true
            } else {
                previousDropped = false
                kept.append(sentence)
            }
        }
        return (kept.joined().trimmingCharacters(in: .whitespacesAndNewlines), true)
    }

    /// Capitalized words that are never somebody's name.
    private static let commonWords: Set<String> = [
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        "january", "february", "march", "april", "may", "june", "july", "august",
        "september", "october", "november", "december",
        "today", "tomorrow", "yesterday", "god", "christmas", "easter",
        "ba-chan", "bachan", "mum", "mom", "dad", "grandma", "grandpa",
    ]
}
