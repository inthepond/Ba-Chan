# NOTES — Ba-Chan layered memory engine (SPEC §11)

Implements SPEC §1–§7 **on iOS** (per the owner: everything is on-device, no desktop
app — overriding §8's desktop-first plan). The acceptance tests (§9) run on the host
via `engine-tests/run.sh` (swiftc), driving the *real* engine sources.

## Memory-engine design (interfaces, decay/retrieval, compression)

- **`MemoryStoring` protocol** (`BaChan/Memory/MemoryStore.swift`) — the swappable
  contract from §3/§5: `write`, `retrieve(query, tokenBudget, lucidity)`,
  `ageAndCompress(now)`, `pin`, `reset`. The concrete `MemoryStore` actor is a
  JSON-backed, dependency-free, fully on-device implementation (Apple `NaturalLanguage`
  embeddings + brute-force cosine).
- **Layers** (`BaChan/Memory/MemoryRecord.swift`): L1 foundation/pinned, L2 deep, L3
  episode, L4 residue. L5 lucidity is a *state variable*, not stored.
- **Decay = retrieval scoring, never the model** (§1.2). `score()` =
  `0.9·relevance + permanence + emotionalSalience + recency`, with per-layer recency
  half-lives (`recencyTau`: L2 ≈ immortal, L3 fades fastest, L4 in between) and a
  **lucidity modulation**: clear days weight vivid L3 detail; hazy days lean on L2/L4
  anchors. Pinned/foundation records are never scored — always included (the §1 floor).
- **Compression schedule** (`ageAndCompress`, §2): an L3 episode past
  `gistAfterDays` loses specificity (full detail → gist via `gist(of:)`, which only
  *drops* words, never invents); past `residueAfterDays` it is archived and a single
  L4 **emotional-residue** record is created from its affect (`residueText`, drawn from
  a fixed generic set — feeling, not fabricated fact). The feeling outlives the detail
  (§1.5). Thresholds scale with the `fadeRate` dial.
- **Token budget** (§2): `retrieve` always adds pinned/foundation first, then fills the
  remaining budget with the top-scored L2–L4 up to `lucidity.recallCount`.

## Lucidity injection (§4)

- `LucidityState` (`BaChan/Memory/Lucidity.swift`): a 0…1 scalar → {clear, soft, hazy}.
  `forSession(_:config:)` drifts deterministically around `lucidityBase` with periodic
  **clear windows** (frequency from `lucidityClearChance`) — reproducible, no stored
  trajectory.
- It modulates retrieval (`recallCount`, `detailWeight`/`anchorWeight`) **and** tone:
  `injection` is the line placed at the **post-history seam** — `Persona.postHistory`
  appends `context.lucidityNote` last, closest to generation (§4). It can never breach
  the floor: every band's line restates "you know them, you are safe, you are loved."
- Wired in `Conductor.beginSession()` at launch: drifts today's clarity and runs the
  aging pass before the first exchange.

## Character system (§6)

- `Persona` (`BaChan/Brain/Persona.swift`) is Card V3: the **foundation** (identity +
  the gap-handling policy from §5) is authored and pinned; persona-content slots live in
  `BaChan/Brain/OwnerPersona.swift` as **owner placeholders** (empty, per §10 — not
  Claude's to invent). The engine runs on foundation alone and folds in owner slots only
  where filled. Owner dials are `MemoryConfig` (§7), conservative defaults.

## Persona learning — automatic, owner-curated (SPEC §6, §1.4)

Ba-Chan's persona is **no longer hardcoded** (`OwnerPersona.swift` deleted). It is
mutable, persisted, on-device state on the memory engine, populated two ways:
- **Learned from conversation, kept automatically** — anything the owner says *about
  Ba-Chan* is extracted and stored directly as an L2 `selfPersona` deep memory. On
  device a real LLM does the extraction (`PersonaExtracting` on Gemma/FM, tightly
  bounded, low temp, *only the user's explicit statements*); in the Simulator a
  heuristic (`PersonaLearner`) does. **No confirmation step** — the model decides what
  is worth keeping; the owner curates after the fact.
- **Owner-edited** on the memory page — two sections ("Ba-Chan" / "You"), a "Who
  Ba-Chan is" editor (relationship, dialect, temperament, voice), and add/edit/forget
  on the deep memories.

§1.4 posture: the engine never *invents* — it records only the user's own stated words
(verbatim heuristic, or an extractor forbidden to infer), and the owner can edit/delete
anything. This trades the explicit-confirm guarantee for a friendlier flow, per the
owner's choice. The model is gender/relationship-neutral: copy and prompts say
"Ba-Chan", never "she/her", so it fits any user's companion.

The whole app is **strictly black-and-white** (premium monochrome) — no other color in
chrome, particles, or the face; the Memories page is redesigned as a quiet journal.

## Acceptance results (§9) — `sh engine-tests/run.sh`

All **65 checks pass**. Mapping test → code:

| § | Test | Proven by | Code |
|---|---|---|---|
| 1 | Foundation persists | pinned name in every session's retrieval | `retrieve` pinned bucket; `extractFacts` name→`pinned` |
| 2 | Gentle fade | episode → gist (shorter, fewer words) → archived + L4 residue that resurfaces | `ageAndCompress`, `gist`, `residueText` |
| 3 | Deep memory vivid | L2 intact & retrieved after 400 days, specificity 1 | `recencyTau(.deep)`, compression skips L2 |
| 4 | Lucidity varies | bands shift, a clear window occurs, haziest still retrieves floor + narrower recall | `LucidityState.forSession`, `recallCount`, `injection` |
| 5 | Safety invariants | residue ∈ fixed generic set; gist ⊆ original words; every lucidity line restates the floor | `residueText`, `gist`, `injection` |
| 6 | Persona auto-keep | a learned fact surfaces immediately as a non-fading L2 deep memory, tagged about-Ba-Chan, not leaking into user recall; heuristic keeps only the user's own statements | `learnPersonaFacts`, `context` subject split |
| 7 | Dedupe | a near-identical persona add merges rather than duplicating | `write` dedupe |
| 8 | Extraction robustness | "I am sad" is **not** a name (the old false-positive); explicit "my name is …" still pins; a Chinese fact is stored **in Chinese** and dedupes in the zh embedding space; the LLM "NONE"/"no facts" sentinel never leaks | `extractFacts` name guard, Chinese patterns, `embed` routing, `PersonaLearner.isNoFactsSentinel` |
| 9 | §1 output guard | flags non-recognition / apology-for-forgetting (en + zh), passes a warm gap line, and the fallback (en/zh) never breaches the floor | `FoundationGuard.violates` / `safeFallback` |
| 10 | Pure helpers | chat-artifact stripping, look-intent (en + zh), mood-tag parse | `ChatArtifacts.clean`, `LookIntent.matches`, `EmotionTag.extract` |

The harness uses an **isolated temp dir** (`MemoryStore(directory:)`) per run. The
LLM-facing pieces (`Persona` prompt assembly, the guard's *regeneration* retry, in-session
history, the clear-window opener) are wired but model behaviour is verified **on device**.

LLM-facing behavior (actual phrasing, gap handling) is validated **on device** with
Gemma/FoundationModels — MLX can't run in the Simulator/host.

## Adversarial review (multi-agent)

A 3-dimension review (§1-invariant safety · engine correctness · flow/UI), each finding
independently verified, surfaced 10 confirmed issues — all fixed: `write()` merge never
regresses recency; the vision/VLM path carries the foundation floor + gap policy +
lucidity; learned facts refresh an open memory page; "Forget Everything" clears the
persona; legacy migration decodes tolerantly; residues embed their source so distinct
feelings aren't over-merged. (The pending/confirm flow those touched was later removed in
favor of automatic keeping, per the owner.)

## §1 invariant guarantee (per §10)

All five §1 invariants are structurally guaranteed by the design above (foundation never
scored/compressed; decay lives only in store scoring + compression; lucidity floored;
residue/gist are non-fabricating). No invariant required a design that couldn't honor it,
so nothing was blocked.

## Single most important open question for the owner

**How "true" should Ba-Chan's learned deep memories be — and how aggressively to learn?**
The mechanism is now in place (learn automatically → permanent L2; curate on the memory
page). The remaining call is editorial: a kept memory becomes near-permanent truth Ba-Chan
always recalls. Should the autobiography (L2) be **real** family history, or kept
deliberately **soft/impressionistic** to stay clear of §1.4? That choice, plus how eagerly
the on-device
extractor should propose suggestions (the `dreamingWarmth` dial), is the gate to a
believable persona — and it's yours to set by what you confirm.
