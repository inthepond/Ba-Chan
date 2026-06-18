#if os(macOS)
import Foundation

/// Decides when Ba-Chan speaks FIRST (macOS presence). Everything else in the app
/// is reactive — this is the initiative: a morning greeting, a word when you come
/// back after being away, an elder's nag after hours at the screen or deep into
/// the night. It only *decides*; the Conductor composes the line (templated or
/// model-grounded) and delivers it (transcript, voice, notification).
///
/// Restraint is the design: one global cooldown across all impulses, day-scoped
/// markers for the once-a-day ones, and the Conductor additionally refuses to butt
/// into an active conversation.
@MainActor
final class ImpulseEngine {
    enum Impulse {
        case morningGreeting
        /// They sat back down after a real absence — worth a model-grounded check-in.
        case welcomeBack(awayMinutes: Int)
        /// Hours at the screen without a break.
        case stretchNag(screenMinutes: Int, appName: String?)
        /// Still at the screen deep into the night.
        case lateNight
        /// Settled into the same app/page a while — Ba-Chan peeks and offers a hand.
        case glanceAtScreen(appName: String?)
    }

    var onImpulse: ((Impulse) -> Void)?

    /// Whether screen awareness is on — only then does Ba-Chan glance at your screen.
    var screenAware = false

    /// Minimum time between ANY two proactive moments.
    var minimumGap: TimeInterval = 25 * 60
    /// Away at least this long before a return earns a welcome-back.
    var awayThreshold: TimeInterval = 45 * 60
    /// Settled on the same app this long before Ba-Chan glances over.
    var glanceDwellMinutes = 30

    private var lastFired = Date.distantPast
    /// First stretch nag at 2 h, then again every 75 more minutes at the screen.
    private var lastNagAtMinutes = 0
    /// The app we last glanced at — so one sustained session earns at most one peek.
    private var glancedApp: String?
    private var lateNightFiredDay: Date?
    private static let greetedDayKey = "impulseGreetedDay"

    /// A real exchange counts as contact — push the cooldown out so Ba-Chan doesn't
    /// pipe up right after you've been talking.
    func conversationHappened() { lastFired = Date() }

    /// Wake events only fire after an idle spell, so the first launch of the day
    /// checks the morning greeting here.
    func appLaunched() {
        if claimMorningGreeting() { fire(.morningGreeting) }
    }

    /// The user is back after `seconds` of whole-system idle.
    func userReturned(afterAway seconds: TimeInterval) {
        if seconds >= 20 * 60, claimMorningGreeting() {
            fire(.morningGreeting)
        } else if seconds >= awayThreshold {
            fire(.welcomeBack(awayMinutes: Int(seconds / 60)))
        }
    }

    /// Each `WorkRhythm` poll while the user is at the screen.
    func tick(_ s: WorkRhythm.Snapshot) {
        if s.screenMinutes < 100 { lastNagAtMinutes = 0 }   // a break re-arms the nag
        if s.screenMinutes >= 120, s.screenMinutes - lastNagAtMinutes >= 75 {
            lastNagAtMinutes = s.screenMinutes
            fire(.stretchNag(screenMinutes: s.screenMinutes, appName: s.appName))
        }

        // Settled into one app/page long enough to be worth a glance — once per
        // sustained session (the app name changing re-arms it).
        if screenAware, let app = s.appName, app != glancedApp,
           s.appMinutes >= glanceDwellMinutes {
            glancedApp = app
            fire(.glanceAtScreen(appName: app))
        }

        let today = Calendar.current.startOfDay(for: Date())
        if (0..<5).contains(Calendar.current.component(.hour, from: Date())),
           s.screenMinutes >= 30, lateNightFiredDay != today {
            lateNightFiredDay = today
            fire(.lateNight)
        }
    }

    /// True at most once per calendar day, in the morning hours (marker persisted).
    private func claimMorningGreeting() -> Bool {
        let today = Calendar.current.startOfDay(for: Date())
        let hour = Calendar.current.component(.hour, from: Date())
        guard (5..<12).contains(hour),
              (UserDefaults.standard.object(forKey: Self.greetedDayKey) as? Date) != today
        else { return false }
        UserDefaults.standard.set(today, forKey: Self.greetedDayKey)
        return true
    }

    private func fire(_ impulse: Impulse) {
        guard Date().timeIntervalSince(lastFired) >= minimumGap else { return }
        lastFired = Date()
        onImpulse?(impulse)
    }
}
#endif
