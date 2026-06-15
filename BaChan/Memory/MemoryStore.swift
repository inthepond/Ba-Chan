import Foundation
import NaturalLanguage

/// The storage/retrieval contract (SPEC §3, §5) — kept small so the engine is
/// independent of the backend. The concrete `MemoryStore` below is a JSON-backed,
/// on-device, dependency-free implementation; anything honoring this could replace it.
protocol MemoryStoring: Actor {
    func write(_ record: MemoryRecord)
    func retrieve(query: String, tokenBudget: Int, lucidity: LucidityState) -> RetrievedContext
    func ageAndCompress(now: Date)
    func pin(_ id: UUID)
    func reset()
}

/// On-device **layered** long-term memory (SPEC §2–§4) — no server, no cloud, no
/// external vector DB. Facts are embedded with Apple's `NaturalLanguage`, scored by
/// `relevance + permanence + emotional-salience + recency` (modulated by lucidity),
/// compressed on a schedule from detail → gist → feeling, and persisted as JSON in
/// Application Support. Everything stays on the phone.
///
/// **Decay lives here, not in the model** (SPEC §1.2): the LLM only ever receives
/// whatever survived retrieval, plus the persona's gap-handling policy. **Pending**
/// (unconfirmed) suggestions are never retrieved — the §1.4 guardrail.
///
/// Also holds Ba-Chan's evolving persona (SPEC §6): an editable `PersonaProfile` plus
/// Ba-Chan's deep autobiographical memories as `subject == .selfPersona` records.
///
/// An `actor` so the (cheap) embedding/IO work never blocks the main thread.
actor MemoryStore: MemoryStoring {
    private(set) var records: [MemoryRecord] = []
    private(set) var config: MemoryConfig
    private(set) var personaProfile = PersonaProfile()
    /// Advances once per session (persisted); drives lucidity drift (SPEC §4).
    private(set) var sessionIndex: Int = 0
    private(set) var lucidity: LucidityState
    /// When the user was last present (persisted) — grounds replies in time (SPEC §6).
    private(set) var lastInteractionAt: Date?

    private let fileURL: URL
    private let legacyURL: URL
    private let personaURL: URL
    // Apple's on-device sentence embeddings, one per supported script. English is
    // 512-dim, Simplified Chinese 640-dim — different spaces, so a Chinese memory and
    // an English one never cross-match (the `cosine` dim guard returns 0). `embed`
    // routes each string to the matching model so Chinese recall/dedupe actually work,
    // instead of falling to the keyword-only hash for everything non-English.
    private let englishEmbedder = NLEmbedding.sentenceEmbedding(for: .english)
    private let chineseEmbedder = NLEmbedding.sentenceEmbedding(for: .simplifiedChinese)

    /// `directory` overrides where the JSON lives (Application Support by default);
    /// the acceptance harness passes a clean temp dir for isolation.
    init(config: MemoryConfig = .default, directory: URL? = nil) {
        self.config = config
        let dir = directory
            ?? (try? FileManager.default.url(for: .applicationSupportDirectory,
                                             in: .userDomainMask,
                                             appropriateFor: nil, create: true))
            ?? URL.temporaryDirectory
        fileURL = dir.appendingPathComponent("bachan_memory_v2.json")
        legacyURL = dir.appendingPathComponent("stackchan_memory.json")
        personaURL = dir.appendingPathComponent("bachan_persona.json")

        let state = Self.loadPersona(from: personaURL)
        personaProfile = state.profile
        sessionIndex = state.sessionIndex
        lastInteractionAt = state.lastInteractionAt
        lucidity = LucidityState.forSession(state.sessionIndex, config: config)
        records = Self.loadRecords(from: fileURL, legacy: legacyURL)
    }

    /// Count of surfaced memories (excludes archived originals).
    var count: Int { records.lazy.filter { !$0.archived }.count }

    // MARK: - Session lifecycle (SPEC §4 lucidity + §2 compression schedule)

    /// Start a new session: advance lucidity drift and run the aging/compression
    /// pass. Returns the new lucidity so the UI/Conductor can reflect it.
    @discardableResult
    func beginSession(now: Date = Date()) -> LucidityState {
        sessionIndex += 1
        lucidity = LucidityState.forSession(sessionIndex, config: config)
        // Hygiene for stores written by older builds, which kept every utterance as
        // a verbatim "They said: …" episode (pre-ConversationLog). The journal owns
        // verbatim now; drop the noise so the memory page shows real facts.
        records.removeAll { $0.kind == "event" && $0.text.hasPrefix("They said:") }
        ageAndCompress(now: now)
        save()
        savePersona()
        return lucidity
    }

    func setConfig(_ newConfig: MemoryConfig) {
        config = newConfig
        lucidity = LucidityState.forSession(sessionIndex, config: config)
    }

    // MARK: - MemoryStoring: write / retrieve / age / pin

    /// Add a record unless we already hold a near-identical one (mem0-style dedupe),
    /// in which case we refresh recency and keep the stronger weights.
    func write(_ record: MemoryRecord) {
        var record = record
        if record.embedding.isEmpty { record.embedding = embed(record.text) }
        if let idx = records.firstIndex(where: {
            !$0.archived && $0.layer == record.layer && $0.subject == record.subject
                && cosine($0.embedding, record.embedding) > 0.88
        }) {
            // Refresh recency *forward only* (a merge must never move it backward)
            // and keep the stronger weights.
            records[idx].lastUsedAt = max(records[idx].lastUsedAt, record.lastUsedAt)
            records[idx].permanence = max(records[idx].permanence, record.permanence)
            records[idx].emotionalSalience = max(records[idx].emotionalSalience, record.emotionalSalience)
            records[idx].pinned = records[idx].pinned || record.pinned
            return
        }
        records.append(record)
        capEpisodes()
    }

    /// Hard ceiling on stored records so the JSON + per-turn cosine scan can't
    /// grow without bound (SPEC §2 decay governs *quality*; this is the safety cap
    /// on *count*). Evicts only the oldest live episodic (L3) user record — pinned,
    /// foundation, deep, persona (selfPersona is stored as .deep), residue, and
    /// already-archived records are never touched, so identity and the §1 floor
    /// always survive.
    private func capEpisodes(max maxRecords: Int = 400) {
        while records.count > maxRecords {
            guard let idx = records.indices.filter({
                records[$0].layer == .episode
                    && !records[$0].pinned
                    && !records[$0].archived
                    && records[$0].subject == .user
            }).min(by: { records[$0].createdAt < records[$1].createdAt })
            else { break }   // nothing safely evictable — stop, never drop protected records
            records.remove(at: idx)
        }
    }

    /// Retrieve under a token budget (SPEC §2): **always** include pinned/foundation
    /// records (the §1 floor), then fill the remaining budget with the top-scored
    /// L2–L4 records, modulated by the current `lucidity`.
    func retrieve(query: String, tokenBudget: Int, lucidity: LucidityState) -> RetrievedContext {
        retrieve(query: query, tokenBudget: tokenBudget, lucidity: lucidity, asOf: Date())
    }

    /// Time-injectable variant — lets the acceptance harness fast-forward sessions.
    func retrieve(query: String, tokenBudget: Int, lucidity: LucidityState, asOf now: Date) -> RetrievedContext {
        let q = embed(query)
        let pins = confirmedPins()
        var result = RetrievedContext(pinned: pins.map(\.text))
        var budget = tokenBudget - pins.reduce(0) { $0 + Self.tokens($1.text) }

        for record in ranked(query: q, now: now, lucidity: lucidity).prefix(lucidity.recallCount) {
            let cost = Self.tokens(record.text)
            guard budget - cost >= 0 else { continue }
            budget -= cost
            result.recalled.append(record.text)
            touch(record.id, at: now)
        }
        return result
    }

    /// Compression schedule (SPEC §2): older L3 episodes lose *specificity* — full
    /// detail → gist → an L4 emotional-residue record (the feeling outlives the
    /// detail, SPEC §1.5). Pinned, deep (incl. persona), and pending records are
    /// never compressed.
    func ageAndCompress(now: Date) {
        var produced: [MemoryRecord] = []
        for i in records.indices {
            guard records[i].layer == .episode, !records[i].pinned, !records[i].archived
            else { continue }
            let ageDays = now.timeIntervalSince(records[i].createdAt) / 86_400

            if ageDays >= config.residueAfterDays {
                records[i].archived = true
                if records[i].emotionalSalience >= 0.15 {
                    let feeling = Self.residueText(for: records[i])
                    // The surfaced *text* is a generic feeling (non-fabricating), but
                    // we embed the SOURCE episode so distinct moments stay distinct and
                    // aren't collapsed by dedupe — the feeling outlives the detail
                    // per-moment (SPEC §1.5), and a query about that topic still finds it.
                    let residue = MemoryRecord(
                        layer: .residue, text: feeling, kind: "feeling",
                        subject: records[i].subject,
                        permanence: 0.5, emotionalSalience: records[i].emotionalSalience,
                        specificity: 0, createdAt: records[i].createdAt, lastUsedAt: now,
                        embedding: embed(records[i].text))
                    produced.append(residue)
                }
            } else if ageDays >= config.gistAfterDays, records[i].specificity > 0.45 {
                records[i].text = Self.gist(of: records[i].text)
                records[i].specificity = 0.4
                records[i].embedding = embed(records[i].text)
            }
        }
        for residue in produced { write(residue) }
    }

    func pin(_ id: UUID) {
        if let i = records.firstIndex(where: { $0.id == id }) { records[i].pinned = true; save() }
    }

    func reset() {
        records.removeAll()
        personaProfile = PersonaProfile()   // "Forget everything" wipes Ba-Chan's learned persona too
        save()
        savePersona()
    }

    // MARK: - Persona (SPEC §6) — profile + learned/confirmed deep memories

    func personaProfileValue() -> PersonaProfile { personaProfile }

    func setPersonaProfile(_ profile: PersonaProfile) {
        personaProfile = profile
        savePersona()
    }

    /// Add one of Ba-Chan's deep memories. Stored as L2 `selfPersona` so it stays
    /// vivid and never fades (SPEC §2).
    func addPersonaMemory(_ text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count >= 3 else { return }
        write(MemoryRecord(layer: .deep, text: clean, kind: "persona",
                           subject: .selfPersona,
                           permanence: 0.95, emotionalSalience: 0.5,
                           createdAt: Date(), lastUsedAt: Date(), embedding: embed(clean)))
        save()
    }

    /// Keep persona facts learned from conversation (the model decides what's worth
    /// keeping; deduped against what we already hold). Stored directly as L2
    /// `selfPersona` memories — no confirmation step. Returns how many were new.
    @discardableResult
    func learnPersonaFacts(_ texts: [String]) -> Int {
        var added = 0
        for text in texts {
            let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard clean.count >= 4 else { continue }
            let vec = embed(clean)
            let known = records.contains {
                $0.subject == .selfPersona && !$0.archived && cosine($0.embedding, vec) > 0.85
            }
            if known { continue }
            write(MemoryRecord(layer: .deep, text: clean, kind: "persona",
                               subject: .selfPersona,
                               permanence: 0.95, emotionalSalience: 0.5,
                               createdAt: Date(), lastUsedAt: Date(), embedding: vec))
            added += 1
        }
        if added > 0 { save() }
        return added
    }

    /// Edit a record's text in place (re-embeds). Used when the owner refines a
    /// learned suggestion or an authored memory on the memory page.
    func editText(_ id: UUID, to newText: String) {
        let clean = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let i = records.firstIndex(where: { $0.id == id }) else { return }
        records[i].text = clean
        records[i].embedding = embed(clean)
        save()
    }

    // MARK: - Scoring

    /// Confirmed, non-archived pins/foundation — the always-included §1 floor.
    private func confirmedPins() -> [MemoryRecord] {
        records.filter { !$0.archived && ($0.pinned || $0.layer == .foundation) }
            .sorted { $0.permanence > $1.permanence }
    }

    /// Confirmed, non-pinned, non-foundation records sorted by score (best first).
    private func ranked(query q: [Double], now: Date, lucidity: LucidityState) -> [MemoryRecord] {
        records
            .filter { !$0.archived && !$0.pinned && $0.layer != .foundation }
            .map { (record: $0, s: score($0, query: q, now: now, lucidity: lucidity)) }
            .sorted { $0.s > $1.s }
            .map(\.record)
    }

    /// `relevance + permanence + emotional-salience + recency`, each ~0…1, then
    /// modulated by lucidity: clearer days weight vivid L3 detail; hazier days lean
    /// on L2/L4 anchors (deep memory + feeling). L2 barely decays with age.
    private func score(_ r: MemoryRecord, query: [Double], now: Date, lucidity: LucidityState) -> Double {
        let relevance = cosine(query, r.embedding)
        let ageDays = now.timeIntervalSince(r.lastUsedAt) / 86_400
        let tau = Self.recencyTau(for: r.layer, fadeRate: config.fadeRate)
        let recency = exp(-ageDays / tau)

        var s = 0.9 * relevance + r.permanence + r.emotionalSalience + recency

        switch r.layer {
        case .episode:
            s *= (0.4 + 0.6 * lucidity.detailWeight) * (0.5 + 0.5 * r.specificity)
        case .deep:
            s *= (1.0 + 0.4 * lucidity.anchorWeight)
        case .residue:
            s *= (0.7 + 0.6 * lucidity.anchorWeight)
        case .foundation:
            break
        }
        return s
    }

    private static func recencyTau(for layer: MemoryLayer, fadeRate: Double) -> Double {
        switch layer {
        case .foundation: return 36_500
        case .deep:       return 3_650
        case .residue:    return 120
        case .episode:    return max(1, 10 / max(0.1, fadeRate))
        }
    }

    private func touch(_ id: UUID, at now: Date) {
        if let i = records.firstIndex(where: { $0.id == id }) { records[i].lastUsedAt = now }
    }

    // MARK: - Compression text (heuristic v0; LLM pass is a future upgrade)

    static func gist(of text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = t.last, ".,;:!?".contains(last) { t.removeLast() }
        if let cut = t.firstIndex(where: { ",;:".contains($0) }) {
            let head = String(t[..<cut]).trimmingCharacters(in: .whitespaces)
            if head.count >= 8 { return head + "…" }
        }
        let words = t.split(separator: " ")
        let keep = max(3, words.count - max(1, words.count / 3))
        if words.count > keep { return words.prefix(keep).joined(separator: " ") + "…" }
        return t + "…"
    }

    // Plain wording on purpose: these lines are injected into the prompt, and a
    // lyrical line here gets imitated by the model (see the persona style note).
    static func residueText(for r: MemoryRecord) -> String {
        switch r.emotionalSalience {
        case 0.7...:     return "Something around this mattered to you both. The details are gone, but it was good."
        case 0.45..<0.7: return "You remember feeling close around this, though the details are gone."
        default:         return "You vaguely remember something nice around this."
        }
    }

    // MARK: - App-facing API (kept stable for the Conductor / memory window)

    /// Build the per-turn context for the brain (SPEC §2, §4, §6): pinned floor as
    /// `profile`, budgeted *user* recall as `memories`, Ba-Chan's persona slots +
    /// deep memories, and the lucidity line for the post-history seam.
    func context(for query: String, tokenBudget: Int = 220) -> BrainContext {
        let now = Date()
        let q = embed(query)
        let pins = confirmedPins()
        var budget = tokenBudget - pins.reduce(0) { $0 + Self.tokens($1.text) }
        let rankedAll = ranked(query: q, now: now, lucidity: lucidity)

        var userMemories: [String] = []
        for r in rankedAll where r.subject == .user {
            let cost = Self.tokens(r.text)
            guard budget - cost >= 0 else { continue }
            budget -= cost
            userMemories.append(r.text)
            touch(r.id, at: now)
            if userMemories.count >= lucidity.recallCount { break }
        }
        // Her own deep memories — vivid anchors, surfaced regardless of query.
        let personaMemories = Array(rankedAll.filter { $0.subject == .selfPersona }.prefix(6).map(\.text))

        return BrainContext(profile: pins.map(\.text).joined(separator: " "),
                            memories: userMemories,
                            persona: personaProfile,
                            personaMemories: personaMemories,
                            sight: "",
                            lucidityNote: lucidity.injection,
                            lucidityHint: lucidity.hint,
                            temporalNote: temporalNote(now: now))
    }

    /// A gentle time-of-day grounding, plus — only when the user is genuinely
    /// returning (a 6h+ gap) — how long it's been (SPEC §6). Mid-conversation turns
    /// get just the time of day, so it never reads as "you've been away" every reply.
    private func temporalNote(now: Date) -> String {
        let cal = Calendar.current
        let partOfDay: String
        switch cal.component(.hour, from: now) {
        case 5..<12:  partOfDay = "morning"
        case 12..<17: partOfDay = "afternoon"
        case 17..<22: partOfDay = "evening"
        default:      partOfDay = "late at night"
        }
        var note = "It is \(partOfDay)."
        if let last = lastInteractionAt, now.timeIntervalSince(last) >= 6 * 3600 {
            let phrase: String
            if cal.isDateInYesterday(last) { phrase = "yesterday" }
            else if cal.isDateInToday(last) { phrase = "earlier today" }
            else {
                let days = Int(now.timeIntervalSince(last) / 86_400)
                phrase = days < 7 ? "a few days ago" : "a while ago"
            }
            note += " You were last together \(phrase) — be glad they're back, without making a fuss of it."
        }
        return note
    }

    /// Pull durable facts about the *user* out of a finished exchange and store them.
    /// `mood` weights emotional salience (→ L4 residue later). Returns the live count.
    @discardableResult
    func ingest(userText: String, reply: String, mood: String = "neutral") -> Int {
        let salience = Self.salience(forMood: mood)
        for c in Self.extractFacts(from: userText) {
            write(MemoryRecord(layer: c.layer, text: c.text, kind: c.kind,
                               subject: .user,
                               permanence: c.permanence, emotionalSalience: salience,
                               pinned: c.pinned, createdAt: Date(), lastUsedAt: Date(),
                               embedding: embed(c.text)))
        }
        lastInteractionAt = Date()   // ground the next reply in time (SPEC §6)
        save()
        savePersona()
        return count
    }

    /// Keep facts the nightly LLM pass distilled from a past day's conversations
    /// (the upgrade over `extractFacts`' regexes). Deep layer — these were judged
    /// durable by the model — with `createdAt` set to the source day so recency
    /// scoring and aging stay honest. `write()` dedupes against what's held.
    /// Returns the live count for the UI chip.
    @discardableResult
    func keepDistilledFacts(_ facts: [String], from day: Date) -> Int {
        var any = false
        for fact in facts {
            let clean = fact.trimmingCharacters(in: .whitespacesAndNewlines)
            guard clean.count >= 4 else { continue }
            write(MemoryRecord(layer: .deep, text: clean, kind: "distilled",
                               subject: .user,
                               permanence: 0.6, emotionalSalience: 0.4,
                               createdAt: day, lastUsedAt: Date(), embedding: embed(clean)))
            any = true
        }
        if any { save() }
        return count
    }

    /// Snapshot for the memory window (excludes archived originals). Includes pending
    /// persona suggestions so the owner can review/confirm them.
    func snapshot() -> [MemoryRecord] { records.filter { !$0.archived } }

    func remove(_ id: UUID) {
        records.removeAll { $0.id == id }
        save()
    }

    // MARK: - Mood → salience

    private static func salience(forMood mood: String) -> Double {
        switch mood.lowercased() {
        case "happy", "surprised":         return 0.7
        case "sad", "angry":               return 0.8
        case "concerned":                  return 0.6
        case "peaceful":                   return 0.4
        case "sleepy", "doubt", "neutral": return 0.3
        default:                            return 0.3
        }
    }

    // MARK: - Heuristic fact extraction (about the user; dependency-free)

    private struct Candidate {
        let layer: MemoryLayer; let kind: String; let text: String
        let permanence: Double; let pinned: Bool
    }

    /// Common feeling/state words that follow "I am …" — never a name. Guards the
    /// name patterns so "I am sad" / "I'm tired" stop becoming "Their name is sad".
    private static let notNames: Set<String> = [
        "sad", "happy", "tired", "fine", "good", "okay", "ok", "hungry", "sorry",
        "here", "back", "busy", "scared", "angry", "sick", "bored", "lost", "well",
        "excited", "nervous", "afraid", "glad", "cold", "hot", "old", "young",
        "confused", "worried", "upset", "ready", "sure", "done", "fed", "not",
        "exhausted", "lonely", "anxious", "stressed", "thinking", "going", "feeling",
    ]

    private static func extractFacts(from userText: String) -> [Candidate] {
        let text = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        var out: [Candidate] = []

        func capture(_ pattern: String, _ options: NSRegularExpression.Options = [.caseInsensitive]) -> String? {
            guard let re = try? NSRegularExpression(pattern: pattern, options: options),
                  let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: text)
            else { return nil }
            return String(text[r]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // ---- Name -----------------------------------------------------------
        // Only *explicit* introductions — NOT bare "i am/i'm", which overwhelmingly
        // precedes a feeling ("I am sad"). A state-word guard backstops the rest.
        if let name = capture(#"(?:my name is|call me|i am called|name's)\s+([\p{L}][\p{L}'\-]{0,30})"#),
           !notNames.contains(name.lowercased()) {
            out.append(Candidate(layer: .deep, kind: "name", text: "Their name is \(name).",
                                 permanence: 1.0, pinned: true))
        } else if let name = capture(#"我(?:的名字)?叫\s*([\p{Han}A-Za-z·]{1,12})"#) {
            out.append(Candidate(layer: .deep, kind: "name", text: "名字是\(name)。",
                                 permanence: 1.0, pinned: true))
        }

        // ---- Preferences / facts (English) ----------------------------------
        if let thing = capture(#"(?:i (?:really )?(?:like|love|enjoy|adore))\s+([^.!?,]{2,40})"#) {
            out.append(Candidate(layer: .deep, kind: "preference", text: "They like \(thing).",
                                 permanence: 0.6, pinned: false))
        }
        if let thing = capture(#"(?:i (?:hate|dislike|can't stand|don't like))\s+([^.!?,]{2,40})"#) {
            out.append(Candidate(layer: .deep, kind: "preference", text: "They dislike \(thing).",
                                 permanence: 0.6, pinned: false))
        }
        if let place = capture(#"i live in\s+([^.!?,]{2,40})"#) {
            out.append(Candidate(layer: .deep, kind: "fact", text: "They live in \(place).",
                                 permanence: 0.8, pinned: false))
        }
        if let work = capture(#"i (?:work as|am)\s+(?:a|an)\s+([^.!?,]{2,40})"#) {
            out.append(Candidate(layer: .deep, kind: "fact", text: "They work as a \(work).",
                                 permanence: 0.7, pinned: false))
        }

        // ---- Preferences / facts (Chinese) — stored *in Chinese* so the note and
        //      its embedding share a language and a Chinese query recalls it. -------
        if let thing = capture(#"我(?:很|真的|最)?(?:喜欢|爱|最爱)\s*([^。！？，,、；\s]{1,20})"#) {
            out.append(Candidate(layer: .deep, kind: "preference", text: "喜欢\(thing)。",
                                 permanence: 0.6, pinned: false))
        }
        if let thing = capture(#"我(?:很)?(?:讨厌|不喜欢|不爱)\s*([^。！？，,、；\s]{1,20})"#) {
            out.append(Candidate(layer: .deep, kind: "preference", text: "不喜欢\(thing)。",
                                 permanence: 0.6, pinned: false))
        }
        if let place = capture(#"我住在\s*([^。！？，,、；\s]{1,20})"#) {
            out.append(Candidate(layer: .deep, kind: "fact", text: "住在\(place)。",
                                 permanence: 0.8, pinned: false))
        }

        // No catch-all: older builds journaled EVERY utterance here as a verbatim
        // "They said: …" episode, which flooded the memory page with noise. The
        // ConversationLog now owns the verbatim record (queried by time), and the
        // nightly MemoryDistiller curates durable facts from it — the store keeps
        // only what's worth knowing.
        return out
    }

    // MARK: - Embeddings + math (Apple NaturalLanguage, on-device)

    /// Route a string to the sentence embedder for its script. Han-heavy text uses the
    /// Chinese model, Latin text the English model; anything else (or a missing model)
    /// falls back to the dependency-free hash bag-of-tokens. Same-language vectors are
    /// comparable; cross-language ones differ in dimension and score 0 in `cosine`.
    private func embed(_ string: String) -> [Double] {
        let han = string.unicodeScalars.reduce(0) { (0x4E00...0x9FFF).contains($1.value) ? $0 + 1 : $0 }
        let latin = string.unicodeScalars.reduce(0) {
            (0x41...0x5A).contains($1.value) || (0x61...0x7A).contains($1.value) ? $0 + 1 : $0
        }
        if han > 0, han >= latin, let v = chineseEmbedder?.vector(for: string) { return v }
        if latin > 0, let v = englishEmbedder?.vector(for: string) { return v }
        if let v = englishEmbedder?.vector(for: string) { return v }
        if let v = chineseEmbedder?.vector(for: string) { return v }
        return Self.hashEmbedding(string)
    }

    private func cosine(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in a.indices { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        guard na > 0, nb > 0 else { return 0 }
        return dot / (na.squareRoot() * nb.squareRoot())
    }

    private static func hashEmbedding(_ string: String, dim: Int = 128) -> [Double] {
        var v = [Double](repeating: 0, count: dim)
        for token in string.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            var h = 5381
            for byte in token.utf8 { h = (h &* 33) ^ Int(byte) }
            v[abs(h) % dim] += 1
        }
        return v
    }

    private static func tokens(_ text: String) -> Int { max(1, text.count / 4) }

    // MARK: - Persistence (+ one-time migration from the flat v1 store)

    /// Static so `init` can load synchronously without touching actor isolation.
    /// Migration from the flat v1 store is persisted by the first `save()` (at session
    /// start), so nothing is lost.
    private static func loadRecords(from fileURL: URL, legacy legacyURL: URL) -> [MemoryRecord] {
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([MemoryRecord].self, from: data) {
            return saved
        }
        if let data = try? Data(contentsOf: legacyURL),
           let legacy = try? JSONDecoder().decode([LegacyMemoryItem].self, from: data) {
            return legacy.map { $0.migrated() }
        }
        return []
    }

    private static func loadPersona(from url: URL) -> PersonaState {
        if let data = try? Data(contentsOf: url),
           let state = try? JSONDecoder().decode(PersonaState.self, from: data) {
            return state
        }
        return PersonaState()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private func savePersona() {
        let state = PersonaState(profile: personaProfile, sessionIndex: sessionIndex,
                                 lastInteractionAt: lastInteractionAt)
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: personaURL, options: .atomic)
    }
}

// MARK: - Legacy v1 record → layered migration

/// The pre-layer flat record (`stackchan_memory.json`). Decoded only to migrate.
private struct LegacyMemoryItem: Codable {
    var id = UUID()
    var type: String
    var text: String
    var importance: Int
    var embedding: [Double]
    var createdAt: Date
    var lastUsedAt: Date

    /// Tolerant decoding so a single malformed/old element doesn't abort (and thus
    /// silently discard) the entire one-time migration.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        type = (try? c.decode(String.self, forKey: .type)) ?? "fact"
        text = (try? c.decode(String.self, forKey: .text)) ?? ""
        importance = (try? c.decode(Int.self, forKey: .importance)) ?? 0
        embedding = (try? c.decode([Double].self, forKey: .embedding)) ?? []
        createdAt = (try? c.decode(Date.self, forKey: .createdAt)) ?? Date()
        lastUsedAt = (try? c.decode(Date.self, forKey: .lastUsedAt)) ?? createdAt
    }

    func migrated() -> MemoryRecord {
        let isName = type == "name"
        let layer: MemoryLayer = (isName || importance >= 6) ? .deep : .episode
        return MemoryRecord(
            layer: layer, text: text, kind: type, subject: .user,
            permanence: min(1, Double(importance) / 10),
            emotionalSalience: 0.3, specificity: 1,
            pinned: isName, archived: false,
            createdAt: createdAt, lastUsedAt: lastUsedAt, embedding: embedding)
    }
}
