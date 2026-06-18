#if os(macOS)
import AppKit
import ApplicationServices

/// Whether Ba-Chan may read other apps' UI via the Accessibility API.
enum AccessibilityAccess {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    private static var prompted = false
    /// True when trusted; the first untrusted call also raises the system prompt
    /// (which sends the user to System Settings ▸ Privacy ▸ Accessibility). Prompt
    /// once per launch so accepting a glance doesn't nag.
    @MainActor static func ensureTrusted() -> Bool {
        if AXIsProcessTrusted() { return true }
        if !prompted {
            prompted = true
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue()
            _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        }
        return false
    }
}

/// Reads the readable text of a browser's current page via the Accessibility tree —
/// the whole article, not just the visible part — so Ba-Chan can really summarize a
/// page when you accept its offer. Returns "" when the app isn't a known browser,
/// Accessibility isn't granted, or nothing readable turns up (the caller then falls
/// back to a screenshot). Reads the app explicitly (by pid), not the live frontmost,
/// since BaChan is frontmost while you type in its popover.
enum PageTextReader {
    @MainActor
    static func pageText(of app: NSRunningApplication?, maxChars: Int = 4000) async -> String {
        guard let app, let bid = app.bundleIdentifier, BrowserActivity.isBrowser(bid),
              AccessibilityAccess.ensureTrusted() else { return "" }
        let pid = app.processIdentifier
        return await Task.detached(priority: .userInitiated) {
            extractText(pid: pid, maxChars: maxChars)
        }.value
    }

    private static func extractText(pid: pid_t, maxChars: Int) -> String {
        let app = AXUIElementCreateApplication(pid)
        guard let window = copyElement(app, kAXFocusedWindowAttribute)
                ?? copyElement(app, kAXMainWindowAttribute),
              let web = findWebArea(window, budget: 6000) else { return "" }

        var out = ""
        var stack = [web]
        var nodes = 0
        while let node = stack.popLast(), nodes < 9000, out.count < maxChars {
            nodes += 1
            switch role(node) {
            case "AXStaticText", "AXTextArea", "AXTextField", "AXHeading":
                if let s = string(node, kAXValueAttribute), !s.isEmpty { out += s + " " }
            default:
                break
            }
            stack.append(contentsOf: children(node).reversed())   // rough reading order
        }

        let tidy = out
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard tidy.count > 40 else { return "" }    // a few stray words isn't a page
        return tidy.count > maxChars ? String(tidy.prefix(maxChars)) + "… (it goes on)" : tidy
    }

    // MARK: - AX helpers

    /// Breadth-first to the first web content area under a window.
    private static func findWebArea(_ root: AXUIElement, budget: Int) -> AXUIElement? {
        var queue = [root]
        var seen = 0
        while !queue.isEmpty, seen < budget {
            let el = queue.removeFirst()
            seen += 1
            if role(el) == "AXWebArea" { return el }
            queue.append(contentsOf: children(el))
        }
        return nil
    }

    private static func copyElement(_ el: AXUIElement, _ attr: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &value) == .success,
              let v = value, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    private static func children(_ el: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &value) == .success,
              let arr = value as? [AXUIElement] else { return [] }
        return arr
    }

    private static func role(_ el: AXUIElement) -> String {
        string(el, kAXRoleAttribute) ?? ""
    }

    private static func string(_ el: AXUIElement, _ attr: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
#endif
