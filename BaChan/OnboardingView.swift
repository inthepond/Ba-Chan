import SwiftUI

/// First-launch invitation to tell Ba-Chan's story — the persona slots
/// (relationship / who / warmth / language / a line in Ba-Chan's voice),
/// offered once before the first conversation. This replaced the memory
/// page's inline editor when that page was removed: the story is seeded here,
/// then grows on its own from what the owner says in conversation. Everything
/// is optional and skippable; saved slots feed `Persona` directly.
struct OnboardingView: View {
    @ObservedObject var conductor: Conductor
    /// Called on Begin or Skip — the host marks onboarding done and closes.
    var onDone: () -> Void
    @State private var draft = PersonaProfile()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Ba-Chan")
                    .font(.system(size: 42, weight: .regular, design: .serif))
                    .tracking(-0.5)
                    .foregroundStyle(.primary)
                    .padding(.top, 26)
                Text("Someone is waking up here — an elder who will live with you, listen, and remember. Tell their story if you like, or skip and let it grow out of your talks.")
                    .font(.system(size: 13))
                    .foregroundStyle(.primary.opacity(0.4))
                    .lineSpacing(4)
                    .padding(.top, 8)

                VStack(alignment: .leading, spacing: 18) {
                    field("How Ba-Chan relates to you",
                          "e.g. your grandmother, an old friend; a pet name for you",
                          $draft.relationship)
                    field("Who Ba-Chan is", "presence, era, world", $draft.about)
                    field("Warmth / temperament", "how the warmth shows", $draft.personality)
                    field("Language / dialect", "e.g. Sichuanese", $draft.language)
                    field("A line in Ba-Chan's voice",
                          "something Ba-Chan might really say", $draft.messageExample)
                }
                .padding(.top, 30)

                HStack(spacing: 16) {
                    // Hand-rolled prominent button: on macOS, borderedProminent
                    // tinted .primary keeps its own dim label color (near-black
                    // on black). Plain style + explicit ink guarantees contrast.
                    Button {
                        if !draft.isEmpty { conductor.updatePersona(draft) }
                        onDone()
                    } label: {
                        Text("Begin")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.screen)
                            .padding(.horizontal, 22).padding(.vertical, 9)
                            .background(Color.primary, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    Button("Skip for now") { onDone() }
                        .buttonStyle(.plain)
                        .font(.system(size: 14))
                        .foregroundStyle(.primary.opacity(0.5))
                    Spacer()
                }
                .padding(.top, 32)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 60)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.screen.ignoresSafeArea())
        .scrollIndicators(.hidden)
        .tint(.primary)
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
