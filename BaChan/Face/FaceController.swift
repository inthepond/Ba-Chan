import SwiftUI
import QuartzCore

/// The "avatar engine": holds the live state of Stackchan's face and runs the
/// idle micro-animations (blinking + wandering gaze) that make it feel alive.
///
/// All motion is **frame-synced**: app logic only sets *target* values, and the
/// rendered values are eased toward those targets once per frame from
/// `AvatarView`'s `TimelineView`. Nothing uses `withAnimation`, so there are no
/// competing animation transactions to jitter at the end of a loop.
@MainActor
final class FaceController: ObservableObject {

    // MARK: - Targets (set by app logic / idle loops)

    private(set) var expression: Expression = .neutral
    private var targetGaze: CGPoint = .zero
    private var targetMouth: CGFloat = 0
    private var targetTilt: CGFloat = 0
    private var targetEyeOpen: CGFloat = 1   // driven by the blink loop

    // MARK: - Rendered state (eased toward the targets every frame)

    var eyeOpen: CGFloat = 1
    var gaze: CGPoint = .zero
    var mouth: CGFloat = 0
    var tilt: CGFloat = 0
    var browAngle: CGFloat = 0
    var browRaise: CGFloat = 0
    var mouthCurve: CGFloat = 0.18
    var eyeSquint: CGFloat = 0
    var blush: CGFloat = 0
    /// Extra eye-closing from being touched/petted (0 = none … 1 = squeezed shut).
    var squeeze: CGFloat = 0
    private var targetSqueeze: CGFloat = 0
    /// Head tilt from device motion (gravity), composited with `tilt` by the renderer.
    var gravityTilt: CGFloat = 0
    private var targetGravityTilt: CGFloat = 0

    // MARK: - Appearance genome (slow evolution)

    /// The slow-changing look (target) — set at launch from the
    /// `AppearanceStore` and nudged by its drift/stylist passes.
    private(set) var genome = FaceGenome()
    /// The rendered genome, eased per trait so a nightly nudge never pops —
    /// the face morphs over a couple of seconds, beneath notice.
    var genomeShown = FaceGenome()
    /// The accessory currently drawn. Discrete, so swaps crossfade instead of
    /// easing: the old prop fades out, then the new one fades in.
    private(set) var accessoryShown: FaceGenome.Accessory = .none
    /// Draw opacity of `accessoryShown`.
    var accessoryAlpha: CGFloat = 0

    /// Adopt a new genome. `animated: false` snaps (launch: the saved look
    /// should be there from the first frame, not morph in from neutral).
    func setGenome(_ g: FaceGenome, animated: Bool = true) {
        genome = g.clamped()
        if !animated {
            genomeShown = genome
            accessoryShown = genome.accessory
            accessoryAlpha = accessoryShown == .none ? 0 : 1
        }
    }

    /// True while the gaze is locked onto the user's face (eye contact) — pauses
    /// the random gaze wander.
    private var gazeOverridden = false
    /// True while the gaze is following the mouse pointer (macOS). Weaker than
    /// eye contact: it never wins over `gazeOverridden`, thinking, or working.
    private var pointerGazeActive = false
    /// Called when a reaction should spawn a particle effect.
    var onEffect: ((FaceEffect) -> Void)?
    private var lastHeartEffect: CFTimeInterval = 0

    /// Builds up as the eyes get poked; tips Ba-Chan from puzzled into angry.
    private var eyeAnnoyance: CGFloat = 0

    /// What Ba-Chan settles into when left alone. Sleeping happens only at night
    /// or in the early-afternoon lull; other idle hours bring a quiet pastime —
    /// reading, tea, humming, cooking — each with its own gaze behavior and a
    /// little prop drawn by the renderer. Any interaction ends it.
    enum Pastime: Equatable, CaseIterable {
        case none, sleeping, reading, tea, humming, cooking
    }
    private(set) var pastime: Pastime = .none
    private var pastimeTask: Task<Void, Never>?
    private var rotationTask: Task<Void, Never>?

