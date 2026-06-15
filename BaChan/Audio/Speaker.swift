import AVFoundation

/// Speaks text with the system synthesizer **and** exposes a live amplitude
/// level so the avatar's mouth can lip-sync. The trick (same as Stackchan's
/// firmware): instead of letting `AVSpeechSynthesizer` play audio itself, we
/// render it to PCM buffers, play them through an `AVAudioEngine`, and tap the
/// mixer to measure loudness in real time.
@MainActor
final class Speaker {
    private let synth = AVSpeechSynthesizer()
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var connected = false
    private var pendingBuffers = 0
    private var streamEnded = false

    /// Called frequently while speaking with the current amplitude (0…1).
    var onLevel: ((Float) -> Void)?
    /// Called once when an utterance has finished playing.
    var onFinished: (() -> Void)?

    init() {
        engine.attach(player)
    }

    func speak(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { onFinished?(); return }

        streamEnded = false
        pendingBuffers = 0

        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.rate = 0.46
        utterance.pitchMultiplier = 1.22       // a little chipper
        utterance.preUtteranceDelay = 0
        utterance.postUtteranceDelay = 0
        if let voice = Self.preferredVoice() { utterance.voice = voice }

        // `write` streams synthesized PCM buffers on a background queue.
        synth.write(utterance) { [weak self] buffer in
            guard let pcm = buffer as? AVAudioPCMBuffer else { return }
            Task { @MainActor [weak self] in self?.handle(pcm) }
        }
    }

    func stop() {
        synth.stopSpeaking(at: .immediate)
        teardown()
        pendingBuffers = 0
        streamEnded = true
        onLevel?(0)
    }

    // MARK: - Buffer pipeline

    private func handle(_ pcm: AVAudioPCMBuffer) {
        // An empty buffer marks the end of the synthesized stream.
        if pcm.frameLength == 0 {
            streamEnded = true
            checkDone()
            return
        }
        if !connected { connect(format: pcm.format) }

        pendingBuffers += 1
        player.scheduleBuffer(pcm, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.pendingBuffers -= 1
                self.checkDone()
            }
        }
        if !player.isPlaying {
            try? engine.start()
            player.play()
        }
    }

    private func connect(format: AVAudioFormat) {
        engine.connect(player, to: engine.mainMixerNode, format: format)
        // Tap the mixer output to read loudness as it actually plays.
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            let level = AudioMath.rms(buffer)
            Task { @MainActor [weak self] in self?.onLevel?(level) }
        }
        engine.prepare()
        connected = true
    }

    private func checkDone() {
        guard streamEnded, pendingBuffers == 0 else { return }
        teardown()
        onLevel?(0)
        onFinished?()
    }

    private func teardown() {
        if connected {
            engine.mainMixerNode.removeTap(onBus: 0)
            connected = false
        }
        if player.isPlaying { player.stop() }
        if engine.isRunning { engine.stop() }
    }

    /// Prefer a higher-quality installed voice for the device locale.
    private static func preferredVoice() -> AVSpeechSynthesisVoice? {
        let voices = AVSpeechSynthesisVoice.speechVoices()
        let lang = AVSpeechSynthesisVoice.currentLanguageCode()
        let forLang = voices.filter { $0.language == lang }
        return forLang.first { $0.quality == .premium }
            ?? forLang.first { $0.quality == .enhanced }
            ?? forLang.first
    }
}
