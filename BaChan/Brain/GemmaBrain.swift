import Foundation
import CoreGraphics

// MARK: - On-device LLM/VLM brain via Apple MLX
//
// Compiles to nothing until the MLX Swift package is present (`import MLXLLM`),
// so the app keeps building/running on the Simulator (scripted brain). With the
// package added this is a real on-device model brain. See INTEGRATION-MLX.md.
//
// Model: Gemma 3 4B (a vision-language model — text chat AND camera). It is
// downloaded on demand (after the user confirms) into **Application Support**,
// which iOS never purges — unlike MLX's default cache location. MLX runs on a
// real Apple-silicon **device**, not meaningfully in the Simulator.

#if canImport(MLXLLM) && canImport(MLXLMCommon)
import MLX
import MLXLLM
import MLXLMCommon
import Hub

actor GemmaBrain: Brain {
    /// Gemma 3n E2B — Google's phone "edge" model (the E2B/E4B variants some sites
    /// also market as "Gemma 4"). It's a ~5B-class model that runs in ~2 GB of
    /// memory via Per-Layer-Embedding caching, so it's far better quality than the
    /// 1B yet still fits a 6 GB device (the 4B needed ~3 GB+ and OOM-crashed).
    /// Text-only (`-lm-`): vision `describe` won't run, but Apple-Vision sight
    /// cues still feed it. Heavier sibling: `gemma-3n-E4B-it-lm-4bit` (~3 GB).
    static let defaultModelId = "mlx-community/gemma-3n-E2B-it-lm-4bit"

    nonisolated let name = "Gemma 3n E2B (on-device)"

    enum LoadState: Equatable { case idle, downloading(Double), ready, failed(String) }
    private(set) var state: LoadState = .idle

    private let modelId: String
    private var container: ModelContainer?

    init(modelId: String = GemmaBrain.defaultModelId) {
        self.modelId = modelId
    }

    var isReady: Bool { if case .ready = state { return true }; return false }

    /// The failure message if the last load failed — surfaced to the user with a retry.
    var loadError: String? { if case .failed(let message) = state { return message }; return nil }

    /// Whether the weights are already on disk (so we can skip the download
    /// prompt and just load). A pure filesystem check — safe to call off-actor.
    nonisolated static func isModelDownloaded(modelId: String = defaultModelId) -> Bool {
        guard let dir = modelDirectory(for: modelId) else { return false }
        return FileManager.default.fileExists(atPath: dir.appendingPathComponent("config.json").path)
    }

    /// Download (if needed) + load the model. Reports 0…1 progress.
    func load(progress: @Sendable @escaping (Double) -> Void) async {
        guard container == nil else { return }
        // Bound MLX's GPU buffer-recycling pool. Its default limit is the memory
        // limit (~1.5× the working set), so on a phone it can grow to several GB
        // of cached inference buffers and trip jetsam — the cause of the ~4 GB /
        // crash-after-a-chat-or-two report. Every official MLX example sets this
        // once before loading; 20 MiB is the proven phone value for E2B's
        // fixed-size per-token buffers.
        MLX.GPU.set(cacheLimit: 20 * 1024 * 1024)
        state = .downloading(0)
        do {
            let loaded: ModelContainer
            if let dir = Self.modelDirectory(for: modelId), Self.isModelDownloaded(modelId: modelId) {
                // Weights are already on disk: load straight from the directory.
                // The `id:` path calls `hub.snapshot(...)`, which makes a Hugging
                // Face network round-trip (file listing + ETag checks) on *every*
                // launch before returning the cached files — the main reason
                // "Loading brain…" drags on cellular/slow Wi-Fi. The `directory:`
                // path skips the network entirely.
                loaded = try await loadModelContainer(hub: Self.persistentHub, directory: dir) { p in
                    progress(p.fractionCompleted)
                }
            } else {
                // First run: fetch from the Hub into the persistent location.
                loaded = try await loadModelContainer(hub: Self.persistentHub, id: modelId) { p in
                    progress(p.fractionCompleted)
                }
            }
            container = loaded
            state = .ready
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func reply(to input: String, context: BrainContext) async -> BrainReply {
        guard let container else {
            return BrainReply(text: "One sec, I'm still waking up my brain…", expression: .sleepy)
        }
        defer { MLX.GPU.clearCache() }   // release this turn's inference buffers
        // 192 tokens ≈ a short paragraph — enough for a substantive answer while
        // keeping on-device decode time tolerable on a phone.
        let params = GenerateParameters(maxTokens: 192, temperature: 0.55)
        let system = Persona.systemPrompt(context: context)
        let userText = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let merged = Persona.prompt(for: input, context: context)
        // The recent thread as REAL chat turns (not narrated in the prompt, which
        // the model copied verbatim) — Sendable pairs, materialized in the closure.
        let history: [(user: String, bachan: String)] = context.history.suffix(3).compactMap {
            let u = $0.user.trimmingCharacters(in: .whitespacesAndNewlines)
            let b = $0.bachan.trimmingCharacters(in: .whitespacesAndNewlines)
            return (u.isEmpty || b.isEmpty) ? nil : (u, b)
        }

        // Generate from a structured chat. `ChatSession.respond(to:)` flattens
        // everything into ONE user turn (and drops the system message), which made the
        // small model recite the "be warm…" framing instead of answering. Sending the
        // persona/context as a real **system** turn and the person's words as the
        // **user** turn keeps the model focused on the message. The `Chat.Message`s are
        // built *inside* the perform closure (it captures only Sendable Strings), since
        // `Chat.Message` isn't `Sendable` and would otherwise cross the actor boundary.
        func generate(useSystemRole: Bool) async throws -> String {
            try await container.perform { (ctx: ModelContext) in
                var messages: [Chat.Message] = [.user(merged)]
                if useSystemRole {
                    messages = [.system(system)]
                    for turn in history {
                        messages.append(.user(turn.user))
                        messages.append(.assistant(turn.bachan))
                    }
                    messages.append(.user(userText))
                }
                let lmInput = try await ctx.processor.prepare(input: UserInput(chat: messages))
                // Annotate the result type: `generate(input:parameters:context:didGenerate:)`
                // has two overloads (([Int])→GenerateResult vs (Int)→GenerateCompletionInfo)
                // and `{ _ in .more }` matches both — the annotation picks the String one.
                // Typing the closure param `[Int]` (not just annotating the result)
                // is what disambiguates on macOS — its MLX type-checker won't pick the
                // overload from the result annotation alone. Picks the GenerateResult one.
                let result: GenerateResult = try MLXLMCommon.generate(
                    input: lmInput, parameters: params, context: ctx) { (_: [Int]) in .more }
                return result.output
            }
        }

        var raw: String
        do {
            raw = try await generate(useSystemRole: true)
        } catch {
            // Some chat templates (older Gemma) reject a separate system role — fold it
            // into the user turn and retry, which every template accepts.
            do {
                raw = try await generate(useSystemRole: false)
            } catch {
                return BrainReply(text: "Hmm, my thoughts got tangled. Try again?", expression: .doubt)
            }
        }
        var text = Self.clean(raw)
        let tagged = EmotionTag.extract(from: &text)
        return BrainReply(text: text, expression: tagged ?? Sentiment.expression(for: text))
    }

    /// Strip Gemma/chat-template artifacts. Implemented in `ChatArtifacts`
    /// (foundation-only) so the host harness can test it; kept here as a thin alias
    /// for the existing call sites (`Self.clean` / `GemmaBrain.clean`).
    static func clean(_ raw: String) -> String { ChatArtifacts.clean(raw) }

    // MARK: - Persistent download location

    /// A HubApi that downloads into Application Support (persistent) rather than
    /// MLX's default `.cachesDirectory`, which iOS can delete under storage pressure.
    private static let persistentHub: HubApi = {
        HubApi(downloadBase: hubBase())
    }()

    nonisolated private static func hubBase() -> URL {
        let support = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                    in: .userDomainMask,
                                                    appropriateFor: nil, create: true))
            ?? URL.temporaryDirectory
        return support.appendingPathComponent("huggingface", isDirectory: true)
    }

    /// Where HubApi stores a model: `<base>/models/<repo-id>`.
    nonisolated private static func modelDirectory(for id: String) -> URL? {
        hubBase().appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
    }

}

