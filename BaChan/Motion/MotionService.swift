#if os(iOS)
import CoreMotion
import QuartzCore

/// Reads device motion and turns it into Ba-Chan reactions: a shake jostles it,
/// laying the phone face-down sends it to sleep, picking it up rouses it, and
/// tilting the phone tilts its head with gravity. Device-only (no-ops where
/// device motion is unavailable, e.g. the Simulator).
@MainActor
final class MotionService {
    private let manager = CMMotionManager()

    var onShake: (() -> Void)?
    var onPickup: (() -> Void)?
    var onFaceDown: ((Bool) -> Void)?
    var onTilt: ((CGFloat) -> Void)?     // gravity-derived head-tilt, radians

    private var lastShake: CFTimeInterval = 0
    private var lastMagnitude = 0.0
    private var wasFaceDown = false

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 30.0
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let m = motion else { return }
            self.handle(m)
        }
    }

    func stop() { manager.stopDeviceMotionUpdates() }

    private func handle(_ m: CMDeviceMotion) {
        let now = CACurrentMediaTime()

        // Shake: a spike in user acceleration.
        let a = m.userAcceleration
        let mag = (a.x * a.x + a.y * a.y + a.z * a.z).squareRoot()
        if mag > 1.7 && now - lastShake > 0.6 {
            lastShake = now
            onShake?()
        }
        // Pickup: a rise from near-rest to moving (not a full shake).
        if mag > 0.55 && lastMagnitude < 0.22 && now - lastShake > 0.4 {
            onPickup?()
        }
        lastMagnitude = mag

        // How far the phone is rolled left/right from upright (radians). The face
        // uses this to counter-rotate and stay level with the horizon.
        onTilt?(CGFloat(atan2(m.gravity.x, -m.gravity.y)))

        // Face-down: screen pointing at the table.
        let down = m.gravity.z > 0.82
        if down != wasFaceDown {
            wasFaceDown = down
            onFaceDown?(down)
        }
    }
}

#else
import CoreGraphics

/// macOS stub: Macs have no device-motion sensors (CoreMotion's `CMMotionManager`
/// is unavailable on macOS), so shake / pickup / face-down / tilt simply never fire.
/// Identical public surface to the iOS version so the Conductor wiring is unchanged.
@MainActor
final class MotionService {
    var onShake: (() -> Void)?
    var onPickup: (() -> Void)?
    var onFaceDown: ((Bool) -> Void)?
    var onTilt: ((CGFloat) -> Void)?

    func start() {}
    func stop() {}
}
#endif
