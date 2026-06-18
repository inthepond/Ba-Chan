#if os(macOS)
import AppKit

/// Watches the rhythm of the owner's work on the Mac — which app is frontmost, how
/// long they've focused on it, and how long they've been at the screen without a
/// real break. Like `SystemActivityMonitor` and `PointerTracker` it only reads
/// public state (`NSWorkspace.frontmostApplication` + the HID idle time), so it
/// needs no Accessibility / Screen-Recording permission.
///
/// Two consumers: every chat turn gets `contextLine()` in `BrainContext.rhythm`
/// (so Ba-Chan knows what you're up to right now), and each poll hands a
/// `Snapshot` to the `ImpulseEngine` (stretch nags, late-night nags).
@MainActor
final class WorkRhythm {
    struct Snapshot {
        /// The frontmost app's name (never our own app — chatting with Ba-Chan
        /// doesn't count as "using BaChan").
        var appName: String?
        /// Continuous minutes the same app has been frontmost.
        var appMinutes: Int = 0
        /// Continuous minutes at the screen since the last real break.
        var screenMinutes: Int = 0
    }

    /// Fired every poll (~5 s) while the user is at the screen.
    var onTick: ((Snapshot) -> Void)?

    /// The last app that was genuinely frontmost (never us). Kept because while you
    /// type in Ba-Chan's popover, BaChan itself is frontmost — so anything that needs
    /// to read *your* app (the browser tab, the page text) must use this, not the live
    /// `frontmostApplication`. Nil until you've focused a real app.
    private(set) var frontApp: NSRunningApplication?

    /// Whole-system idle that counts as a real break (stepping away, not just
    /// pausing to think) — it resets the screen stretch.
    var breakThreshold: TimeInterval = 180

    private(set) var snapshot = Snapshot()

    private var task: Task<Void, Never>?
    private var appSince = Date()
    private var stretchStart = Date()
    private var onBreak = false

    func start() {
        guard task == nil else { return }
        stretchStart = Date()
        appSince = Date()
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                self.tick()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    func stop() { task?.cancel(); task = nil }

    /// How the rhythm reads inside the prompt context — empty when there's nothing
    /// notable yet (they just sat down).
    func contextLine() -> String {
        var bits: [String] = []
        if let app = snapshot.appName, !app.isEmpty {
            bits.append(snapshot.appMinutes >= 10
                ? "using \(app) for about \(Self.spell(minutes: snapshot.appMinutes))"
                : "using \(app)")
        }
        if snapshot.screenMinutes >= 45 {
            bits.append("at the screen about \(Self.spell(minutes: snapshot.screenMinutes)) without a real break")
        }
        return bits.joined(separator: ", ")
    }

    private func tick() {
        let idle = SystemActivityMonitor.systemIdleSeconds()
        let now = Date()
        if idle >= breakThreshold {
            onBreak = true
            return                       // away — nothing accrues, no ticks
        }
        if onBreak {                     // back from a break: a fresh stretch
            onBreak = false
            stretchStart = now
            appSince = now
        }
        if let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            frontApp = front
            let name = front.localizedName ?? ""
            if name != snapshot.appName {
                snapshot.appName = name
                appSince = now
            }
        }
        snapshot.appMinutes = Int(now.timeIntervalSince(appSince) / 60)
        snapshot.screenMinutes = Int(now.timeIntervalSince(stretchStart) / 60)
        onTick?(snapshot)
    }

    /// Plain spoken-style duration ("25 minutes", "an hour and a half", "3 hours").
    static func spell(minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) minutes" }
        let hours = minutes / 60, rest = minutes % 60
        if rest < 15 { return hours == 1 ? "an hour" : "\(hours) hours" }
        if rest < 45 { return hours == 1 ? "an hour and a half" : "\(hours) and a half hours" }
        return "\(hours + 1) hours"
    }
}
#endif
