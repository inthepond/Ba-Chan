import Foundation

/// Everything the Conductor knows that might help the brain answer, assembled by
/// the memory engine and handed to a stateless brain. Foundation-only (no Face /
/// CoreGraphics) so the memory engine and persona compile on the host for the
/// acceptance harness as well as on device.
struct BrainContext {
    /// The never-decaying floor as text (SPEC §1): who the user is, that they're
    /// known/loved/safe — from the persona foundation + pinned records.
    var profile: String = ""
    /// Top-scored L2–L4 recall about the *user* for this turn, within the budget.
    var memories: [String] = []
    /// Ba-Chan's own learned/authored persona content (SPEC §6) — who she is.
    var persona = PersonaProfile()
    /// Her confirmed deep autobiographical memories (L2, `subject == .selfPersona`).
    var personaMemories: [String] = []
    /// What the camera sees right now, as text (from `SightService`).
    var sight: String = ""
    /// What's on the owner's computer screen, as text — set only on a macOS
    /// "look at my screen" turn while the Screen toggle is on (`ScreenSightService`).
    var screen: String = ""
    /// The rhythm of their work at the Mac right now ("using Xcode for about an
    /// hour, at the screen 3 hours without a real break") — from `WorkRhythm`,
    /// macOS only; empty elsewhere or when nothing is notable.
    var rhythm: String = ""
    /// The current lucidity line, injected at the post-history seam (SPEC §4). Used by
    /// the capable (Apple FM) path; the lean (Gemma) path uses `lucidityHint` instead.
    var lucidityNote: String = ""
    /// A terse tone hint for small models — the lean prompt uses this rather than the
    /// full `lucidityNote`, which a 2B model tends to recite instead of answering.
    var lucidityHint: String = ""
    /// A gentle line grounding the moment in time — time of day, and how long since
    /// you last spoke (e.g. "It's evening; you last spoke this morning"). Helps the
    /// reply feel present rather than timeless.
    var temporalNote: String = ""
    /// Files the user fed into this turn, distilled to text — document excerpts,
    /// Apple-Vision summaries of images / sampled video frames (one per line).
    var attachments: String = ""
    /// What was actually said in past conversations, pulled from the persistent
    /// `ConversationLog` when the user asks about a past time ("what did we chat
    /// about yesterday"). Pre-labelled with the time it covers; empty otherwise.
    var journal: String = ""
    /// The last few exchanges this session, oldest first — short-term continuity so a
    /// reply can follow the thread of the conversation, not just retrieved memories.
    /// Used by the lean (Gemma) prompt; capable models keep their own session history.
    var history: [Turn] = []
    /// Set only on a §1-repair retry (`FoundationGuard`): a strong corrective handed to
    /// the model after it breached the floor, placed last so it conditions generation.
    var repair: String = ""

    /// One past exchange in this session.
    struct Turn: Sendable {
        var user: String
        var bachan: String
    }

    static let empty = BrainContext()
}