    /// True while Ba-Chan is dozing. Read by the renderer to draw "Zzz".
    var isAsleep: Bool { pastime == .sleeping }
    /// Seconds of no interaction before Ba-Chan settles into a pastime.
    private let idleSleepDelay: Double = 20

    /// When false, Ba-Chan never dozes off on its own app-inactivity timer — used on
    /// macOS, where a `SystemActivityMonitor` drives sleep/wake from whole-machine
    /// idle instead. Disabling it cancels any pending doze.
    var autoIdleSleep = true {
        didSet { if !autoIdleSleep { idleTask?.cancel(); idleTask = nil } }
    }

    /// Launch draw-on progress: 0 = nothing on screen yet … 1 = fully drawn (normal
    /// rendering). The renderer traces each feature like a pen stroke (SVG-style
    /// path drawing) while this rises; it advances frame-synced like everything else.
    private(set) var intro: CGFloat = 1
    private var introStarted = false
    /// How long the full trace takes.
    private let introDuration: Double = 0.9

    /// Play the draw-on trace again (used when the macOS popover first opens, so
    /// the big face gets the entrance the tiny tray icon already had at launch).
    func replayIntro() { intro = 0 }

    private var lastTick: TimeInterval?
    private var blinkTask: Task<Void, Never>?
    private var gazeTask: Task<Void, Never>?
    private var revertTask: Task<Void, Never>?
    private var idleTask: Task<Void, Never>?
    private var startleTask: Task<Void, Never>?

    // Haptic throttling state.
    private var lastTouchRegion: FaceRegion?
    private var wasAngryFromPoke = false
    private var lastPokeHaptic: CFTimeInterval = 0
    private var lastPetHaptic: CFTimeInterval = 0

    // MARK: - Control

    func start() {
        guard blinkTask == nil else { return }
        if !introStarted { introStarted = true; intro = 0 }   // launch draw-on
        startBlinking()
        startGazing()
        restartIdleTimer()
    }

    func stop() {
        blinkTask?.cancel(); blinkTask = nil
        gazeTask?.cancel(); gazeTask = nil
        idleTask?.cancel(); idleTask = nil
        startleTask?.cancel(); startleTask = nil
        revertTask?.cancel(); revertTask = nil
        thinkTask?.cancel(); thinkTask = nil
        workTask?.cancel(); workTask = nil
        pastimeTask?.cancel(); pastimeTask = nil
        rotationTask?.cancel(); rotationTask = nil
    }

    func set(_ expression: Expression) {
        endPastime()             // conversation pulls Ba-Chan back, calmly
        restartIdleTimer()
        revertTask?.cancel()     // an explicit expression cancels any gesture auto-revert
        self.expression = expression
    }
    func setMouth(_ value: CGFloat) { targetMouth = max(0, min(1, value)) }
    func setTilt(_ value: CGFloat) { targetTilt = value }
    func look(at point: CGPoint) { targetGaze = point }

    // MARK: - Thinking

    /// True while "thinking" — pauses the idle gaze wander so the pondering
    /// glance below drives the eyes instead.
    private(set) var isThinking = false
    private var thinkTask: Task<Void, Never>?

    /// True while Ba-Chan is busy loading its brain (model download / prepare).
    /// Like `isThinking` it steers the gaze, and it additionally suppresses the
    /// idle-doze timer so Ba-Chan never falls asleep mid-load.
    private(set) var isWorking = false
    private var workTask: Task<Void, Never>?

    /// Play a pondering animation while a reply is being generated: a puzzled brow
    /// and eyes that glance up and around, as if mulling it over. Ends with `stopThinking()`.
    func startThinking() {
        endPastime()
        restartIdleTimer()
        revertTask?.cancel()
        expression = .doubt
        isThinking = true
        thinkTask?.cancel()
        thinkTask = Task { [weak self] in
            // Look up-and-around — the classic "hmm, let me think" eyes.
            let spots: [CGPoint] = [CGPoint(x: -0.45, y: -0.5), CGPoint(x: 0.45, y: -0.55),
                                    CGPoint(x: 0.0, y: -0.62), CGPoint(x: 0.5, y: -0.3),
                                    CGPoint(x: -0.3, y: -0.4)]
            var i = 0
            while !Task.isCancelled {
                guard let self else { break }
                self.targetGaze = spots[i % spots.count]
                self.targetTilt = (i % 2 == 0) ? 0.05 : -0.04   // tiny head wobble
                i += 1
                try? await Task.sleep(nanoseconds: UInt64(Double.random(in: 0.5...0.85) * 1_000_000_000))
            }
        }
    }

