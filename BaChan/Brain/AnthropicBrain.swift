import Foundation
import CoreGraphics

// MARK: - Cloud brain via the Anthropic Messages API
//
// POST https://api.anthropic.com/v1/messages — raw URLSession (there is no
// official Swift SDK). Mirrors OllamaBrain's shape: an actor, the lean persona
// as a real top-level `system`, the recent thread as real user/assistant turns,
// and the person's words alone as the final user turn. The user supplies the
// key in Settings (stored in the Keychain).
//
// Opus 4.8 gotchas (per the current API): `temperature`/`top_p` are REMOVED and
// return 400 if sent — unlike the local brains, send no sampling params at all.
// Thinking is off when the `thinking` field is omitted, which is what a
// low-latency companion wants. Safety classifiers can return a successful
// response with `stop_reason: "refusal"` — check it before reading content.

actor AnthropicBrain: Brain {
    static let defaultModel = "claude-opus-4-8"
    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    nonisolated let name = "Claude"

    private let apiKey: String
    private let model: String
    private let urlSession: URLSession

    init(apiKey: String, model: String = AnthropicBrain.defaultModel) {
        self.apiKey = apiKey
        self.model = model
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 120
        config.waitsForConnectivity = false   // fail fast → Conductor falls back
        self.urlSession = URLSession(configuration: config)
    }

    // MARK: - Reply

    func reply(to input: String, context: BrainContext) async -> BrainReply {
        var text: String
        do {
            var messages: [Message] = []
            for turn in context.history.suffix(3) {
                let u = turn.user.trimmingCharacters(in: .whitespacesAndNewlines)
                let b = turn.bachan.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !u.isEmpty, !b.isEmpty else { continue }
                messages.append(Message(role: "user", content: u))
                messages.append(Message(role: "assistant", content: b))
            }
            messages.append(Message(role: "user",
                                    content: input.trimmingCharacters(in: .whitespacesAndNewlines)))
            let raw = try await send(system: Persona.systemPrompt(context: context),
                                     messages: messages, maxTokens: 1024)
            text = ChatArtifacts.clean(raw)
        } catch {
            return BrainReply(text: "One moment — my thoughts are a little far away.",
                              expression: .sleepy)
        }
        let tagged = EmotionTag.extract(from: &text)
        return BrainReply(text: text, expression: tagged ?? Sentiment.expression(for: text))
    }

    // MARK: - HTTP

    struct Message: Codable {
        let role: String
        let content: String
    }

    private struct Request: Encodable {
        let model: String
        let max_tokens: Int
        let system: String
        let messages: [Message]
    }

    private struct Response: Decodable {
        struct Block: Decodable {
            let type: String
            let text: String?
        }
        let content: [Block]
        let stop_reason: String?
    }

    enum APIError: Error { case http(Int), refusal, empty }

    /// One non-streaming Messages API call; returns the first text block.
    func send(system: String, messages: [Message], maxTokens: Int) async throws -> String {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONEncoder().encode(
            Request(model: model, max_tokens: maxTokens, system: system, messages: messages))

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw APIError.http((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        // A 200 with stop_reason "refusal" carries empty/partial content —
        // surface as an error so the caller's holding line answers instead.
        guard decoded.stop_reason != "refusal" else { throw APIError.refusal }
        guard let text = decoded.content.first(where: { $0.type == "text" })?.text,
              !text.isEmpty else { throw APIError.empty }
        return text
    }
}

// Vision: Claude is natively multimodal — a camera frame / image attachment
// goes up as a base64 JPEG image block ahead of the vision instruction.
// Returns "" on any failure so the Conductor falls back to the text path.
extension AnthropicBrain: VisionBrain {
    private struct VisionBlock: Encodable {
        struct Source: Encodable {
            let type = "base64"
            let media_type = "image/jpeg"
            let data: String
        }
        let type: String
        var text: String?
        var source: Source?
    }
    private struct VisionMessage: Encodable {
        let role = "user"
        let content: [VisionBlock]
    }
    private struct VisionRequest: Encodable {
        let model: String
        let max_tokens: Int
        let messages: [VisionMessage]
    }

    func describe(_ image: CGImage, prompt: String, context: BrainContext) async -> String {
        guard let encoded = AttachmentIngestor.jpegBase64(image) else { return "" }
        do {
            var request = URLRequest(url: Self.endpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            request.httpBody = try JSONEncoder().encode(VisionRequest(
                model: model, max_tokens: 1024,
                messages: [VisionMessage(content: [
                    VisionBlock(type: "image", source: .init(data: encoded)),
                    VisionBlock(type: "text",
                                text: Persona.visionInstruction(userPrompt: prompt,
                                                                context: context)),
                ])]))
            let (data, response) = try await urlSession.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return "" }
            let decoded = try JSONDecoder().decode(Response.self, from: data)
            guard decoded.stop_reason != "refusal",
                  let text = decoded.content.first(where: { $0.type == "text" })?.text
            else { return "" }
            return ChatArtifacts.clean(text)
        } catch {
            return ""
        }
    }
}

// Nightly memory distillation — same bounded contract as the local brains;
// nil on any transport/model error so the Conductor retries next launch.
extension AnthropicBrain: MemoryDistilling {
    func distillMemories(from transcript: String, dayLabel: String) async -> [String]? {
        do {
            let raw = try await send(
                system: "You extract only facts that were explicitly said. Never infer or invent.",
                messages: [Message(role: "user",
                                   content: MemoryDistiller.prompt(transcript: transcript,
                                                                   dayLabel: dayLabel))],
                maxTokens: 300)
            return MemoryDistiller.parse(ChatArtifacts.clean(raw), transcript: transcript)
        } catch {
            return nil
        }
    }
}

// Persona learning — keeps only facts the user explicitly stated about Ba-Chan.
extension AnthropicBrain: PersonaExtracting {
    func extractPersonaFacts(from userText: String) async -> [String] {
        do {
            let raw = try await send(
                system: "You extract only facts the user explicitly stated. Never infer or invent.",
                messages: [Message(role: "user",
                                   content: PersonaLearner.extractionPrompt(for: userText))],
                maxTokens: 200)
            return PersonaLearner.parseExtractedLines(ChatArtifacts.clean(raw), groundedIn: userText)
        } catch {
            return []
        }
    }
}

// Nightly appearance stylist — proposes a tiny change to the resting face.
extension AnthropicBrain: AppearanceStyling {
    func proposeAppearance(genome: FaceGenome, transcript: String) async -> AppearanceProposal? {
        do {
            let raw = try await send(
                system: "You adjust a cartoon face's traits. Reply with one line of JSON, or NONE.",
                messages: [Message(role: "user",
                                   content: AppearanceStylist.prompt(genome: genome,
                                                                     transcript: transcript))],
                maxTokens: 200)
            return AppearanceStylist.parse(ChatArtifacts.clean(raw))
        } catch {
            return nil
        }
    }
}
