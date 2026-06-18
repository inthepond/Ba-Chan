#if os(macOS)
import AppKit

/// Makes Cmd-V attach a pasted file or image instead of letting the text field
/// swallow it as a filename string. A focused `NSTextField`'s field editor handles
/// `paste:` before SwiftUI's `onPasteCommand` ever sees it, so we intercept the key
/// event upstream: on Cmd-V, if the clipboard holds a file or image we take it and
/// swallow the event; otherwise we pass it through so a normal text paste still
/// lands in the field.
@MainActor
final class PasteMonitor {
    /// Handle a Cmd-V. Return true to consume the event (we took file/image content),
    /// false to let it through (plain text → the field).
    var onPaste: (() -> Bool)?

    private var monitor: Any?

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  event.charactersIgnoringModifiers == "v"
            else { return event }
            return (self.onPaste?() == true) ? nil : event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
#endif