// Persona learning (SPEC §6): extract facts the user stated about Ba-Chan and keep
// them. Low temperature + a tightly-bounded prompt to avoid invention; only the
// user's explicit statements are kept (§1.4), and the owner can edit/delete them.
extension GemmaBrain: PersonaExtracting {
    func extractPersonaFacts(from userText: String) async -> [String] {
        guard let container else { return [] }
        defer { MLX.GPU.clearCache() }
        let session = ChatSession(
            container,
            generateParameters: GenerateParameters(maxTokens: 120, temperature: 0.1)
        )
        do {
            let raw = try await session.respond(to: PersonaLearner.extractionPrompt(for: userText))
            return PersonaLearner.parseExtractedLines(Self.clean(raw), groundedIn: userText)
        } catch {
            return []
        }
    }
}

// Nightly memory distillation: same bounded shape as persona extraction —
// fresh session, low temperature. nil when the model isn't loaded or errors,
// so the Conductor retries that day next launch.
extension GemmaBrain: MemoryDistilling {
    func distillMemories(from transcript: String, dayLabel: String) async -> [String]? {
        guard let container else { return nil }
        defer { MLX.GPU.clearCache() }
        let session = ChatSession(
            container,
            generateParameters: GenerateParameters(maxTokens: 200, temperature: 0.1)
        )
        do {
            let raw = try await session.respond(
                to: MemoryDistiller.prompt(transcript: transcript, dayLabel: dayLabel))
            return MemoryDistiller.parse(Self.clean(raw), transcript: transcript)
        } catch {
            return nil
        }
    }
}

