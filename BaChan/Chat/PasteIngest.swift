#if os(macOS)
import Foundation
import UniformTypeIdentifiers

/// Resolves an item pasted into the chat box (an `NSItemProvider` from SwiftUI's
/// `onPasteCommand`) into something `AttachmentIngestor` can read: a file copied
/// from Finder keeps its URL; a raw image off the clipboard — a screenshot, a
/// "Copy Image" from the web — arrives as bytes with no backing file.
extension NSItemProvider {
    /// The pasted item as a file URL, when it's a file (from Finder).
    func pastedFileURL() async -> URL? {
        let id = UTType.fileURL.identifier
        guard hasItemConformingToTypeIdentifier(id) else { return nil }
        return await withCheckedContinuation { continuation in
            loadItem(forTypeIdentifier: id) { item, _ in
                if let url = item as? URL {
                    continuation.resume(returning: url)
                } else if let data = item as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil) {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// The pasted item as raw image bytes + a friendly name, when it's an image
    /// with no file behind it. Tries common still formats in clipboard order.
    func pastedImage() async -> (data: Data, name: String)? {
        for type in [UTType.png, .tiff, .jpeg, .heic, .gif] {
            guard hasItemConformingToTypeIdentifier(type.identifier),
                  let data = await loadData(type.identifier) else { continue }
            let ext = type.preferredFilenameExtension ?? "png"
            let base = suggestedName ?? "Pasted image"
            return (data, base.hasSuffix(".\(ext)") ? base : "\(base).\(ext)")
        }
        return nil
    }

    private func loadData(_ identifier: String) async -> Data? {
        await withCheckedContinuation { continuation in
            loadDataRepresentation(forTypeIdentifier: identifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }
}
#endif
