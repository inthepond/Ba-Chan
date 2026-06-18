import SwiftUI
import AVFoundation
import CoreGraphics
import Combine
#if os(macOS)
import UserNotifications
#endif

/// Orchestrates the conversation and keeps the face in sync. Two capabilities
/// are **manual toggles**, off by default:
///
/// - **Speech** — hearing (mic → STT) *and* voice (TTS + lip-sync). While off,
///   Stackchan makes no sound at all; you chat by typing and it replies as text.
///   It never turns itself on.
/// - **Vision** — the camera. While on, Stackchan sees a frame each turn (Apple
///   Vision cues, plus a VLM look when you ask "what do you see").
///
/// Typing always works, regardless of either toggle.
@MainActor
final class Conductor: ObservableObject {
    enum AgentState: String {
        case idle, listening, thinking, speaking
        var label: String {
            switch self {
            case .idle:      return ""
            case .listening: return "Listening…"
            case .thinking:  return "Thinking…"
            case .speaking:  return "Talking…"
            }
        }
    }

    @Published private(set) var state: AgentState = .idle
    @Published var heard: String = ""
    @Published var reply: String = ""
    /// The visible chat thread (newest last). Restored from the conversation log
    /// on launch when the last exchange was recent; capped so it stays light.
    @Published private(set) var transcript: [ChatMessage] = []
    /// Files staged for the next message (already ingested to text/frames).
    @Published private(set) var pendingAttachments: [ChatAttachment] = []
    /// True while a dropped/picked file is still being read and distilled.
    @Published private(set) var isIngestingAttachment = false
    @Published private(set) var micLevel: Float = 0
    @Published private(set) var memoryCount = 0
    /// Snapshot of remembered facts for the memory window; refreshed when it opens.
    @Published private(set) var memoryItems: [MemoryRecord] = []
    /// How many exchanges the conversation journal holds (shown on the memory page
    /// so it's clear where full conversations live vs. distilled facts).
    @Published private(set) var journalCount = 0
    /// Ba-Chan's editable persona (SPEC §6) — shown in the "About Ba-Chan" section.
    @Published private(set) var personaProfile = PersonaProfile()
    /// Today's clarity (SPEC §4) — drifts per session; shown in the memory window.
    @Published private(set) var lucidity: LucidityBand = .soft

    /// Manual capability toggles (both start OFF; never auto-enabled).
    @Published private(set) var speechEnabled = false
    @Published private(set) var visionEnabled = false
    #if os(macOS)
    /// Screen sight (macOS): "look at my screen" grabs one ScreenCaptureKit frame.
    /// Manual and off by default like the others; needs the Screen Recording TCC.
    @Published private(set) var screenEnabled = false
    #endif

    /// Lifecycle of the on-device model. The download is **user-confirmed**, not
    /// automatic — `needsDownload` means the UI should ask first.
    enum ModelPhase: Equatable {
        case none            // no MLX model in this build
        case needsDownload   // weights absent — confirm before downloading
        case downloading(Double)
        case preparing       // already on disk, loading into memory
        case ready
        case unavailable
        case failed(String)  // download/load failed (or no space) — message + retry
    }
    @Published private(set) var modelPhase: ModelPhase = .none

    let face = FaceController()
    let camera = CameraService()
    /// The slow appearance evolution: persisted genome + daily drift + the
    /// nightly stylist marker. The face adopts its genome at launch and after
    /// every nudge.
    private let appearance = AppearanceStore()

    /// Set by the tray menu (macOS) to slide the Settings page over the
    /// popover; cleared by its Close button.
    @Published var settingsRequested = false

    /// Which model is active, and the models the user may switch between (only
    /// those actually available on this build/OS). The switcher hides when there
    /// are fewer than two. `selectedModel` drives both `brain` and which
    /// capability toggles are shown.
    @Published private(set) var selectedModel: BrainKind = .gemma
    /// Local/on-device kinds present in this build + cloud kinds with a saved
    /// key. Published so Settings and the switcher update when keys change.
    @Published private(set) var availableModels: [BrainKind] = []
    /// The build's local kinds (fixed at init; cloud kinds are appended by
    /// `refreshCloudBrains()` as keys come and go).
    private var localModels: [BrainKind] = []

    private let recognizer = SpeechRecognizer()
    private let speaker = Speaker()
    private let scripted = ScriptedBrain()   // silent fallback (loading / no model)
    private let memory = MemoryStore()
    /// Timestamped record of every exchange (persistent) — answers "what did we
    /// chat about yesterday" from the record, and restores the thread on relaunch.
    private let chatLog = ConversationLog()
    private let motion = MotionService()
    #if os(macOS)
    private let activity = SystemActivityMonitor()
    /// Presence (macOS): the work-rhythm monitor and the speak-first impulses.
    private let rhythm = WorkRhythm()
    private let impulse = ImpulseEngine()
    /// Intercepts Cmd-V so a pasted file/image attaches instead of typing its name.
    private let pasteMonitor = PasteMonitor()
    /// A tiny screenshot shown by the face when Ba-Chan glances at your screen
    /// (a proactive moment); cleared a few seconds later.
    @Published private(set) var lookingImage: CGImage?
    private var lookingClearTask: Task<Void, Never>?
    /// When Ba-Chan last offered to look/summarize (a glance). A non-declining reply
    /// within a few minutes is taken as "yes" and triggers the real page read.
    private var screenOfferAt: Date?
    /// Set by the app delegate: whether the face is on screen right now (popover
    /// open). When it isn't, a proactive line also goes out as a notification.
    var isFaceVisible: (() -> Bool)?
    #endif
    /// When the last real exchange happened — proactive moments keep out of an
    /// active conversation.
    private var lastExchangeAt = Date.distantPast
    /// Calendar day the visible chat box belongs to; when the day rolls over
    /// (app left running past midnight) the next message clears it first, so the
    /// box is always "today" (owner preference — matches the clean-slate launch).
    private var activityDay = Calendar.current.startOfDay(for: Date())
    private var cancellables = Set<AnyCancellable>()

    /// Clear the on-screen chat box if we've crossed into a new day.
    private func clearTranscriptIfNewDay(now: Date = Date()) {
        let today = Calendar.current.startOfDay(for: now)
        guard today != activityDay else { return }
        activityDay = today
        transcript = []
        recentHistory = []
    }

    private static let selectedModelKey = "selectedModel"

