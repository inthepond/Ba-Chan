import SwiftUI

/// Settings — opened from the tray menu (macOS). Four quiet sections in the
/// memory-page typography: the active brain, Ba-Chan's story (the persona
/// slots, editable any time after onboarding), a hand-added memory, and the
/// cloud API keys (Claude / OpenAI / Gemini / OpenRouter — saved to the
/// Keychain; a saved key adds that brain to the picker).
struct SettingsView: View {
    @ObservedObject var conductor: Conductor
    var onClose: () -> Void

    @State private var draftProfile = PersonaProfile()
    @State private var memoryDraft = ""
    @State private var memoryAdded = false
    // Key fields are write-only mirrors: saved keys show as a placeholder, not
    // the secret itself; typing replaces, clearing deletes.
    @State private var keyDrafts: [BrainKind: String] = [:]
    @State private var openRouterModel =
        UserDefaults.standard.string(forKey: Conductor.openRouterModelKey) ?? ""
    @State private var anthropicModel =
        UserDefaults.standard.string(forKey: Conductor.anthropicModelKey) ?? ""

    private let cloudKinds: [BrainKind] = [.claude, .openai, .gemini, .openrouter]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                titleRow
                brainSection.padding(.top, 30)
                storySection.padding(.top, 40)
                memorySection.padding(.top, 40)
                keysSection.padding(.top, 40)
            }
            .padding(.horizontal, 24)
            .padding(.top, 26)
            .padding(.bottom, 60)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.screen.ignoresSafeArea())
        .scrollIndicators(.hidden)
        .tint(.primary)
        .onAppear { draftProfile = conductor.personaProfile }
    }

    private var titleRow: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Settings")
                .font(.system(size: 42, weight: .regular, design: .serif))
                .tracking(-0.5).foregroundStyle(.primary)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.5))
                    .frame(width: 32, height: 40)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
    }

    // MARK: - Brain (model switching, mirrored from the chat-bar menu)

    private var brainSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            label("Brain")
            Text("Who answers when you talk to Ba-Chan. Also switchable from the \(Image(systemName: conductor.selectedModel.menuIcon)) button next to the chat box.")
                .font(.system(size: 12))
                .foregroundStyle(.primary.opacity(0.35))
                .lineSpacing(3)
                .padding(.top, 8)
            VStack(alignment: .leading, spacing: 12) {
                ForEach(conductor.availableModels) { kind in
                    Button {
                        conductor.selectModel(kind)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: kind == conductor.selectedModel
                                  ? "circle.inset.filled" : "circle")
                                .font(.system(size: 13))
                                .foregroundStyle(.primary.opacity(
                                    kind == conductor.selectedModel ? 0.9 : 0.35))
                            Text(kind.displayName).font(.system(size: 15))
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                // Cloud brains without a key stay visible but locked, so it's
                // obvious that pasting a key below is what unlocks them.
                ForEach(cloudKinds.filter { !conductor.availableModels.contains($0) }) { kind in
                    HStack(spacing: 8) {
                        Image(systemName: "lock")
                            .font(.system(size: 12))
                            .foregroundStyle(.primary.opacity(0.25))
                        Text(kind.displayName).font(.system(size: 15))
                            .foregroundStyle(.primary.opacity(0.35))
                        Spacer()
                        Text("add its API key below")
                            .font(.system(size: 11))
                            .foregroundStyle(.primary.opacity(0.3))
                    }
                }
            }
            .padding(.top, 14)
        }
    }

    // MARK: - Ba-Chan's story (the persona slots, editable after onboarding)

    private var storySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            label("Ba-Chan's story")
            VStack(alignment: .leading, spacing: 18) {
                field("How Ba-Chan relates to you",
                      "e.g. your grandmother, an old friend; a pet name for you",
                      $draftProfile.relationship)
                field("Who Ba-Chan is", "presence, era, world", $draftProfile.about)
                field("Warmth / temperament", "how the warmth shows", $draftProfile.personality)
                field("Language / dialect", "e.g. Sichuanese", $draftProfile.language)
                field("A line in Ba-Chan's voice",
                      "something Ba-Chan might really say", $draftProfile.messageExample)
                Button("Save story") { conductor.updatePersona(draftProfile) }
                    .buttonStyle(.plain)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
            }
            .padding(.top, 14)
        }
    }

    // MARK: - Add a memory by hand

    private var memorySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            label("Add a memory")
            VStack(alignment: .leading, spacing: 10) {
                TextField("Something Ba-Chan would want kept", text: $memoryDraft,
                          axis: .vertical)
                    .textFieldStyle(.plain).lineLimit(1...4).font(.system(size: 15))
                    .foregroundStyle(.primary).tint(.primary)
                    .padding(.bottom, 5)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(.primary.opacity(0.18)).frame(height: 1)
                    }
                HStack(spacing: 12) {
                    Button("Add") {
                        conductor.addPersonaMemory(memoryDraft)
                        memoryDraft = ""
                        memoryAdded = true
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                    .disabled(memoryDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                    .opacity(memoryDraft.trimmingCharacters(in: .whitespaces).isEmpty ? 0.35 : 1)
                    if memoryAdded {
                        Text("Kept.").font(.system(size: 13))
                            .foregroundStyle(.primary.opacity(0.4))
                    }
                }
            }
            .padding(.top, 14)
        }
    }

    // MARK: - Cloud API keys

    private var keysSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            label("Cloud brains")
            Text("Paste an API key to add that model to the brain picker. Keys are stored only in the system Keychain; replies then go through that provider's servers.")
                .font(.system(size: 12))
                .foregroundStyle(.primary.opacity(0.35))
                .lineSpacing(3)
                .padding(.top, 8)

            VStack(alignment: .leading, spacing: 18) {
                ForEach(cloudKinds) { kind in
                    keyField(for: kind)
                }
                field("Claude model (optional)",
                      "e.g. claude-fable-5 — empty = claude-opus-4-8",
                      $anthropicModel)
                field("OpenRouter model (optional)",
                      "e.g. anthropic/claude-opus-4.8 — empty = auto router",
                      $openRouterModel)
            }
            .padding(.top, 16)

            Button("Save keys") {
                for kind in cloudKinds {
                    // Untouched fields (no draft) keep their stored key.
                    if let draft = keyDrafts[kind] {
                        KeyStore.save(draft, for: kind.rawValue)
                    }
                }
                UserDefaults.standard.set(
                    anthropicModel.trimmingCharacters(in: .whitespaces),
                    forKey: Conductor.anthropicModelKey)
                UserDefaults.standard.set(
                    openRouterModel.trimmingCharacters(in: .whitespaces),
                    forKey: Conductor.openRouterModelKey)
                keyDrafts = [:]
                conductor.refreshCloudBrains()
            }
            .buttonStyle(.plain)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.primary)
            .padding(.top, 18)
        }
    }

    private func keyField(for kind: BrainKind) -> some View {
        let saved = KeyStore.load(kind.rawValue) != nil
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(kind.displayName.uppercased())
                    .font(.system(size: 10, weight: .medium)).tracking(2)
                    .foregroundStyle(.primary.opacity(0.45))
                if saved {
                    Text("KEY SAVED")
                        .font(.system(size: 9, weight: .semibold)).tracking(1.5)
                        .foregroundStyle(.primary.opacity(0.3))
                }
            }
            SecureField(saved ? "•••••••• (type to replace, clear to remove)"
                              : "API key",
                        text: Binding(
                            get: { keyDrafts[kind] ?? "" },
                            set: { keyDrafts[kind] = $0 }))
                .textFieldStyle(.plain).font(.system(size: 14))
                .foregroundStyle(.primary).tint(.primary)
                .padding(.bottom, 5)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(.primary.opacity(0.18)).frame(height: 1)
                }
        }
    }

    // MARK: - Shared pieces (memory-page typography)

    private func label(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .medium)).tracking(3)
            .foregroundStyle(.primary.opacity(0.5))
    }

    private func field(_ title: String, _ placeholder: String,
                       _ text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .medium)).tracking(2)
                .foregroundStyle(.primary.opacity(0.45))
            TextField(placeholder, text: text, axis: .vertical)
                .textFieldStyle(.plain).lineLimit(1...4).font(.system(size: 15))
                .foregroundStyle(.primary).tint(.primary)
                .padding(.bottom, 5)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(.primary.opacity(0.18)).frame(height: 1)
                }
        }
    }
}
