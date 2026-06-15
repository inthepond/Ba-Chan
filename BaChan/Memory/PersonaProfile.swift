import Foundation

/// Ba-Chan's learned/authored persona content (SPEC §6 persona-content slots) —
/// **mutable state, not constants**. Per SPEC §6 these slots are meant to be
/// "rewritten by living together over time": filled by the owner on the memory page
/// and/or learned from conversation. The pinned *foundation* (who Ba-Chan is at the
/// floor) stays in `Persona`, authored and immutable; only these surface slots evolve.
///
/// Deliberately starts **empty** — Ba-Chan's voice is the owner's to shape, never
/// invented (SPEC §10). Ba-Chan's deep autobiographical memories are stored as L2
/// `MemoryRecord`s with `subject == .selfPersona`, not here.
struct PersonaProfile: Codable, Sendable {
    var relationship = ""    // how Ba-Chan relates to you; how Ba-Chan addresses you
    var about = ""           // who Ba-Chan is — presence, era, world
    var personality = ""     // Ba-Chan's temperament and warmth, how it shows
    var language = ""        // Ba-Chan's natural language/dialect, e.g. "Sichuanese"
    var messageExample = ""  // a few real exchanges in Ba-Chan's voice
    var greetings: [String] = []

    var isEmpty: Bool {
        relationship.isEmpty && about.isEmpty && personality.isEmpty
            && language.isEmpty && messageExample.isEmpty && greetings.isEmpty
    }
}

/// Persisted persona-side state: the editable profile, the session counter that drives
/// lucidity drift across launches (SPEC §4), and when the user was last present (so a
/// reply can be grounded in time — "you were last together yesterday").
struct PersonaState: Codable, Sendable {
    var profile = PersonaProfile()
    var sessionIndex = 0
    var lastInteractionAt: Date?

    /// Tolerant decoding so older on-disk state (no `lastInteractionAt`) still loads.
    init(profile: PersonaProfile = PersonaProfile(), sessionIndex: Int = 0,
         lastInteractionAt: Date? = nil) {
        self.profile = profile
        self.sessionIndex = sessionIndex
        self.lastInteractionAt = lastInteractionAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        profile = (try? c.decode(PersonaProfile.self, forKey: .profile)) ?? PersonaProfile()
        sessionIndex = (try? c.decode(Int.self, forKey: .sessionIndex)) ?? 0
        lastInteractionAt = try? c.decodeIfPresent(Date.self, forKey: .lastInteractionAt)
    }
}
