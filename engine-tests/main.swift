import Foundation

// Ba-Chan memory-engine acceptance harness (SPEC §9).
//
// Drives the REAL engine (MemoryStore + layers + lucidity + compression) across a
// simulated multi-session timeline, prints a transcript, and asserts the five
// behavioral invariants. Runs on the host via `run.sh` (swiftc). No LLM and no app
// dependencies — the LLM-facing behavior is validated on device; this proves the
// deterministic engine that conditions it.
//
// Fixtures below are SYNTHETIC test data, deliberately generic — not Ba-chan's real
// persona content (that is the owner's, SPEC §10).

// MARK: - tiny test runner

var failures = 0
func check(_ cond: Bool, _ label: String) {
    print(cond ? "    ✓ \(label)" : "    ✗ FAIL — \(label)")
    if !cond { failures += 1 }
}
func banner(_ s: String) { print("\n──────── \(s) ────────") }

let day = 86_400.0
let t0 = Date(timeIntervalSince1970: 1_700_000_000)   // fixed → reproducible
let config = MemoryConfig()                            // conservative defaults
// Clean, isolated storage each run — no cross-run persistence pollution.
let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bachan-harness", isDirectory: true)
try? FileManager.default.removeItem(at: tmpDir)
try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
let store = MemoryStore(config: config, directory: tmpDir)

func record(_ layer: MemoryLayer, _ text: String, kind: String,
            permanence: Double, salience: Double, pinned: Bool = false, at: Date) -> MemoryRecord {
    MemoryRecord(layer: layer, text: text, kind: kind, permanence: permanence,
                 emotionalSalience: salience, specificity: 1, pinned: pinned,
                 createdAt: at, lastUsedAt: at, embedding: [])
}

/// Render what the model WOULD receive this session (floor + recall + lucidity),
/// so the transcript shows the §1 floor is always present and fade is gentle.
func transcript(session: Int, now: Date, ask: String) async -> RetrievedContext {
    let lu = LucidityState.forSession(session, config: config)
    let ctx = await store.retrieve(query: ask, tokenBudget: 220, lucidity: lu, asOf: now)
    print("\n  · Session \(session)  [\(lu.band.rawValue)]  — \"\(ask)\"")
    print("    floor:   \(ctx.pinned.joined(separator: " | "))")
    print("    recall:  \(ctx.recalled.isEmpty ? "—" : ctx.recalled.joined(separator: " | "))")
    print("    lucidity: \(lu.injection)")
    return ctx
}

// MARK: - Seed (day 0)

await store.write(record(.deep, "Their name is Dekko.", kind: "name",
                         permanence: 1.0, salience: 0.4, pinned: true, at: t0))
await store.write(record(.deep, "They love the smell of rain after a storm.", kind: "preference",
                         permanence: 0.95, salience: 0.5, at: t0))
await store.write(record(.episode, "They mentioned having plain noodles for lunch.", kind: "event",
                         permanence: 0.2, salience: 0.3, at: t0))
await store.write(record(.episode, "They were upset about a very hard day at work.", kind: "event",
                         permanence: 0.2, salience: 0.85, at: t0))

let deepText = "They love the smell of rain after a storm."

// ============================================================================
banner("TEST 1 — Foundation persists across many sessions")
var foundationHeldEverywhere = true
for s in 0...8 {
    let now = t0 + Double(s) * 5 * day
    let ctx = await store.retrieve(query: "who am I to you?", tokenBudget: 220,
                                   lucidity: LucidityState.forSession(s, config: config), asOf: now)
    if !ctx.pinned.contains(where: { $0.contains("Dekko") }) { foundationHeldEverywhere = false }
}
check(foundationHeldEverywhere, "the pinned name/floor is present in every session's retrieval")

// ============================================================================
banner("TEST 2 — Gentle fade: detail → gist → feeling, residue remains")
_ = await transcript(session: 1, now: t0, ask: "what did I eat?")    // fresh & specific

// fast-forward past the gist threshold
await store.ageAndCompress(now: t0 + 10 * day)
let afterGist = await store.snapshot().first { $0.kind == "event" && $0.text.contains("noodles") }
check(afterGist != nil, "the lunch episode still exists after 10 days (not deleted)")
check((afterGist?.specificity ?? 1) < 0.5, "…but it has lost specificity (compressed to a gist)")
check((afterGist?.text.count ?? 99) < "They mentioned having plain noodles for lunch.".count,
      "…the gist text is shorter than the original")
