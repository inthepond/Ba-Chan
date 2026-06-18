#if os(macOS)
import AppKit
import ScreenCaptureKit
import CoreGraphics

/// Ba-Chan's third sight (macOS): on-demand grabs of the screen via
/// ScreenCaptureKit — "look at my screen" turns route the frames through the same
/// pipeline as the camera (Apple-Vision cues + a VLM look). Strictly captured on an
/// asking turn, never a stream, and only while the manual Screen toggle is on.
///
/// Spans **every display**: with two monitors a glance has to take in both, so
/// `captureAll()` returns one shot per screen, position-labelled ("your left
/// screen") with the display under the mouse marked focal — that's the one handed
/// to the VLM, while all of them feed OCR cues.
///
/// Needs the **Screen Recording** permission (TCC). `CGPreflightScreenCaptureAccess`
/// checks it without prompting; `CGRequestScreenCaptureAccess` raises the system
/// dialog that sends the user to System Settings (macOS then wants an app relaunch).
enum ScreenSightService {
    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Ask macOS for the permission. Returns immediately; granting happens in
    /// System Settings and typically takes effect after the app is reopened.
    @discardableResult
    static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    /// One captured display.
    struct DisplayShot {
        var image: CGImage
        /// How Ba-Chan refers to it ("your screen", "your left screen", …).
        var label: String
        /// The display the mouse is on — where they're actually working.
        var isFocal: Bool
    }

    /// A frame of every display (our own windows excluded), downscaled enough for
    /// OCR and a small VLM payload. Empty on any failure (no permission, no display).
    /// Capped at three screens to bound an on-ask turn's cost.
    @MainActor
    static func captureAll() async -> [DisplayShot] {
        guard let content = try? await SCShareableContent
            .excludingDesktopWindows(false, onScreenWindowsOnly: true),
            !content.displays.isEmpty else { return [] }

        let us = content.applications.filter {
            $0.processID == ProcessInfo.processInfo.processIdentifier
        }

        // Left-to-right, so "your left screen" / "your right screen" match reality.
        let ordered = content.displays.sorted { $0.frame.minX < $1.frame.minX }
        let focalID = mouseDisplayID()
        let n = min(ordered.count, 3)

        var shots: [DisplayShot] = []
        for (i, display) in ordered.prefix(n).enumerated() {
            guard let image = await capture(display, excluding: us) else { continue }
            let focal = display.displayID == focalID
            shots.append(DisplayShot(image: image,
                                     label: Self.label(index: i, count: n, focal: focal),
                                     isFocal: focal))
        }
        return shots
    }

    private static func capture(_ display: SCDisplay,
                                excluding us: [SCRunningApplication]) async -> CGImage? {
        let filter = SCContentFilter(display: display, excludingApplications: us,
                                     exceptingWindows: [])
        let config = SCStreamConfiguration()
        let scale = min(1, 1512.0 / Double(display.width))
        config.width = Int(Double(display.width) * scale)
        config.height = Int(Double(display.height) * scale)
        config.showsCursor = false
        return try? await SCScreenshotManager.captureImage(contentFilter: filter,
                                                           configuration: config)
    }

    /// The display the mouse is on, mapped back to its `CGDirectDisplayID`.
    private static func mouseDisplayID() -> CGDirectDisplayID? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens
            .first { NSMouseInRect(mouse, $0.frame, false) }?
            .deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    /// "your screen" for a single display; spatial names for two or three; the focal
    /// one gets " (where you're working)" so the model knows where the attention is.
    private static func label(index: Int, count: Int, focal: Bool) -> String {
        let base: String
        switch (count, index) {
        case (1, _):      base = "your screen"
        case (2, 0):      base = "your left screen"
        case (2, _):      base = "your right screen"
        case (3, 0):      base = "your left screen"
        case (3, 1):      base = "your middle screen"
        case (3, _):      base = "your right screen"
        default:          base = "screen \(index + 1)"
        }
        return focal && count > 1 ? "\(base) (where you're working)" : base
    }
}
#endif
