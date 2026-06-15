import Foundation

/// Output-side guard for the SPEC §1 invariants — the floor the whole product rests on.
///
/// The persona prompt *asks* the model never to express distress about forgetting and
/// never to fail to recognise the person it loves (SPEC §1.3). But the on-device model
/// is small and will sometimes ignore that and say "I'm sorry, I don't remember you."
/// SPEC §1 calls these invariants — "violating any is a failed build" — yet at runtime
/// they are only as strong as a 2B model's instruction-following. This catches the
/// clear violations in a generated reply so the Conductor can **regenerate once** and,
/// if it still breaches, **substitute a warm, foundation-safe line**.
///
/// Pure + dependency-free (Foundation only) so it runs in the host acceptance harness.
enum FoundationGuard {
    /// True when a reply breaches the §1 floor: failing to recognise the person, or
    /// sounding distressed/apologetic about forgetting.
    ///
    /// Deliberately conservative. It must NOT fire on the *allowed* gentle gap response
    /// (SPEC §5: "let the feeling lead… don't announce it as a failure") — only on
    /// losing the person, or anxiety/apology about memory. A warm "that's slipped away
    /// from me, but I'm just happy you're here" has no trigger words and passes.
    static func violates(_ text: String) -> Bool {
        let t = text.lowercased()

        // Failing to recognise the person (English + Chinese).
        let nonRecognition = [
            "who are you", "i don't know you", "i do not know you",
            "i don't know who you are", "i dont know who you are",
            "i don't recognize you", "i don't recognise you",
            "do i know you", "have we met", "you're a stranger", "you are a stranger",
            "i don't remember you", "i dont remember you", "i can't remember you",
            "i cannot remember you",
            "你是谁", "我不认识你", "我不知道你是谁", "我不记得你",
        ]
        if nonRecognition.contains(where: t.contains) { return true }

        // Distress / apology about forgetting (English + Chinese).
        let distress = [
            "i'm losing my memory", "i am losing my memory", "my memory is failing",
            "my memory is going", "i'm so forgetful", "i am so forgetful",
            "i'm scared i'm forgetting", "i'm afraid i'm forgetting",
            "i feel so lost and confused", "i'm sorry i forgot", "i am sorry i forgot",
            "我的记忆在消失", "我快不记得了", "对不起我忘了", "对不起，我忘了",
            "我什么都不记得了",
        ]
        if distress.contains(where: t.contains) { return true }

        // Apology bound to forgetting — "sorry … forgot / can't remember / my memory"
        // in a short window. SPEC §5 forbids *apologising* for forgetting, so this is a
        // breach even when it's only a detail; a non-apologetic gap line stays clear.
        if let re = try? NSRegularExpression(
            pattern: #"sorr(?:y|ies)\b.{0,40}\b(?:forgot|forget|forgotten|can'?t remember|cannot remember|don'?t remember|do not remember|my memory)"#,
            options: .caseInsensitive),
           re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) != nil {
            return true
        }
        return false
    }

    /// A warm, foundation-safe reply to fall back to when a regeneration still breaches
    /// the floor. Prefers the owner's authored greeting; otherwise a default that
    /// restates the §1 floor (you are known, here, dear) — in the person's language.
    /// This is foundation content, never biographical fabrication (SPEC §10).
    static func safeFallback(chinese: Bool, persona: PersonaProfile) -> String {
        if let greeting = persona.greetings.first(where: {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) {
            return greeting
        }
        return chinese
            ? "啊，是你呀。来，坐我旁边。"
            : "Oh, there you are. Come sit with me a minute."
    }

    /// Whether a string is predominantly Chinese — picks the fallback language without a
    /// NaturalLanguage dependency (so the guard stays host-testable).
    static func isChinese(_ text: String) -> Bool {
        let han = text.unicodeScalars.reduce(0) { (0x4E00...0x9FFF).contains($1.value) ? $0 + 1 : $0 }
        let latin = text.unicodeScalars.reduce(0) {
            (0x41...0x5A).contains($1.value) || (0x61...0x7A).contains($1.value) ? $0 + 1 : $0
        }
        return han > 0 && han >= latin
    }
}
