import Foundation
import CoreGraphics

/// Owns the persisted `FaceGenome` and the two things that move it:
///
/// 1. **Daily drift** — every delivered expression is tallied; when the day
///    rolls over, the day's emotional warmth nudges the resting face (laugh
///    lines form on warm days, the resting mouth settles toward how life has
///    been). Statistics only — works even on the scripted brain.
/// 2. **The stylist** — `applyProposal` takes the nightly LLM pass's targets
///    (see `AppearanceStylist`), capped and clamped the same way.
///
/// State lives in `bachan_appearance.json` in Application Support, alongside
/// the memory and persona files. Like the genome itself, the file is tolerant:
/// unreadable state just means starting from the neutral look.
@MainActor
final class AppearanceStore {

    private struct State: Codable {
        var genome = FaceGenome()
        var history: [AppearanceEvent] = []
        var tallyDay: Date?
        var warmthSum: Double = 0
        var samples: Int = 0
        /// Day boundary up to which the nightly stylist has run (its
        /// `journalDistilledThrough` equivalent, kept with the rest of the
        /// appearance state instead of UserDefaults).
        var styledThrough: Date?
        /// When the accessory last changed — swaps are gated to one per week.
        var accessoryChangedAt: Date?
    }

    private var state: State
    private let fileURL: URL

    var genome: FaceGenome { state.genome }
    var history: [AppearanceEvent] { state.history }
    var styledThrough: Date { state.styledThrough ?? .distantPast }

    /// `directory` overrides where the JSON lives (Application Support by default).
    init(directory: URL? = nil) {
        let dir = directory
            ?? (try? FileManager.default.url(for: .applicationSupportDirectory,
                                             in: .userDomainMask,
                                             appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        fileURL = dir.appendingPathComponent("bachan_appearance.json")
        if let data = try? Data(contentsOf: fileURL),
           let loaded = try? JSONDecoder().decode(State.self, from: data) {
            state = loaded
            state.genome = state.genome.clamped()
        } else {
            state = State()
        }
        // A day (or more) passed since the last tally — fold it into the genome
        // now so the drift shows at launch, not only mid-conversation.
        rollOverIfNeeded()
    }

    // MARK: - Daily drift (statistics, no LLM)

    /// How a delivered expression colors the day. Neutral/doubt/surprised count
    /// as samples (they keep a flat day flat) but carry no warmth.
    private static func valence(_ e: Expression) -> Double {
        switch e {
        case .happy:     return 1.0
        case .peaceful:  return 0.7
        case .sad:       return -1.0
        case .angry:     return -0.6
        case .concerned: return -0.4
        default:         return 0
        }
    }

    /// Record one delivered expression. On the first tally of a new day the
    /// previous day's totals drift the genome first.
    func tally(_ expression: Expression, now: Date = Date()) {
        rollOverIfNeeded(now: now)
        state.warmthSum += Self.valence(expression)
        state.samples += 1
        save()
    }

    private func rollOverIfNeeded(now: Date = Date()) {
        let today = Calendar.current.startOfDay(for: now)
        guard let day = state.tallyDay else {
            state.tallyDay = today
            return
        }
        guard day != today else { return }
        applyDrift(on: day)
        state.tallyDay = today
        state.warmthSum = 0
        state.samples = 0
        save()
    }

    /// Fold a finished day's emotional weather into the resting face. Needs a
    /// handful of expressions to count as signal; laugh lines form readily on
    /// warm days and fade only slowly on hard ones (they're semi-permanent,
    /// like the real thing).
    private func applyDrift(on day: Date) {
        guard state.samples >= 4 else { return }
        let warmth = max(-1, min(1, state.warmthSum / Double(state.samples)))

        var targets: [FaceGenome.Trait: CGFloat] = [:]
        targets[.mouthCurveBias] = CGFloat(warmth) * 0.18
        targets[.blushBaseline] = CGFloat(max(0, warmth)) * 0.25
        if warmth > 0.2 {
            targets[.smileLines] = state.genome.smileLines + CGFloat(warmth) * 0.02
        } else if warmth < -0.3 {
            targets[.smileLines] = state.genome.smileLines - 0.006
        }

        let reason = warmth > 0.2 ? "A warm day together."
                   : warmth < -0.3 ? "A hard day."
                   : "A quiet day."
        record(targets: targets, reason: reason, source: "drift", date: day)
    }

    // MARK: - Stylist proposals (nightly LLM pass)

    /// Apply the stylist's proposed trait targets — same per-day caps and range
    /// clamps as drift, so even a wild model output only nudges. An accessory
    /// pick is honored at most once a week (a keepsake, not an outfit change).
    func applyProposal(_ proposal: AppearanceProposal, for day: Date) {
        var adopted: FaceGenome.Accessory?
        if let pick = proposal.accessory, pick != state.genome.accessory,
           day.timeIntervalSince(state.accessoryChangedAt ?? .distantPast) >= 6.5 * 86_400 {
            state.genome.accessory = pick
            state.accessoryChangedAt = day
            adopted = pick
        }
        record(targets: proposal.targets, reason: proposal.reason,
               source: "stylist", date: day, accessory: adopted)
    }

    /// Advance the stylist marker past `day` (run, or nothing to run on).
    func markStyled(through day: Date) {
        state.styledThrough = day
        save()
    }

    // MARK: - Shared application + persistence

    private func record(targets: [FaceGenome.Trait: CGFloat], reason: String,
                        source: String, date: Date,
                        accessory: FaceGenome.Accessory? = nil) {
        let taken = state.genome.step(toward: targets)
        guard !taken.isEmpty || accessory != nil else { return }
        state.history.append(AppearanceEvent(date: date, source: source,
                                             reason: reason, changes: taken,
                                             accessory: accessory?.rawValue))
        if state.history.count > 120 {
            state.history.removeFirst(state.history.count - 120)
        }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
