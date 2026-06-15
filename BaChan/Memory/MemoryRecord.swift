import Foundation

// MARK: - Layered memory model (SPEC §2)
//
// Five layers with distinct decay behavior. L5 (lucidity) is a *state variable*
// (see `LucidityState`), not a stored record — so only L1–L4 live here.
//
//   L1 foundation — pinned, never decays, always in context (identity, "loved/safe")
//   L2 deep       — deep autobiography, near-zero decay, top retrieval priority
//   L3 episode    — recent episodes, gentle decay → loses *specificity*, not presence
//   L4 residue    — emotional residue, persists well beyond the L3 detail it came from
//
// Decay is a property of the *store* (retrieval scoring + a compression schedule),
// never a behavior asked of the model (SPEC §1.2).

enum MemoryLayer: Int, Codable, Sendable, CaseIterable {
    case foundation = 1
    case deep = 2
    case episode = 3
    case residue = 4

    var label: String {
        switch self {
        case .foundation: return "Foundation"
        case .deep:       return "Deep memory"
        case .episode:    return "Recent"
        case .residue:    return "Feeling"
        }
    }
}

/// Who a memory is *about*. The memory page shows two sections built from this:
/// what Ba-Chan knows about you, and who Ba-Chan is (the learned/authored persona).
enum MemorySubject: String, Codable, Sendable {
    case user        // 关于你 — facts about the person Ba-Chan is with
    case selfPersona // 关于 Ba-Chan — Ba-Chan's own identity / deep autobiography
}

/// One memory. The same struct spans all four layers; `layer` + the weights below
/// decide how it ages and how strongly it surfaces in retrieval.
struct MemoryRecord: Codable, Identifiable, Sendable {
    var id = UUID()
    var layer: MemoryLayer
    var text: String
    var kind: String                 // name | preference | fact | event | feeling | persona
    var subject: MemorySubject = .user

    /// Depth/durability weight, 0…1. High for L2 (near-immune to age).
    var permanence: Double
    /// How affectively charged this is, 0…1. Drives L4 residue and hazy-day recall.
    var emotionalSalience: Double
    /// 1 = full episodic detail … 0 = pure feeling. L3 compression lowers this.
    var specificity: Double

    /// Pinned records never decay or compress and are always retrieved (L1-grade,
    /// e.g. the user's name). The §1 floor — "you know them, they are loved" — is
    /// carried by the persona foundation *and* these pins.
    var pinned: Bool
    /// A compressed-away original. Kept (optionally) but not normally retrieved.
    var archived: Bool

    var createdAt: Date
    var lastUsedAt: Date
    var embedding: [Double]

    init(layer: MemoryLayer, text: String, kind: String,
         subject: MemorySubject = .user,
         permanence: Double, emotionalSalience: Double, specificity: Double = 1,
         pinned: Bool = false, archived: Bool = false,
         createdAt: Date, lastUsedAt: Date, embedding: [Double]) {
        self.layer = layer
        self.text = text
        self.kind = kind
        self.subject = subject
        self.permanence = permanence
        self.emotionalSalience = emotionalSalience
        self.specificity = specificity
        self.pinned = pinned
        self.archived = archived
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.embedding = embedding
    }

    /// Tolerant decoding so older on-disk records (without `subject`/`status`) still
    /// load — they default to a confirmed user fact.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        layer = try c.decode(MemoryLayer.self, forKey: .layer)
        text = try c.decode(String.self, forKey: .text)
        kind = (try? c.decode(String.self, forKey: .kind)) ?? "fact"
        subject = (try? c.decode(MemorySubject.self, forKey: .subject)) ?? .user
        permanence = (try? c.decode(Double.self, forKey: .permanence)) ?? 0.3
        emotionalSalience = (try? c.decode(Double.self, forKey: .emotionalSalience)) ?? 0.3
        specificity = (try? c.decode(Double.self, forKey: .specificity)) ?? 1
        pinned = (try? c.decode(Bool.self, forKey: .pinned)) ?? false
        archived = (try? c.decode(Bool.self, forKey: .archived)) ?? false
        createdAt = (try? c.decode(Date.self, forKey: .createdAt)) ?? Date()
        lastUsedAt = (try? c.decode(Date.self, forKey: .lastUsedAt)) ?? createdAt
        embedding = (try? c.decode([Double].self, forKey: .embedding)) ?? []
    }
}

/// What retrieval hands back under a token budget: the always-present pins (L1),
/// plus the budgeted L2–L4 recall. The persona supplies the textual foundation;
/// these pins are the user-specific part of the never-decaying floor.
struct RetrievedContext: Sendable {
    var pinned: [String] = []     // always included
    var recalled: [String] = []   // top-scored L2/L3/L4 within budget
}