    /// Stop the pondering animation and recenter (the reply expression follows).
    func stopThinking() {
        guard isThinking else { return }
        isThinking = false
        thinkTask?.cancel(); thinkTask = nil
        targetTilt = 0
        targetGaze = .zero
        restartIdleTimer()   // start the doze countdown now that thinking has ended
    }

    // MARK: - Working (brain loading)

    /// Play a focused "working on something" animation while the on-device model
    /// downloads / loads: a mildly concentrated brow, a slow gaze that sweeps as
    /// if scanning, and a tiny rhythmic head bob — busy, not idle. Sleep is held
    /// off for the whole load by `isWorking` (see `fallAsleep`). End with `endWorking()`.
    func beginWorking() {
        guard !isWorking else { return }
        endPastime()               // never start working from a pastime pose
        idleTask?.cancel()         // suppress dozing for the whole load
        revertTask?.cancel()
        expression = .doubt        // a focused, mildly-furrowed look
        isWorking = true
        workTask?.cancel()
        workTask = Task { [weak self] in
            // A calm left/right sweep, lower than the thinking "look up" glance,
            // reading as "scanning / processing" rather than "puzzled".
            let spots: [CGPoint] = [CGPoint(x: -0.4, y: 0.1), CGPoint(x: 0.4, y: 0.05),
                                    CGPoint(x: 0.2, y: -0.15), CGPoint(x: -0.25, y: -0.1),
                                    CGPoint(x: 0.0, y: 0.12)]
            var i = 0
            while !Task.isCancelled {
                guard let self else { break }
                self.targetGaze = spots[i % spots.count]
                self.targetTilt = (i % 2 == 0) ? 0.04 : -0.03   // gentle busy head-bob
                i += 1
                try? await Task.sleep(nanoseconds: UInt64(Double.random(in: 0.6...0.95) * 1_000_000_000))
            }
        }
    }

    /// Stop the working animation, recenter, and re-arm the normal idle timer so
    /// Ba-Chan can doze again once the brain is ready.
    func endWorking() {
        guard isWorking else { return }
        isWorking = false
        workTask?.cancel(); workTask = nil
        targetTilt = 0
        targetGaze = .zero
        expression = .neutral
        restartIdleTimer()         // resume normal idle/sleep now that it is loaded
    }

    // MARK: - Touch reactions

    /// React to a touch on a part of the face. `moving` = the finger is stroking
    /// (petting) rather than poking.
    func touch(_ region: FaceRegion, moving: Bool) {
        // A touch always wakes Ba-Chan *gently* — never straight to angry.
        if pastime != .none { wake(startled: false); return }   // a touch ends any pastime gently

        revertTask?.cancel()
        restartIdleTimer()

        switch region {
        case .leftEye, .rightEye:
            // Poking the eyes is uncomfortable — it builds annoyance and Ba-Chan
            // squints shut, tipping from puzzled into angry if you keep going.
            eyeAnnoyance = min(1, eyeAnnoyance + (moving ? 0.03 : 0.09))
            expression = eyeAnnoyance > 0.5 ? .angry : .doubt
            targetSqueeze = 0.9
            targetTilt = 0
        case .mouth:
            expression = .doubt        // puzzled "mmf"
            targetSqueeze = 0
            targetMouth = 0.45
        case .head:
            expression = .happy        // head pat = content
            targetSqueeze = 0.3
        case .leftCheek:
            expression = .happy        // leans into a cheek touch and beams
            targetSqueeze = 0.25
            targetTilt = 0.16
        case .rightCheek:
            expression = .happy
            targetSqueeze = 0.25
            targetTilt = -0.16
        case .face:
            expression = .happy
            targetSqueeze = 0.15
        }

        emitTouchHaptic(region: region)
    }

