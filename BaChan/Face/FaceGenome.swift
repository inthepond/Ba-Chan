import CoreGraphics
import Foundation

/// The slow-changing part of Ba-Chan's look — the "appearance genome". Where
/// `Expression` moves the face moment to moment, the genome drifts over days
/// and weeks so living together leaves a visible trace (laugh lines after warm
/// stretches, a resting mouth that settles where life has been).
///
/// Every trait is bounded: whatever writes the genome (the daily drift pass or
/// the LLM stylist) only picks positions *inside* these ranges, and steps are
/// capped per day, so any genome renders a valid face and change is always
/// gradual. The default value of every trait reproduces today's tuned look
/// exactly — a fresh install is pixel-identical to the pre-genome face.
struct FaceGenome: Equatable {
    /// Multiplies the eye radius.
    var eyeScale: CGFloat = 1
    /// Multiplies the eye distance from center.
    var eyeSpacing: CGFloat = 1
    /// Multiplies the eyebrow thickness.
    var browWeight: CGFloat = 1
    /// Multiplies the mouth width.
    var mouthWidth: CGFloat = 1
    /// Multiplies the mouth stroke weight.
    var strokeWeight: CGFloat = 1
    /// Added to every expression's mouth curve — where the mouth *rests*.
    var mouthCurveBias: CGFloat = 0
    /// 0 = none … 1 = deep laugh lines beside the eyes.
    var smileLines: CGFloat = 0
    /// A faint resting cheek glow, independent of the happy/peaceful blush.
    var blushBaseline: CGFloat = 0
    /// What Ba-Chan wears, if anything — picked from the curated catalog below.
    var accessory: Accessory = .none

    /// The accessory catalog: each case has hand-authored procedural line art
    /// in `AvatarView`. The stylist *picks a slot*, it never invents geometry —
    /// that's what keeps an LLM-chosen look safe. The store gates swaps to at
    /// most one per week (an accessory is a keepsake, not an outfit change).
    enum Accessory: String, CaseIterable, Codable {
        case none, flower, glasses, hairpin
    }

    /// The genome's adjustable dials. The raw value doubles as the JSON key the
    /// LLM stylist speaks, so renaming a case is a persistence/prompt change.
    enum Trait: String, CaseIterable, Codable {
        case eyeScale, eyeSpacing, browWeight, mouthWidth, strokeWeight
        case mouthCurveBias, smileLines, blushBaseline

        var keyPath: WritableKeyPath<FaceGenome, CGFloat> {
            switch self {
            case .eyeScale:       return \.eyeScale
            case .eyeSpacing:     return \.eyeSpacing
            case .browWeight:     return \.browWeight
            case .mouthWidth:     return \.mouthWidth
            case .strokeWeight:   return \.strokeWeight
            case .mouthCurveBias: return \.mouthCurveBias
            case .smileLines:     return \.smileLines
            case .blushBaseline:  return \.blushBaseline
            }
        }

        /// Hard bounds — the face stays cute anywhere inside them.
        var range: ClosedRange<CGFloat> {
            switch self {
            case .eyeScale:       return 0.85...1.15
            case .eyeSpacing:     return 0.92...1.08
            case .browWeight:     return 0.80...1.25
            case .mouthWidth:     return 0.85...1.15
            case .strokeWeight:   return 0.85...1.25
            case .mouthCurveBias: return -0.12...0.20
            case .smileLines:     return 0...1
            case .blushBaseline:  return 0...0.30
            }
        }

        /// The most a single daily pass may move this trait — evolution reads
        /// as seasons, not weather, and a wild stylist output can't jump the face.
        var maxDailyStep: CGFloat {
            switch self {
            case .smileLines:     return 0.04
            case .blushBaseline:  return 0.03
            case .mouthCurveBias: return 0.02
            default:              return 0.02
            }
        }

