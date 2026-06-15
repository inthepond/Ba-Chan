#if canImport(FoundationModels)
import FoundationModels

/// On-device LLM brain using Apple's FoundationModels framework (iOS 26+).
/// No network, no API key — everything runs on the Neural Engine.
@available(iOS 26.0, macOS 26.0, *)
final class FoundationModelsBrain: Brain {
    let name = "Apple on-device model"
    private let session: LanguageModelSession

    init() {
        session = LanguageModelSession(instructions: Persona.baseInstructions)
    }

    /// Whether the system model is actually downloaded and usable right now.
    static var isReady: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    func reply(to input: String, context: BrainContext) async -> BrainReply {
        do {
            // Persona is the session's standing instructions; pass per-turn context.
            var turn = Persona.contextBlock(context)
            if !turn.isEmpty { turn += "\n\n" }
            turn += input.trimmingCharacters(in: .whitespacesAndNewlines)
            let response = try await session.respond(to: turn)
            var text = ChatArtifacts.clean(response.content)
            let tagged = EmotionTag.extract(from: &text)
            return BrainReply(text: text, expression: tagged ?? Sentiment.expression(for: text))
        } catch {
            return BrainReply(text: "Hmm, my little brain hiccuped. Say that again?",
                              expression: .doubt)
        }
    }
}

/// Nightly memory distillation: a fresh extraction session over one day's
/// transcript. nil on error so the Conductor retries that day next launch.
@available(iOS 26.0, macOS 26.0, *)
extension FoundationModelsBrain: MemoryDistilling {
    func distillMemories(from transcript: String, dayLabel: String) async -> [String]? {
        let extractor = LanguageModelSession(
            instructions: "You extract only facts that were explicitly said. Never infer or invent.")
        do {
            let response = try await extractor.respond(
                to: MemoryDistiller.prompt(transcript: transcript, dayLabel: dayLabel))
            return MemoryDistiller.parse(response.content, transcript: transcript)
        } catch {
            return nil
        }
    }
}

/// Nightly appearance stylist: a fresh session over yesterday's transcript.
/// nil on error so the Conductor retries that night next launch.
@available(iOS 26.0, macOS 26.0, *)
extension FoundationModelsBrain: AppearanceStyling {
    func proposeAppearance(genome: FaceGenome, transcript: String) async -> AppearanceProposal? {
        let stylist = LanguageModelSession(
            instructions: "You adjust a cartoon face's traits. Reply with one line of JSON, or NONE.")
        do {
            let response = try await stylist.respond(
                to: AppearanceStylist.prompt(genome: genome, transcript: transcript))
            return AppearanceStylist.parse(response.content)
        } catch {
            return nil
        }
    }
}

/// Persona learning (SPEC §6): a fresh session (separate from the persona one) extracts
/// facts the user stated about Ba-Chan and keeps them. Only the user's explicit
/// statements are kept (§1.4); the owner can edit/delete on the memory page.
@available(iOS 26.0, macOS 26.0, *)
extension FoundationModelsBrain: PersonaExtracting {
    func extractPersonaFacts(from userText: String) async -> [String] {
        let extractor = LanguageModelSession(
            instructions: "You extract only facts the user explicitly stated. Never infer or invent.")
        do {
            let response = try await extractor.respond(to: PersonaLearner.extractionPrompt(for: userText))
            return PersonaLearner.parseExtractedLines(response.content, groundedIn: userText)
        } catch {
            return []
        }
    }
}
#endif
