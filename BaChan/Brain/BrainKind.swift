import Foundation

/// What a given brain can actually make use of, used to show/hide the matching
/// capability toggles in the UI. These describe the **model's** modalities — not
/// the device's (the system STT/TTS and camera work regardless), so the UI
/// reflects what each model can meaningfully do with the input.
struct BrainCapabilities {
    let vision: Bool   // can use the camera (VLM describe, or Apple-Vision sight cues)
    let speech: Bool   // has an audio modality → hearing + voice make sense
}

/// The selectable on-device models, surfaced in the model-switcher. The Conductor
/// keeps one instance per available kind and routes `reply(...)` to the selected
/// one; `ScriptedBrain` is the silent internal fallback and is intentionally not
/// listed here.
enum BrainKind: String, CaseIterable, Identifiable {
    case gemma      // on-device MLX — Gemma 3n E2B today (Gemma 4 once mlx-swift adds it)
    case appleFM    // Apple FoundationModels (iOS 26+ / macOS 26+)
    #if os(macOS)
    case ollama     // local Ollama server (http://localhost:11434) — macOS-first
    #endif
    // Cloud brains — listed only when the user has saved an API key in Settings.
    case claude     // Anthropic Messages API
    case openai     // OpenAI chat completions
    case gemini     // Gemini via its OpenAI-compatible endpoint
    case openrouter // OpenRouter (any model on the router, OpenAI-compatible)

    var id: String { rawValue }

    /// The kinds that need an API key from Settings (vs local/on-device).
    var isCloud: Bool {
        switch self {
        case .claude, .openai, .gemini, .openrouter: return true
        default: return false
        }
    }

    var displayName: String {
        switch self {
        case .gemma:      return "Gemma (on-device)"
        case .appleFM:    return "Apple Intelligence"
        #if os(macOS)
        case .ollama:     return "Ollama (local)"
        #endif
        case .claude:     return "Claude (cloud)"
        case .openai:     return "OpenAI (cloud)"
        case .gemini:     return "Gemini (cloud)"
        case .openrouter: return "OpenRouter (cloud)"
        }
    }

    /// SF Symbol for the switcher menu row.
    var menuIcon: String {
        switch self {
        case .gemma:      return "cpu"
        case .appleFM:    return "sparkles"   // valid + visible (apple.logo renders blank on device)
        #if os(macOS)
        case .ollama:     return "server.rack"
        #endif
        case .claude, .openai, .gemini, .openrouter: return "cloud"
        }
    }

    var capabilities: BrainCapabilities {
        switch self {
        // Gemma E2B is multimodal — camera and hearing+voice both make sense.
        case .gemma:   return BrainCapabilities(vision: true, speech: true)
        // Apple's on-device model understands images (fed via Apple-Vision sight
        // cues) but has no audio modality, so Speech is hidden for it.
        case .appleFM: return BrainCapabilities(vision: true, speech: false)
        #if os(macOS)
        // gemma3:4b via /api/chat is multimodal: camera frames and image attachments
        // are fed as base64 via the message `images` field (VisionBrain), with the
        // Apple-Vision sight cues as text backup; system STT/TTS work regardless.
        case .ollama:  return BrainCapabilities(vision: true, speech: true)
        #endif
        // The cloud models are all natively multimodal: camera frames and image
        // attachments go up as base64 image blocks (VisionBrain), and system
        // STT/TTS handle hearing + voice.
        case .claude, .openai, .gemini, .openrouter:
            return BrainCapabilities(vision: true, speech: true)
        }
    }
}
