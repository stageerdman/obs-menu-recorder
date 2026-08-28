import Foundation
import Combine

enum RecordingMode: String, CaseIterable, Identifiable {
    case sales
    case guide
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sales: return "Sales Call"
        case .guide: return "Guide"
        case .other: return "Other Call"
        }
    }

    var symbolName: String {
        switch self {
        case .sales: return "dollarsign.circle.fill"
        case .guide: return "video.fill"
        case .other: return "mic.fill"
        }
    }

    func config(_ config: RecBarConfig) -> ModeConfig {
        switch self {
        case .sales: return config.salesMode
        case .guide: return config.guideMode
        case .other: return config.otherMode
        }
    }
}

enum RecordingState: Equatable {
    case idle
    case recording
    case paused
}

struct ChannelLevel: Identifiable {
    var id: String { name }
    let name: String
    let peakLevel: Float // 0...1
}

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var recordingState: RecordingState = .idle
    @Published private(set) var connectionState: OBSClient.ConnectionState = .disconnected
    @Published private(set) var currentMode: RecordingMode?
    @Published private(set) var elapsed: TimeInterval = 0
    @Published var errorMessage: String?
    @Published var debugDrawerExpanded: Bool = false
    @Published private(set) var channelLevels: [ChannelLevel] = []
    @Published private(set) var resolvedMicDescription: String?
    @Published private(set) var isBusy = false
    /// Non-nil while the silence watchdog is waiting on a presence confirmation; the popover
    /// shows a countdown to this deadline, after which the recording auto-stops.
    @Published private(set) var watchdogPromptDeadline: Date?

    /// Not `let`: each `*Release` config's `lastKnown*` fields get updated (and persisted) in
    /// place every time `releaseInput(at:)` snapshots that source before removing it.
    private(set) var config: RecBarConfig
    private let obs: OBSClient
    private let obsLauncher = OBSLauncher()
    private let watchdogNotifier = WatchdogNotifier()
    private let watchdogOverlay = WatchdogOverlayWindow()

    private var recordStartDate: Date?
    private var pausedAccumulated: TimeInterval = 0
    private var pauseStartDate: Date?
    private var elapsedTimer: Timer?
    /// The OBS input name of the mic source actually live for the current recording (e.g.
    /// the USB or built-in mic source, whichever MicrophonePriority resolved to). Exposed
    /// read-only so the debug drawer can highlight this specific channel for threshold
    /// calibration.
    private(set) var resolvedMicSourceName: String?
    /// Every channel the watchdog treats as "presence" for the current recording — the
    /// resolved mic plus desktop audio for Sales/Other Call (Guide never has desktop audio
    /// live at all). Deliberately excludes the *other*, muted mic source: a muted source can
    /// still pick up ambient room noise even though it contributes nothing to the actual
    /// recording, which would mask real silence on the channels that matter. Set in
    /// `beginRecording`, cleared in `resetToIdle`.
    private(set) var watchdogChannelNames: Set<String> = []
    /// Last time any channel in `watchdogChannelNames` was at/above the watchdog threshold.
    /// Reset on recording start, on resume from pause, and on any presence confirmation.
    private var micLastAboveThresholdDate: Date?
    /// Non-nil after a presence confirmation ("I'm here") until either it's reached or a
    /// fresh burst of real activity pushes the ordinary silence deadline past it — see
    /// `confirmPresence()` and `tickWatchdog()`'s "later deadline wins" comparison.
    private var watchdogExtendedDeadline: Date?
    /// Last time `AlertSound` was played for the in-flight watchdog prompt — nil while no
    /// prompt is active. Repeating this (rather than a single chime at prompt start) is the
    /// main fix for the prompt being missed entirely: a `UNUserNotificationCenter` banner
    /// depends on notification permission having actually been granted (see WatchdogNotifier),
    /// which is easy to have silently never happened, and the inline popover banner only shows
    /// while the popover happens to be open — this alert sound needs neither.
    private var lastWatchdogAlertSoundDate: Date?
    /// How often `AlertSound` repeats while a watchdog prompt is unconfirmed.
    private let watchdogAlertRepeatInterval: TimeInterval = 8
    /// Tracks `goIdleInOBS()` whenever it's kicked off in the background (from `resetToIdle()`
    /// — stop/external-stop/connect-time sync), so `beginRecording()` can wait for it to
    /// actually finish before touching OBS itself. Without this, `resetToIdle()` returning
    /// immediately (it can't await from a sync context) let `isBusy` clear while idle cleanup
    /// was still mid-flight — cycling through every scene, up to 3 attempts per released
    /// input — so a mode button pressed right after a stop (or right after connecting) raced
    /// `SetCurrentProgramScene` calls against `beginRecording`'s own, sometimes landing the
    /// new recording on the idle scene instead (observed 2026-08-22: Guide recording started
    /// on an empty scene, OBS's camera source showing "no sources were found").
    private var idleTransitionTask: Task<Void, Never>?

    private struct EventWaiter {
        let id: UUID
        let eventType: String
        let matches: ([String: Any]) -> Bool
        let resume: ([String: Any]) -> Void
    }
    private var eventWaiters: [EventWaiter] = []

    init() {
        let config = ConfigStore.load()
        self.config = config
        self.obs = OBSClient(host: config.obsHost, port: config.obsPort, password: config.obsPassword)

        obs.onConnectionStateChanged = { [weak self] state in
            self?.connectionState = state
            if state == .connected {
                Task { [weak self] in await self?.syncFromOBS() }
            }
        }
        obs.onEvent = { [weak self] type, data in
            self?.handleEvent(type: type, data: data)
        }
        obs.connect()

        watchdogNotifier.onConfirm = { [weak self] in self?.confirmPresence() }
    }

    // MARK: - Startup / external-state sync

    /// Matches the popover to OBS's real current state, including recordings started or
    /// stopped from outside this app (e.g. someone pressed stop inside OBS directly).
    private func syncFromOBS() async {
        guard let status = try? await obs.getRecordStatus() else { return }
        if status.active {
            if recordStartDate == nil {
                recordStartDate = Date()
                pausedAccumulated = 0
            }
            recordingState = status.paused ? .paused : .recording
            if status.paused {
                if pauseStartDate == nil { pauseStartDate = Date() }
            } else {
                pauseStartDate = nil
            }
            startElapsedTimerIfNeeded()
        } else {
            resetToIdle()
        }
    }

    // MARK: - Mode start

    func start(mode: RecordingMode) {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        Task {
            defer { isBusy = false }
            do {
                try await beginRecording(mode: mode)
            } catch {
                errorMessage = error.localizedDescription
                // A partial start (e.g. scene already switched, camera already recreated for
                // Guide mode) shouldn't leave OBS sitting hot — recover back to idle.
                await goIdleInOBS()
            }
        }
    }

    private func beginRecording(mode: RecordingMode) async throws {
        // Let any in-flight idle cleanup (from a just-prior stop, or the connect-time sync)
        // finish before this recording starts mutating OBS itself — see idleTransitionTask.
        if let pending = idleTransitionTask {
            await pending.value
            idleTransitionTask = nil
        }

        var justLaunchedOBS = false
        if connectionState != .connected {
            justLaunchedOBS = try await ensureOBSRunningAndConnected()
        }
        guard connectionState == .connected else {
            throw simpleError("OBS not connected")
        }

        // On a cold launch, OBS's own audio subsystem can still be mid-initialization for a
        // moment right after the websocket handshake completes. Hitting it with
        // SetInputSettings/SetInputMute that early has been observed to crash OBS outright
        // (SIGSEGV inside obs_source_output_audio/copy_audio_data on the audio IO thread,
        // reproduced consistently) — a short settle delay avoids that window. Only applied
        // right after RecBar itself launched OBS, not on every recording start.
        if justLaunchedOBS {
            try await Task.sleep(nanoseconds: 3_000_000_000)
        }

        let resolved = try MicrophonePriority.resolve()
        let modeConfig = mode.config(config)

        try await obs.setCurrentProgramScene(modeConfig.sceneName)
        if mode == .guide {
            await restoreInput(at: \.cameraRelease)
        } else {
            await restoreInput(at: \.screenRelease)
            await restoreInput(at: \.desktopAudioRelease)
        }
        // Shared across every mode — recreated into whichever real scene is current now.
        await restoreInput(at: \.micBuiltInRelease, sceneNameOverride: modeConfig.sceneName)
        await restoreInput(at: \.micWiredRelease, sceneNameOverride: modeConfig.sceneName)
        try await obs.setRecordDirectory(modeConfig.saveFolder)
        try await applyMicrophonePriority(resolved, includeDesktopAudio: mode != .guide)
        try await obs.startRecord()

        let started = await waitForEvent("RecordStateChanged", timeout: 5) { data in
            (data["outputState"] as? String) == "OBS_WEBSOCKET_OUTPUT_STARTED"
        }
        guard started != nil else {
            throw simpleError("OBS did not confirm the recording started")
        }

        currentMode = mode
        resolvedMicDescription = "\(resolved.deviceName) (\(resolved.role == .usb ? "USB" : "built-in"))"
        resolvedMicSourceName = resolved.role == .usb ? config.sources.micUSBSourceName : config.sources.micBuiltInSourceName
        watchdogChannelNames = Set([resolvedMicSourceName].compactMap { $0 })
        if mode != .guide {
            watchdogChannelNames.insert(config.sources.desktopAudioSourceName)
        }
        recordStartDate = Date()
        pausedAccumulated = 0
        pauseStartDate = nil
        micLastAboveThresholdDate = Date()
        recordingState = .recording
        startElapsedTimerIfNeeded()
    }

    /// Mutes every configured mic source except the one that should be active, and (for modes
    /// that actually have it live — see `includeDesktopAudio`) keeps desktop audio unmuted.
    /// Re-writes the USB source's device_id every time, since OBS's saved device_id can go
    /// stale between physical (dis)connects.
    ///
    /// `includeDesktopAudio` must be `false` for Guide mode: `desktopAudioSourceName`
    /// ("Desktop Sounds") is only ever restored in the Sales/Other Call branch of
    /// `beginRecording` (Guide never uses it — see `config.desktopAudioRelease`), and
    /// `goIdleInOBS` unconditionally releases it on every idle transition. So after any idle
    /// transition following a Sales/Other Call recording, the source no longer exists at all
    /// by the time a Guide recording starts — muting it unconditionally here failed with
    /// "OBS request failed (600): No source was found" (confirmed 2026-08-22; Guide was the
    /// only mode that could ever hit this, since it's the only one that skips restoring it).
    private func applyMicrophonePriority(_ resolved: ResolvedMic, includeDesktopAudio: Bool) async throws {
        let sources = config.sources

        if resolved.role == .usb {
            try await obs.setInputSettings(inputName: sources.micUSBSourceName, settings: ["device_id": resolved.deviceUID])
        }

        try await obs.setInputMute(inputName: sources.micUSBSourceName, muted: resolved.role != .usb)
        try await obs.setInputMute(inputName: sources.micBuiltInSourceName, muted: resolved.role != .builtIn)
        try await obs.setInputMute(inputName: sources.micWiredSourceName, muted: true)
        if includeDesktopAudio {
            try await obs.setInputMute(inputName: sources.desktopAudioSourceName, muted: false)
        }
    }

    // MARK: - Idle resource minimization

    /// Switches OBS to an (auto-created) empty scene and releases the camera, screen capture,
    /// and desktop audio whenever RecBar isn't actively recording, so a never-quit OBS doesn't
    /// sit indefinitely on a scene with live capture. Called from `resetToIdle()` (every path
    /// back to idle) and from a failed `start()` (to recover from a partial setup).
    private func goIdleInOBS() async {
        guard connectionState == .connected else { return }
        do {
            try await ensureIdleSceneExists()
            try await obs.setCurrentProgramScene(config.idleSceneName)
        } catch {
            NSLog("RecBar: failed to switch OBS to its idle scene: \(error)")
        }
        await releaseInput(at: \.cameraRelease)
        await releaseInput(at: \.screenRelease)
        await releaseInput(at: \.desktopAudioRelease)
        await releaseInput(at: \.micBuiltInRelease)
        await releaseInput(at: \.micWiredRelease)
    }

    private func ensureIdleSceneExists() async throws {
        let scenes = try await obs.getSceneList()
        guard !scenes.contains(config.idleSceneName) else { return }
        try await obs.createScene(config.idleSceneName)
    }

    /// Scene item transform keys that SetSceneItemTransform actually accepts — GetSceneItemList
    /// also returns several read-only computed ones (sourceWidth/sourceHeight/width/height)
    /// that describe the source's native size, not something to send back.
    private static let writableTransformKeys: Set<String> = [
        "positionX", "positionY", "rotation", "scaleX", "scaleY", "alignment",
        "boundsType", "boundsAlignment", "boundsWidth", "boundsHeight",
        "cropTop", "cropBottom", "cropLeft", "cropRight", "cropToBounds"
    ]

    /// Switches through every existing scene, ending back on the idle scene. `RemoveInput` has
    /// been observed (2026-08-22) to return success while leaving the underlying capture
    /// session running indefinitely — reproduced directly against a live instance for the
    /// camera (`macos-avcapture-fast`), stuck 10+ minutes and multiple bare retries, after the
    /// source had been through one real recording; and for screen capture/desktop audio
    /// (`screen_capture`/`sck_audio_capture`), where merely switching away from and back to the
    /// idle scene (two scenes) wasn't enough either. `RemoveInput` appears to only queue the
    /// removal, and cycling through every scene — not just waiting, and not just one switch —
    /// is what reliably flushes it.
    private func cycleAllScenesEndingOnIdle() async {
        let scenes = (try? await obs.getSceneList()) ?? [config.idleSceneName]
        for scene in scenes {
            try? await obs.setCurrentProgramScene(scene)
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        try? await obs.setCurrentProgramScene(config.idleSceneName)
        try? await Task.sleep(nanoseconds: 400_000_000)
    }

    /// Removes a capture input entirely — confirmed via direct testing (2026-08-22, see
    /// CLAUDE.md) that a scene switch alone doesn't release the camera's AVCaptureSession, and
    /// only fully stops screen capture/desktop audio's ScreenCaptureKit session once actually
    /// removed too. Snapshots current kind/settings/enabled state/scene-item placement first —
    /// including placement, so a manually resized or repositioned source doesn't silently reset
    /// on the next `restoreInput` — so it can be recreated identically. No-ops if it's already
    /// gone (e.g. a second idle transition in a row) or not configured for release.
    private func releaseInput(at keyPath: WritableKeyPath<RecBarConfig, ReleasableInputConfig>) async {
        let inputConfig = config[keyPath: keyPath]
        guard inputConfig.enabled else { return }
        guard let (kind, settings) = try? await obs.getInputSettings(inputName: inputConfig.inputName) else {
            return
        }
        var enabled = inputConfig.lastKnownEnabled
        var transform: [String: Any]?
        if let item = try? await obs.findSceneItem(sceneName: inputConfig.sceneName, sourceName: inputConfig.inputName) {
            enabled = item.enabled
            transform = item.transform.filter { Self.writableTransformKeys.contains($0.key) }
        }
        if let data = try? JSONSerialization.data(withJSONObject: settings),
           let json = String(data: data, encoding: .utf8) {
            config[keyPath: keyPath].lastKnownInputKind = kind
            config[keyPath: keyPath].lastKnownSettingsJSON = json
            config[keyPath: keyPath].lastKnownEnabled = enabled
            if let transform, let transformData = try? JSONSerialization.data(withJSONObject: transform),
               let transformJSON = String(data: transformData, encoding: .utf8) {
                config[keyPath: keyPath].lastKnownTransformJSON = transformJSON
            }
            ConfigStore.save(config)
        }

        let name = inputConfig.inputName
        for attempt in 1...3 {
            try? await obs.removeInput(inputName: name)
            await cycleAllScenesEndingOnIdle()
            guard let inputs = try? await obs.getInputList(), inputs.contains(name) else {
                return // gone — done
            }
            NSLog("RecBar: \(name) still present after RemoveInput attempt \(attempt)/3")
        }
        NSLog("RecBar: failed to release \(name) after 3 attempts (including scene-cycle "
              + "nudges) — OBS accepted the RemoveInput request but the resource is still held "
              + "open. Quitting and relaunching OBS is the only other confirmed way to clear it.")
    }

    /// Recreates an input from its last snapshot, right before a recording that needs it
    /// starts. A no-op if it was never seen live (nothing to snapshot from yet), if it's
    /// already present (e.g. the user added it back manually), or not configured for release.
    ///
    /// `sceneNameOverride` lets a caller recreate the input into a different scene than the
    /// one it was last snapshotted from — used for the shared mic sources (`micBuiltInRelease`
    /// /`micWiredRelease`), which are a single config despite being usable from either real
    /// scene (see the doc comment on `RecBarConfig.micBuiltInRelease` for why they aren't
    /// split per-scene like camera/screen/desktop-audio). `enabled`/transform are reused as-is
    /// regardless of target scene, which is fine for these — audio-only sources have no
    /// meaningful visual placement.
    private func restoreInput(at keyPath: WritableKeyPath<RecBarConfig, ReleasableInputConfig>, sceneNameOverride: String? = nil) async {
        let inputConfig = config[keyPath: keyPath]
        let sceneName = sceneNameOverride ?? inputConfig.sceneName
        guard inputConfig.enabled else { return }
        guard !inputConfig.lastKnownInputKind.isEmpty,
              let data = inputConfig.lastKnownSettingsJSON.data(using: .utf8),
              let settings = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return
        }
        do {
            let existing = try await obs.getInputList()
            guard !existing.contains(inputConfig.inputName) else { return }
            guard let itemId = try await obs.createInput(
                sceneName: sceneName, inputName: inputConfig.inputName,
                inputKind: inputConfig.lastKnownInputKind, settings: settings
            ) else { return }
            try await obs.setSceneItemEnabled(sceneName: sceneName, sceneItemId: itemId, enabled: inputConfig.lastKnownEnabled)
            if let transformData = inputConfig.lastKnownTransformJSON.data(using: .utf8),
               var transform = (try? JSONSerialization.jsonObject(with: transformData)) as? [String: Any],
               !transform.isEmpty {
                // OBS rejects boundsWidth/boundsHeight < 1 even when boundsType is NONE
                // (confirmed 2026-08-22 testing the audio-only Desktop Sounds source, which has
                // no intrinsic size) — drop them in that case since they're unused anyway.
                if (transform["boundsType"] as? String) == "OBS_BOUNDS_NONE" {
                    transform.removeValue(forKey: "boundsWidth")
                    transform.removeValue(forKey: "boundsHeight")
                }
                try await obs.setSceneItemTransform(sceneName: sceneName, sceneItemId: itemId, transform: transform)
            }
        } catch {
            NSLog("RecBar: failed to restore \(inputConfig.inputName): \(error)")
        }
    }

    /// Launches OBS hidden if it isn't running yet (no-ops, and claims no ownership, if it's
    /// already open — see OBSLauncher), then waits for the websocket connection to come up.
    /// Returns whether RecBar performed a fresh launch (vs. OBS already being up).
    @discardableResult
    private func ensureOBSRunningAndConnected() async throws -> Bool {
        let didLaunch: Bool
        if !obsLauncher.isOBSRunning() {
            try await obsLauncher.launchHiddenIfNeeded()
            didLaunch = true
        } else {
            didLaunch = false
        }
        obs.reconnectNow()

        let deadline = Date().addingTimeInterval(45)
        while connectionState != .connected {
            if Date() >= deadline {
                // The most common cause is OBS's own "did not shut down properly, start in
                // Safe Mode?" dialog blocking obs-websocket from coming up — invisible while
                // OBS sits hidden with no Dock icon, so surface the window rather than just
                // failing silently a second time.
                obsLauncher.bringToForegroundIfLaunchedByUs()
                throw simpleError(
                    "Timed out waiting for OBS to start and connect. If OBS just launched, check "
                    + "for a \"did not shut down properly\" dialog — RecBar brought it to the "
                    + "foreground; click \"Run in Normal Mode\" and try again."
                )
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        return didLaunch
    }

    // MARK: - Silence / presence watchdog

    /// Runs once a second while actively recording (never while paused — see tickElapsed).
    /// Tracks how long every channel in `watchdogChannelNames` has stayed below the
    /// configured threshold and, once it's been silent long enough, opens (or times out) the
    /// presence prompt.
    ///
    /// The deadline that actually has to be reached is `max(silenceDeadline,
    /// watchdogExtendedDeadline)` — an ordinary `silenceDurationSeconds`-from-last-activity
    /// deadline, versus a fixed `confirmExtensionSeconds`-from-the-last-"I'm here"-press
    /// deadline (see `confirmPresence()`). Whichever is later wins: if real activity happens
    /// and then stops again well before the extension would've elapsed, the extension (being
    /// later) still applies; if activity happens close enough to the extension's own deadline
    /// that a fresh 3-minute-from-then window would run past it, that fresh window wins
    /// instead. No explicit bookkeeping is needed to make the fresh window "win" — since
    /// `micLastAboveThresholdDate` only ever advances while there's real activity,
    /// `silenceDeadline` only ever grows, so it naturally overtakes the fixed
    /// `watchdogExtendedDeadline` the moment it would matter.
    private func tickWatchdog() {
        guard let currentMode else { return }
        let watchdog = currentMode.config(config).watchdog
        guard watchdog.enabled else {
            if watchdogPromptDeadline != nil { clearWatchdogPrompt() }
            return
        }

        let now = Date()

        if let deadline = watchdogPromptDeadline {
            if now >= deadline {
                autoStopForSilence()
                return
            }
            // Repeat the alert chime for as long as the prompt is unconfirmed, rather than
            // once at the start — the whole point is to be noticed even away from the screen.
            if lastWatchdogAlertSoundDate.map({ now.timeIntervalSince($0) >= watchdogAlertRepeatInterval }) ?? true {
                lastWatchdogAlertSoundDate = now
                AlertSound.play()
            }
            return
        }

        let thresholdMul = Self.dbToLinear(watchdog.silenceThresholdDB)
        if let level = maxWatchedLevel(), level >= thresholdMul {
            micLastAboveThresholdDate = now
            return
        }

        let lastAbove = micLastAboveThresholdDate ?? now
        let silenceDeadline = lastAbove.addingTimeInterval(watchdog.silenceDurationSeconds)
        let effectiveDeadline = max(silenceDeadline, watchdogExtendedDeadline ?? .distantPast)

        if now >= effectiveDeadline {
            watchdogExtendedDeadline = nil
            let deadline = now.addingTimeInterval(watchdog.responseWindowSeconds)
            watchdogPromptDeadline = deadline
            watchdogNotifier.postPrompt(responseWindowSeconds: watchdog.responseWindowSeconds)
            watchdogOverlay.show(deadline: deadline) { [weak self] in self?.confirmPresence() }
        }
    }

    /// The loudest live level among every channel the watchdog is currently treating as
    /// "presence" (see `watchdogChannelNames`) — any one of them being active counts as not
    /// silent, since a loud screen-share is just as much "someone's here" as their own mic.
    private func maxWatchedLevel() -> Float? {
        let levels = channelLevels.filter { watchdogChannelNames.contains($0.name) }
        guard !levels.isEmpty else { return nil }
        return levels.map(\.peakLevel).max()
    }

    private static func dbToLinear(_ db: Double) -> Float {
        Float(pow(10.0, db / 20.0))
    }

    /// Confirms presence — from the inline "I'm here" button or the notification action —
    /// resetting the silence clock and letting the recording continue normally. Also grants
    /// `confirmExtensionSeconds` of slack from this moment (longer than the ordinary
    /// `silenceDurationSeconds`, since a confirmed "I'm here" is stronger evidence than an
    /// ordinary pause in talking) — see `tickWatchdog()` for how this competes with a later
    /// burst of real activity.
    func confirmPresence() {
        guard watchdogPromptDeadline != nil, let currentMode else { return }
        clearWatchdogPrompt()
        let now = Date()
        micLastAboveThresholdDate = now
        watchdogExtendedDeadline = now.addingTimeInterval(currentMode.config(config).watchdog.confirmExtensionSeconds)
    }

    private func clearWatchdogPrompt() {
        guard watchdogPromptDeadline != nil else { return }
        watchdogPromptDeadline = nil
        lastWatchdogAlertSoundDate = nil
        watchdogNotifier.clearPrompt()
        watchdogOverlay.hide()
    }

    /// The response window elapsed with no confirmation: stop the recording (keeping the
    /// file — never discard), drop back to View 1, and confirm via notification why it
    /// happened, since the popover may not be open to see it.
    private func autoStopForSilence() {
        guard watchdogPromptDeadline != nil, recordingState == .recording else { return }
        clearWatchdogPrompt()
        stop(discard: false)
        watchdogNotifier.postAutoStopped()
    }

    // MARK: - Transport controls

    func togglePause() {
        guard !isBusy, recordingState == .recording || recordingState == .paused else { return }
        isBusy = true
        let pausing = recordingState == .recording
        Task {
            defer { isBusy = false }
            do {
                if pausing {
                    try await obs.pauseRecord()
                    _ = await waitForEvent("RecordStateChanged", timeout: 5) { ($0["outputState"] as? String) == "OBS_WEBSOCKET_OUTPUT_PAUSED" }
                    pauseStartDate = Date()
                    recordingState = .paused
                    // The watchdog is suppressed while paused (see tickElapsed); clear any
                    // in-flight prompt so it doesn't resolve to an auto-stop during the pause.
                    clearWatchdogPrompt()
                } else {
                    try await obs.resumeRecord()
                    _ = await waitForEvent("RecordStateChanged", timeout: 5) { ($0["outputState"] as? String) == "OBS_WEBSOCKET_OUTPUT_RESUMED" }
                    if let pauseStartDate {
                        pausedAccumulated += Date().timeIntervalSince(pauseStartDate)
                    }
                    pauseStartDate = nil
                    recordingState = .recording
                    // Start the silence clock fresh on resume rather than counting the pause itself.
                    micLastAboveThresholdDate = Date()
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func stop(discard: Bool) {
        guard !isBusy, recordingState != .idle else { return }
        isBusy = true
        Task {
            defer { isBusy = false }
            do {
                let outputPath = try await obs.stopRecord()
                _ = await waitForEvent("RecordStateChanged", timeout: 5) { ($0["outputState"] as? String) == "OBS_WEBSOCKET_OUTPUT_STOPPED" }

                if discard, let outputPath {
                    do {
                        try FileManager.default.removeItem(atPath: outputPath)
                        NSLog("RecBar: discarded recording at \(outputPath)")
                    } catch {
                        NSLog("RecBar: failed to delete discarded recording at \(outputPath): \(error)")
                    }
                }

                resetToIdle()
                // RecBar never quits OBS itself (see OBSLauncher) — the user quits it manually.
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func resetToIdle() {
        recordingState = .idle
        currentMode = nil
        resolvedMicDescription = nil
        resolvedMicSourceName = nil
        watchdogChannelNames = []
        recordStartDate = nil
        pauseStartDate = nil
        pausedAccumulated = 0
        elapsed = 0
        channelLevels = []
        stopElapsedTimer()
        clearWatchdogPrompt()
        micLastAboveThresholdDate = nil
        watchdogExtendedDeadline = nil
        idleTransitionTask = Task { [weak self] in await self?.goIdleInOBS() }
    }

    // MARK: - Elapsed timer

    private func startElapsedTimerIfNeeded() {
        guard elapsedTimer == nil else { return }
        tickElapsed()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickElapsed() }
        }
        RunLoop.main.add(timer, forMode: .common)
        elapsedTimer = timer
    }

    private func stopElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
    }

    private func tickElapsed() {
        guard let recordStartDate else { return }
        if recordingState == .paused {
            return // frozen while paused — the watchdog is suppressed along with it
        }
        elapsed = Date().timeIntervalSince(recordStartDate) - pausedAccumulated
        tickWatchdog()
    }

    // MARK: - Events from OBS

    private func handleEvent(type: String, data: [String: Any]) {
        var remaining: [EventWaiter] = []
        for waiter in eventWaiters {
            if waiter.eventType == type && waiter.matches(data) {
                waiter.resume(data)
            } else {
                remaining.append(waiter)
            }
        }
        eventWaiters = remaining

        switch type {
        case "RecordStateChanged":
            handleRecordStateChanged(data)
        case "InputVolumeMeters":
            handleInputVolumeMeters(data)
        default:
            break
        }
    }

    /// Keeps the UI truthful even when OBS's state changes from outside this app.
    private func handleRecordStateChanged(_ data: [String: Any]) {
        guard let outputState = data["outputState"] as? String else { return }
        switch outputState {
        case "OBS_WEBSOCKET_OUTPUT_STARTED":
            if recordingState == .idle {
                recordStartDate = Date()
                pausedAccumulated = 0
                recordingState = .recording
                startElapsedTimerIfNeeded()
            }
        case "OBS_WEBSOCKET_OUTPUT_STOPPED", "OBS_WEBSOCKET_OUTPUT_STOPPING":
            if outputState == "OBS_WEBSOCKET_OUTPUT_STOPPED" {
                resetToIdle()
            }
        case "OBS_WEBSOCKET_OUTPUT_PAUSED":
            recordingState = .paused
            clearWatchdogPrompt()
        case "OBS_WEBSOCKET_OUTPUT_RESUMED":
            recordingState = .recording
            micLastAboveThresholdDate = Date()
        default:
            break
        }
    }

    private func handleInputVolumeMeters(_ data: [String: Any]) {
        guard let inputs = data["inputs"] as? [[String: Any]] else { return }
        let sources = config.sources
        let tracked: Set<String> = [
            sources.micUSBSourceName,
            sources.micBuiltInSourceName,
            sources.desktopAudioSourceName
        ]

        var levels: [ChannelLevel] = []
        for input in inputs {
            guard let name = input["inputName"] as? String, tracked.contains(name) else { continue }
            guard let levelGroups = input["inputLevelsMul"] as? [[Any]] else { continue }
            // Each channel is [peak, peakHold, magnitude] as NSNumbers; take the loudest channel's peak.
            let peak = levelGroups.compactMap { channel -> Float? in
                guard let first = channel.first as? NSNumber else { return nil }
                return first.floatValue
            }.max() ?? 0
            levels.append(ChannelLevel(name: name, peakLevel: min(1, max(0, peak))))
        }
        channelLevels = levels
    }

    private func waitForEvent(_ type: String, timeout: TimeInterval, matches: @escaping ([String: Any]) -> Bool) async -> [String: Any]? {
        await withCheckedContinuation { (continuation: CheckedContinuation<[String: Any]?, Never>) in
            let id = UUID()
            var didResume = false
            let resumeOnce: ([String: Any]?) -> Void = { [weak self] value in
                guard !didResume else { return }
                didResume = true
                self?.eventWaiters.removeAll { $0.id == id }
                continuation.resume(returning: value)
            }

            eventWaiters.append(EventWaiter(id: id, eventType: type, matches: matches, resume: resumeOnce))

            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                resumeOnce(nil)
            }
        }
    }

    private func simpleError(_ message: String) -> Error {
        NSError(domain: "RecBar", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
