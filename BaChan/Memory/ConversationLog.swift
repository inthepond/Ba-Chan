import Foundation

/// A persistent, timestamped record of every exchange — the "what was actually
/// said" companion to `MemoryStore`'s distilled facts. The store remembers *who
/// the user is*; this log remembers *the conversations themselves*, so questions
/// like "what did we chat about yesterday" can be answered from the record
/// instead of invented. JSON in Application Support, capped, fully on-device.
///
/// Deliberately separate from `MemoryStore`: the SPEC's layered decay governs
/// what Ba-Chan *holds*; the log is her diary — flat, chronological, queried by
/// time rather than by embedding.
actor ConversationLog {
    struct LoggedTurn: Codable {
        var user: String
        var bachan: String
        var date: Date
    }

    private(set) var turns: [LoggedTurn] = []
    private let fileURL: URL
    /// Hard cap so the JSON stays small (~2000 turns ≈ months of chat).
    private let cap = 2000

    /// `directory` overrides where the JSON lives (Application Support by default).
    init(directory: URL? = nil) {
        let dir = directory
            ?? (try? FileManager.default.url(for: .applicationSupportDirectory,
                                             in: .userDomainMask,
                                             appropriateFor: nil, create: true))
            ?? URL.temporaryDirectory
        fileURL = dir.appendingPathComponent("bachan_chatlog.json")
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([LoggedTurn].self, from: data) {
            // Scrub artifacts that older builds let slip into logged replies — mood
            // tags, em dashes, markdown asterisks — so restored transcripts and
            // journal digests match the current output rules.
            turns = saved.map { turn in
                var turn = turn
                turn.bachan = Self.scrubbed(turn.bachan)
                return turn
            }
        }
    }

    private static func scrubbed(_ text: String) -> String {
        let untagged = text.replacingOccurrences(of: #"\[[A-Za-z]{2,16}\]"#, with: "",
                                                 options: .regularExpression)
        return ChatArtifacts.normalizePunctuation(untagged)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var count: Int { turns.count }

    func append(user: String, bachan: String, at date: Date = Date()) {
        turns.append(LoggedTurn(user: user, bachan: bachan, date: date))
        if turns.count > cap { turns.removeFirst(turns.count - cap) }
        save()
    }

    /// Every exchange within a time window, oldest first.
    func turns(in interval: DateInterval) -> [LoggedTurn] {
        turns.filter { interval.contains($0.date) }
    }

    /// The last `count` exchanges no older than `maxAge` — used to restore the
    /// short-term thread (and the visible transcript) across a relaunch, without
    /// resurrecting a days-old conversation as if it just happened.
    func recent(_ count: Int, maxAge: TimeInterval) -> [LoggedTurn] {
        let cutoff = Date().addingTimeInterval(-maxAge)
        return Array(turns.suffix(count).filter { $0.date >= cutoff })
    }

    func reset() {
        turns.removeAll()
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(turns) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    // MARK: - Journal digest (what gets injected into the prompt)

    /// Compress a window of logged turns into a compact, labelled journal block.
    /// Narrated past-tense (like the lean history lines) so a small model treats
    /// it as a record to answer from, not a dialogue to continue. Budgeted hard —
    /// most recent turns win.
    static func digest(_ turns: [LoggedTurn], label: String,
                       maxTurns: Int = 8, maxChars: Int = 900) -> String {
        guard !turns.isEmpty else {
            return "You didn't talk \(label) — it was quiet between you then."
        }
        var lines: [String] = []
        var used = 0
        for turn in turns.suffix(maxTurns).reversed() {   // newest first while budgeting…
            let u = Self.clip(turn.user, to: 140)
            let b = Self.clip(turn.bachan, to: 140)
            let line = "- They said “\(u)”, and you answered “\(b)”."
            if used + line.count > maxChars { break }
            used += line.count
            lines.append(line)
        }
        return "What was said \(label):\n" + lines.reversed().joined(separator: "\n")   // …shown oldest first
    }

    private static func clip(_ text: String, to limit: Int) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count > limit ? String(t.prefix(limit)) + "…" : t
    }
}

/// Detects "about a past time" in a user message and resolves it to a concrete
/// date window — the trigger for pulling the conversation log into context.
/// Heuristic and bilingual (English + Chinese), mirroring `MemoryStore`'s
/// extraction style: cheap, on-device, no model call.
enum TemporalQuery {
    struct Match {
        let interval: DateInterval
        /// How to speak of the window in the prompt ("yesterday", "this morning"…).
        let label: String
    }

    static func parse(_ text: String, now: Date = Date(),
                      calendar: Calendar = .current) -> Match? {
        let t = text.lowercased()
        let todayStart = calendar.startOfDay(for: now)

        func day(_ offset: Int) -> DateInterval {
            let start = calendar.date(byAdding: .day, value: -offset, to: todayStart)!
            return DateInterval(start: start, duration: 86_400)
        }

        if t.contains("day before yesterday") || t.contains("前天") {
            return Match(interval: day(2), label: "the day before yesterday")
        }
        if t.contains("yesterday") || t.contains("昨天") || t.contains("昨晚") {
            return Match(interval: day(1), label: "yesterday")
        }
        if t.contains("this morning") || t.contains("今天早上") || t.contains("今早") {
            let start = calendar.date(bySettingHour: 5, minute: 0, second: 0, of: now)!
            return Match(interval: DateInterval(start: min(start, now), end: now),
                         label: "this morning")
        }
        if t.contains("today") || t.contains("earlier today") || t.contains("今天") {
            return Match(interval: DateInterval(start: todayStart, end: now), label: "today")
        }
        if t.contains("last week") || t.contains("上周") || t.contains("上星期") || t.contains("past week") {
            let start = calendar.date(byAdding: .day, value: -7, to: todayStart)!
            return Match(interval: DateInterval(start: start, end: now), label: "this past week")
        }
        // "N days ago" / "N天前"
        if let match = t.range(of: #"(\d{1,2})\s*(?:days ago|天前)"#, options: .regularExpression),
           let n = Int(t[match].components(separatedBy: CharacterSet.decimalDigits.inverted).joined()),
           n > 0, n <= 30 {
            return Match(interval: day(n), label: "\(n) days ago")
        }
        // A recall question with no explicit day ("what have we talked about",
        // "do you remember what we discussed") → the recent week.
        let recallVerbs = ["talk", "chat", "discuss", "tell you", "we said", "聊", "说过", "讲过", "记得"]
        let asksRecall = (t.contains("what") || t.contains("remember") || t.contains("记得") || t.contains("什么"))
            && recallVerbs.contains(where: t.contains)
        if asksRecall {
            let start = calendar.date(byAdding: .day, value: -7, to: todayStart)!
            return Match(interval: DateInterval(start: start, end: now), label: "recently")
        }
        return nil
    }
}