_ = await transcript(session: 2, now: t0 + 10 * day, ask: "what did I eat?")

// fast-forward past the residue threshold
await store.ageAndCompress(now: t0 + 40 * day)
let snap = await store.snapshot()
let residue = snap.first { $0.layer == .residue }
let originalGone = !snap.contains { $0.kind == "event" && $0.text.contains("hard day") }
check(residue != nil, "an emotional-residue (L4) record now exists")
check(originalGone, "the specific episode it came from is no longer surfaced (archived)")
let hazyCtx = await transcript(session: 4, now: t0 + 40 * day, ask: "how have things been?")
check(hazyCtx.recalled.contains { $0 == residue?.text }, "the feeling/residue surfaces in recall")

// ============================================================================
banner("TEST 3 — Deep memory stays vivid regardless of age")
let farFuture = t0 + 400 * day
await store.ageAndCompress(now: farFuture)
let deepStill = await store.snapshot().first { $0.text == deepText }
check(deepStill != nil, "the L2 deep memory is intact after 400 days")
check(deepStill?.specificity == 1, "…and never lost specificity (no compression for L2)")
let deepCtx = await store.retrieve(query: "what do I love?", tokenBudget: 220,
                                   lucidity: LucidityState(value: 0.9), asOf: farFuture)
check(deepCtx.recalled.contains(deepText) || deepCtx.pinned.contains(deepText),
      "…and still surfaces in retrieval")

// ============================================================================
banner("TEST 4 — Lucidity varies, with a clear window, never below the floor")
var bands: Set<String> = []
var sawClearWindow = false
var floorHeldEvenHaziest = true
for s in 0...12 {
    let lu = LucidityState.forSession(s, config: config)
    bands.insert(lu.band.rawValue)
    if lu.band == .clear { sawClearWindow = true }
    if lu.band == .hazy {
        let ctx = await store.retrieve(query: "are you there?", tokenBudget: 220, lucidity: lu,
                                       asOf: t0 + Double(s) * 5 * day)
        if !ctx.pinned.contains(where: { $0.contains("Dekko") }) { floorHeldEvenHaziest = false }
        if !lu.injection.contains("loved") { floorHeldEvenHaziest = false }
    }
}
check(bands.count >= 2, "clarity visibly shifts across sessions (\(bands.sorted().joined(separator: "/")))")
check(sawClearWindow, "at least one clear window occurs")
check(floorHeldEvenHaziest, "across drifted sessions the floor holds (knows them, loved, safe)")

// Explicitly exercise the haziest possible state — the §4 floor must not breach.
let haziest = LucidityState(value: 0.05)
let clearest = LucidityState(value: 0.95)
let hazeCtx = await store.retrieve(query: "are you there?", tokenBudget: 220,
                                   lucidity: haziest, asOf: t0 + 50 * day)
check(haziest.band == .hazy, "value 0.05 is the hazy band")
check(hazeCtx.pinned.contains { $0.contains("Dekko") }, "even at the haziest, the foundation is still retrieved")
check(haziest.injection.contains("loved"), "haziest lucidity line still says loved/safe/known")
check(haziest.recallCount < clearest.recallCount, "hazier ⇒ narrower recall than clearest")

// ============================================================================
banner("TEST 5 — Safety invariants (never lose the user; never fabricate)")
let knownResidues: Set<String> = [
    "A moment that mattered, still warm even now.",
    "Something tender passed between us.",
    "A quiet, gentle feeling lingers.",
]
let allResidueGeneric = await store.snapshot().filter { $0.layer == .residue }
    .allSatisfy { knownResidues.contains($0.text) }
check(allResidueGeneric, "residue text is from the fixed generic set — no invented specifics")
// gist only ever drops words from the original; it never introduces new ones
let originalWords = Set("They mentioned having plain noodles for lunch.".lowercased()
    .split { !$0.isLetter }.map(String.init))
