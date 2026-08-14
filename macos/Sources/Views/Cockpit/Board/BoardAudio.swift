import AVFoundation

/// Synthesized detent/book/remove/wall sounds — a native port of
/// web/src/board/audio.ts's `sfx()`. No external asset (licensing + offline
/// safety, same rule as the web), fails silent whenever AVFoundation is
/// unavailable or the engine can't start, lazy engine init (no cost paid
/// until the first tick), and every entry point hops to the main thread
/// before touching `AVAudioEngine` (it is not thread-safe).
///
/// APPROXIMATION, documented per the brief: the web chain is
/// oscillator -> biquad bandpass (Q=1.2, centered on the tone's own
/// frequency) -> linear gain ramped exponentially to ~0.0001 by `dur`.
/// AVAudioEngine has no stock "bandpass-filtered oscillator" node, and
/// wiring an `AVAudioUnitEQ` band per one-shot click wasn't worth the
/// complexity for a <=60ms UI tick — instead each tone is a hand-synthesized
/// PCM buffer (square/triangle wave) shaped by a pure exponential amplitude
/// envelope. The envelope alone carries the "percussive click" character;
/// the bandpass's timbral narrowing is NOT reproduced. Audibly close, not
/// bit-identical — acceptable for a UI tick, called out here so it's never
/// mistaken for a literal port.
final class BoardAudio: BoardTicker {
    static let shared = BoardAudio()

    private var engine: AVAudioEngine?
    private let sampleRate: Double = 44100

    private enum Waveform {
        case square, triangle

        /// One period normalized to [-1, 1], `phase` in cycles (not radians).
        func sample(phase: Double) -> Double {
            let frac = phase - phase.rounded(.down)
            switch self {
            case .square:
                return frac < 0.5 ? 1.0 : -1.0
            case .triangle:
                return 4 * abs(frac - 0.5) - 1.0
            }
        }
    }

    private func ensureEngine() -> AVAudioEngine? {
        if let engine, engine.isRunning { return engine }
        let e = AVAudioEngine()
        do {
            try e.start()
        } catch {
            return nil
        }
        engine = e
        return e
    }

    /// Renders `duration` seconds of `waveform` at `freq`, peak-scaled by
    /// `gain`, under an `exp(-6 * t / duration)` envelope (~0.25% of peak
    /// remaining at `t == duration`, reading as a full decay to silence —
    /// the web's own ramp target, 0.0001, is likewise "effectively zero"
    /// rather than exact digital silence), then plays it once through a
    /// throwaway `AVAudioPlayerNode` that detaches itself on completion.
    private func play(freq: Double, duration: Double, gain: Double, waveform: Waveform) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.play(freq: freq, duration: duration, gain: gain, waveform: waveform)
            }
            return
        }
        guard let engine = ensureEngine() else { return }
        let frameCount = AVAudioFrameCount(duration * sampleRate) + 1
        guard
            let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
            let data = buffer.floatChannelData?[0]
        else { return }
        buffer.frameLength = frameCount

        for frame in 0..<Int(frameCount) {
            let t = Double(frame) / sampleRate
            let osc = waveform.sample(phase: t * freq)
            let envelope = exp(-6.0 * t / duration)
            data[frame] = Float(osc * gain * envelope)
        }

        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        player.scheduleBuffer(buffer, at: nil, options: []) { [weak self, weak engine, weak player] in
            DispatchQueue.main.async {
                guard let engine, let player else { return }
                self?.detach(player, from: engine)
            }
        }
        player.play()
    }

    private func detach(_ player: AVAudioPlayerNode, from engine: AVAudioEngine) {
        player.stop()
        engine.disconnectNodeOutput(player)
        engine.detach(player)
    }

    // MARK: - BoardTicker (web/src/board/audio.ts's four exports)

    func tickDetent() {
        play(freq: 2400, duration: 0.016, gain: 0.07, waveform: .square)
    }

    func tickBook() {
        play(freq: 1400, duration: 0.03, gain: 0.1, waveform: .square)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.045) { [weak self] in
            self?.play(freq: 2000, duration: 0.025, gain: 0.08, waveform: .square)
        }
    }

    func tickRemove() {
        play(freq: 420, duration: 0.06, gain: 0.12, waveform: .triangle)
    }

    func tickWall() {
        play(freq: 240, duration: 0.05, gain: 0.1, waveform: .triangle)
    }
}