    /// Finger lifted — relax back to a resting face after a beat.
    func releaseTouch() {
        targetSqueeze = 0
        targetTilt = 0
        targetMouth = 0
        lastTouchRegion = nil
        wasAngryFromPoke = false
        scheduleRevertToNeutral(after: 1.4)
    }

    /// Haptics + particles tuned per region: an uncomfortable buzz + anger marks
    /// for eye-pokes, a warm soft pulse + hearts for petting, a sweat-drop for the
    /// mouth poke.
    private func emitTouchHaptic(region: FaceRegion) {
        let now = CACurrentMediaTime()
        let newRegion = region != lastTouchRegion
        lastTouchRegion = region

        switch region {
        case .leftEye, .rightEye:
            if now - lastPokeHaptic > 0.16 {
                lastPokeHaptic = now
                Haptics.impact(expression == .angry ? .rigid : .medium,
                               intensity: expression == .angry ? 1.0 : 0.7)
            }
            if expression == .angry && !wasAngryFromPoke {
                wasAngryFromPoke = true
                Haptics.notify(.error)   // a sharp "stop that!"
                onEffect?(.anger)
            }
        case .head, .leftCheek, .rightCheek, .face:
            if newRegion || now - lastPetHaptic > 0.3 {
                lastPetHaptic = now
                Haptics.impact(.soft, intensity: 0.6)
            }
            if now - lastHeartEffect > 0.5 { lastHeartEffect = now; onEffect?(.hearts) }
        case .mouth:
            if newRegion { Haptics.impact(.light); onEffect?(.sweat) }
        }
    }

    // MARK: - Eye contact & device motion

    /// Lock the gaze onto the user's detected face (eye contact). Ignored while
    /// asleep so it doesn't fight the sleeping pose.
    func lookAtUser(_ point: CGPoint) {
        guard !isAsleep else { return }
        if pastime != .none { endPastime() }   // looks up from the book when it sees you
        gazeOverridden = true
        targetGaze = CGPoint(x: max(-0.85, min(0.85, point.x)),
                             y: max(-0.6, min(0.6, point.y)))
        restartIdleTimer()                  // engaged with you → don't doze off
    }

    func clearGazeOverride() { gazeOverridden = false }

    /// Glance toward the mouse pointer (macOS). Lower priority than everything
    /// expressive: eye contact, thinking, working, and sleep all win — so the
    /// cursor never drags the eyes out of a pondering glance or a doze.
    func followPointer(_ point: CGPoint) {
        guard pastime == .none, !gazeOverridden, !isThinking, !isWorking else { return }
        pointerGazeActive = true
        targetGaze = CGPoint(x: max(-0.85, min(0.85, point.x)),
                             y: max(-0.6, min(0.6, point.y)))
    }

    /// The pointer went still — release the eyes back to the idle wander.
    func stopFollowingPointer() {
        guard pointerGazeActive else { return }
        pointerGazeActive = false
        targetGaze = .zero
    }

    /// A minimal lean toward level as the phone is rolled — just a subtle hint of
    /// gravity, not full horizon-leveling. `radians` is the device roll; we take a
    /// small fraction of it (countering the roll) and clamp it tight so the face
    /// barely moves.
    func setGravityTilt(_ radians: CGFloat) {
        targetGravityTilt = max(-0.07, min(0.07, -radians * 0.2))
    }

    /// A shake jostles Ba-Chan — startled if asleep, otherwise a quick "whoa!".
    func jostle() {
        if isAsleep { wake(startled: true); return }
        revertTask?.cancel()
        restartIdleTimer()
        expression = .surprised
        targetMouth = 0.45
        Haptics.impact(.heavy)
        onEffect?(.sparkle)
        scheduleRevertToNeutral(after: 1.2)
    }