    #if canImport(MLXLLM)
    private var gemma: GemmaBrain?
    #endif
    #if canImport(FoundationModels)
    private var _fmBrain: Any?
    @available(iOS 26.0, macOS 26.0, *)
    private var fmBrain: FoundationModelsBrain? { _fmBrain as? FoundationModelsBrain }
    #endif
    #if os(macOS)
    /// Local Ollama server brain (macOS-first). Cached eagerly; `ollamaReady` is
    /// refreshed asynchronously by probing GET /api/tags for the configured model.
    private let ollama = OllamaBrain()
    @Published private(set) var ollamaReady = false
    #endif

    /// The brain for the current selection, falling back to the scripted brain
    /// while a real model is unavailable or still loading.
    private var brain: Brain {
        switch selectedModel {
        #if os(macOS)
        case .ollama:
            // Use Ollama only once the server + model are confirmed present; until
            // then the scripted brain answers (graceful fallback).
            return ollamaReady ? ollama : scripted
        #endif
        case .gemma:
            #if canImport(MLXLLM)
            if let gemma { return gemma }
            #endif
            return scripted
        case .appleFM:
            #if canImport(FoundationModels)
            if #available(iOS 26.0, macOS 26.0, *), FoundationModelsBrain.isReady, let fmBrain { return fmBrain }
            #endif
            return scripted
        case .claude, .openai, .gemini, .openrouter:
            return cloudBrains[selectedModel] ?? scripted
        }
    }

    // MARK: - Cloud brains (API keys from Settings, stored in the Keychain)

    /// One instance per cloud kind whose key is saved. Rebuilt whenever
    /// Settings saves a key, so a new/cleared key takes effect immediately.
    private var cloudBrains: [BrainKind: Brain] = [:]
    /// UserDefaults key for the OpenRouter model tag (not a secret).
    static let openRouterModelKey = "openRouterModel"
    /// UserDefaults key for the Anthropic model id (e.g. "claude-fable-5";
    /// empty = the default `claude-opus-4-8`). Not a secret.
    static let anthropicModelKey = "anthropicModel"

    /// Rebuild the cloud brains from the Keychain and republish the model list.
    /// Called after every Settings save. (Init uses `rebuildCloudBrains()` only:
    /// the saved-model restore hasn't run yet, so the fallback/select/phase
    /// steps here would clobber it or load a model for the default selection.)
    func refreshCloudBrains() {
        rebuildCloudBrains()
        // The selected brain's key may have just been cleared — fall back.
        if !availableModels.contains(selectedModel), let first = availableModels.first {
            selectModel(first)
        }
        refreshModelPhase()
    }

