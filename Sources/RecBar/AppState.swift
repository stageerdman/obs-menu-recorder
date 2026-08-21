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

    let config: RecBarConfig
    private let obs: OBSClient

    private var recordStartDate: Date?
    private var pausedAccumulated: TimeInterval = 0
    private var pauseStartDate: Date?
    private var elapsedTimer: Timer?

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
            }
        }
    }

    private func beginRecording(mode: RecordingMode) async throws {
        guard connectionState == .connected else {
            throw simpleError("OBS not connected")
        }

        let resolved = try MicrophonePriority.resolve()
        let modeConfig = mode.config(config)

        try await obs.setCurrentProgramScene(modeConfig.sceneName)
        try await obs.setRecordDirectory(modeConfig.saveFolder)
        try await applyMicrophonePriority(resolved)
        try await obs.startRecord()

        let started = await waitForEvent("RecordStateChanged", timeout: 5) { data in
            (data["outputState"] as? String) == "OBS_WEBSOCKET_OUTPUT_STARTED"
        }
        guard started != nil else {
            throw simpleError("OBS did not confirm the recording started")
        }

        currentMode = mode
        resolvedMicDescription = "\(resolved.deviceName) (\(resolved.role == .usb ? "USB" : "built-in"))"
        recordStartDate = Date()
        pausedAccumulated = 0
        pauseStartDate = nil
        recordingState = .recording
        startElapsedTimerIfNeeded()
    }

    /// Mutes every configured mic source except the one that should be active, and always
    /// keeps desktop audio unmuted. Re-writes the USB source's device_id every time, since
    /// OBS's saved device_id can go stale between physical (dis)connects.
    private func applyMicrophonePriority(_ resolved: ResolvedMic) async throws {
        let sources = config.sources

        if resolved.role == .usb {
            try await obs.setInputSettings(inputName: sources.micUSBSourceName, settings: ["device_id": resolved.deviceUID])
        }

        try await obs.setInputMute(inputName: sources.micUSBSourceName, muted: resolved.role != .usb)
        try await obs.setInputMute(inputName: sources.micBuiltInSourceName, muted: resolved.role != .builtIn)
        try await obs.setInputMute(inputName: sources.micWiredSourceName, muted: true)
        try await obs.setInputMute(inputName: sources.desktopAudioSourceName, muted: false)
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
                } else {
                    try await obs.resumeRecord()
                    _ = await waitForEvent("RecordStateChanged", timeout: 5) { ($0["outputState"] as? String) == "OBS_WEBSOCKET_OUTPUT_RESUMED" }
                    if let pauseStartDate {
                        pausedAccumulated += Date().timeIntervalSince(pauseStartDate)
                    }
                    pauseStartDate = nil
                    recordingState = .recording
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
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func resetToIdle() {
        recordingState = .idle
        currentMode = nil
        resolvedMicDescription = nil
        recordStartDate = nil
        pauseStartDate = nil
        pausedAccumulated = 0
        elapsed = 0
        channelLevels = []
        stopElapsedTimer()
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
            return // frozen while paused
        }
        elapsed = Date().timeIntervalSince(recordStartDate) - pausedAccumulated
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
        case "OBS_WEBSOCKET_OUTPUT_RESUMED":
            recordingState = .recording
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