    /// Picking the phone up gently rouses Ba-Chan if it was dozing.
    func perkUp() {
        if isAsleep { wake(startled: false) } else { restartIdleTimer() }
    }

    /// Laying the phone face-down puts Ba-Chan to sleep.
    func restForFaceDown() {
        guard !isAsleep else { return }
        fallAsleep()
    }

    /// Settle into a time-appropriate pastime — used by the idle timer and by the
    /// macOS system-activity monitor when you step away from the Mac. Nap hours
    /// (night 9pm–6am, the early-afternoon lull 1–3pm) bring a doze; the rest of
    /// the day Ba-Chan picks something up: a book, tea, a hum, the cooking pot.
    /// Honors the same guards as sleep (never mid-think/-load).
    func settleIntoPastime(hour: Int = Calendar.current.component(.hour, from: Date())) {
        guard !isThinking, !isWorking, pastime == .none else { return }
        // Night guarantees a doze. The early-afternoon lull only *leans* toward
        // one — it used to force it, which meant two daytime hours where the
        // awake pastimes could never appear. A small off-schedule doze chance
        // the rest of the day keeps it human.
        let napChance: Double
        if hour >= 21 || hour < 6 { napChance = 1.0 }
        else if (13...14).contains(hour) { napChance = 0.4 }
        else { napChance = 0.15 }
        if Double.random(in: 0...1) < napChance {
            fallAsleep()
        } else {
            begin([.reading, .tea, .humming, .cooking].randomElement()!)
        }
    }

