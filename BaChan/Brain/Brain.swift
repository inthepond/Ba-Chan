import Foundation
import CoreGraphics

/// What Stackchan says back, plus the mood to wear while saying it.
struct BrainReply {
    let text: String
    let expression: Expression
}

/// Pluggable "brain". Swap in FoundationModels, an MLX/Gemma model, or the
/// built-in scripted brain without touching the rest of the app.
protocol Brain: Sendable {
    var name: String { get }
    func reply(to input: String, context: BrainContext) async -> BrainReply
}

/// A brain that can look at a raw camera frame (a multimodal VLM). The hybrid
/// vision design uses Apple Vision text cues for every brain, and — when the
/// brain also conforms to this — a richer free-form description from the frame
/// itself. The Conductor checks `brain as? VisionBrain` at look-time.
protocol VisionBrain {
    func describe(_ image: CGImage, prompt: String, context: BrainContext) async -> String
}

extension Brain {
    /// Convenience for callers that have no context to pass.
    func reply(to input: String) async -> BrainReply {
        await reply(to: input, context: .empty)
    }
}

/// Parses a trailing emotion tag like `[happy]` out of an LLM reply — the same
/// idea as Stack-chan's firmware scanning the text for `(Happy)`/`[happy]` and
/// stripping it before speaking. Bracketed names are used because models rarely
/// emit literal `[happy]` in normal prose, so false positives are unlikely.
enum EmotionTag {
    /// Strips every single-word bracketed tag from `text` (in place) and returns
    /// the mood of the last one it can interpret. Models improvise beyond the
    /// listed set — `[concerned]`, `[warmly]`, `[wistful]` — so unknown tags are
    /// mapped to the nearest expression where possible, and removed from the
    /// visible text either way (a leaked `[peaceful]` reads as a glitch).
    static func extract(from text: inout String) -> Expression? {
        guard let re = try? NSRegularExpression(pattern: #"\[([A-Za-z]{2,16})\]"#) else { return nil }
        let matches = re.matches(in: text, range: NSRange(text.startIndex..., in: text))
        var found: Expression?
        for match in matches.reversed() {   // back-to-front so ranges stay valid while removing
            guard let whole = Range(match.range, in: text),
                  let word = Range(match.range(at: 1), in: text) else { continue }
            // The trailing tag is the mood; earlier ones only get a say if it's unknown.
            if found == nil { found = expression(forTag: String(text[word]).lowercased()) }
            text.removeSubrange(whole)
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return found
    }

    /// Exact tag names first, then the synonyms small models reach for.
    private static func expression(forTag word: String) -> Expression? {
        if let exact = Expression(rawValue: word) { return exact }
        switch word {
        case "worried", "anxious", "nervous", "uneasy", "caring":
            return .concerned
        case "calm", "content", "serene", "relaxed", "gentle", "warm", "warmly",
             "tender", "loving", "fond", "soft":
            return .peaceful
        case "joyful", "excited", "delighted", "cheerful", "glad", "pleased",
             "smiling", "laughing", "amused", "proud":
            return .happy
        case "curious", "confused", "puzzled", "thinking", "thoughtful", "wondering":
            return .doubt
        case "tired", "drowsy", "yawning", "dreamy":
            return .sleepy
        case "shocked", "amazed", "astonished", "startled":
            return .surprised
        case "melancholy", "wistful", "sorrowful", "lonely", "hurt", "nostalgic":
            return .sad
        case "annoyed", "frustrated", "grumpy", "irritated", "stern":
            return .angry
        default:
            return nil
        }
    }

    /// The instruction appended to an LLM system prompt so it tags its mood.
    static let promptInstruction = """
    End every reply with exactly one mood tag on its own, chosen from: \
    [neutral] [happy] [sleepy] [doubt] [sad] [angry] [surprised] [concerned] [peaceful]. \
    Write nothing after the tag.
    """
}

/// Cheap sentiment → expression mapping, used as a fallback when a reply has no
/// explicit mood tag (e.g. the scripted brain, or a model that forgot to tag).
enum Sentiment {
    static func expression(for text: String) -> Expression {
        let t = text.lowercased()
        if t.contains("sorry") || t.contains("sad") || t.contains("unfortunately") || t.contains("can't") {
            return .sad
        }
        if t.contains("!") || t.contains("yay") || t.contains("great") || t.contains("love") || t.contains("happy") {
            return .happy
        }
        if t.contains("hmm") || t.contains("?") {
            return .doubt
        }
        return .neutral
    }
}