        /// One line for the stylist prompt: current value plus what the dial means.
        func describe(in genome: FaceGenome) -> String {
            let v = String(format: "%.2f", genome[keyPath: keyPath])
            let lo = String(format: "%.2f", range.lowerBound)
            let hi = String(format: "%.2f", range.upperBound)
            let meaning: String
            switch self {
            case .eyeScale:       meaning = "eye size"
            case .eyeSpacing:     meaning = "distance between the eyes"
            case .browWeight:     meaning = "eyebrow thickness"
            case .mouthWidth:     meaning = "mouth width"
            case .strokeWeight:   meaning = "line weight of the mouth"
            case .mouthCurveBias: meaning = "resting mouth, below 0 turns down, above 0 turns up"
            case .smileLines:     meaning = "laugh lines beside the eyes, 0 none, 1 deep"
            case .blushBaseline:  meaning = "faint resting cheek glow"
            }
            return "\(rawValue): \(v) (\(meaning), range \(lo) to \(hi))"
        }
    }

    /// Every trait forced into its bounds — the single guarantee the renderer
    /// relies on, applied at every write site.
    func clamped() -> FaceGenome {
        var g = self
        for t in Trait.allCases {
            let r = t.range
            g[keyPath: t.keyPath] = min(max(g[keyPath: t.keyPath], r.lowerBound), r.upperBound)
        }
        return g
    }

    /// Step each trait toward its proposed target, capped at the trait's daily
    /// step and clamped to its range. Returns the steps actually taken (only
    /// meaningful ones), keyed by trait raw value — what the history records.
    mutating func step(toward targets: [Trait: CGFloat]) -> [String: CGFloat] {
        var taken: [String: CGFloat] = [:]
        for (trait, target) in targets {
            let current = self[keyPath: trait.keyPath]
            let cap = trait.maxDailyStep
            let step = min(max(target - current, -cap), cap)
            guard abs(step) > 0.001 else { continue }
            let r = trait.range
            let next = min(max(current + step, r.lowerBound), r.upperBound)
            guard abs(next - current) > 0.001 else { continue }
            self[keyPath: trait.keyPath] = next
            taken[trait.rawValue] = next - current
        }
        return taken
    }
}

// Tolerant decoding: traits added in a later version fall back to their
// defaults instead of failing the whole saved genome.
extension FaceGenome: Codable {
    private enum CodingKeys: String, CodingKey {
        case eyeScale, eyeSpacing, browWeight, mouthWidth, strokeWeight
        case mouthCurveBias, smileLines, blushBaseline, accessory
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        eyeScale       = try c.decodeIfPresent(CGFloat.self, forKey: .eyeScale) ?? 1
        eyeSpacing     = try c.decodeIfPresent(CGFloat.self, forKey: .eyeSpacing) ?? 1
        browWeight     = try c.decodeIfPresent(CGFloat.self, forKey: .browWeight) ?? 1
        mouthWidth     = try c.decodeIfPresent(CGFloat.self, forKey: .mouthWidth) ?? 1
        strokeWeight   = try c.decodeIfPresent(CGFloat.self, forKey: .strokeWeight) ?? 1
        mouthCurveBias = try c.decodeIfPresent(CGFloat.self, forKey: .mouthCurveBias) ?? 0
        smileLines     = try c.decodeIfPresent(CGFloat.self, forKey: .smileLines) ?? 0
        blushBaseline  = try c.decodeIfPresent(CGFloat.self, forKey: .blushBaseline) ?? 0
        // An accessory retired from the catalog falls back to none, not a crash.
        accessory = (try c.decodeIfPresent(String.self, forKey: .accessory))
            .flatMap(Accessory.init(rawValue:)) ?? .none
        self = clamped()
    }
}

/// One entry in the appearance diary: when the look changed, by how much, and
/// why — "I started smiling at rest because we had a warm week" is a feature,
/// not just a log line.
struct AppearanceEvent: Codable, Identifiable {
    var id = UUID()
    let date: Date
    /// "drift" (the daily statistics pass) or "stylist" (the nightly LLM pass).
    let source: String
    let reason: String
    /// Steps actually applied, keyed by trait raw value.
    let changes: [String: CGFloat]
    /// The accessory adopted by this event, if it changed one ("flower", "none"…).
    var accessory: String?
}
