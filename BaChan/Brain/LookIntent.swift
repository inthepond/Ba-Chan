import Foundation

/// Detects when the user is asking Ba-Chan to *look* (use the camera) rather than just
/// chat — so the Conductor routes the turn to the vision path, or (if Look is off)
/// gently prompts to turn it on. Foundation-only so the host harness can unit-test it.
///
/// Cues are **phrases about Ba-Chan looking right now**, never the bare verbs:
/// substring "look"/"see" misfired on ordinary talk ("the hiring manager looked at
/// my profile", "see you tomorrow") and turned a chat turn into camera guidance.
enum LookIntent {
    static func matches(_ text: String) -> Bool {
        let t = text.lowercased()
        // A lone imperative "look" (or "look!") is a real ask; "look" inside a
        // longer sentence needs one of the explicit phrases below.
        let bare = t.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "!.?"))
        if bare == "look" { return true }
        let cues = ["look at th", "look at me", "look at it", "look at what",
                    "have a look", "take a look", "take a peek", "look here",
                    "can you look", "can you see", "do you see", "you can see",
                    "what do you see", "what can you see", "see this", "see that",
                    "what's this", "whats this", "what is this",
                    "what am i holding", "what am i wearing", "show you",
                    "camera", "in front of you", "check this out",
                    "can you tell what", "read this",
                    "看看", "这是什么", "你看到", "帮我看", "看一下"]
        return cues.contains { t.contains($0) }
    }

    /// The macOS variant: asking Ba-Chan to look at the **screen** (ScreenCaptureKit)
    /// rather than through the camera. Kept to explicit screen words so an ordinary
    /// sentence never trips the Screen-toggle guidance.
    static func screenMatches(_ text: String) -> Bool {
        let t = text.lowercased()
        let cues = ["screen", "monitor", "my display", "what am i working on",
                    "屏幕", "螢幕", "显示器"]
        return cues.contains { t.contains($0) }
    }
}
