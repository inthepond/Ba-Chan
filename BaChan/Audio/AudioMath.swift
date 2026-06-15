import AVFoundation

enum AudioMath {
    /// Root-mean-square amplitude of a PCM buffer's first channel, ~0…1.
    /// Used both for lip-sync (TTS output) and a mic level indicator.
    static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.floatChannelData else { return 0 }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }
        let samples = channels[0]
        var sum: Float = 0
        for i in 0..<frames {
            let s = samples[i]
            sum += s * s
        }
        return (sum / Float(frames)).squareRoot()
    }
}
