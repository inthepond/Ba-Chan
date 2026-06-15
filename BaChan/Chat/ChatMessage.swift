import Foundation

/// One bubble in the on-screen transcript. The visible chat is UI state owned by
/// the Conductor; durable history lives in `ConversationLog` (timestamped, on
/// disk) and distilled facts in `MemoryStore`.
struct ChatMessage: Identifiable, Equatable {
    enum Role { case user, bachan }

    let id = UUID()
    let role: Role
    var text: String
    let date: Date
    /// File names the user attached to this message (shown as small chips).
    var attachments: [String] = []
}
