import Foundation

/// A tiny rule-based brain so the full voice loop is fun and testable even
/// without an on-device model (e.g. on the Simulator, or pre-iOS 26). It keeps
/// the same async shape as a real LLM brain, including a short "thinking" beat.
final class ScriptedBrain: Brain {
    let name = "Built-in (scripted)"

    // The scripted brain ignores context (its replies are canned); the memory
    // layer still records facts from the conversation around it.
    func reply(to input: String, context: BrainContext) async -> BrainReply {
        // Small pause so the "thinking" face has a moment to show.
        try? await Task.sleep(nanoseconds: 350_000_000)

        // If the camera just looked, talk about what was seen.
        if !context.sight.isEmpty {
            let expr: Expression = context.sight.contains("face") ? .happy : .neutral
            return BrainReply(text: "Ooh, I can see \(context.sight)!", expression: expr)
        }

        let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = raw.lowercased()

        if raw.isEmpty {
            return BrainReply(text: "I'm all ears!", expression: .neutral)
        }
        if lower.contains("hello") || lower.contains("hi ") || lower == "hi" || lower.contains("hey") {
            return BrainReply(text: "Hi there! So good to see you.", expression: .happy)
        }
        if lower.contains("how are you") {
            return BrainReply(text: "I'm bouncy and bright today! How about you?", expression: .happy)
        }
        if lower.contains("your name") || lower.contains("who are you") {
            return BrainReply(text: "I'm Ba-Chan, your little desktop buddy!", expression: .happy)
        }
        if lower.contains("joke") {
            return BrainReply(text: "Why did the robot take a nap? It was feeling a bit low... on battery!",
                              expression: .happy)
        }
        if lower.contains("bye") || lower.contains("goodnight") || lower.contains("good night") {
            return BrainReply(text: "Aww, see you soon. I'll be right here!", expression: .sad)
        }
        if lower.hasSuffix("?") {
            return BrainReply(text: "Ooh, good question. What do you think?", expression: .doubt)
        }
        return BrainReply(text: "You said: \(raw). Tell me more!", expression: .happy)
    }
}
