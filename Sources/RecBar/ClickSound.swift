import AVFoundation

/// Plays a short synthesized UI click — an exponentially-decaying sine burst — so we don't
/// need to bundle or license any external audio asset.
enum ClickSound {
    private static let engine = AVAudioEngine()
    private static let player = AVAudioPlayerNode()
    private static let buffer: AVAudioPCMBuffer = makeClickBuffer()
    private static var didStart = false

    static func play() {
        if !didStart {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: buffer.format)
            do {
                try engine.start()
                didStart = true
            } catch {
                NSLog("RecBar: failed to start audio engine for click sound: \(error)")
                return
            }
        }
        player.scheduleBuffer(buffer, at: nil, options: .interrupts)
        if !player.isPlaying { player.play() }
    }

    private static func makeClickBuffer() -> AVAudioPCMBuffer {
        let sampleRate = 44_100.0
        let duration = 0.035
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount

        let channel = buffer.floatChannelData![0]
        let frequency = 1800.0
        for frame in 0..<Int(frameCount) {
            let t = Double(frame) / sampleRate
            let envelope = exp(-t * 90.0)
            channel[frame] = Float(sin(2.0 * .pi * frequency * t) * envelope * 0.35)
        }
        return buffer
    }
}
