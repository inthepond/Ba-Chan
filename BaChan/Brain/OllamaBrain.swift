import Foundation
import CoreGraphics

// MARK: - Local-LLM brain via Ollama's HTTP API
//
// Talks to a locally-running Ollama server (https://ollama.com) over its REST API
// at http://localhost:11434 — no external Swift packages, pure Foundation
// URLSession (async/await). This is the macOS-first path: Ollama hosts the model in
// its own process, so unlike `GemmaBrain` there's no in-app download / MLX memory
// dance — we POST and parse JSON. The Conductor prefers it on macOS and falls back
// to `ScriptedBrain` when the server (or the model) isn't reachable.
//
// Mirrors `GemmaBrain`'s shape: an `actor` (network state isolated), a readiness
// check (`isAvailable()` ~ `isModelDownloaded()`), `reply(to:context:)` that sends
// the SAME lean single-message prompt the Gemma path uses (`Persona.prompt` — the
// format tuned for small Gemma chat models, which `gemma3:4b` is), `EmotionTag` /
// `Sentiment` mood handling, and `clean()` reusing the shared `ChatArtifacts` stripper.

actor OllamaBrain: Brain {
    /// Model tags in preference order — the readiness probe picks the best one
    /// actually pulled. Both are multimodal Gemma 3 (the family the lean persona
    /// prompt is tuned for): `12b` is markedly better and comfortable on ≥24 GB
    /// Apple Silicon (`ollama pull gemma3:12b`); `4b` is the light fallback.
    static let preferredModels = ["gemma3:12b", "gemma3:4b"]
    static let defaultModel = "gemma3:4b"

    /// Ollama's default loopback endpoint. Configurable for a non-standard host/port.
    static let defaultHost = URL(string: "http://localhost:11434")!

    nonisolated let name = "Ollama (local)"

    private var model: String
    /// True when init was given an explicit tag — auto-upgrade is then disabled.
    private let pinnedModel: Bool
    private let host: URL
    private let urlSession: URLSession

    /// `model` pins a specific Ollama tag (any pulled model works, e.g.
    /// "qwen2.5:7b"); nil lets the readiness probe choose the best of
    /// `preferredModels` that's pulled. `host` is the server base URL. Bounded
    /// timeouts keep the voice loop responsive — if Ollama is busy/cold we'd
    /// rather fall back than block the "Thinking…" face indefinitely.
    init(model: String? = nil, host: URL = OllamaBrain.defaultHost) {
        self.model = model ?? OllamaBrain.defaultModel
        self.pinnedModel = model != nil
        self.host = host
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60    // 12b: cold load + a full reply fit
        config.timeoutIntervalForResource = 120
        config.waitsForConnectivity = false   // fail fast → Conductor falls back
        self.urlSession = URLSession(configuration: config)
    }

    // MARK: - Reply

    func reply(to input: String, context: BrainContext) async -> BrainReply {
        var text: String
        do {
            // Mirror GemmaBrain's primary path: the lean persona/context as a real
            // **system** turn, the recent thread as REAL user/assistant turns (quoting
            // it inside the prompt made the model copy its own old lines verbatim),
            // and the person's words alone as the final **user** turn. The old merged
            // single message ended with `They just said: "<input>"`, which made the
            // model mirror the framing — echoed openings and quote-wrapped replies.
            var messages = [Message(role: "system", content: Persona.systemPrompt(context: context))]
            for turn in context.history.suffix(3) {
                let u = turn.user.trimmingCharacters(in: .whitespacesAndNewlines)
                let b = turn.bachan.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !u.isEmpty, !b.isEmpty else { continue }
                messages.append(Message(role: "user", content: u))
                messages.append(Message(role: "assistant", content: b))
            }
            messages.append(Message(role: "user",
                                    content: input.trimmingCharacters(in: .whitespacesAndNewlines)))
            let raw = try await chat(messages: messages)
            text = Self.clean(raw)
        } catch {
            // Connection refused / timeout / non-200 / decode failure: the local
            // server can't answer this turn. Return a warm, in-character holding line
            // — the Conductor only routes here when `ollamaReady`, and ScriptedBrain
            // backstops otherwise, so this is the second line of defence.
            return BrainReply(text: "One moment — my thoughts are a little far away.",
                              expression: .sleepy)
        }
        let tagged = EmotionTag.extract(from: &text)
        return BrainReply(text: text, expression: tagged ?? Sentiment.expression(for: text))
    }

    /// Strip chat-template artifacts a small model can leak as literal text. Reuses
    /// the shared Foundation-only stripper (same as `GemmaBrain.clean`).
    static func clean(_ raw: String) -> String { ChatArtifacts.clean(raw) }

    // MARK: - Availability (GET /api/tags)

    /// Whether the Ollama server is reachable AND a usable model is pulled.
    /// With no pinned tag this also RESOLVES the model: the best entry of
    /// `preferredModels` that's actually pulled wins (so pulling `gemma3:12b`
    /// upgrades the brain on the next probe, and a 4b-only machine still works).
    /// Analogous to `GemmaBrain.isModelDownloaded()` / `isReady`. Any failure
    /// (server down, decode error) is reported as "not available".
    func isAvailable() async -> Bool {
        guard let tags = try? await listModels() else { return false }
        // Ollama lists pulled models by full tag, e.g. "gemma3:4b". Match a
        // configured tag, tolerating a bare name ("gemma3" matches "gemma3:4b").
        func pulled(_ tag: String) -> Bool {
            tags.contains { $0 == tag || $0.hasPrefix(tag + ":") }
        }
        if pinnedModel { return pulled(model) }
        guard let best = Self.preferredModels.first(where: pulled) else { return false }
        model = best
        return true
    }

    /// Whether the server responds at all, regardless of which models are pulled —
    /// lets the UI tell "Ollama isn't running" apart from "the model isn't pulled".
    func isServerReachable() async -> Bool {
        (try? await listModels()) != nil
    }

    // MARK: - HTTP

    private struct Message: Codable {
        let role: String
        let content: String
        /// Base64-encoded images for a multimodal model (Ollama's VLM field —
        /// gemma3:4b accepts these). Omitted from the JSON when nil.
        var images: [String]?
    }

    private struct ChatRequest: Encodable {
        let model: String
        let messages: [Message]
        let stream: Bool
        let options: Options
        struct Options: Encodable {
            let num_predict: Int    // Ollama's max-output-tokens knob (≈ GemmaBrain maxTokens)
            let temperature: Double
        }
    }

    private struct ChatResponse: Decodable { let message: Message }

    private struct TagsResponse: Decodable {
        let models: [Model]
        struct Model: Decodable { let name: String; let model: String? }
    }

    /// POST /api/chat with `{"stream": false}`; returns the assistant message content.
    /// Generation params mirror the matching GemmaBrain call (reply: 256 / 0.55 —
    /// room for a substantive paragraph, not just a one-liner; persona
    /// extraction: 120 / 0.1).
    private func chat(messages: [Message],
                      numPredict: Int = 256, temperature: Double = 0.55) async throws -> String {
        var request = URLRequest(url: host.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            ChatRequest(model: model, messages: messages, stream: false,
                        options: .init(num_predict: numPredict, temperature: temperature)))
        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw OllamaError.badStatus
        }
        return try JSONDecoder().decode(ChatResponse.self, from: data).message.content
    }

    /// GET /api/tags → the tags of every pulled model.
    private func listModels() async throws -> [String] {
        let request = URLRequest(url: host.appendingPathComponent("api/tags"))
        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw OllamaError.badStatus
        }
        return try JSONDecoder().decode(TagsResponse.self, from: data)
            .models.map { $0.model ?? $0.name }
    }

    private enum OllamaError: Error { case badStatus }
}

