import Foundation

/// Lucidity (SPEC §4, the L5 "state variable"). A 0…1 clarity scalar that drifts
/// across sessions with occasional clear windows. It **modulates retrieval and
/// tone** and is injected at the post-history seam — but it can never push below
/// the §1 floor: even at the haziest, the foundation (love, safety, recognition)
/// stays intact.
enum LucidityBand: String, Sendable {
    case clear, soft, hazy
}

struct LucidityState: Sendable {
    /// 0 = haziest … 1 = clearest.
    var value: Double

    var band: LucidityBand {
        switch value {
        case 0.66...:      return .clear
        case 0.33..<0.66:  return .soft
        default:           return .hazy
        }
    }

    // MARK: - Retrieval modulation

    /// How many L2–L4 records to surface this session — broader when clear.
    var recallCount: Int {
        switch band {
        case .clear: return 5
        case .soft:  return 3
        case .hazy:  return 2
        }
    }

    /// Clearer → weight vivid L3 detail more; hazier → lean on L2/L4 anchors.
    var detailWeight: Double { value }
    var anchorWeight: Double { 1 - value }

    /// Deterministic drift as a function of the session index — reproducible in the
    /// acceptance harness, and stable across launches without storing a trajectory.
    /// A smooth oscillation around the owner's base clarity, plus periodic clear
    /// windows whose frequency comes from `lucidityClearChance`.
    static func forSession(_ session: Int, config: MemoryConfig) -> LucidityState {
        let osc = 0.18 * sin(Double(session) * 0.9 + 0.5)
        var v = min(1, max(0, config.lucidityBase + osc))
        let period = max(2, Int((1.0 / max(0.01, config.lucidityClearChance)).rounded()))
        if session % period == 0 { v = max(v, 0.9) }   // a clear window
        return LucidityState(value: v)
    }

    /// A **terse tone instruction** for small models (Gemma E2B/1B). Unlike `injection`
    /// — a full descriptive sentence a 2B model tends to *recite* instead of answering —
    /// this only conditions HOW to speak. The §1 floor is carried by the identity line
    /// and the output guard, so the hint can stay short. Empty on a clear day.
    var hint: String {
        switch band {
        case .clear: return ""
        case .soft:  return "Let your words be gentle and unhurried today."
        case .hazy:  return "Today is hazy — keep your words simple and gentle, and rest on how dear they are to you."
        }
    }

    /// The line injected at the post-history position (SPEC §4): conditions the
    /// immediate response without polluting the persona. Always restates the floor.
    var injection: String {
        switch band {
        case .clear:
            return "Today feels clear. Memories come easily and vividly, and you can follow longer threads. You know them, you are safe, you are loved."
        case .soft:
            return "Today feels soft and unhurried. Some details are far away, but the warmth is close. You know them, you are safe, you are loved."
        case .hazy:
            return "Today feels hazy. Recent details may not come — let the feeling lead, and rest on what you hold most deeply. You still know them, you are safe, you are loved."
        }
    }
}