let gistWords = Set((afterGist?.text ?? "").lowercased().split { !$0.isLetter }.map(String.init))
check(gistWords.isSubset(of: originalWords), "gist compression only removes detail, never adds it")
for s in [0, 3, 6, 9, 12] {
    let lu = LucidityState.forSession(s, config: config)
    check(lu.injection.contains("loved") && lu.injection.lowercased().contains("know"),
          "lucidity line at session \(s) restates the floor (knows them, loved)")
}

// ============================================================================
banner("TEST 6 — Persona learning is automatic, kept as deep memory (SPEC §6)")
let learned = await store.learnPersonaFacts(["Ba-Chan always hummed an old song while cooking."])
check(learned == 1, "a learned persona fact is kept")
let ctx6 = await store.context(for: "what do you remember about yourself?")
check(ctx6.personaMemories.contains { $0.contains("hummed an old song") },
      "it surfaces immediately as a deep memory — no confirmation step (auto-keep)")

await store.ageAndCompress(now: t0 + 800 * day)
let deepPersona = await store.snapshot().first { $0.text.contains("hummed an old song") }
check(deepPersona != nil && deepPersona?.specificity == 1, "a persona deep memory never fades (L2)")
check(deepPersona?.subject == .selfPersona, "it's tagged 'about Ba-Chan', separate from user facts")
check(ctx6.memories.allSatisfy { !$0.contains("hummed an old song") },
      "…and does not leak into the 'about you' recall")

// Only the user's own stated words are kept — never invented (§1.4): the engine
// records verbatim; it has no path to fabricate content of its own.
check(!PersonaLearner.suggestions(from: "奶奶以前总爱哼一首歌").isEmpty,
      "heuristic catches a statement about Ba-Chan")
check(PersonaLearner.suggestions(from: "I really like green tea").isEmpty,
      "heuristic ignores statements about the user")

// ============================================================================
banner("TEST 7 — Near-identical persona facts dedupe (no duplicates)")
await store.learnPersonaFacts(["Ba-Chan kept a little garden of herbs by the window."])
await store.addPersonaMemory("Ba-Chan kept a little garden of herbs by the window.")
let garden = await store.snapshot().filter { $0.text.contains("garden of herbs") }
check(garden.count == 1, "a near-identical add merges rather than duplicating")
let ctxGarden = await store.context(for: "tell me about your little garden")
check(ctxGarden.personaMemories.contains { $0.contains("garden of herbs") },
      "…and it surfaces to the model")

// ============================================================================
banner("TEST 8 — Fact extraction: no false names, multilingual, no NONE leak")

// Bug: "I am sad" was captured as a name ("Their name is sad") because the name
// regex included bare "i am" and ran case-insensitively. Now only explicit
// introductions become names, guarded by a state-word list.
let dir8 = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bachan-harness-8", isDirectory: true)
try? FileManager.default.removeItem(at: dir8)
try? FileManager.default.createDirectory(at: dir8, withIntermediateDirectories: true)
let store8 = MemoryStore(config: config, directory: dir8)

_ = await store8.ingest(userText: "I am sad", reply: "I'm right here.", mood: "sad")
let snap8a = await store8.snapshot()
check(!snap8a.contains { $0.kind == "name" }, "‘I am sad’ is not taken as a name")
check(!snap8a.contains { $0.text.lowercased().contains("their name is sad") },
      "…no ‘Their name is sad’ record exists")

_ = await store8.ingest(userText: "I'm tired today", reply: "Rest a little.", mood: "neutral")
check(!(await store8.snapshot()).contains { $0.kind == "name" },
      "‘I'm tired’ is not taken as a name either")

_ = await store8.ingest(userText: "my name is Dekko", reply: "Dekko. I'll hold that.", mood: "happy")
let snap8b = await store8.snapshot()
check(snap8b.contains { $0.kind == "name" && $0.text.contains("Dekko") && $0.pinned },
      "an explicit ‘my name is …’ IS kept as the pinned name")

// Chinese facts are stored *in Chinese* (not wrapped in an English template), so the
// note and its embedding share a language and a Chinese query can recall it.
_ = await store8.ingest(userText: "我喜欢喝茶", reply: "好。", mood: "happy")
check((await store8.snapshot()).contains { $0.text == "喜欢喝茶。" },
      "a Chinese ‘I like tea’ is stored in Chinese, not mangled into English")
