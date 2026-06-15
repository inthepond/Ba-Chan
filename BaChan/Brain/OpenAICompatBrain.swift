import Foundation
import CoreGraphics

// MARK: - Cloud brain via the OpenAI-compatible chat-completions API
//
// One actor serves two providers: OpenAI itself, and Google's Gemini through
// its OpenAI-compatible endpoint (https://ai.google.dev/gemini-api/docs/openai)
// — both speak `POST .../chat/completions` with a Bearer key. Mirrors the
// other brains' shape: system turn + recent thread as real turns + the user's
// words last. No sampling params or token caps are sent — the current OpenAI
// models reject `max_tokens` (replaced by `max_completion_tokens`) and the
// reply length is governed by the persona's brevity rules anyway.

actor OpenAICompatBrain: Brain {
    struct Provider {
        let name: String
        let endpoint: URL
        let model: String
    }

    /// OpenAI — `gpt-5.2-chat-latest` is the chat-tuned low-latency tier
    /// (tracks ChatGPT's instant model; verified current June 2026).
    static func openAI(apiKey: String) -> OpenAICompatBrain {
        OpenAICompatBrain(apiKey: apiKey, provider: Provider(
            name: "OpenAI",
            endpoint: URL(string: "https://api.openai.com/v1/chat/completions")!,
            model: "gpt-5.2-chat-latest"))
    }

    /// Gemini via the OpenAI-compatible endpoint — `gemini-3.5-flash` is the
    /// fast tier (verified current June 2026).
    static func gemini(apiKey: String) -> OpenAICompatBrain {
        OpenAICompatBrain(apiKey: apiKey, provider: Provider(
            name: "Gemini",
            endpoint: URL(string: "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions")!,
            model: "gemini-3.5-flash"))
    }

    /// OpenRouter — one key, any model on the router. `model` is the
    /// OpenRouter tag (e.g. "anthropic/claude-opus-4.8"); empty/nil falls back
    /// to the auto router, which picks per request.
    static func openRouter(apiKey: String, model: String?) -> OpenAICompatBrain {
        let tag = model?.trimmingCharacters(in: .whitespacesAndNewlines)
        return OpenAICompatBrain(apiKey: apiKey, provider: Provider(
            name: "OpenRouter",
            endpoint: URL(string: "https://openrouter.ai/api/v1/chat/completions")!,
            model: (tag?.isEmpty == false ? tag! : "openrouter/auto")))
    }

    nonisolated let name: String

    private let apiKey: String
    private let provider: Provider
    private let urlSession: URLSession

    init(apiKey: String, provider: Provider) {
        self.apiKey = apiKey
        self.provider = provider
        self.name = provider.name
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
            var messages = [Message(role: "system",
                                    content: Persona.systemPrompt(context: context))]
            for turn in context.history.suffix(3) {
                let u = turn.user.trimmingCharacters(in: .whitespacesAndNewlines)
                let b = turn.bachan.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !u.isEmpty, !b.isEmpty else { continue }
                messages.append(Message(role: "user", content: u))
                messages.append(Message(role: "assistant", content: b))
            }
            messages.append(Message(role: "user",
                                    content: input.trimmingCharacters(in: .whitespacesAndNewlines)))
            text = ChatArtifacts.clean(try await send(messages: messages))
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
        let messages: [Message]
    }

    private struct Response: Decodable {
        struct Choice: Decodable {
            struct Msg: Decodable { let content: String? }
            let message: Msg
        }
        let choices: [Choice]
    }

    enum APIError: Error { case http(Int), empty }

    func send(messages: [Message]) async throws -> String {
        var request = URLRequest(url: provider.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(
            Request(model: provider.model, messages: messages))

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw APIError.http((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        guard let text = decoded.choices.first?.message.content, !text.isEmpty else {
            throw APIError.empty
        }
        return text
    }

    /// Shared bounded-extraction helper for the conformances below.
    private func extract(system: String, prompt: String) async throws -> String {
        try await send(messages: [Message(role: "system", content: system),
                                  Message(role: "user", content: prompt)])
    }
}

// Vision: all three providers behind this brain are natively multimodal and
// accept a `data:` URI in the OpenAI `image_url` content block. Returns "" on
// any failure so the Conductor falls back to the text path.
extension OpenAICompatBrain: VisionBrain {
    private struct VisionBlock: Encodable {
        struct ImageURL: Encodable { let url: String }
        let type: String
        var text: String?
        var image_url: ImageURL?
    }
    private struct VisionMessage: Encodable {
        let role = "user"
        let content: [VisionBlock]
    }
    private struct VisionRequest: Encodable {
        let model: String
        let messages: [VisionMessage]
    }

    func describe(_ image: CGImage, prompt: String, context: BrainContext) async -> String {
        guard let encoded = AttachmentIngestor.jpegBase64(image) else { return "" }
        do {
            var request = URLRequest(url: provider.endpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.httpBody = try JSONEncoder().encode(VisionRequest(
                model: provider.model,
                messages: [VisionMessage(content: [
                    VisionBlock(type: "text",
                                text: Persona.visionInstruction(userPrompt: prompt,
                                                                context: context)),
                    VisionBlock(type: "image_url",
                                image_url: .init(url: "data:image/jpeg;base64,\(encoded)")),
                ])]))
            let (data, response) = try await urlSession.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return "" }
            let decoded = try JSONDecoder().decode(Response.self, from: data)
            guard let text = decoded.choices.first?.message.content, !text.isEmpty else { return "" }
            return ChatArtifacts.clean(text)
        } catch {
            return ""
        }
    }
}

// The same nightly/extraction conformances as every other real brain.
extension OpenAICompatBrain: MemoryDistilling {
    func distillMemories(from transcript: String, dayLabel: String) async -> [String]? {
        do {
            let raw = try await extract(
                system: "You extract only facts that were explicitly said. Never infer or invent.",
                prompt: MemoryDistiller.prompt(transcript: transcript, dayLabel: dayLabel))
            return MemoryDistiller.parse(ChatArtifacts.clean(raw), transcript: transcript)
        } catch {
            return nil
        }
    }
}

extension OpenAICompatBrain: PersonaExtracting {
    func extractPersonaFacts(from userText: String) async -> [String] {
        do {
            let raw = try await extract(
                system: "You extract only facts the user explicitly stated. Never infer or invent.",
                prompt: PersonaLearner.extractionPrompt(for: userText))
            return PersonaLearner.parseExtractedLines(ChatArtifacts.clean(raw), groundedIn: userText)
        } catch {
            return []
        }
    }
}

extension OpenAICompatBrain: AppearanceStyling {
    func proposeAppearance(genome: FaceGenome, transcript: String) async -> AppearanceProposal? {
        do {
            let raw = try await extract(
                system: "You adjust a cartoon face's traits. Reply with one line of JSON, or NONE.",
                prompt: AppearanceStylist.prompt(genome: genome, transcript: transcript))
            return AppearanceStylist.parse(ChatArtifacts.clean(raw))
        } catch {
            return nil
        }
    }
}
