#if os(macOS)
import AppKit

/// Reads the active tab of the frontmost browser — its title and URL — so Ba-Chan
/// knows not just *which* app you're in (that's `WorkRhythm`) but *what* you're
/// reading. The light, structured, ambient half of screen awareness; the heavy
/// on-ask half is `ScreenSightService` (a real screenshot + OCR).
///
/// Reading another app's tab is an Apple Event, so unlike `WorkRhythm` this needs
/// the **Automation** permission — macOS prompts "BaChan wants to control Safari"
/// the first time per browser. Denied or no window → "" (we silently fall back to
/// the bare app name). Gated by the same opt-in switch as screen sight, and only
/// run on a real chat turn, so the consent prompt lands while the user is present.
enum BrowserActivity {
    struct Tab: Sendable { var title: String; var url: String }

    /// Chromium-family browsers share one scripting model: `active tab of front
    /// window` with `title` / `URL`. Safari uses `current tab` with `name` / `URL`.
    private static let chromium: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary",
        "com.microsoft.edgemac", "com.brave.Browser", "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera", "company.thebrowser.Browser",      // Arc
    ]
    private static let safari: Set<String> = [
        "com.apple.Safari", "com.apple.SafariTechnologyPreview",
    ]

    /// Whether a bundle id is a browser whose active tab we know how to read.
    static func isBrowser(_ bundleID: String) -> Bool {
        safari.contains(bundleID) || chromium.contains(bundleID)
    }

    /// The active tab of `app`, or nil when it isn't a known browser (or has no
    /// window / we're not authorized). Takes the app explicitly — NOT the live
    /// frontmost — because BaChan is frontmost while you type in its popover.
    static func tab(of app: NSRunningApplication?) async -> Tab? {
        guard let bid = app?.bundleIdentifier else { return nil }
        let accessor: String
        if safari.contains(bid) {
            accessor = "get {name, URL} of current tab of front window"
        } else if chromium.contains(bid) {
            accessor = "get {title, URL} of active tab of front window"
        } else {
            return nil
        }
        // `application id` avoids hard-coding localized app names.
        return await run("tell application id \"\(bid)\" to \(accessor)")
    }

    /// A short context phrase for the prompt, or "" — "reading “Title” on host.com".
    static func contextLine(of app: NSRunningApplication?) async -> String {
        guard let tab = await tab(of: app) else { return "" }
        let title = tab.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = URL(string: tab.url)?.host?
            .replacingOccurrences(of: "www.", with: "") ?? ""
        switch (title.isEmpty, host.isEmpty) {
        case (false, false): return "reading \u{201C}\(title)\u{201D} on \(host)"
        case (false, true):  return "reading \u{201C}\(title)\u{201D}"
        case (true, false):  return "browsing \(host)"
        case (true, true):   return ""
        }
    }

    /// NSAppleScript isn't thread-safe and the first call can block on a system
    /// consent dialog, so run it off the main thread on a dedicated serial queue —
    /// the UI stays live and no two scripts compile at once.
    private static let queue = DispatchQueue(label: "com.example.BaChan.browseractivity")

    private static func run(_ source: String) async -> Tab? {
        await withCheckedContinuation { continuation in
            queue.async {
                var error: NSDictionary?
                guard let script = NSAppleScript(source: source) else {
                    return continuation.resume(returning: nil)
                }
                let out = script.executeAndReturnError(&error)
                guard error == nil, out.numberOfItems >= 2,        // AERecord, 1-based
                      let title = out.atIndex(1)?.stringValue,
                      let url = out.atIndex(2)?.stringValue else {
                    return continuation.resume(returning: nil)
                }
                continuation.resume(returning: Tab(title: title, url: url))
            }
        }
    }
}
#endif
