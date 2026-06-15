#if os(macOS)
import AppKit
import ScreenCaptureKit
import CoreGraphics

/// Ba-Chan's third sight (macOS): a single on-demand grab of the screen via
/// ScreenCaptureKit — "look at my screen" turns route the frame through the same
/// pipeline as the camera (Apple-Vision cues + a VLM look). Strictly one frame per
/// asking turn, never a stream, and only while the manual Screen toggle is on.
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

    /// One frame of the display the mouse is on (where they're working), with our
    /// own windows excluded — the popover must not cover what they're asking about.
    /// Downscaled enough for OCR and a small local VLM payload. Nil on any failure
    /// (no permission, no display).
    @MainActor
    static func captureFrame() async -> CGImage? {
        guard let content = try? await SCShareableContent
            .excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return nil }

        let mouse = NSEvent.mouseLocation
        let mouseScreenID = NSScreen.screens
            .first { NSMouseInRect(mouse, $0.frame, false) }?
            .deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        guard let display = content.displays.first(where: { $0.displayID == mouseScreenID })
            ?? content.displays.first else { return nil }

        let us = content.applications.filter {
            $0.processID == ProcessInfo.processInfo.processIdentifier
        }
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
}
#endif
