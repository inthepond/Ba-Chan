import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    // Injected by the app entry point so the same Conductor (and its FaceController)
    // is shared with the macOS menu-bar tray face — the tray and the popover then
    // animate and react identically.
    @ObservedObject var conductor: Conductor
    @StateObject private var particles = ParticleSystem()
    @State private var typed = ""
    @State private var showOnboarding = false
    @State private var showImporter = false
    /// A file is being dragged over the popover (drives the expectant face).
    @State private var isDropTargeted = false
    /// Set once the first-launch "tell Ba-Chan's story" invitation has been
    /// seen (Begin or Skip). Cleared by Forget Everything so a fresh start
    /// begins with the story again.
    static let onboardingShownKey = "onboardingShown"
    @State private var availableHeight: CGFloat = 0
    /// Natural height of the transcript content, so the panel fits the messages
    /// instead of always filling its cap (a short exchange = a short box).
    @State private var transcriptContentHeight: CGFloat = 0
    @FocusState private var typingFocused: Bool

    var body: some View {
        ZStack {
            Color.screen.ignoresSafeArea()        // adaptive backdrop (white in Light, black in Dark)

            // The face, its visor, and its particles move as one: when the chat
            // panel is up it would cover the mouth, so the whole group slides up
            // to keep the expression in view.
            ZStack {
                AvatarView(face: conductor.face, feature: .primary, background: .clear)

                // When Look is on, the camera shows through goggles over Ba-Chan's
                // eyes — so it feels like it's looking. Gated on `visionEnabled`
                // (a Conductor @Published) so it hides the instant Look turns off.
                if conductor.visionEnabled {
                    GoggleView(camera: conductor.camera) { conductor.flipCamera() }
                        .ignoresSafeArea()
                        .transition(.opacity)
                }

                // Reaction particles (hearts when petted, etc.) float over the face.
                ParticleOverlay(system: particles)
                    .onAppear { conductor.face.onEffect = { particles.spawn($0) } }

                #if os(macOS)
                // When Ba-Chan glances at your screen (a proactive moment), a tiny
                // screenshot floats by the face so the look reads as "I see *this*."
                if let shot = conductor.lookingImage {
                    LookingThumbnail(image: shot)
                        .transition(.scale(scale: 0.5).combined(with: .opacity))
                }
                #endif
            }
            .offset(y: faceOffset)
            .animation(.easeInOut(duration: 0.35), value: faceOffset)
            #if os(macOS)
            .animation(.spring(response: 0.45, dampingFraction: 0.7),
                       value: conductor.lookingImage == nil)
            #endif

            // Minimal top overlay: live state + what it remembers (no wake bar).
            topOverlay
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding()

            VStack(spacing: 12) {
                Spacer()
                if transcriptVisible {
                    transcriptPanel
                }
                modelBanner
                if !conductor.pendingAttachments.isEmpty || conductor.isIngestingAttachment {
                    attachmentRow
                }
                controlsRow
                inputBar
            }
            .padding()
        }
        .background {
            GeometryReader { g in
                Color.clear
                    .onAppear { availableHeight = g.size.height }
                    .onChange(of: g.size.height) { _, h in availableHeight = h }
            }
        }
        .animation(.easeInOut, value: conductor.visionEnabled)
        #if os(macOS)
        // Drop a file or image anywhere on the popover to attach it; the face lights
        // up (expectant) while it hovers, like the paperclip and Cmd-V paths.
        .onDrop(of: [.fileURL, .image], isTargeted: $isDropTargeted) { providers in
            conductor.attach(pasted: providers)
            return true
        }
        .onChange(of: isDropTargeted) { _, hovering in conductor.face.anticipate(hovering) }
        #endif
        .tint(.primary)                     // monochrome: ink follows the system theme
        .onAppear {
            if !UserDefaults.standard.bool(forKey: Self.onboardingShownKey) {
                showOnboarding = true
            }
        }
        #if os(iOS)
        .sheet(isPresented: $showOnboarding, onDismiss: markOnboardingShown) {
            OnboardingView(conductor: conductor) { showOnboarding = false }
        }
        #else
        // macOS: keep the story inside the same popover window — a sheet would float
        // as a separate panel with no way to dismiss it.
        .overlay {
            if showOnboarding {
                OnboardingView(conductor: conductor) {
                    markOnboardingShown()
                    showOnboarding = false
                }
                .background(Color.screen)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        // Settings slides over the popover when the tray menu asks for it.
        .overlay {
            if conductor.settingsRequested {
                SettingsView(conductor: conductor) { conductor.settingsRequested = false }
                    .background(Color.screen)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: showOnboarding)
        .animation(.easeInOut(duration: 0.25), value: conductor.settingsRequested)
        #endif
    }

    private func markOnboardingShown() {
        UserDefaults.standard.set(true, forKey: Self.onboardingShownKey)
    }

    private var transcriptVisible: Bool {
        !conductor.transcript.isEmpty
            || (conductor.state == .listening && !conductor.heard.isEmpty)
    }

    /// How far the face group rises when the chat panel is up. The mouth sits at
    /// ~58% of the height and the panel caps at 26% from the bottom, so lifting
    /// by ~14% clears the mouth (and the visor) without pushing the brows out
    /// the top.
    private var faceOffset: CGFloat {
        transcriptVisible ? -(availableHeight > 0 ? availableHeight : 640) * 0.14 : 0
    }

    // MARK: - Top overlay

    private var topOverlay: some View {
        HStack {
            Spacer()
            let status = modelStatusText ?? conductor.state.label
            if !status.isEmpty {
                Text(status)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
            }
        }
    }

    /// Short status pill text for the model, or nil when there's nothing to show.
    private var modelStatusText: String? {
        switch conductor.modelPhase {
        case .downloading(let f): return "Downloading brain \(Int(f * 100))%"
        case .preparing:          return "Loading brain…"
        case .unavailable:
            return conductor.selectedModel == .appleFM
                ? "Turn on Apple Intelligence in Settings"
                : "Brain unavailable"
        case .failed:             return nil   // the banner shows the reason + retry
        case .none, .needsDownload, .ready: return nil
        }
    }

    /// The failure message when a download/load failed (or there's no space).
    private var modelFailureMessage: String? {
        if case .failed(let message) = conductor.modelPhase { return message }
        return nil
    }

    /// First-launch confirmation before the large model download. Shown only
    /// while the weights are absent and the user hasn't chosen to download yet.
    @ViewBuilder private var modelBanner: some View {
        if conductor.modelPhase == .needsDownload {
            VStack(alignment: .leading, spacing: 8) {
                Label("Download \(conductor.selectedModel.displayName)?", systemImage: "brain.head.profile")
                    .font(.subheadline.weight(.semibold))
                Text("Gemma 3n (E2B edge) runs fully on your device. It's a one-time ~3 GB download, kept on your phone. Until then I'll use my simple built-in replies.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Text("Tap Download when you're on Wi-Fi.")
                        .font(.caption2).foregroundStyle(.tertiary)
                    Spacer()
                    Button("Download") { conductor.downloadModel() }
                        .buttonStyle(.borderedProminent)
                        .tint(.primary)
                        .foregroundStyle(Color.screen)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        } else if let message = modelFailureMessage {
            VStack(alignment: .leading, spacing: 8) {
                Label("Download didn't finish", systemImage: "exclamationmark.triangle")
                    .font(.subheadline.weight(.semibold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Text("Any progress so far is kept — this resumes.")
                        .font(.caption2).foregroundStyle(.tertiary)
                    Spacer()
                    Button("Try again") { conductor.downloadModel() }
                        .buttonStyle(.borderedProminent)
                        .tint(.primary)
                        .foregroundStyle(Color.screen)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    // MARK: - Transcript

    /// Height-capped so a long exchange never covers Ba-Chan's face — it scrolls
    /// within the cap instead. No icons: the user's words read as quiet sans, and
    /// Ba-Chan answers in serif (the same voice as the memory page). Everything
    /// before the current exchange softens away — dimmed and gently blurred — so
    /// the newest words carry the panel.
    private var transcriptPanel: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    let currentStart = conductor.transcript.lastIndex { $0.role == .user } ?? 0
                    ForEach(Array(conductor.transcript.enumerated()), id: \.element.id) { index, message in
                        messageView(message)
                            .opacity(index >= currentStart ? 1 : 0.38)
                            .blur(radius: index >= currentStart ? 0 : 1.3)
                    }
                    // Live partial while listening (not yet a sent message).
                    if conductor.state == .listening, !conductor.heard.isEmpty {
                        Text(conductor.heard)
                            .font(.system(size: 13))
                            .foregroundStyle(.primary.opacity(0.5))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(14)
                // Measure the content so the panel can size to it (capped below).
                .background(GeometryReader { g in
                    Color.clear
                        .onAppear { transcriptContentHeight = g.size.height }
                        .onChange(of: g.size.height) { _, h in transcriptContentHeight = h }
                })
            }
            // Fit the messages, but never taller than the cap (then it scrolls).
            .frame(height: min(transcriptContentHeight, transcriptMaxHeight))
            #if os(iOS)
            .scrollDismissesKeyboard(.interactively)   // swipe the transcript to dismiss too
            #endif
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
            // Stick to the newest message: the default anchor keeps the view pinned
            // to the bottom as content grows, and the deferred scrollTo (next
            // runloop, after the new bubble has been laid out) brings it back even
            // if the user had scrolled up to reread something.
            .defaultScrollAnchor(.bottom)
            .animation(.default, value: conductor.heard)
            .animation(.default, value: conductor.transcript)
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: conductor.transcript) { _, _ in
                DispatchQueue.main.async {
                    withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
            .onChange(of: conductor.heard) { _, _ in
                DispatchQueue.main.async { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    /// One transcript bubble: quiet sans for the user, serif for Ba-Chan, with
    /// small chips naming any files that came with the message.
    @ViewBuilder private func messageView(_ message: ChatMessage) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if !message.attachments.isEmpty {
                HStack(spacing: 6) {
                    ForEach(message.attachments, id: \.self) { name in
                        Label(name, systemImage: "paperclip")
                            .font(.caption2)
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Color.primary.opacity(0.08), in: Capsule())
                    }
                }
            }
            Text(message.text)
                .font(message.role == .user ? .system(size: 13)
                                            : .system(size: 15, design: .serif))
                .foregroundStyle(message.role == .user ? Color.primary.opacity(0.55)
                                                       : Color.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The transcript lives in the band between the centered face (mouth ≈ 58% down)
    /// and the controls — capped near a quarter of the screen and scrolling beyond
    /// that, never covering Ba-Chan's expression. (A touch taller than the original
    /// 20% now that replies can run to a short paragraph.)
    private var transcriptMaxHeight: CGFloat {
        availableHeight > 0 ? availableHeight * 0.26 : 190
    }

    // MARK: - Staged attachments (files going out with the next message)

    private var attachmentRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(conductor.pendingAttachments) { attachment in
                    HStack(spacing: 5) {
                        Image(systemName: attachment.icon)
                        Text(attachment.fileName).lineLimit(1)
                        Button { conductor.removeAttachment(attachment.id) } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(attachment.fileName)")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                }
                if conductor.isIngestingAttachment {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.horizontal, 6)
                }
            }
        }
    }

    // MARK: - The two capability toggles

    private var controlsRow: some View {
        HStack(spacing: 12) {
            // Look = vision (camera) on/off. Shown only when the selected model
            // can make use of vision.
            if conductor.canShowLook {
                IconToggle(systemImage: conductor.visionEnabled ? "eye.fill" : "eye.slash",
                           isOn: conductor.visionEnabled,
                           label: "Look — camera") { conductor.toggleVision() }
            }

            #if os(macOS)
            // Screen = screen awareness on/off (macOS): ambiently knows the browser
            // tab you're reading, and "look at my screen" grabs every display. Same
            // vision gate as Look — the screenshot feeds the same VLM path.
            if conductor.canShowLook {
                IconToggle(systemImage: conductor.screenEnabled ? "rectangle.inset.filled" : "rectangle.slash",
                           isOn: conductor.screenEnabled,
                           label: "Screen — see your screen and what you're reading") { conductor.toggleScreen() }
            }
            #endif

            // Speech = hearing + voice. Off = completely silent. Hidden for models
            // with no audio modality (e.g. Apple Intelligence).
            if conductor.canShowSpeech {
                IconToggle(systemImage: conductor.speechEnabled ? "waveform" : "speaker.slash.fill",
                           isOn: conductor.speechEnabled,
                           label: "Speech — hearing and voice") { conductor.toggleSpeech() }
                    .disabled(conductor.isBrainLoading)
                    .opacity(conductor.isBrainLoading ? 0.4 : 1)
            }

            // Model switcher — sits next to Speech. Hidden unless there's a choice.
            if conductor.availableModels.count > 1 {
                modelSwitcher
            }

            if conductor.state == .listening {
                MicMeter(level: conductor.micLevel)
            }
            Spacer()
        }
        .animation(.easeInOut, value: conductor.canShowLook)
        .animation(.easeInOut, value: conductor.canShowSpeech)
    }

    /// Brain-icon button opening a menu of the available models, with a checkmark
    /// on the current one. Styled to match the capability toggles.
    private var modelSwitcher: some View {
        Menu {
            ForEach(conductor.availableModels) { kind in
                Button {
                    conductor.selectModel(kind)
                } label: {
                    // A selected menu item shows a checkmark; others show the model icon.
                    Label(kind.displayName,
                          systemImage: kind == conductor.selectedModel ? "checkmark" : kind.menuIcon)
                }
            }
        } label: {
            // Shows the active model's icon so it reads as a model picker — distinct
            // from the memory chip's brain icon.
            Image(systemName: conductor.selectedModel.menuIcon)
                .font(ControlMetrics.icon.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: ControlMetrics.button, height: ControlMetrics.button)
                .background { Circle().fill(.ultraThinMaterial) }
        }
        .menuIndicator(.hidden)
        #if os(macOS)
        .menuStyle(.borderlessButton)   // drop the default macOS pull-down box + chevron
        .fixedSize()
        #endif
        .accessibilityLabel("Switch model — currently \(conductor.selectedModel.displayName)")
        .help("Switch brain — currently \(conductor.selectedModel.displayName)")
    }

    // MARK: - Text input (always available)

    private var inputBar: some View {
        HStack(spacing: 10) {
            // Feed Ba-Chan a file — a picture, a video, or a document to read.
            Button { showImporter = true } label: {
                Image(systemName: "paperclip")
                    .font(ControlMetrics.icon.weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(width: ControlMetrics.sendButton, height: ControlMetrics.sendButton)
                    .background { Circle().fill(.ultraThinMaterial) }
            }
            .buttonStyle(.plain)
            .disabled(conductor.isBrainLoading)
            .accessibilityLabel("Share a file with Ba-Chan")
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: [.image, .movie, .pdf, .text],
                          allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { conductor.attach(urls: urls) }
            }

            TextField("", text: $typed,
                      prompt: Text(conductor.isBrainLoading ? "Waking up my brain…" : "Type to Ba-Chan…")
                        .foregroundColor(.primary.opacity(0.45)))
                .textFieldStyle(.plain)
                .foregroundStyle(.primary)
                .tint(.primary)
                .focused($typingFocused)
                .submitLabel(.send)
                .onSubmit(sendTyped)
                .disabled(conductor.isBrainLoading)
                .padding(.horizontal, ControlMetrics.inputHPadding)
                .padding(.vertical, ControlMetrics.inputVPadding)
                .background(Color.primary.opacity(0.12), in: Capsule())
                .overlay(Capsule().strokeBorder(.primary.opacity(0.18), lineWidth: 1))
                #if os(iOS)
                // Dismiss the keyboard. Kept on the LEADING edge so it sits
                // diagonally opposite the trailing send button — otherwise the
                // two trailing-edge controls read as colliding above the keyboard.
                // `.keyboard` toolbar placement is iOS-only (no software keyboard on macOS).
                .toolbar {
                    ToolbarItemGroup(placement: .keyboard) {
                        Button { typingFocused = false } label: {
                            Image(systemName: "keyboard.chevron.compact.down")
                                .font(.system(size: 18, weight: .medium))
                                .foregroundStyle(.primary)
                        }
                        .accessibilityLabel("Dismiss keyboard")
                        Spacer()
                    }
                }
                #endif

            Button(action: sendTyped) {
                Image(systemName: "arrow.up")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(canSend ? Color.screen : Color.primary.opacity(0.4))
                    .frame(width: ControlMetrics.sendButton, height: ControlMetrics.sendButton)
                    .background(canSend ? Color.primary : Color.primary.opacity(0.12), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
        }
    }

    private var canSend: Bool {
        !conductor.isBrainLoading && !typed.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func sendTyped() {
        conductor.send(typed: typed)
        typed = ""
    }
}

#if os(macOS)
/// A tiny framed screenshot that floats above the face while Ba-Chan glances at
/// your screen — so the observing look reads as "I'm looking at *this*."
private struct LookingThumbnail: View {
    let image: CGImage

    var body: some View {
        Image(decorative: image, scale: 1, orientation: .up)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: 136, height: 86)
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(.primary.opacity(0.22), lineWidth: 1))
            .shadow(color: .black.opacity(0.28), radius: 9, y: 3)
            .rotationEffect(.degrees(-4))
            .offset(y: -162)
            .allowsHitTesting(false)
    }
}
#endif

/// Control sizing tuned per platform — chunky touch targets on iOS, compact on macOS.
private enum ControlMetrics {
    #if os(macOS)
    static let button: CGFloat = 30
    static let icon: Font = .body
    static let sendButton: CGFloat = 30
    static let inputVPadding: CGFloat = 7
    static let inputHPadding: CGFloat = 12
    #else
    static let button: CGFloat = 50
    static let icon: Font = .title3
    static let sendButton: CGFloat = 46
    static let inputVPadding: CGFloat = 12
    static let inputHPadding: CGFloat = 16
    #endif
}

/// A round icon-only toggle, white when on. Label is for VoiceOver only.
private struct IconToggle: View {
    let systemImage: String
    let isOn: Bool
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(ControlMetrics.icon.weight(.semibold))
                .foregroundStyle(isOn ? Color.screen : Color.primary)
                .frame(width: ControlMetrics.button, height: ControlMetrics.button)
                .background {
                    if isOn { Circle().fill(.primary) }
                    else { Circle().fill(.ultraThinMaterial) }
                }
        }
        .buttonStyle(.plain)   // no default macOS bordered-button background
        .accessibilityLabel(label)
    }
}

/// A small bouncing level meter shown while listening.
private struct MicMeter: View {
    let level: Float
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<4, id: \.self) { i in
                Capsule()
                    .frame(width: 4, height: barHeight(i))
                    .foregroundStyle(.primary)
            }
        }
        .frame(height: 22)
        .animation(.easeOut(duration: 0.1), value: level)
    }

    private func barHeight(_ index: Int) -> CGFloat {
        let threshold = Float(index + 1) / 5
        return level * 6 > threshold ? CGFloat(8 + index * 4) : 5
    }
}

#Preview {
    ContentView(conductor: Conductor())
}
