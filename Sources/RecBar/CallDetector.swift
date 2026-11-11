import CoreAudio

/// Notices when a call app (Chrome for Google Meet, WhatsApp, …) starts using the microphone,
/// so RecBar can suggest starting a recording. Uses CoreAudio's per-process objects (macOS 14+),
/// the same information behind the system's orange mic dot. It reacts only to apps on the
/// configured allowlist, never to "any process holding the mic": OBS itself, dictation tools,
/// etc. would otherwise trigger it constantly.
///
/// Polls once a second (a few property reads over ~30 process objects, negligible cost) rather
/// than registering per-process CoreAudio listeners — same simple-timer idiom as the rest of
/// the app. A short debounce on both edges keeps a one-tick enumeration blip from flickering
/// the result.
@MainActor
final class CallDetector {
    /// Called with the display name of the call app holding the mic, or nil once none is.
    var onChange: ((String?) -> Void)?
    private(set) var activeAppName: String?

    private let apps: [CallApp]
    private var timer: Timer?
    private var candidate: (name: String?, since: Date)?

    /// How long a call app must hold the mic before it counts as a call: 1 minute (user
    /// request, 2026-11-11 — was 2s), so short WhatsApp voice messages don't trigger it.
    private let startDebounce: TimeInterval = 60
    /// So a Meet mute or a device switch doesn't end the "call".
    private let endDebounce: TimeInterval = 5

    init(apps: [CallApp]) {
        self.apps = apps
    }

    func start() {
        guard timer == nil, !apps.isEmpty else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        poll()
    }

    private func poll() {
        let observed = Self.callAppCapturingInput(apps)
        guard observed != activeAppName else {
            candidate = nil
            return
        }
        let now = Date()
        if candidate?.name != observed {
            candidate = (observed, now)
        }
        let debounce = observed == nil ? endDebounce : startDebounce
        guard let since = candidate?.since, now.timeIntervalSince(since) >= debounce else { return }
        candidate = nil
        activeAppName = observed
        onChange?(observed)
    }

    /// Display name of the first allowlisted app currently capturing audio input, if any.
    /// Matches by bundle-ID prefix so helper processes count too — Chrome captures audio in
    /// `com.google.Chrome.helper`, not the main `com.google.Chrome` process.
    static func callAppCapturingInput(_ apps: [CallApp]) -> String? {
        for process in processObjects() where isRunningInput(process) {
            guard let bundleID = bundleID(of: process),
                  let app = apps.first(where: { bundleID.hasPrefix($0.bundleIDPrefix) }) else { continue }
            return app.name
        }
        return nil
    }

    // MARK: - CoreAudio process objects

    private static func processObjects() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func isRunningInput(_ process: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningInput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(process, &address, 0, nil, &size, &value) == noErr && value != 0
    }

    private static func bundleID(of process: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(process, &address, 0, nil, &size, &value) == noErr,
              let string = value?.takeRetainedValue() else { return nil }
        return string as String
    }
}
