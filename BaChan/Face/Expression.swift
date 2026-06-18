import CoreGraphics

/// The named moods Stackchan can wear, mirroring the original M5Stack-Avatar
/// expression set (plus a few the models reach for often enough to deserve real
/// faces: concerned, peaceful). Each case carries the geometry tweaks that make
/// it readable: eyebrow angle/raise, mouth curvature, and how much the eyes squint.
enum Expression: String, CaseIterable {
    case neutral, happy, sleepy, doubt, angry, sad, surprised
    /// Gentle worry — inner brows knit, small frown, slightly narrowed eyes.
    case concerned
    /// Calm contentment — soft near-closed eyes and an easy smile, quieter than `happy`.
    case peaceful
    /// Bright anticipation — brows up, eyes wide, a ready smile. Worn while a file is
    /// dragged over or being taken in ("ooh, what's this?").
    case curious
    /// Attentive focus — Ba-Chan peering at something on your screen.
    case observing

    /// Eyebrow tilt in degrees. Positive lifts the *outer* end (angry/stern),
    /// negative lifts the inner end (sad/worried).
    var browAngle: Double {
        switch self {
        case .neutral:   return 0
        case .happy:     return -6
        case .sleepy:    return 3
        case .doubt:     return -12
        case .angry:     return 20
        case .sad:       return -18
        case .surprised: return -4
        case .concerned: return -14
        case .peaceful:  return -3
        case .curious:   return -6
        case .observing: return -4
        }
    }

    /// Vertical eyebrow offset as a **fraction of the face unit**, so the lift scales
    /// with the rendered size (a fixed point offset flew off the top of the tiny macOS
    /// menu-bar face). Negative raises the brows (surprise/curiosity). Tuned against a
    /// ~390pt face, so the full-size look is unchanged.
    var browRaise: CGFloat {
        switch self {
        case .happy:     return -0.0128
        case .doubt:     return -0.0154
        case .sad:       return 0.0051
        case .surprised: return -0.0333
        case .concerned: return 0.0026
        case .curious:   return -0.0262
        case .observing: return -0.0160
        default:         return 0
        }
    }

    /// Mouth curvature, +1 full smile … -1 full frown.
    var mouthCurve: CGFloat {
        switch self {
        case .happy:     return 1.0
        case .neutral:   return 0.18
        case .sleepy:    return 0.0
        case .doubt:     return -0.15
        case .angry:     return -0.55
        case .sad:       return -1.0
        case .surprised: return 0.0
        case .concerned: return -0.45
        case .peaceful:  return 0.5
        case .curious:   return 0.45
        case .observing: return 0.08
        }
    }

    /// How much the eyes narrow at rest, 0 = wide open … 1 = nearly shut.
    var eyeSquint: CGFloat {
        switch self {
        case .happy:     return 0.45
        case .sleepy:    return 0.72
        case .angry:     return 0.30
        case .surprised: return -0.25   // eyes pop wider than normal
        case .concerned: return 0.18
        case .peaceful:  return 0.6
        case .curious:   return -0.18   // wide with anticipation
        case .observing: return -0.08   // a touch wide, attentive
        default:         return 0.0
        }
    }

    /// Kawaii cheek blush — when delighted or quietly content (or excited by a gift).
    var showsBlush: Bool { self == .happy || self == .peaceful || self == .curious }
}
