import Foundation

/// Strips chat-template artifacts a small local model emits as literal text. MLX does
/// not always stop at Gemma's `<end_of_turn>`, so the model runs on and prints it (often
/// many times); other templates leak `<|im_end|>`, `</s>`, etc. Truncate at the first
/// turn/eos marker and drop any stray bracketed special tokens.
///
/// Foundation-only so the host acceptance harness can exercise it — `GemmaBrain` lives
/// behind `#if canImport(MLXLLM)` and never compiles off-device.
enum ChatArtifacts {
    static func clean(_ raw: String) -> String {
        var t = raw
        for marker in ["<end_of_turn>", "<start_of_turn>", "<eos>", "</s>",
                       "<|im_end|>", "<|endoftext|>"] {
            if let r = t.range(of: marker) { t = String(t[..<r.lowerBound]) }
        }
        // Remove any remaining bracketed special tokens (spoken replies have none).
        t = t.replacingOccurrences(of: #"<[^>\n]{1,24}>"#, with: "", options: .regularExpression)
        return unwrapEdgeQuotes(normalizePunctuation(t))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A model that saw its input framed as quoted speech sometimes wraps the whole
    /// reply in quotation marks. Spoken words never need edge quotes: strip leading
    /// quote characters, and a trailing one only when it dangles (no matching opener
    /// left inside — a real quoted phrase at the end keeps its pair).
    static func unwrapEdgeQuotes(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let quotes: Set<Character> = ["\"", "“", "”", "'", "‘", "’", "「", "」", "『", "』"]
        while let first = t.first, quotes.contains(first) { t.removeFirst() }
        let openerFor: [Character: Character] = ["”": "“", "\"": "\"", "’": "‘",
                                                 "'": "'", "」": "「", "』": "『"]
        while let last = t.last, quotes.contains(last) {
            let body = String(t.dropLast())
            if let opener = openerFor[last], body.contains(opener) { break }   // paired — keep
            t = body
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Spoken-text punctuation: models love em/en dashes and markdown emphasis,
    /// neither of which belongs in a chat bubble that may also be read aloud. The
    /// prompt asks for plain punctuation, but a small model won't reliably obey —
    /// so dashes become commas (mid-sentence pause) and `*emphasis*` is unwrapped.
    static func normalizePunctuation(_ text: String) -> String {
        var t = text
        // "word — word" / "word—word" / spaced hyphen used as a dash → ", "
        t = t.replacingOccurrences(of: #"\s*[—–]+\s*|\s+-\s+"#, with: ", ",
                                   options: .regularExpression)
        // Tidy any ", ," / " ," the substitution can produce next to existing commas.
        t = t.replacingOccurrences(of: #"\s*,(\s*,)+"#, with: ",", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s+([,.!?;:])"#, with: "$1", options: .regularExpression)
        // *emphasis* / **bold** → bare word (TTS would read the asterisks), then any
        // stray unpaired asterisk — spoken text never needs one.
        t = t.replacingOccurrences(of: #"\*{1,2}([^*\n]+)\*{1,2}"#, with: "$1",
                                   options: .regularExpression)
        t = t.replacingOccurrences(of: "*", with: "")
        return t
    }
}
