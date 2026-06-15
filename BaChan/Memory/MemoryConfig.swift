import Foundation

/// Owner-controlled dials (SPEC §7), with **conservative defaults**. These are the
/// knobs the owner tunes; nothing here fabricates content. Kept as plain values so
/// the engine compiles and runs on the host (acceptance harness) and on device.
struct MemoryConfig: Codable, Sendable {
    /// How much gentle, non-factual gap-filling the persona is allowed (0…1).
    /// Default low — warmth and feeling, not invented specifics (SPEC §1.4, §5).
    var dreamingWarmth: Double = 0.2

    /// Multiplier on how quickly L3 detail compresses to gist → feeling.
    /// 1 = baseline; >1 fades faster, <1 slower.
    var fadeRate: Double = 1.0

    /// Base clarity, 0 (hazy) … 1 (clear). Lucidity drifts around this (SPEC §4).
    var lucidityBase: Double = 0.6
    /// Roughly how often a session is a "clear window" (0…1).
    var lucidityClearChance: Double = 0.2

    /// Her natural language/dialect — owner-set (SPEC §7). Empty = unspecified.
    var language: String = ""

    static let `default` = MemoryConfig()

    // MARK: - Compression thresholds derived from `fadeRate` (SPEC §2, §7)

    /// Age (days) past which an L3 episode loses specificity (full detail → gist).
    var gistAfterDays: Double { 7 / max(0.1, fadeRate) }
    /// Age (days) past which an L3 episode collapses to an L4 emotional residue.
    var residueAfterDays: Double { 30 / max(0.1, fadeRate) }
}