    /// Start one of the awake pastimes: set the face, run its gaze/motion loop,
    /// and schedule a drift to something else after a few minutes.
    private func begin(_ activity: Pastime) {
        pastime = activity
        revertTask?.cancel()
        pastimeTask?.cancel()
        targetMouth = 0

        switch activity {
        case .reading:
            expression = .neutral
            pastimeTask = Task { [weak self] in
                // Eyes lowered, scanning lines left to right, an occasional pause.
                while !Task.isCancelled {
                    guard let self else { return }
                    for x in stride(from: -0.45, through: 0.45, by: 0.18) {
                        guard !Task.isCancelled else { return }
                        self.targetGaze = CGPoint(x: x, y: 0.55)
                        try? await Task.sleep(nanoseconds: UInt64.random(in: 350_000_000...650_000_000))
                    }
                }
            }
        case .tea:
            expression = .peaceful
            targetGaze = CGPoint(x: 0.18, y: 0.35)
            pastimeTask = Task { [weak self] in
                // Every little while, a slow sip: eyes close, head tips, and back.
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: UInt64.random(in: 3_000_000_000...6_500_000_000))
                    guard let self, !Task.isCancelled else { return }
                    self.targetSqueeze = 0.85
                    self.targetTilt = 0.06
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    guard !Task.isCancelled else { return }
                    self.targetSqueeze = 0
                    self.targetTilt = 0
                }
            }
        case .humming:
            expression = .peaceful
            targetGaze = CGPoint(x: 0, y: -0.15)
            pastimeTask = Task { [weak self] in
                // A gentle metronome sway while the notes drift by.
                var beat = false
                while !Task.isCancelled {
                    guard let self else { return }
                    self.targetTilt = beat ? 0.06 : -0.06
                    beat.toggle()
                    try? await Task.sleep(nanoseconds: 900_000_000)
                }
            }
        case .cooking:
            expression = .neutral
            pastimeTask = Task { [weak self] in
                // Watching the pot, with a little stir now and then.
                while !Task.isCancelled {
                    guard let self else { return }
                    self.targetGaze = CGPoint(x: .random(in: -0.2...0.2), y: 0.5)
                    try? await Task.sleep(nanoseconds: UInt64.random(in: 1_200_000_000...2_400_000_000))
                    guard !Task.isCancelled else { return }
                    self.targetTilt = 0.04
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    self.targetTilt = -0.03
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    self.targetTilt = 0
                }
            }
        case .sleeping, .none:
            return
        }

        // Drift to another pastime (or a nap, if the hour has turned) after a while.
        rotationTask?.cancel()
        rotationTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64.random(in: 90_000_000_000...210_000_000_000))
            guard let self, !Task.isCancelled, self.pastime == activity else { return }
            self.endPastime()
            self.settleIntoPastime()
        }
    }

    /// Stop whatever Ba-Chan settled into and return to a neutral, present face.
    private func endPastime() {
        guard pastime != .none else { return }
        pastimeTask?.cancel(); pastimeTask = nil
        rotationTask?.cancel(); rotationTask = nil
        pastime = .none
        targetGaze = .zero
        targetTilt = 0
        targetSqueeze = 0
        expression = .neutral
    }

    private func scheduleRevertToNeutral(after seconds: Double) {
        revertTask?.cancel()
        revertTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.expression = .neutral
        }
    }

    // MARK: - Sleep & waking

    /// Ba-Chan settles into a pastime after `idleSleepDelay` with no interaction.
    private func restartIdleTimer() {
        idleTask?.cancel()
        guard autoIdleSleep else { idleTask = nil; return }
        idleTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(self.idleSleepDelay * 1_000_000_000))
            guard !Task.isCancelled, self.pastime == .none else { return }
            self.settleIntoPastime()
        }
    }

    private func fallAsleep() {
        // Never doze off mid-thought or while loading the brain. Generation (esp.
        // first inference) and a multi-GB download both run far longer than the
        // idle delay; this single chokepoint covers every sleep route — the idle
        // timer, a shake/pickup that re-arms it, and the face-down direct call.
        // The doze clock restarts when stopThinking()/endWorking() runs.
        guard !isThinking, !isWorking else { return }
        pastimeTask?.cancel(); pastimeTask = nil
        rotationTask?.cancel(); rotationTask = nil
        pastime = .sleeping
        expression = .sleepy
        targetSqueeze = 0.94       // eyes closed
        targetTilt = 0.06          // head droops
        targetMouth = 0
        revertTask?.cancel()
    }

    /// Wake Ba-Chan. A **startled** wake (loud) jolts it into shock then anger; a
    /// gentle wake (touch / soft voice) just opens its eyes calmly.
    func wake(startled: Bool) {
        let wasAsleep = isAsleep
        endPastime()             // ends a doze or any awake pastime
        restartIdleTimer()
        guard wasAsleep else { return }   // waking from a book/tea needs no startle theater

        if startled {
            expression = .surprised
            targetMouth = 0.5          // mouth pops open
            targetTilt = 0.12
            Haptics.notify(.error)
            onEffect?(.sparkle)
            startleTask?.cancel()
            startleTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 480_000_000)
                guard let self, !Task.isCancelled else { return }
                self.expression = .angry   // "don't scare me!"
                self.targetMouth = 0
                self.targetTilt = 0
                self.scheduleRevertToNeutral(after: 3.0)
            }
        } else {
            expression = .neutral
            Haptics.impact(.soft)
            scheduleRevertToNeutral(after: 2.5)
        }
    }

    // MARK: - Per-frame advance

    /// Ease every rendered value toward its target. Called once per frame from
    /// the Canvas with the timeline's timestamp. `dt` is clamped so a paused or
    /// backgrounded app can't produce a large jump on resume; if the same
    /// timestamp arrives twice (Canvas may draw more than once per frame) `dt`
    /// is 0 and this is a no-op.
    func advance(to now: TimeInterval) {
        let dt = min(0.05, max(0, now - (lastTick ?? now)))
        lastTick = now
        guard dt > 0 else { return }

        if intro < 1 { intro = min(1, intro + CGFloat(dt / introDuration)) }

        gaze.x = ease(gaze.x, targetGaze.x, tau: 0.13, dt: dt)
        gaze.y = ease(gaze.y, targetGaze.y, tau: 0.13, dt: dt)
        eyeOpen = ease(eyeOpen, targetEyeOpen, tau: 0.035, dt: dt)
        mouth   = ease(mouth, targetMouth, tau: 0.05, dt: dt)
        tilt    = ease(tilt, targetTilt, tau: 0.20, dt: dt)
        gravityTilt = ease(gravityTilt, targetGravityTilt, tau: 0.28, dt: dt)

        browAngle  = ease(browAngle, CGFloat(expression.browAngle), tau: 0.14, dt: dt)
        browRaise  = ease(browRaise, expression.browRaise, tau: 0.14, dt: dt)
        // The genome shifts where the mouth *rests* and gives the cheeks a faint
        // standing glow; expressions still move on top of both.
        mouthCurve = ease(mouthCurve,
                          min(max(expression.mouthCurve + genomeShown.mouthCurveBias, -1), 1),
                          tau: 0.16, dt: dt)
        eyeSquint  = ease(eyeSquint, expression.eyeSquint, tau: 0.16, dt: dt)
        blush      = ease(blush,
                          max(expression.showsBlush ? 1 : 0, genomeShown.blushBaseline),
                          tau: 0.20, dt: dt)
        squeeze    = ease(squeeze, targetSqueeze, tau: 0.07, dt: dt)

        // Genome traits ease very gently — a nightly nudge fades in unnoticed.
        for t in FaceGenome.Trait.allCases {
            genomeShown[keyPath: t.keyPath] = ease(genomeShown[keyPath: t.keyPath],
                                                   genome[keyPath: t.keyPath],
                                                   tau: 1.8, dt: dt)
        }
        // Accessory swaps crossfade: fade the worn prop out, swap, fade in.
        if accessoryShown != genome.accessory {
            accessoryAlpha = ease(accessoryAlpha, 0, tau: 0.8, dt: dt)
            if accessoryAlpha < 0.02 { accessoryShown = genome.accessory }
        } else {
            accessoryAlpha = ease(accessoryAlpha, accessoryShown == .none ? 0 : 1,
                                  tau: 0.8, dt: dt)
        }

        // Annoyance from eye-poking fades over a few seconds.
        eyeAnnoyance = max(0, eyeAnnoyance - CGFloat(dt) * 0.22)
    }

    /// Critically-damped exponential smoothing: frame-rate independent, and it
    /// always converges, so there is no abrupt settle at the end.
    private func ease(_ current: CGFloat, _ target: CGFloat, tau: Double, dt: Double) -> CGFloat {
        let k = 1 - exp(-dt / tau)
        return current + (target - current) * CGFloat(k)
    }

    // MARK: - Idle animation loops (set targets only)

    private func startBlinking() {
        blinkTask = Task { [weak self] in
            while !Task.isCancelled {
                let pause = Double.random(in: 2.0...5.5)
                try? await Task.sleep(nanoseconds: UInt64(pause * 1_000_000_000))
                guard let self, !Task.isCancelled else { break }
                await self.blinkOnce()
                // Occasional quick double-blink for character.
                if Double.random(in: 0...1) < 0.25 {
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    await self.blinkOnce()
                }
            }
        }
    }

    private func blinkOnce() async {
        targetEyeOpen = 0.04
        try? await Task.sleep(nanoseconds: 95_000_000)
        targetEyeOpen = 1
    }

    private func startGazing() {
        gazeTask = Task { [weak self] in
            while !Task.isCancelled {
                let pause = Double.random(in: 1.6...4.2)
                try? await Task.sleep(nanoseconds: UInt64(pause * 1_000_000_000))
                guard let self, !Task.isCancelled else { break }
                if gazeOverridden || pointerGazeActive || isThinking || isWorking
                    || pastime != .none { continue }   // eye contact / pointer / thinking / loading / a pastime steer the gaze
                targetGaze = CGPoint(x: .random(in: -0.6...0.6), y: .random(in: -0.4...0.45))
                // Drift back toward center after a beat.
                try? await Task.sleep(nanoseconds: 700_000_000)
                guard !Task.isCancelled else { break }
                if Bool.random() { targetGaze = CGPoint(x: targetGaze.x * 0.2, y: 0) }
            }
        }
    }
}