    /// Read the Keychain, build one brain per saved key, republish the list.
    func rebuildCloudBrains() {
        cloudBrains = [:]
        if let key = KeyStore.load(BrainKind.claude.rawValue) {
            let tag = UserDefaults.standard.string(forKey: Self.anthropicModelKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            cloudBrains[.claude] = AnthropicBrain(
                apiKey: key,
                model: (tag?.isEmpty == false) ? tag! : AnthropicBrain.defaultModel)
        }
        if let key = KeyStore.load(BrainKind.openai.rawValue) {
            cloudBrains[.openai] = OpenAICompatBrain.openAI(apiKey: key)
        }
        if let key = KeyStore.load(BrainKind.gemini.rawValue) {
            cloudBrains[.gemini] = OpenAICompatBrain.gemini(apiKey: key)
        }
        if let key = KeyStore.load(BrainKind.openrouter.rawValue) {
            cloudBrains[.openrouter] = OpenAICompatBrain.openRouter(
                apiKey: key,
                model: UserDefaults.standard.string(forKey: Self.openRouterModelKey))
        }
        availableModels = localModels + BrainKind.allCases.filter { cloudBrains[$0] != nil }
    }

    /// True while the on-device model is actively downloading or loading into
    /// memory — input is held until it's ready so messages don't hit the scripted
    /// fallback mid-load.
    var isBrainLoading: Bool {
        switch modelPhase {
        case .downloading, .preparing: return true
        default: return false
        }
    }

    /// Whether Apple Intelligence is enabled/downloaded and usable right now.
    var isAppleFMReady: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) { return FoundationModelsBrain.isReady }
        #endif
        return false
    }

    // MARK: - Capability gating (drives which toggles the UI shows)

    /// When no real model is selectable (Simulator / pre-iOS 26 with no MLX), the
    /// scripted brain drives the app and both toggles stay available.
    var canShowLook: Bool { availableModels.isEmpty || selectedModel.capabilities.vision }
    var canShowSpeech: Bool { availableModels.isEmpty || selectedModel.capabilities.speech }

    private var silenceTask: Task<Void, Never>?
    private let silenceTimeout: Double = 1.4

    /// The last few exchanges this session — short-term continuity handed to the lean
    /// (Gemma) prompt so a reply can follow the thread, not just retrieved memories
    /// (SPEC §5 is long-term fade; this is "don't lose what was just said"). Not the
    /// long-term store; it lives only for the app session.
    private var recentHistory: [BrainContext.Turn] = []
    private let historyLimit = 4

    init() {
        // Build the set of models the user can switch between — only those whose
        // package/OS is present. Order matches the old preference (Gemma first).
        var models: [BrainKind] = []
        #if os(macOS)
        // macOS-first: prefer the local Ollama server. Listed first so a fresh launch
        // (no saved choice) defaults to it; its readiness is probed asynchronously by
        // refreshModelPhase(), and replies fall back to scripted until confirmed.
        models.append(.ollama)
        #endif
        #if canImport(MLXLLM)
        gemma = GemmaBrain()
        models.append(.gemma)
        #endif
        // List Apple FM whenever the OS supports the framework — not only when
        // it's ready *right now*. On a real device Apple Intelligence may be off
        // or still downloading; we still want it in the switcher (its readiness
        // is surfaced as a status, and replies fall back to scripted until then).
        var fmReady = false
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            _fmBrain = FoundationModelsBrain()
            models.append(.appleFM)
            fmReady = FoundationModelsBrain.isReady
        }
        #endif
        localModels = models
        rebuildCloudBrains()   // availableModels = local + cloud kinds with keys

        // Restore the last choice. On a fresh launch (no saved choice) prefer a
        // model that works *without* a download: Gemma needs a ~3 GB fetch, so
        // unless its weights are already on disk we default to Apple FM. The user
        // can still pick Gemma from the switcher (which triggers the download).
        if let saved = UserDefaults.standard.string(forKey: Self.selectedModelKey),
           let kind = BrainKind(rawValue: saved), availableModels.contains(kind) {
            selectedModel = kind
        } else if let first = models.first {
            selectedModel = first
            #if canImport(MLXLLM) && os(iOS)
            // iOS: default to Apple FM only when it's actually ready (so we don't land
            // on Gemma, which needs a ~3 GB fetch). On macOS we keep the first entry
            // (Ollama) as the default.
            let gemmaReady = models.contains(.gemma) && GemmaBrain.isModelDownloaded()
            if !gemmaReady, models.contains(.appleFM), fmReady { selectedModel = .appleFM }
            #endif
        }

        speaker.onLevel = { [weak self] level in
            self?.face.setMouth(Self.mouthOpen(forLevel: level))
        }
        speaker.onFinished = { [weak self] in
            self?.face.setMouth(0)
            self?.handleSpeechFinished()
        }
        recognizer.onLevel = { [weak self] level in
            guard let self else { return }
            self.micLevel = level
            // A loud noise while Ba-Chan is dozing startles it awake (shock → angry).
            // Soft speech doesn't cross the threshold, so it wakes gently via the
            // normal reply path.
            if self.face.isAsleep && level > 0.085 {
                self.face.wake(startled: true)
            }
        }

        face.start()
        // The evolved look should be there from the first frame, not morph in.
        face.setGenome(appearance.genome, animated: false)
        // Start a session: drift lucidity for today and run the aging/compression
        // pass (SPEC §2, §4) before the first exchange.
        Task {
            let lu = await memory.beginSession()
            lucidity = lu.band
            memoryCount = await memory.count
            personaProfile = await memory.personaProfileValue()
            // The visible chat box starts empty every launch (owner preference) —
            // no restored bubbles, no carried-over short-term thread. Long-term
            // memory + the conversation journal still persist, so Ba-Chan recalls
            // and can answer "what did we talk about yesterday"; only the on-screen
            // back-and-forth is a clean slate.
            activityDay = Calendar.current.startOfDay(for: Date())
            // SPEC §4/§6 — presence: on a clear-window session Ba-Chan occasionally
            // speaks first, surfacing something she holds deeply. Only while truly idle
            // and silent, so it never interrupts. Templated (the model may not be
            // loaded yet at launch), foundation-safe, and shown as text (speech is off
            // by default); spoken too if the user has already turned speech on.
            if lu.band == .clear, state == .idle, reply.isEmpty, heard.isEmpty {
                let opener = Persona.clearWindowOpener(persona: personaProfile)
                // Through deliver() so it lands in the transcript; it only speaks
                // when the user has already turned speech on.
                deliver(BrainReply(text: opener, expression: .happy))
            }
        }

        // Device motion → face reactions.
        motion.onShake = { [weak self] in self?.face.jostle() }
        motion.onPickup = { [weak self] in self?.face.perkUp() }
        motion.onFaceDown = { [weak self] down in if down { self?.face.restForFaceDown() } }
        motion.onTilt = { [weak self] radians in self?.face.setGravityTilt(radians) }
        motion.start()

        #if os(macOS)
        // On macOS Ba-Chan lives in the menu bar, so it settles into a pastime when
        // you step away from the Mac (whole-system idle ≥ 15s) rather than after
        // app-only inactivity — a nap at nap hours, else reading/tea/humming/cooking
        // — and any input brings it back. The monitor is the idle driver here, so
        // the app's own idle timer is disabled.
        face.autoIdleSleep = false
        activity.idleThreshold = 15
        activity.onSleep = { [weak self] in self?.face.settleIntoPastime() }
        activity.onWake  = { [weak self] away in
            self?.face.wake(startled: false)
            self?.impulse.userReturned(afterAway: away)
        }
        activity.start()

        // Presence: the work rhythm feeds both the per-turn context (what you're up
        // to at the Mac) and the impulses (stretch/late-night nags); wake events
        // above feed the rest (morning greeting, welcome-back). Ba-Chan composes
        // and delivers the line in act(on:).
        rhythm.onTick = { [weak self] snapshot in self?.impulse.tick(snapshot) }
        rhythm.start()
        impulse.onImpulse = { [weak self] event in self?.act(on: event) }
        impulse.screenAware = screenEnabled
        pasteMonitor.onPaste = { [weak self] in self?.attachFromPasteboard() ?? false }
        pasteMonitor.start()
        // Wake events need a prior idle spell, so the first launch of a morning
        // checks the greeting here — after the launch dust settles, and only if
        // nothing (e.g. the clear-window opener) has spoken yet.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self, self.state == .idle, self.reply.isEmpty else { return }
            self.impulse.appLaunched()
        }
        #endif

        // Eye contact: the camera's detected face steers Ba-Chan's gaze.
        camera.$facePosition
            .removeDuplicates()                 // collapse the ~8/sec unchanged (often nil) updates
            .receive(on: RunLoop.main)
            .sink { [weak self] position in
                guard let self else { return }
                if let position, self.visionEnabled {
                    self.face.lookAtUser(position)
                } else {
                    self.face.clearGazeOverride()
                }
            }
            .store(in: &cancellables)

        refreshModelPhase()
    }

    /// Set `modelPhase` to reflect the selected model. Gemma has a (large,
    /// user-confirmed) download/load lifecycle; Apple FM is ready or it isn't.
    private func refreshModelPhase() {
        switch selectedModel {
        #if os(macOS)
        case .ollama:
            // No in-app download; reflect whether the local server + model is up.
            modelPhase = ollamaReady ? .ready : .preparing
            refreshOllamaReadiness()
        #endif
        case .gemma:
            #if canImport(MLXLLM)
            guard gemma != nil else { modelPhase = .none; return }
            if GemmaBrain.isModelDownloaded() {
                // Already on disk: load silently if we haven't yet.
                if modelPhase != .ready { startModelLoad() }
            } else {
                modelPhase = .needsDownload   // wait for the user to confirm
            }
            #else
            modelPhase = .none
            #endif
        case .appleFM:
            // No download flow; reflect whether Apple Intelligence is usable yet.
            modelPhase = isAppleFMReady ? .none : .unavailable
            if isAppleFMReady { distillJournalBacklog() }
        case .claude, .openai, .gemini, .openrouter:
            // A cloud kind is only listed when its key is saved — ready as soon
            // as it's selectable (failures fall back to a holding line per turn).
            modelPhase = cloudBrains[selectedModel] != nil ? .ready : .unavailable
            if cloudBrains[selectedModel] != nil { distillJournalBacklog() }
        }
    }

    #if os(macOS)
    /// Probe the Ollama server (GET /api/tags) off the main actor and publish the
    /// result: `.preparing` while unknown → `.ready` if reachable + pulled, else
    /// `.unavailable` (so the status can prompt the user to start Ollama / pull a model).
    private func refreshOllamaReadiness() {
        Task {
            let ready = await ollama.isAvailable()
            ollamaReady = ready
            if selectedModel == .ollama { modelPhase = ready ? .ready : .unavailable }
            if ready { distillJournalBacklog() }
        }
    }
    #endif

    // MARK: - Capability toggles

    /// Turn hearing + voice on/off. Enabling asks for mic/speech permission and
    /// begins listening; disabling silences everything immediately.
    func toggleSpeech() {
        if speechEnabled {
            speechEnabled = false
            silenceTask?.cancel()
            recognizer.cancel()
            speaker.stop()
            face.setMouth(0)
            if state == .listening || state == .speaking { state = .idle }
        } else {
            Task {
                let granted = await recognizer.authorize()
                guard granted, recognizer.isAvailable else { return }   // stays off if denied
                speechEnabled = true
                configureSession()
                if state == .idle { listen() }
            }
        }
    }

    /// Turn the camera on/off.
    func toggleVision() {
        if visionEnabled {
            camera.stop()
            visionEnabled = false
        } else {
            Task { visionEnabled = await camera.start() }
        }
    }

    /// Flip front/back (wired to tapping the preview thumbnail).
    func flipCamera() { camera.flip() }

    #if os(macOS)
    /// Turn screen awareness on/off. Off is immediate. On needs the Screen Recording
    /// permission: without it we raise the system prompt and explain (macOS grants
    /// it in System Settings and then wants the app reopened, so the toggle stays
    /// off this run). Reading the browser tab additionally asks for Automation the
    /// first time it runs — that prompt lands naturally on the next chat turn.
    func toggleScreen() {
        if screenEnabled {
            screenEnabled = false
        } else if ScreenSightService.hasPermission {
            screenEnabled = true
        } else {
            ScreenSightService.requestPermission()
            deliver(BrainReply(
                text: "macOS wants your okay first. Allow screen recording for me in System Settings, Privacy and Security, then open me again and flip this on.",
                expression: .doubt))
        }
        impulse.screenAware = screenEnabled   // glances only when you've opted in
    }
    #endif

    /// Switch the active model. Any capability the new model lacks is turned off
    /// (reusing the toggle off-paths so the underlying service is torn down), and
    /// the model lifecycle/phase is refreshed for the new selection.
    func selectModel(_ kind: BrainKind) {
        guard kind != selectedModel, availableModels.contains(kind) else { return }
        selectedModel = kind
        UserDefaults.standard.set(kind.rawValue, forKey: Self.selectedModelKey)

        let caps = kind.capabilities
        if speechEnabled && !caps.speech { toggleSpeech() }   // off-path: silence + stop mic
        if visionEnabled && !caps.vision { toggleVision() }   // off-path: stop camera
        #if os(macOS)
        if screenEnabled && !caps.vision { screenEnabled = false }
        #endif

        refreshModelPhase()
    }

    /// Load the current memories + persona into the published state (call when the
    /// memory window opens).
    func refreshMemories() {
        Task {
            memoryItems = await memory.snapshot()
            personaProfile = await memory.personaProfileValue()
            journalCount = await chatLog.count
        }
    }

    /// Forget a single remembered fact (or reject a pending persona suggestion).
    func forget(_ id: UUID) {
        Task {
            await memory.remove(id)
            await reloadMemoryState()
        }
    }

    /// Wipe everything Ba-Chan remembers about the user (and the learned persona),
    /// including the timestamped conversation journal.
    func forgetEverything() {
        Task {
            await memory.reset()
            await chatLog.reset()
            memoryCount = 0; memoryItems = []
            transcript = []; recentHistory = []
            personaProfile = PersonaProfile()
        }
    }

    // MARK: - Persona management (SPEC §6) — owner edits on the memory page

    /// Edit a memory's wording in place (re-embeds for recall).
    func editMemory(_ id: UUID, to newText: String) {
        Task { await memory.editText(id, to: newText); await reloadMemoryState() }
    }

    /// Add one of Ba-Chan's deep memories by hand.
    func addPersonaMemory(_ text: String) {
        Task { await memory.addPersonaMemory(text); await reloadMemoryState() }
    }

    /// Save edits to Ba-Chan's persona slots (relationship, language, personality, …).
    func updatePersona(_ profile: PersonaProfile) {
        personaProfile = profile
        Task { await memory.setPersonaProfile(profile) }
    }

    private func reloadMemoryState() async {
        memoryItems = await memory.snapshot()
        memoryCount = await memory.count
        personaProfile = await memory.personaProfileValue()
    }

    // MARK: - Nightly memory distillation (LLM pass over the conversation journal)

    /// Set once the backlog sweep has run with a real model this launch.
    private var distilledThisLaunch = false
    /// Day boundary up to which the journal has been distilled (persisted).
    private static let distilledThroughKey = "journalDistilledThrough"

    /// Distill past days' logged conversations into durable memories — the
    /// "nightly summarization" upgrade over the regex extractor. Runs once per
    /// launch, as soon as a distillation-capable brain is ready, and only over
    /// days not yet processed (marker in UserDefaults). Off the critical path:
    /// a failed day (server down mid-pass) is simply retried next launch.
    private func distillJournalBacklog() {
        guard !distilledThisLaunch, let distiller = brain as? MemoryDistilling else { return }
        distilledThisLaunch = true
        Task {
            let cal = Calendar.current
            let todayStart = cal.startOfDay(for: Date())
            let doneThrough = UserDefaults.standard
                .object(forKey: Self.distilledThroughKey) as? Date ?? .distantPast
            for back in stride(from: MemoryDistiller.backlogDays, through: 1, by: -1) {
                guard let dayStart = cal.date(byAdding: .day, value: -back, to: todayStart),
                      dayStart >= doneThrough else { continue }
                let turns = await chatLog.turns(in: DateInterval(start: dayStart, duration: 86_400))
                if !turns.isEmpty {
                    let label = back == 1 ? "yesterday" : "\(back) days ago"
                    guard let facts = await distiller.distillMemories(
                        from: MemoryDistiller.transcriptText(turns), dayLabel: label)
                    else { return }   // model hiccup — leave the marker; retry next launch
                    if !facts.isEmpty {
                        memoryCount = await memory.keepDistilledFacts(facts, from: dayStart)
                    }
                }
                // This day is done (or had nothing) — advance the marker past it.
                UserDefaults.standard.set(dayStart.addingTimeInterval(86_400),
                                          forKey: Self.distilledThroughKey)
            }

            // Nightly appearance stylist: once per day, yesterday's conversation
            // may leave a tiny trace on the resting face. Same cadence and
            // failure posture as distillation (a model hiccup retries next
            // launch); the marker lives with the appearance state.
            if let stylist = brain as? AppearanceStyling,
               appearance.styledThrough < todayStart,
               let yesterday = cal.date(byAdding: .day, value: -1, to: todayStart) {
                let turns = await chatLog.turns(in: DateInterval(start: yesterday,
                                                                 duration: 86_400))
                if turns.isEmpty {
                    appearance.markStyled(through: todayStart)
                } else if let proposal = await stylist.proposeAppearance(
                    genome: appearance.genome,
                    transcript: MemoryDistiller.transcriptText(turns)) {
                    appearance.applyProposal(proposal, for: yesterday)
                    appearance.markStyled(through: todayStart)
                    face.setGenome(appearance.genome)
                }
            }
        }
    }

    // MARK: - Attachments (documents / images / videos fed into the chat)

    /// Ingest picked/dropped files and stage them for the next message. URLs from
    /// the system file picker are security-scoped; access is bracketed per file.
    func attach(urls: [URL]) {
        guard !urls.isEmpty else { return }
        Task {
            beginIngest()
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                if let attachment = await AttachmentIngestor.ingest(url: url) {
                    pendingAttachments.append(attachment)
                }
                if scoped { url.stopAccessingSecurityScopedResource() }
            }
            endIngest()
        }
    }

    /// Bracket an ingest with the busy flag and the bright, expectant face. The
    /// face wears `.curious` while files are coming in, then settles.
    private func beginIngest() {
        isIngestingAttachment = true
        #if os(macOS)
        face.anticipate(true)
        #endif
    }
    private func endIngest() {
        isIngestingAttachment = false
        #if os(macOS)
        face.anticipate(false)
        #endif
    }

    #if os(macOS)
    /// Ingest items pasted into the chat box (Cmd-V), mirroring `attach(urls:)`: a
    /// file copied from Finder keeps its path; a raw clipboard image (a screenshot,
    /// a "Copy Image" from the web) is decoded straight from its bytes.
    func attach(pasted providers: [NSItemProvider]) {
        guard !providers.isEmpty else { return }
        Task {
            beginIngest()
            for provider in providers {
                if let url = await provider.pastedFileURL() {
                    let scoped = url.startAccessingSecurityScopedResource()
                    if let attachment = await AttachmentIngestor.ingest(url: url) {
                        pendingAttachments.append(attachment)
                    }
                    if scoped { url.stopAccessingSecurityScopedResource() }
                } else if let img = await provider.pastedImage(),
                          let attachment = await AttachmentIngestor.ingest(imageData: img.data, name: img.name) {
                    pendingAttachments.append(attachment)
                }
            }
            endIngest()
        }
    }

    /// Read a Cmd-V from the system pasteboard, kicked off by `PasteMonitor`. Returns
    /// true (synchronously, on content presence) so the monitor swallows the event;
    /// the actual ingest runs async. A copied file keeps its path; a raw clipboard
    /// image (screenshot, "Copy Image") is decoded straight from its bytes.
    func attachFromPasteboard() -> Bool {
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(forClasses: [NSURL.self],
                                     options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            attach(urls: urls)
            return true
        }
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            guard let data = pb.data(forType: type) else { continue }
            let ext = type == .png ? "png" : "tiff"
            Task {
                beginIngest()
                if let attachment = await AttachmentIngestor.ingest(imageData: data,
                                                                    name: "Pasted image.\(ext)") {
                    pendingAttachments.append(attachment)
                }
                endIngest()
            }
            return true
        }
        return false
    }
    #endif

    func removeAttachment(_ id: UUID) {
        pendingAttachments.removeAll { $0.id == id }
    }

    /// Type-to-talk entry point — always available, silent unless speech is on.
    func send(typed text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        silenceTask?.cancel()
        recognizer.cancel()
        heard = clean
        think(about: clean)
    }

    // MARK: - Loop stages

    private func listen() {
        guard speechEnabled else { state = .idle; return }
        state = .listening
        face.set(.neutral)
        heard = ""

        recognizer.onPartial = { [weak self] text in
            self?.heard = text
            self?.restartSilenceTimer()
        }
        recognizer.onFinal = { [weak self] text in
            self?.finishedListening(with: text)
        }

        do {
            try recognizer.start()
            restartSilenceTimer()
        } catch {
            speechEnabled = false
            state = .idle
        }
    }

    private func finishedListening(with text: String) {
        guard state == .listening else { return }
        silenceTask?.cancel()
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { listen(); return }   // heard nothing → keep listening
        think(about: clean)
    }

    private func think(about text: String) {
        clearTranscriptIfNewDay()   // a new day starts with a clean chat box
        state = .thinking
        face.startThinking()
        lastExchangeAt = Date()
        #if os(macOS)
        impulse.conversationHappened()
        #endif

        // Take this turn's staged attachments (cleared so the next message starts fresh).
        let attachments = pendingAttachments
        pendingAttachments = []
        transcript.append(ChatMessage(role: .user, text: text, date: Date(),
                                      attachments: attachments.map(\.fileName)))

        Task {
            let wantsToLook = LookIntent.matches(text)
            #if os(macOS)
            // Two ways to reach into the screen: a *visual* look ("look at my screen"
            // → screenshot/VLM) and a *read* ("sum it up", or accepting a glance offer
            // → the page's real text). Both are manual, so asking while Screen is off
            // gets guidance. A read prefers the page text and falls back to a shot.
            let wantsScreen = LookIntent.screenMatches(text) && attachments.isEmpty
            let wantsRead = attachments.isEmpty
                && (acceptedScreenOffer(for: text) || LookIntent.summarizeMatches(text))
            let deepScreen = wantsScreen || wantsRead
            if deepScreen && !screenEnabled {
                deliver(BrainReply(text: "Turn on Screen and I'll have a look at what you're working on!",
                                   expression: .doubt))
                return
            }
            #else
            let wantsScreen = false
            let wantsRead = false
            #endif

            // If they ask Stackchan to look but vision is off, guide them — the
            // camera is manual-only and never turns itself on. (Unless they attached
            // a file, or it's a screen *read* like "read this page": those aren't the
            // camera.)
            if wantsToLook && !wantsScreen && !wantsRead && !visionEnabled && attachments.isEmpty {
                deliver(BrainReply(text: "Turn on Look and I'll see what you're showing me!",
                                   expression: .doubt))
                return
            }

            // 1. Recall relevant memories (fast, on-device) + this session's recent
            //    thread for short-term continuity (SPEC §5).
            var context = await memory.context(for: text)
            context.history = recentHistory

            // Files fed into this message — already distilled to text by the ingestor.
            if !attachments.isEmpty {
                context.attachments = attachments.map(\.contextLine).joined(separator: "\n")
            }

            // Asking about a past time ("what did we chat about yesterday")
            // → answer from the persistent log of what was actually said,
            // labelled with the window it covers, instead of inventing.
            if let when = TemporalQuery.parse(text) {
                let past = await chatLog.turns(in: when.interval)
                context.journal = ConversationLog.digest(past, label: when.label)
            }

            // 2. If vision is on, see a frame this turn. Always produce a non-empty
            //    sight when a frame is captured, so replies actually reflect the camera.
            var frame: CGImage?
            if visionEnabled, camera.isRunning {
                frame = await camera.captureFrame()
                if let frame {
                    let summary = await SightService.analyze(frame).summary
                    context.sight = summary.isEmpty ? "something I can't quite make out" : summary
                }
            }

            #if os(macOS)
            // 2b. Screen sight, on an asking turn only — never ambient. A *read* takes
            //     the page's real text (the whole article, via Accessibility) so a
            //     summary is grounded; if that's empty (not a browser / no access) OR
            //     it's a plain visual look, fall back to a ScreenCaptureKit shot of
            //     every display (the focal one also goes to the VLM).
            var screenLook: CGImage?
            if deepScreen && screenEnabled {
                let pageText = wantsRead ? await PageTextReader.pageText(of: rhythm.frontApp) : ""
                if !pageText.isEmpty {
                    context.screen = pageText
                } else {
                    let shots = await ScreenSightService.captureAll()
                    screenLook = shots.first(where: \.isFocal)?.image ?? shots.first?.image
                    var cues: [String] = []
                    for shot in shots {
                        let summary = await SightService.analyze(shot.image).summary
                        guard !summary.isEmpty else { continue }
                        // One display: just describe it; several: name each.
                        cues.append(shots.count == 1 ? summary : "\(shot.label): \(summary)")
                    }
                    context.screen = cues.isEmpty
                        ? "a busy screen, hard to make out" : cues.joined(separator: "; ")
                }
            }
            // Whole-system presence: what they're up to at the Mac right now (app,
            // focus streak, time since a real break) — free, every turn. When screen
            // awareness is on, enrich it with the active browser tab (title + site) of
            // the app you were last really in (not BaChan, which is frontmost now).
            context.rhythm = rhythm.contextLine()
            if screenEnabled {
                let browsing = await BrowserActivity.contextLine(of: rhythm.frontApp)
                if !browsing.isEmpty {
                    context.rhythm = context.rhythm.isEmpty
                        ? browsing : "\(context.rhythm), \(browsing)"
                }
            }
            #else
            let screenLook: CGImage? = nil
            #endif

            // 3. Reply. A vision-capable brain (VLM) gets a raw image — an attached
            //    picture takes precedence over the camera frame (which still needs
            //    look-intent). If the VLM can't answer (e.g. a text-only Ollama
            //    model), the text path below carries it via the Apple-Vision cues.
            //    Either way the §1 output guard backstops the floor (SPEC §1.3).
            let reply: BrainReply
            let lookImage = attachments.first(where: { $0.image != nil })?.image
                ?? screenLook                    // macOS: the screen grab on a screen turn
                ?? (wantsToLook ? frame : nil)
            var described: String?
            if let lookImage, let visionBrain = brain as? VisionBrain {
                // A screen grab needs its own framing — "through your visor" reads
                // as the camera, and the model should know it's a computer screen.
                let visionPrompt = (lookImage === screenLook)
                    ? "You are looking at their computer screen right now. " + text
                    : text
                let d = await visionBrain.describe(lookImage, prompt: visionPrompt, context: context)
                if !d.isEmpty { described = d }
            }
            if var described {
                if FoundationGuard.violates(described) {
                    // A look-at-this turn must never tip into distress/non-recognition;
                    // substitute a warm, foundation-safe line rather than re-describe.
                    let chinese = FoundationGuard.isChinese(text) || FoundationGuard.isChinese(described)
                    described = FoundationGuard.safeFallback(chinese: chinese, persona: personaProfile)
                    reply = BrainReply(text: described, expression: .happy)
                } else {
                    let mood = EmotionTag.extract(from: &described)
                        ?? (context.sight.contains("face") ? .happy : .neutral)
                    reply = BrainReply(text: described, expression: mood)
                }
            } else {
                let base = await brain.reply(to: text, context: context)
                reply = await guardedReply(base, to: text, context: context)
            }
            deliver(reply)

            // Journal the exchange (persistent, timestamped) so future sessions can
            // answer "what did we talk about then" from the record.
            await chatLog.append(user: text, bachan: reply.text)

            // Remember this exchange for the rest of the session (short-term thread).
            recentHistory.append(BrainContext.Turn(user: text, bachan: reply.text))
            if recentHistory.count > historyLimit {
                recentHistory.removeFirst(recentHistory.count - historyLimit)
            }

            // 4. Harvest durable facts (off the critical path). The reply's mood
            //    weights emotional salience → later becomes L4 residue (SPEC §2).
            memoryCount = await memory.ingest(userText: text, reply: reply.text,
                                              mood: reply.expression.rawValue)

            // 5. Learn persona (SPEC §6): anything the user said *about Ba-Chan* is kept
            //    automatically — the model decides what's worth keeping (only facts the
            //    user stated, never invented). Prefer an on-device LLM extractor; fall
            //    back to the heuristic. The owner can edit/delete on the memory page.
            // Only spend a SECOND full LLM generation when the turn plausibly
            // states something about Ba-Chan; otherwise the free heuristic is
            // enough. Halves per-turn compute/peak memory on ordinary chat (the
            // double-generation per turn was a key driver of the CPU/RAM spike).
            let facts: [String]
            if let extractor = brain as? PersonaExtracting,
               PersonaLearner.mightContainPersonaFact(text) {
                facts = await extractor.extractPersonaFacts(from: text)
            } else {
                facts = PersonaLearner.suggestions(from: text)
            }
            if await memory.learnPersonaFacts(facts) > 0 {
                memoryItems = await memory.snapshot()   // so an open memory page shows them
            }
        }
    }

    /// The output guards. The persona prompt *asks* for the invariants, but a small
    /// on-device model sometimes ignores them — these make them robust at runtime:
    ///
    /// 1. **§1 floor** (`FoundationGuard`): never fail to recognise the person, never
    ///    distress about forgetting. Breach → regenerate once with a corrective; still
    ///    breaching → substitute a warm, foundation-safe line.
    /// 2. **Fabrication** (`Fabrication`): never name people/pets that exist nowhere
    ///    in the conversation or notes ("Mrs. Higgins' cat"). Offending sentences are
    ///    stripped — usually the rest of the reply stands fine; if nothing survives,
    ///    regenerate once with a corrective, then fall back.
    private func guardedReply(_ reply: BrainReply, to input: String,
                              context: BrainContext) async -> BrainReply {
        var current = reply

        if FoundationGuard.violates(current.text) {
            var repaired = context
            repaired.repair = Persona.repairDirective
            let second = await brain.reply(to: input, context: repaired)
            if !FoundationGuard.violates(second.text) {
                current = second
            } else {
                let chinese = FoundationGuard.isChinese(input) || FoundationGuard.isChinese(current.text)
                return BrainReply(text: FoundationGuard.safeFallback(chinese: chinese, persona: personaProfile),
                                  expression: .happy)
            }
        }

        let known = knownText(for: input, context: context)
        let scrubbed = Fabrication.scrub(current.text, known: known)
        if scrubbed.dropped {
            if !scrubbed.text.isEmpty {
                current = BrainReply(text: scrubbed.text, expression: current.expression)
            } else {
                // The whole reply was invention — one corrective retry, else safe line.
                var repaired = context
                repaired.repair = Persona.inventionRepair
                let second = await brain.reply(to: input, context: repaired)
                let again = Fabrication.scrub(second.text, known: known)
                if !again.text.isEmpty {
                    current = BrainReply(text: again.text, expression: second.expression)
                } else {
                    let chinese = FoundationGuard.isChinese(input)
                    current = BrainReply(text: FoundationGuard.safeFallback(chinese: chinese, persona: personaProfile),
                                         expression: .happy)
                }
            }
        }
        return current
    }

    /// Everything legitimately in context this turn — the corpus a reply's names
    /// are checked against. A name absent from all of this was invented.
    private func knownText(for input: String, context: BrainContext) -> String {
        var parts = [input, context.profile, context.journal, context.attachments,
                     context.sight, context.screen, context.rhythm, Persona.name]
        parts += context.memories
        parts += context.personaMemories
        parts += context.history.flatMap { [$0.user, $0.bachan] }
        let p = personaProfile
        parts += [p.relationship, p.about, p.personality, p.language, p.messageExample]
        parts += p.greetings
        return parts.joined(separator: "\n")
    }

    /// Show the reply. Speaks it only if speech is enabled — otherwise it's
    /// text-only and completely silent.
    private func deliver(_ message: BrainReply) {
        face.stopThinking()
        // Backstop the output rules (no dashes, no markdown) on EVERYTHING shown or
        // spoken — brain replies are already cleaned, but authored lines (openers,
        // guard fallbacks, guidance) reach here directly. Idempotent for clean text.
        let text = ChatArtifacts.unwrapEdgeQuotes(ChatArtifacts.normalizePunctuation(message.text))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        reply = text
        transcript.append(ChatMessage(role: .bachan, text: text, date: Date()))
        if transcript.count > 60 { transcript.removeFirst(transcript.count - 60) }
        face.set(message.expression)
        // Tally the day's emotional weather; on a day rollover the previous
        // day drifts the resting face (laugh lines etc.), so re-adopt.
        appearance.tally(message.expression)
        face.setGenome(appearance.genome)
        if speechEnabled {
            state = .speaking
            configureSession()
            speaker.speak(text)                // onFinished → handleSpeechFinished
        } else {
            state = .idle
        }
    }

    private func handleSpeechFinished() {
        guard state == .speaking else { return }
        if speechEnabled { listen() } else { state = .idle }
    }

    #if os(macOS)
    // MARK: - Proactive moments (macOS presence — Ba-Chan speaks first)

    /// An impulse fired — compose the line and deliver it. Quiet rules: only while
    /// truly idle, never mid-load, and never within a few minutes of a real
    /// exchange (the ImpulseEngine's own cooldowns sit on top of these).
    private func act(on event: ImpulseEngine.Impulse) {
        guard state == .idle, !isBrainLoading else { return }
        guard Date().timeIntervalSince(lastExchangeAt) > 5 * 60 else { return }
        clearTranscriptIfNewDay()   // a proactive line on a new day starts fresh
        switch event {
        case .morningGreeting:
            deliverProactive(BrainReply(text: Persona.morningLine(persona: personaProfile),
                                        expression: .happy))
        case .welcomeBack:
            Task { deliverProactive(await checkInReply()) }
        case .stretchNag(let minutes, let app):
            deliverProactive(BrainReply(
                text: Persona.stretchLine(screenMinutes: minutes, appName: app,
                                          persona: personaProfile),
                expression: .concerned))
        case .lateNight:
            deliverProactive(BrainReply(text: Persona.lateNightLine(persona: personaProfile),
                                        expression: .concerned))
        case .glanceAtScreen(let app):
            Task { await glanceAtScreen(appName: app) }
        }
    }

    /// Ba-Chan glances at what you're doing: capture the focal screen + read the
    /// active browser tab, show a tiny screenshot by the face with the observing
    /// look, and offer something grounded in what's actually there. Only when Screen
    /// is on AND the popover is open — the glance is meant to be seen, and we don't
    /// take background screenshots of a closed companion.
    private func glanceAtScreen(appName: String?) async {
        guard screenEnabled, isFaceVisible?() == true,
              state == .idle, !isBrainLoading,
              Date().timeIntervalSince(lastExchangeAt) > 5 * 60 else { return }
        let shots = await ScreenSightService.captureAll()
        let focal = shots.first(where: \.isFocal)?.image ?? shots.first?.image
        let browsing = await BrowserActivity.contextLine(of: rhythm.frontApp)
        showLooking(focal)
        let line = Persona.glanceLine(browsing: browsing, appName: appName, persona: personaProfile)
        deliverProactive(BrainReply(text: line, expression: .observing))
        screenOfferAt = Date()   // a non-declining reply now means "yes, do it"
    }

    /// Whether the user just accepted a glance offer — an affirmative reply within a
    /// few minutes of Ba-Chan offering. Consumed on a yes; an unrelated message leaves
    /// the offer armed (the window still bounds it), so it never false-triggers a read.
    private func acceptedScreenOffer(for text: String) -> Bool {
        guard let at = screenOfferAt, Date().timeIntervalSince(at) < 5 * 60 else {
            screenOfferAt = nil
            return false
        }
        guard Self.isAffirmative(text) else { return false }
        screenOfferAt = nil
        return true
    }

    private static func isAffirmative(_ text: String) -> Bool {
        let t = text.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "!.?"))
        guard !t.isEmpty else { return false }
        let yes = ["yes", "yeah", "yep", "yup", "sure", "ok", "okay", "please",
                   "go on", "go ahead", "do it", "sounds good", "why not", "alright",
                   "yes please", "go for it", "好", "好的", "好啊", "好呀", "可以",
                   "行", "嗯", "麻烦你", "来吧"]
        return yes.contains { t == $0 || t.hasPrefix($0 + " ") || t.hasPrefix($0 + ",") }
    }

    /// Float a tiny screenshot beside the face and wear the observing look, then
    /// settle back after a few seconds.
    private func showLooking(_ image: CGImage?) {
        lookingClearTask?.cancel()
        lookingImage = image
        lookingClearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 6_500_000_000)
            guard let self, !Task.isCancelled else { return }
            self.lookingImage = nil
            if self.face.expression == .observing { self.face.set(.neutral) }
        }
    }

    /// A welcome-back grounded in what Ba-Chan actually holds: the model gets the
    /// check-in instruction plus recalled memories and the work rhythm, behind the
    /// same output guards as any reply. Falls back to a templated line whenever the
    /// model isn't up (scripted fallback) or returns nothing usable.
    private func checkInReply() async -> BrainReply {
        let fallback = BrainReply(text: Persona.welcomeBackLine(persona: personaProfile),
                                  expression: .happy)
        guard !(brain is ScriptedBrain) else { return fallback }
        let instruction = Persona.checkInInstruction
        var context = await memory.context(for: "their day, how they have been")
        context.history = recentHistory
        context.rhythm = rhythm.contextLine()
        let base = await brain.reply(to: instruction, context: context)
        let safe = await guardedReply(base, to: instruction, context: context)
        let text = safe.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? fallback : safe
    }

    /// Show a self-initiated line: through the normal `deliver` path (transcript,
    /// face, voice if Speech is on), plus a notification when the face is hidden —
    /// the popover is usually closed, and this is how Ba-Chan calls out. Not
    /// journaled: the ConversationLog holds exchanges, and a one-sided line would
    /// read as a turn the user never had.
    private func deliverProactive(_ message: BrainReply) {
        guard state == .idle else { return }
        face.wake(startled: false)
        deliver(message)
        notifyIfHidden(message.text)
    }

    /// Post the line as a user notification when the popover is closed. Permission
    /// is requested lazily on the first proactive moment; if it's declined the line
    /// still waits in the transcript.
    private func notifyIfHidden(_ text: String) {
        guard isFaceVisible?() != true else { return }
        let center = UNUserNotificationCenter.current()
        Task {
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Ba-Chan"
            content.body = text
            try? await center.add(UNNotificationRequest(identifier: UUID().uuidString,
                                                        content: content, trigger: nil))
        }
    }
    #endif

    // MARK: - Silence detection (end-of-turn)

    private func restartSilenceTimer() {
        silenceTask?.cancel()
        silenceTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(self.silenceTimeout * 1_000_000_000))
            guard !Task.isCancelled, self.state == .listening else { return }
            self.recognizer.finish()
        }
    }

    // MARK: - On-device model loading (MLX/Gemma)

    /// User tapped "Download" (or "Try again") — start fetching + loading the model.
    func downloadModel() {
        #if canImport(MLXLLM)
        switch modelPhase {
        case .needsDownload, .unavailable, .failed: break   // .failed ⇒ retry
        default: return
        }
        // Refuse early with a clear message rather than failing mid-download: the
        // weights are ~3 GB and need working headroom on top (SPEC robustness).
        if !GemmaBrain.isModelDownloaded(), !Self.hasFreeSpace(forBytes: 4_000_000_000) {
            modelPhase = .failed("Not enough free space — about 4 GB is needed for the brain. Free some space and try again.")
            return
        }
        startModelLoad()
        #endif
    }

    /// Whether the volume holding the model has at least `bytes` free. Best-effort: if
    /// the capacity can't be read we don't block (return true).
    private static func hasFreeSpace(forBytes bytes: Int64) -> Bool {
        let url = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                in: .userDomainMask,
                                                appropriateFor: nil, create: false))
            ?? URL.temporaryDirectory
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let available = values.volumeAvailableCapacityForImportantUsage else { return true }
        return available >= bytes
    }

    #if canImport(MLXLLM)
    private func startModelLoad() {
        guard let gemma else { return }
        let isFresh = !GemmaBrain.isModelDownloaded()
        modelPhase = isFresh ? .downloading(0) : .preparing
        face.beginWorking()        // "working on something" face for the whole load; suppresses sleep
        Task {
            await gemma.load { fraction in
                Task { @MainActor in
                    if case .downloading = self.modelPhase { self.modelPhase = .downloading(fraction) }
                }
            }
            // Loading is done (success or not): always restore the face, even if
            // the user switched models mid-load (handled by the guard below).
            face.endWorking()
            // Only reflect the result if Gemma is still the selection — the user
            // may have switched models while it was loading.
            guard selectedModel == .gemma else { return }
            if await gemma.isReady {
                modelPhase = .ready
                distillJournalBacklog()
            } else {
                // Surface the real reason and offer a retry. A partial download is kept
                // on disk (Hub resumes at file granularity), so "Try again" resumes.
                modelPhase = .failed(await gemma.loadError
                    ?? "Couldn't load the brain. Check your connection and try again.")
            }
        }
    }
    #endif

    // MARK: - Helpers

    private func configureSession() {
        #if os(iOS)
        // AVAudioSession is iOS-only; on macOS AVAudioEngine (Speaker / SpeechRecognizer)
        // routes audio without a session, so this is a no-op there.
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord,
                                 mode: .default,
                                 options: [.defaultToSpeaker, .duckOthers])
        try? session.setActive(true, options: [])
        #endif
    }

    private static func mouthOpen(forLevel level: Float) -> CGFloat {
        CGFloat(min(1, max(0, level * 14)))
    }
}