// Nightly appearance stylist: same bounded shape as distillation — fresh
// session, low temperature. nil when the model isn't loaded or errors, so the
// Conductor retries that night next launch.
extension GemmaBrain: AppearanceStyling {
    func proposeAppearance(genome: FaceGenome, transcript: String) async -> AppearanceProposal? {
        guard let container else { return nil }
        defer { MLX.GPU.clearCache() }
        let session = ChatSession(
            container,
            generateParameters: GenerateParameters(maxTokens: 120, temperature: 0.2)
        )
        do {
            let raw = try await session.respond(
                to: AppearanceStylist.prompt(genome: genome, transcript: transcript))
            return AppearanceStylist.parse(Self.clean(raw))
        } catch {
            return nil
        }
    }
}

// Vision: with MLXVLM linked and the Gemma 3 VLM loaded, Ba-Chan can look at a
// raw camera frame and describe it. The Conductor routes look-intent turns here.
#if canImport(MLXVLM)
import CoreImage

extension GemmaBrain: VisionBrain {
    func describe(_ image: CGImage, prompt: String, context: BrainContext) async -> String {
        guard let container else { return "I can't quite focus my eyes yet." }
        defer { MLX.GPU.clearCache() }
        let session = ChatSession(
            container,
            generateParameters: GenerateParameters(maxTokens: 192, temperature: 0.6)
        )
        // Carry the §1 foundation floor + gap-handling policy + lucidity into the
        // vision prompt too (not just the text-reply path).
        let instruction = Persona.visionInstruction(userPrompt: prompt, context: context)
        do {
            let raw = try await session.respond(to: instruction,
                                                image: .ciImage(CIImage(cgImage: image)))
            return GemmaBrain.clean(raw)
        } catch {
            return "I see something, but I can't put words to it yet."
        }
    }
}
#endif

#endif
