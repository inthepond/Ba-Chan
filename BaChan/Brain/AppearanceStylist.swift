import Foundation
import CoreGraphics

/// A brain that can run the nightly "stylist" pass: read yesterday's
/// conversation and propose a tiny adjustment to Ba-Chan's resting look (the
/// `FaceGenome`). The LLM only picks new values for named, bounded traits —
/// the store caps each step and clamps each range, so a wild output can never
/// break the face. Returns `nil` on a model error (the night is retried next
/// launch) and an empty proposal when the day warrants no change.
protocol AppearanceStyling {
    func proposeAppearance(genome: FaceGenome, transcript: String) async -> AppearanceProposal?
}

/// What the stylist asked for: absolute target values per trait (easier for a
/// small model than signed deltas; the per-day step cap lives in the store)
/// and the one-line reason that goes into the appearance diary.
struct AppearanceProposal {
    var targets: [FaceGenome.Trait: CGFloat] = [:]
    /// A pick from the curated accessory catalog (the store gates swaps to at
    /// most one per week); nil = leave the current accessory alone.
    var accessory: FaceGenome.Accessory?
    var reason: String = ""
}

/// Prompt and parsing for the stylist pass, shared by every brain (the
/// `MemoryDistiller` pattern). Low temperature, one line of JSON or NONE.
enum AppearanceStylist {
    static func prompt(genome: FaceGenome, transcript: String) -> String {
        let traits = FaceGenome.Trait.allCases
            .map { "- " + $0.describe(in: genome) }
            .joined(separator: "\n")
        let catalog = FaceGenome.Accessory.allCases.map(\.rawValue).joined(separator: ", ")
        return """
        Ba-Chan is a hand-drawn companion face whose look slowly changes with \
        the life it shares. Below are the face's adjustable traits with their \
        current values, then yesterday's conversation between Ba-Chan and the \
        person Ba-Chan lives with.

        \(traits)
        - accessory: \(genome.accessory.rawValue) (one of: \(catalog); changes rarely, \
        only when the conversation clearly suits one)

        If the day should leave a small trace on the face, pick at most 2 \
        traits and give each a new value close to its current one, with a \
        short reason. Reply with ONLY one line of JSON, like:
        {"changes": {"smileLines": 0.15}, "reason": "we laughed a lot"}
        or, when an accessory truly fits the day:
        {"changes": {}, "accessory": "flower", "reason": "they talked about their garden"}
        If no change feels right, reply with exactly: NONE

        \(transcript)
        """
    }

    /// Parse the model's reply. Tolerates code fences and prose around the
    /// JSON; anything unusable becomes an empty proposal (skip the night) —
    /// the look is cosmetic, never worth a retry loop.
    static func parse(_ raw: String) -> AppearanceProposal {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.uppercased().hasPrefix("NONE"),
              let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"), start < end,
              let data = String(text[start...end]).data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return AppearanceProposal() }

        var proposal = AppearanceProposal()
        for (key, value) in object["changes"] as? [String: Any] ?? [:] {
            guard let trait = FaceGenome.Trait(rawValue: key) else { continue }
            if let n = value as? NSNumber {
                proposal.targets[trait] = CGFloat(truncating: n)
            } else if let s = value as? String, let d = Double(s) {
                proposal.targets[trait] = CGFloat(d)
            }
        }
        if let name = object["accessory"] as? String {
            proposal.accessory = FaceGenome.Accessory(
                rawValue: name.lowercased().trimmingCharacters(in: .whitespaces))
        }
        let reason = (object["reason"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        proposal.reason = reason.isEmpty ? "A small change after yesterday."
                                         : String(reason.prefix(120))
        return proposal
    }
}