// The default `gemma3:4b` is multimodal in Ollama: a base64 frame in the message's
// `images` field gives a real VLM look — used for camera "what do you see" turns and
// for image attachments. Returns "" on any failure (including a text-only model
// rejecting images) so the Conductor can fall back to the text path.
extension OllamaBrain: VisionBrain {
    func describe(_ image: CGImage, prompt: String, context: BrainContext) async -> String {
        guard let encoded = AttachmentIngestor.jpegBase64(image) else { return "" }
        do {
            let raw = try await chat(messages: [
                Message(role: "user",
                        content: Persona.visionInstruction(userPrompt: prompt, context: context),
                        images: [encoded]),
            ])
            return Self.clean(raw)
        } catch {
            return ""
        }
    }
}

// Nightly memory distillation: a low-temperature pass over one day's transcript.
// nil on any transport/model error so the Conductor retries that day next launch.
extension OllamaBrain: MemoryDistilling {
    func distillMemories(from transcript: String, dayLabel: String) async -> [String]? {
        do {
            let raw = try await chat(messages: [
                Message(role: "system",
                        content: "You extract only facts that were explicitly said. Never infer or invent."),
                Message(role: "user",
                        content: MemoryDistiller.prompt(transcript: transcript, dayLabel: dayLabel)),
            ], numPredict: 200, temperature: 0.1)
            return MemoryDistiller.parse(Self.clean(raw), transcript: transcript)
        } catch {
            return nil
        }
    }
}

// Nightly appearance stylist: a low-temperature pass over yesterday's transcript
// that proposes a tiny change to the resting face. nil on transport/model error
// so the Conductor retries that night next launch.
extension OllamaBrain: AppearanceStyling {
    func proposeAppearance(genome: FaceGenome, transcript: String) async -> AppearanceProposal? {
        do {
            let raw = try await chat(messages: [
                Message(role: "system",
                        content: "You adjust a cartoon face's traits. Reply with one line of JSON, or NONE."),
                Message(role: "user",
                        content: AppearanceStylist.prompt(genome: genome, transcript: transcript)),
            ], numPredict: 120, temperature: 0.2)
            return AppearanceStylist.parse(Self.clean(raw))
        } catch {
            return nil
        }
    }
}

// Persona learning (SPEC §6): a separate, tightly-bounded extraction call keeps only
// facts the user explicitly stated about Ba-Chan. Low temperature to avoid invention;
// returns [] on any error so ordinary chat is never blocked by extraction.
extension OllamaBrain: PersonaExtracting {
    func extractPersonaFacts(from userText: String) async -> [String] {
        do {
            let raw = try await chat(messages: [
                Message(role: "system",
                        content: "You extract only facts the user explicitly stated. Never infer or invent."),
                Message(role: "user", content: PersonaLearner.extractionPrompt(for: userText)),
            ], numPredict: 120, temperature: 0.1)
            return PersonaLearner.parseExtractedLines(Self.clean(raw), groundedIn: userText)
        } catch {
            return []
        }
    }
}
