import Speech
import AVFoundation

/// Wraps `SFSpeechRecognizer` for on-device speech-to-text. Captures mic audio
/// with an `AVAudioEngine`, streams it to the recognizer, and reports partial
/// transcripts as you talk plus a final transcript when capture ends.
@MainActor
final class SpeechRecognizer {
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var didFinish = false

    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?
    var onLevel: ((Float) -> Void)?

    var isAvailable: Bool { recognizer?.isAvailable ?? false }

    /// Ask for mic + speech permission. Returns true only if both are granted.
    func authorize() async -> Bool {
        let speech = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0 == .authorized) }
        }
        #if os(iOS)
        // iOS mic consent goes through AVAudioApplication (part of the AVAudioSession
        // family, which doesn't exist on macOS).
        let mic = await withCheckedContinuation { cont in
            AVAudioApplication.requestRecordPermission { cont.resume(returning: $0) }
        }
        #else
        // On macOS, mic access is governed by AVCaptureDevice authorization for audio.
        let mic = await AVCaptureDevice.requestAccess(for: .audio)
        #endif
        return speech && mic
    }

    func start() throws {
        cancel()
        didFinish = false

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // Do NOT force on-device recognition: if the offline speech assets for the
        // locale aren't installed, forcing it makes the task error out immediately
        // and return nothing (the loop then silently re-listens — "no response").
        // Let the system use on-device when ready and fall back otherwise.
        request.requiresOnDeviceRecognition = false
        self.request = request

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.request?.append(buffer)
            let level = AudioMath.rms(buffer)
            Task { @MainActor [weak self] in self?.onLevel?(level) }
        }
        engine.prepare()
        try engine.start()

        task = recognizer?.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let result {
                    let text = result.bestTranscription.formattedString
                    if result.isFinal {
                        self.deliverFinal(text)
                    } else {
                        self.onPartial?(text)
                    }
                }
                if error != nil {
                    self.deliverFinal(result?.bestTranscription.formattedString ?? "")
                }
            }
        }
    }

    /// Stop capturing audio; the recognizer flushes a final transcript.
    func finish() {
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        request?.endAudio()
    }

    /// Hard stop with no final result (e.g. user cancelled).
    func cancel() {
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        task?.cancel()
        task = nil
        request = nil
    }

    private func deliverFinal(_ text: String) {
        guard !didFinish else { return }   // isFinal + completion can both fire
        didFinish = true
        cancel()
        onFinal?(text)
    }
}
