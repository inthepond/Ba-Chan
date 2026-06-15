#if os(macOS)
import Foundation
import CoreGraphics

/// Watches whole-system user activity (keyboard / mouse / trackpad anywhere on the
/// Mac) and drives Ba-Chan's sleep/wake: when you step away from the laptop it dozes,
/// and any input brings it back. Reads the HID idle time on a short poll — it does NOT
/// intercept events, so it needs no Accessibility / Input-Monitoring permission.
@MainActor
final class SystemActivityMonitor {
    /// Fired once when whole-system idle crosses `idleThreshold` (you stepped away).
    var onSleep: (() -> Void)?
    /// Fired once on the first input after being idle (you're back), with how long
    /// the whole break lasted — from the last input before it to now.
    var onWake: ((TimeInterval) -> Void)?

    /// Seconds of whole-system inactivity before dozing.
    var idleThreshold: TimeInterval = 15

    private var task: Task<Void, Never>?
    private var isIdle = false
    /// When the input that started the current break happened (set on crossing).
    private var idleBegan: Date?

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                self.tick()
                try? await Task.sleep(nanoseconds: 500_000_000)   // poll twice a second
            }
        }
    }

    func stop() { task?.cancel(); task = nil }

    private func tick() {
        let idle = Self.systemIdleSeconds()
        if idle >= idleThreshold {
            if !isIdle {
                isIdle = true
                idleBegan = Date().addingTimeInterval(-idle)
                onSleep?()
            }
        } else if isIdle {
            isIdle = false
            let away = idleBegan.map { Date().timeIntervalSince($0) } ?? idleThreshold
            idleBegan = nil
            onWake?(away)
        }
    }

    /// Seconds since the most recent system-wide input event — the minimum across the
    /// input event types (i.e. the most recent one). Using the per-type minimum avoids
    /// relying on the non-Swift `kCGAnyInputEventType` constant.
    static func systemIdleSeconds() -> TimeInterval {
        let types: [CGEventType] = [.mouseMoved, .leftMouseDown, .rightMouseDown,
                                    .keyDown, .flagsChanged, .scrollWheel]
        return types
            .map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }
            .min() ?? .greatestFiniteMagnitude
    }
}
#endif
