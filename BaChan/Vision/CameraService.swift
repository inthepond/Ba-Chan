import AVFoundation
import CoreImage
import CoreGraphics
import QuartzCore
import Vision

/// Manages the device cameras and grabs a single still frame **on demand**
/// (no continuous streaming — battery-friendly, matches the "look when asked"
/// design). Supports flipping between the back and front cameras.
///
/// On the Simulator there are no capture devices, so `authorized` may be true
/// but `start()` finds no camera and `captureFrame()` returns nil — callers
/// handle that gracefully.
final class CameraService: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    @Published private(set) var authorized = false
    @Published private(set) var isRunning = false
    #if os(macOS)
    // Macs have one user-facing camera; treat it like a front camera so the feed is
    // mirrored (selfie behaviour), which is what you want for a companion looking back.
    @Published private(set) var position: AVCaptureDevice.Position = .front
    #else
    @Published private(set) var position: AVCaptureDevice.Position = .back
    #endif
    /// A continuously-updated, tiny, blurred-able snapshot of the live feed, used
    /// to drive a real-time light reflection on the goggles. Low-res (cheap).
    @Published private(set) var reflection: CGImage?
    /// Where the user's face is, as a gaze target (-1…1 each axis), or nil if no
    /// face is visible. Drives Ba-Chan's eye contact.
    @Published private(set) var facePosition: CGPoint?

    let session = AVCaptureSession()

    private let queue = DispatchQueue(label: "stackchan.camera.session")
    private let output = AVCaptureVideoDataOutput()
    private var input: AVCaptureDeviceInput?
    private let ciContext = CIContext()

    /// A pending one-shot frame request, fulfilled by the next sample buffer.
    private var pendingFrame: ((CGImage?) -> Void)?
    private let lock = NSLock()
    private var lastReflectionTime: CFTimeInterval = 0
    private var lastFaceTime: CFTimeInterval = 0

    // MARK: - Lifecycle

    /// Request permission (if needed) and start the session. Returns whether a
    /// camera is actually running — computed ON the session queue right after
    /// configuring. (Returning the published `isRunning` raced its main-thread
    /// update and reported false on the first press, so the Look toggle needed
    /// a second press to read as on.)
    @discardableResult
    func start() async -> Bool {
        guard await requestAccess() else { return false }
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            queue.async { [weak self] in
                guard let self else { cont.resume(returning: false); return }
                self.configure(position: self.currentDesiredPosition)
                cont.resume(returning: self.session.isRunning && self.input != nil)
            }
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning { self.session.stopRunning() }
            // Remove the input so the camera is fully released (privacy LED off),
            // not just paused. Always publish isRunning = false.
            self.session.beginConfiguration()
            if let input = self.input { self.session.removeInput(input); self.input = nil }
            self.session.commitConfiguration()
            DispatchQueue.main.async { self.isRunning = false; self.reflection = nil; self.facePosition = nil }
        }
    }

    func flip() {
        #if os(macOS)
        // Macs have a single user-facing camera — nothing to flip. (Continuity /
        // external cameras are picked automatically by `device(for:)`.)
        return
        #else
        let next: AVCaptureDevice.Position = position == .back ? .front : .back
        position = next                       // published on main (UI thread)
        queue.async { [weak self] in self?.configure(position: next) }
        #endif
    }

    private var currentDesiredPosition: AVCaptureDevice.Position { position }

    // MARK: - On-demand capture

    /// Grab the next available frame as a `CGImage`, oriented upright.
    func captureFrame() async -> CGImage? {
        guard isRunning else { return nil }
        return await withCheckedContinuation { cont in
            lock.lock()
            pendingFrame = { cont.resume(returning: $0) }
            lock.unlock()
        }
    }

    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // Publish a tiny snapshot ~18×/sec to drive the live goggle reflection.
        let now = CACurrentMediaTime()
        if now - lastReflectionTime > 0.055 {
            lastReflectionTime = now
            if let small = downscaledCGImage(pixelBuffer, targetWidth: 90) {
                DispatchQueue.main.async { self.reflection = small }
            }
        }

        // Detect the user's face ~8×/sec for eye contact.
        if now - lastFaceTime > 0.12 {
            lastFaceTime = now
            detectFace(pixelBuffer)
        }

        // One-shot full-res frame, only when something asked for it.
        lock.lock()
        let request = pendingFrame
        pendingFrame = nil
        lock.unlock()
        guard let request else { return }

        var ci = CIImage(cvPixelBuffer: pixelBuffer)
        if position == .front { ci = mirrored(ci) }
        request(ciContext.createCGImage(ci, from: ci.extent))
    }

    private func mirrored(_ ci: CIImage) -> CIImage {
        ci.transformed(by: CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: -ci.extent.width, y: 0))
    }

    /// Find the largest face and publish its center as a gaze target (or nil).
    private func detectFace(_ pixelBuffer: CVPixelBuffer) {
        guard let image = downscaledCGImage(pixelBuffer, targetWidth: 240) else { return }
        let request = VNDetectFaceRectanglesRequest()
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])

        guard let face = (request.results ?? []).max(by: { $0.boundingBox.width < $1.boundingBox.width }) else {
            DispatchQueue.main.async { self.facePosition = nil }
            return
        }
        // Vision boundingBox: normalized, origin bottom-left. Map face center to a
        // gaze (-1…1), flipping Y to screen space, with a little extra range.
        let box = face.boundingBox
        let gx = Float((box.midX - 0.5) * 2.0 * 1.2)
        let gy = Float((0.5 - box.midY) * 2.0 * 1.0)
        let point = CGPoint(x: CGFloat(max(-1, min(1, gx))), y: CGFloat(max(-1, min(1, gy))))
        DispatchQueue.main.async { self.facePosition = point }
    }

    /// Cheap downscale of the live frame for the reflection (front-mirrored too).
    private func downscaledCGImage(_ pixelBuffer: CVPixelBuffer, targetWidth: CGFloat) -> CGImage? {
        var ci = CIImage(cvPixelBuffer: pixelBuffer)
        let scale = targetWidth / max(1, ci.extent.width)
        ci = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        if position == .front { ci = mirrored(ci) }
        return ciContext.createCGImage(ci, from: ci.extent)
    }

    // MARK: - Setup

    private func requestAccess() async -> Bool {
        let granted: Bool
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: granted = true
        case .notDetermined: granted = await AVCaptureDevice.requestAccess(for: .video)
        default: granted = false
        }
        await MainActor.run { self.authorized = granted }
        return granted
    }

    /// (Re)configure the session for the requested camera. Runs on `queue`.
    private func configure(position: AVCaptureDevice.Position) {
        session.beginConfiguration()
        session.sessionPreset = .high

        if let input { session.removeInput(input); self.input = nil }
        if let device = Self.device(for: position),
           let newInput = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(newInput) {
            session.addInput(newInput)
            input = newInput
        }

        if !session.outputs.contains(output) {
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: queue)
            if session.canAddOutput(output) { session.addOutput(output) }
        }
        session.commitConfiguration()

        let hasCamera = input != nil
        if hasCamera, !session.isRunning { session.startRunning() }
        DispatchQueue.main.async { self.isRunning = self.session.isRunning && hasCamera }
    }

    private static func device(for position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        #if os(macOS)
        // Macs have no `.back` camera, and the built-in / Continuity / external
        // cameras report position `.unspecified` — query by device type instead.
        // Prefer the Mac's own built-in (FaceTime) camera explicitly: discovery can
        // list an iPhone Continuity Camera or another external camera first, and
        // "front" on a Mac means the camera above the screen, looking at the user.
        let types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .external, .continuityCamera]
        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: types, mediaType: .video, position: .unspecified
        ).devices
        return devices.first { $0.deviceType == .builtInWideAngleCamera }
            ?? devices.first { $0.deviceType == .external }
            ?? devices.first
        #else
        return AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera],
            mediaType: .video,
            position: position
        ).devices.first
        #endif
    }
}
