import AVFoundation

/// Plays a synthesized two-tone alert chime for the silence watchdog's "Are you there?"
/// prompt — deliberately louder and more distinct than `ClickSound`'s UI click, and played
/// directly through this process's own `AVAudioEngine` rather than routed through
/// `UNUserNotificationCenter`'s `content.sound`, so it's audible even when notification
/// permission was never granted or the system notification banner doesn't show for some
/// other reason (see AppState.tickWatchdog / CLAUDE.md's "Silence / presence watchdog").
enum AlertSound {
    private static let engine = AVAudioEngine()
    private static let player = AVAudioPlayerNode()
    private static let buffer: AVAudioPCMBuffer = makeChimeBuffer()
    private static var didStart = false

    static func play() {
        if !didStart {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: buffer.format)
            do {
                try engine.start()
                didStart = true
            } catch {
                NSLog("RecBar: failed to start audio engine for watchdog alert sound: \(error)")
                return
            }
        }
        player.scheduleBuffer(buffer, at: nil, options: .interrupts)
        if !player.isPlaying { player.play() }
    }

    /// Two ascending beeps rather than one, so it reads as "alert" rather than a UI click.
    private static func makeChimeBuffer() -> AVAudioPCMBuffer {
        let sampleRate = 44_100.0
        let toneDuration = 0.14
        let gapDuration = 0.06
        let totalDuration = toneDuration * 2 + gapDuration
        let frameCount = AVAudioFrameCount(sampleRate * totalDuration)
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount

        let channel = buffer.floatChannelData![0]
        let toneFrames = Int(sampleRate * toneDuration)
        let gapFrames = Int(sampleRate * gapDuration)
        let frequencies = [880.0, 1320.0]

        for frame in 0..<Int(frameCount) {
            var sample: Float = 0
            if frame < toneFrames {
                sample = tone(frequency: frequencies[0], frame: frame, sampleRate: sampleRate, toneFrames: toneFrames)
            } else if frame >= toneFrames + gapFrames {
                let f = frame - toneFrames - gapFrames
                sample = tone(frequency: frequencies[1], frame: f, sampleRate: sampleRate, toneFrames: toneFrames)
            }
            channel[frame] = sample
        }
        return buffer
    }

    private static func tone(frequency: Double, frame: Int, sampleRate: Double, toneFrames: Int) -> Float {
        let t = Double(frame) / sampleRate
        // Fade the last ~15% of each tone in/out to avoid a click at the tone boundaries.
        let fadeFrames = max(1, toneFrames / 7)
        var envelope = 1.0
        if frame < fadeFrames {
            envelope = Double(frame) / Double(fadeFrames)
        } else if frame > toneFrames - fadeFrames {
            envelope = Double(toneFrames - frame) / Double(fadeFrames)
        }
        return Float(sin(2.0 * .pi * frequency * t) * envelope * 0.5)
    }
}
