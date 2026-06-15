#if os(macOS)
import AppKit

/// Follows the mouse pointer so Ba-Chan's eyes can track it (macOS). Polls
/// `NSEvent.mouseLocation` on a short timer — like `SystemActivityMonitor` it
/// never intercepts events, so it needs no Accessibility / Input-Monitoring
/// permission, and it works whether the cursor is over our windows or not.
///
/// The owner supplies `anchor` — where the face currently is in screen
/// coordinates (the popover when open, else the menu-bar tray icon) — and gets
/// back a normalized gaze point in the FaceController's space (x right, y down,
/// clamped like eye contact). After `restDelay` with no movement `onRest` fires
/// once so the idle gaze wander can resume.
@MainActor
final class PointerTracker {
    /// Where the face is on screen right now (AppKit coordinates, origin bottom-left).
    var anchor: (() -> CGPoint?)?
    /// The pointer moved — normalized gaze target toward it.
    var onMove: ((CGPoint) -> Void)?
    /// The pointer has been still for `restDelay` — release the gaze.
    var onRest: (() -> Void)?

    /// Seconds of stillness before the eyes let go of the cursor.
    var restDelay: TimeInterval = 2.5

    /// Pointer distance (in points) that swings the eyes to full deflection.
    /// Small enough that movement near the face reads clearly; farther cursor
    /// positions just pin the gaze toward that edge.
    private let xRange: CGFloat = 700
    private let yRange: CGFloat = 450

    private var task: Task<Void, Never>?
    private var lastLocation: CGPoint?
    private var stillTicks = 0
    private var resting = true

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                self.tick()
                try? await Task.sleep(nanoseconds: 33_000_000)   // ~30 Hz
            }
        }
    }

    func stop() { task?.cancel(); task = nil }

    private func tick() {
        let location = NSEvent.mouseLocation
        defer { lastLocation = location }

        guard let last = lastLocation else { return }
        let moved = abs(location.x - last.x) > 0.5 || abs(location.y - last.y) > 0.5

        if moved {
            stillTicks = 0
            resting = false
            if let anchor = anchor?() {
                // AppKit y grows upward; gaze y grows downward — flip the sign.
                let gaze = CGPoint(
                    x: max(-0.85, min(0.85, (location.x - anchor.x) / xRange)),
                    y: max(-0.6, min(0.6, -(location.y - anchor.y) / yRange)))
                onMove?(gaze)
            }
        } else if !resting {
            stillTicks += 1
            if Double(stillTicks) * 0.033 >= restDelay {
                resting = true
                onRest?()
            }
        }
    }
}
#endif