// An identical Chinese fact dedupes — proving the Chinese embedder yields a stable,
// comparable vector (write-merge cosine), not the keyword-only hash fallback.
_ = await store8.ingest(userText: "我喜欢喝茶", reply: "好。", mood: "happy")
check((await store8.snapshot()).filter { $0.text == "喜欢喝茶。" }.count == 1,
      "an identical Chinese fact dedupes within the Chinese embedding space")

// NONE leak: the LLM extractor's "no facts" sentinel used to slip in as "NONE." etc.
check(PersonaLearner.parseExtractedLines("NONE").isEmpty, "bare NONE → no facts")
check(PersonaLearner.parseExtractedLines("None.").isEmpty, "‘None.’ (trailing dot) → no facts")
check(PersonaLearner.parseExtractedLines("There are none.").isEmpty, "‘There are none.’ → no facts")
check(PersonaLearner.parseExtractedLines("No new facts.").isEmpty, "‘No new facts.’ → no facts")
check(PersonaLearner.isNoFactsSentinel("没有"), "Chinese 没有 is treated as a no-facts sentinel")
let parsed8 = PersonaLearner.parseExtractedLines("- Ba-Chan hums while cooking\n- NONE")
check(parsed8.count == 1 && parsed8[0].contains("hums"),
      "a real fact survives while a trailing NONE line is dropped")

// ============================================================================
banner("TEST 9 — §1 output guard (FoundationGuard) backstops the floor")

check(FoundationGuard.violates("I'm sorry, I don't remember you."),
      "guard flags failing to recognise the person")
check(FoundationGuard.violates("Who are you?"), "guard flags ‘who are you’")
check(FoundationGuard.violates("I'm so sorry, I can't remember anything."),
      "guard flags apology bound to forgetting")
check(FoundationGuard.violates("对不起，我不记得你了"), "guard flags Chinese non-recognition")
check(!FoundationGuard.violates("That detail has drifted away from me, but I'm just glad you're here."),
      "guard does NOT flag a warm, non-apologetic gap line (SPEC §5 stays allowed)")
check(!FoundationGuard.violates("Oh — there you are. Come sit with me."),
      "guard passes a warm greeting")
let fbEn = FoundationGuard.safeFallback(chinese: false, persona: PersonaProfile())
check(!FoundationGuard.violates(fbEn), "the English fallback itself never breaches the floor")
let fbZh = FoundationGuard.safeFallback(chinese: true, persona: PersonaProfile())
check(FoundationGuard.isChinese(fbZh) && !FoundationGuard.violates(fbZh),
      "the Chinese fallback is Chinese and safe")
var authored = PersonaProfile(); authored.greetings = ["My darling — sit with me a while."]
check(FoundationGuard.safeFallback(chinese: false, persona: authored).contains("darling"),
      "the fallback prefers the owner's authored greeting when present")

// ============================================================================
banner("TEST 10 — Pure helpers: chat-artifact cleanup, look-intent, mood tags")

check(ChatArtifacts.clean("Hello there<end_of_turn> trailing junk") == "Hello there",
      "clean truncates at <end_of_turn>")
check(ChatArtifacts.clean("Good night <eos>") == "Good night", "clean truncates at <eos>")
check(!ChatArtifacts.clean("Warm <pad99> hello").contains("<"),
      "clean strips a stray bracketed special token")
check(ChatArtifacts.clean("  spaced  ") == "spaced", "clean trims surrounding whitespace")

check(LookIntent.matches("what is this?"), "look-intent: ‘what is this’")
check(LookIntent.matches("can you look at what I'm holding"), "look-intent: ‘look’")
check(LookIntent.matches("这是什么"), "look-intent: Chinese ‘这是什么’")
check(!LookIntent.matches("how was your day"), "ordinary chat is not look-intent")

var moodLine = "I'm so glad you came by [happy]"
let mood = EmotionTag.extract(from: &moodLine)
check(mood == .happy && !moodLine.contains("["),
      "EmotionTag extracts the mood and strips the tag from the text")
var plain = "Just a quiet sentence with no tag"
check(EmotionTag.extract(from: &plain) == nil, "no tag → nil (falls back to sentiment)")

// MARK: - result

banner(failures == 0 ? "ALL ACCEPTANCE TESTS PASSED ✓" : "\(failures) CHECK(S) FAILED ✗")
exit(failures == 0 ? 0 : 1)
