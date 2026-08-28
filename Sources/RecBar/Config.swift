import Foundation

/// Which physical mic source (as configured in OBS) should be active for a resolved priority device.
enum MicSourceRole: String, Codable {
    case usb
    case builtIn
}

struct SceneSourceNames: Codable {
    var micUSBSourceName: String
    var micBuiltInSourceName: String
    var micWiredSourceName: String
    var desktopAudioSourceName: String
}

/// Per-mode silence/presence watchdog settings. While recording, if every currently-active
/// audio channel (the resolved mic plus desktop audio, whichever are actually unmuted for
/// the mode — see `AppState.watchdogChannelNames`) stays below silenceThresholdDB for
/// silenceDurationSeconds, RecBar prompts "Are you there?" and auto-stops (keeping the file)
/// if there's no response within responseWindowSeconds. A confirmed "I'm here" buys
/// confirmExtensionSeconds of slack from the moment of the press instead of the normal
/// silenceDurationSeconds — see AppState.tickWatchdog/confirmPresence for the "later deadline
/// wins" logic between the two.
struct WatchdogConfig: Codable {
    var enabled: Bool
    var silenceThresholdDB: Double
    var silenceDurationSeconds: Double
    var responseWindowSeconds: Double
    var confirmExtensionSeconds: Double

    enum CodingKeys: String, CodingKey {
        case enabled, silenceThresholdDB, silenceDurationSeconds, responseWindowSeconds, confirmExtensionSeconds
    }

    init(enabled: Bool, silenceThresholdDB: Double, silenceDurationSeconds: Double,
         responseWindowSeconds: Double, confirmExtensionSeconds: Double) {
        self.enabled = enabled
        self.silenceThresholdDB = silenceThresholdDB
        self.silenceDurationSeconds = silenceDurationSeconds
        self.responseWindowSeconds = responseWindowSeconds
        self.confirmExtensionSeconds = confirmExtensionSeconds
    }

    /// Custom decoding so config.json files written before confirmExtensionSeconds existed
    /// still load their real values for every other field, defaulting only the new one.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        silenceThresholdDB = try c.decode(Double.self, forKey: .silenceThresholdDB)
        silenceDurationSeconds = try c.decode(Double.self, forKey: .silenceDurationSeconds)
        responseWindowSeconds = try c.decode(Double.self, forKey: .responseWindowSeconds)
        confirmExtensionSeconds = try c.decodeIfPresent(Double.self, forKey: .confirmExtensionSeconds) ?? 420
    }

    // -50dB was the original guess and turned out to be unreachable in practice — a real
    // recording analyzed 2026-08-28 (ffmpeg silencedetect against the saved file) never once
    // dipped below -40dB even briefly, let alone continuously for silenceDurationSeconds. -35
    // is still a deliberately conservative (quiet) pick based on that one sample; the debug
    // drawer now shows each channel's live dB and highlights the watched mic red when it's
    // under the configured threshold, specifically so this can be tuned per-room without
    // needing to analyze a recording after the fact.
    //
    // silenceDurationSeconds defaults to 3 minutes and confirmExtensionSeconds to 7 (both
    // 2026-08-28, per explicit user request) — long enough that normal conversational pauses
    // never trip it, with a confirmed "I'm here" buying extra headroom since the user has just
    // demonstrated they're mid-call, not idle.
    static let defaultOn = WatchdogConfig(
        enabled: true, silenceThresholdDB: -35, silenceDurationSeconds: 180,
        responseWindowSeconds: 60, confirmExtensionSeconds: 420
    )
    static let defaultOff = WatchdogConfig(
        enabled: false, silenceThresholdDB: -35, silenceDurationSeconds: 180,
        responseWindowSeconds: 60, confirmExtensionSeconds: 420
    )
}

/// Governs releasing a capture resource (camera, screen capture, desktop audio) that OBS
/// holds open regardless of which scene is active. `AppState.releaseInput(_:)` removes it
/// whenever RecBar isn't recording and it isn't needed by the mode about to start, and
/// `AppState.restoreInput(_:)` recreates it (from the settings/enabled-state/scene-item
/// transform snapshotted the moment before removal — including transform so a manually
/// resized/repositioned placement doesn't silently reset on every release/restore cycle)
/// right before a recording that needs it starts. Camera (`macos-avcapture-fast`), screen
/// capture (`screen_capture`), and desktop audio (`sck_audio_capture`) all use this same
/// shape — see CLAUDE.md's "Idle resource minimization" for why each needs actual removal
/// (not just a scene switch) to fully release, and why removal reliably needs cycling
/// through every scene rather than just switching away and back once (confirmed via direct
/// testing 2026-08-22).
struct ReleasableInputConfig: Codable {
    var enabled: Bool
    var inputName: String
    var sceneName: String
    /// Snapshotted live, right before each removal, so recreation is identical to whatever
    /// the source actually looked like — never hardcoded. Empty until the first snapshot.
    var lastKnownInputKind: String
    var lastKnownSettingsJSON: String
    var lastKnownEnabled: Bool
    var lastKnownTransformJSON: String

    static func makeDefault(inputName: String, sceneName: String) -> ReleasableInputConfig {
        ReleasableInputConfig(
            enabled: true, inputName: inputName, sceneName: sceneName,
            lastKnownInputKind: "", lastKnownSettingsJSON: "", lastKnownEnabled: false,
            lastKnownTransformJSON: ""
        )
    }
}

struct ModeConfig: Codable {
    var sceneName: String
    var saveFolder: String
    var watchdog: WatchdogConfig

    enum CodingKeys: String, CodingKey {
        case sceneName, saveFolder, watchdog
    }

    init(sceneName: String, saveFolder: String, watchdog: WatchdogConfig) {
        self.sceneName = sceneName
        self.saveFolder = saveFolder
        self.watchdog = watchdog
    }

    /// Custom decoding so existing config.json files written before per-mode watchdog
    /// settings existed still load their real sceneName/saveFolder instead of falling back
    /// to defaults — only the new watchdog field defaults when absent.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sceneName = try c.decode(String.self, forKey: .sceneName)
        saveFolder = try c.decode(String.self, forKey: .saveFolder)
        watchdog = try c.decodeIfPresent(WatchdogConfig.self, forKey: .watchdog) ?? .defaultOn
    }
}

struct RecBarConfig: Codable {
    var obsHost: String
    var obsPort: Int
    var obsPassword: String
    var sources: SceneSourceNames
    var salesMode: ModeConfig
    var guideMode: ModeConfig
    var otherMode: ModeConfig
    /// Scene RecBar switches OBS to whenever it isn't actively recording, to release
    /// screen-capture/desktop-audio/scene-local-mic resources without quitting OBS (see
    /// AppState.goIdleInOBS()). Auto-created via CreateScene if it doesn't already exist.
    var idleSceneName: String
    var cameraRelease: ReleasableInputConfig
    /// Screen capture and desktop audio are only used by Sales Call/Other Call (both share
    /// `Meet Recording Setup`) — Guide mode never touches either.
    var screenRelease: ReleasableInputConfig
    var desktopAudioRelease: ReleasableInputConfig
    /// Unlike camera/screen/desktop-audio (each only ever live in one scene), the built-in
    /// and wired mic sources are used by every mode, so they're live in whichever of the two
    /// real scenes last needed them — `applyMicrophonePriority` mutes/unmutes them by the
    /// same source name regardless of which scene is current. A first attempt gave each one
    /// two `ReleasableInputConfig`s (one per scene, sharing an `inputName`) mirroring
    /// screen/desktop-audio/camera's single-scene shape — that was wrong: since it's really
    /// one shared global input, `goIdleInOBS` releasing the Meet entry before the Guide entry
    /// meant the Meet copy always captured the live snapshot and the Guide copy's
    /// `GetInputSettings` always found it already gone, so its snapshot stayed empty forever
    /// and `restoreInput` for Guide silently no-op'd every time — Macbook/Headphones Mic never
    /// came back in Guide Recording Setup, and `applyMicrophonePriority` then failed muting a
    /// source that no longer existed ("OBS request failed (600): No source was found",
    /// confirmed 2026-08-22, Guide-only). Fixed by using a single config per mic source and
    /// passing the target scene explicitly at restore time (`AppState.restoreSharedMicInput`)
    /// instead of baking it into `ReleasableInputConfig.sceneName` — correct because these are
    /// audio-only sources with no meaningful per-scene transform to preserve anyway.
    var micBuiltInRelease: ReleasableInputConfig
    var micWiredRelease: ReleasableInputConfig

    static let `default` = RecBarConfig(
        obsHost: "127.0.0.1",
        obsPort: 4455,
        obsPassword: "",
        sources: SceneSourceNames(
            micUSBSourceName: "USB PnP",
            micBuiltInSourceName: "Macbook",
            micWiredSourceName: "Headphones Mic",
            desktopAudioSourceName: "Desktop Sounds"
        ),
        salesMode: ModeConfig(
            sceneName: "Meet Recording Setup",
            saveFolder: "/Users/stage/Documents/Recordings/Sales Meetings",
            watchdog: .defaultOn
        ),
        guideMode: ModeConfig(
            sceneName: "Guide Recording Setup",
            saveFolder: "/Users/stage/Documents/Recordings/Guides",
            // Off by default: Guide recordings are often narrated on-screen with long
            // stretches of intentional on-mic silence, which isn't the "walked away" case
            // the watchdog is meant to catch.
            watchdog: .defaultOff
        ),
        otherMode: ModeConfig(
            sceneName: "Meet Recording Setup",
            saveFolder: "/Users/stage/Documents/Recordings/Other Meetings",
            watchdog: .defaultOn
        ),
        idleSceneName: "RecBar Idle",
        cameraRelease: .makeDefault(inputName: "Capture Card Device", sceneName: "Guide Recording Setup"),
        screenRelease: .makeDefault(inputName: "Screen", sceneName: "Meet Recording Setup"),
        desktopAudioRelease: .makeDefault(inputName: "Desktop Sounds", sceneName: "Meet Recording Setup"),
        // sceneName here is unused (restoreSharedMicInput takes the target scene explicitly)
        // — kept only because ReleasableInputConfig.makeDefault requires one.
        micBuiltInRelease: .makeDefault(inputName: "Macbook", sceneName: "Meet Recording Setup"),
        micWiredRelease: .makeDefault(inputName: "Headphones Mic", sceneName: "Meet Recording Setup")
    )

    enum CodingKeys: String, CodingKey {
        case obsHost, obsPort, obsPassword, sources, salesMode, guideMode, otherMode
        case idleSceneName, cameraRelease, screenRelease, desktopAudioRelease
        case micBuiltInRelease, micWiredRelease
    }

    init(obsHost: String, obsPort: Int, obsPassword: String, sources: SceneSourceNames,
         salesMode: ModeConfig, guideMode: ModeConfig, otherMode: ModeConfig,
         idleSceneName: String, cameraRelease: ReleasableInputConfig,
         screenRelease: ReleasableInputConfig, desktopAudioRelease: ReleasableInputConfig,
         micBuiltInRelease: ReleasableInputConfig, micWiredRelease: ReleasableInputConfig) {
        self.obsHost = obsHost
        self.obsPort = obsPort
        self.obsPassword = obsPassword
        self.sources = sources
        self.salesMode = salesMode
        self.guideMode = guideMode
        self.otherMode = otherMode
        self.idleSceneName = idleSceneName
        self.cameraRelease = cameraRelease
        self.screenRelease = screenRelease
        self.desktopAudioRelease = desktopAudioRelease
        self.micBuiltInRelease = micBuiltInRelease
        self.micWiredRelease = micWiredRelease
    }

    /// Custom decoding so existing config.json files written before the per-mode watchdog
    /// block (or the idle-scene/camera-release/screen-release/desktop-audio-release/
    /// mic-release fields) existed still load (and keep their real host/port/password/etc.)
    /// instead of silently falling back to RecBarConfig.default.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        obsHost = try c.decode(String.self, forKey: .obsHost)
        obsPort = try c.decode(Int.self, forKey: .obsPort)
        obsPassword = try c.decode(String.self, forKey: .obsPassword)
        sources = try c.decode(SceneSourceNames.self, forKey: .sources)
        // Decoded with an explicit per-mode default (rather than via ModeConfig's own
        // Decodable init) because Guide's watchdog default differs from Sales/Other's —
        // ModeConfig alone has no way to know which mode it's decoding.
        salesMode = try Self.decodeModeConfig(c, forKey: .salesMode, defaultWatchdog: .defaultOn)
        guideMode = try Self.decodeModeConfig(c, forKey: .guideMode, defaultWatchdog: .defaultOff)
        otherMode = try Self.decodeModeConfig(c, forKey: .otherMode, defaultWatchdog: .defaultOn)
        idleSceneName = try c.decodeIfPresent(String.self, forKey: .idleSceneName) ?? "RecBar Idle"
        cameraRelease = try c.decodeIfPresent(ReleasableInputConfig.self, forKey: .cameraRelease)
            ?? .makeDefault(inputName: "Capture Card Device", sceneName: "Guide Recording Setup")
        screenRelease = try c.decodeIfPresent(ReleasableInputConfig.self, forKey: .screenRelease)
            ?? .makeDefault(inputName: "Screen", sceneName: "Meet Recording Setup")
        desktopAudioRelease = try c.decodeIfPresent(ReleasableInputConfig.self, forKey: .desktopAudioRelease)
            ?? .makeDefault(inputName: "Desktop Sounds", sceneName: "Meet Recording Setup")
        micBuiltInRelease = try c.decodeIfPresent(ReleasableInputConfig.self, forKey: .micBuiltInRelease)
            ?? .makeDefault(inputName: "Macbook", sceneName: "Meet Recording Setup")
        micWiredRelease = try c.decodeIfPresent(ReleasableInputConfig.self, forKey: .micWiredRelease)
            ?? .makeDefault(inputName: "Headphones Mic", sceneName: "Meet Recording Setup")
    }

    private static func decodeModeConfig(
        _ c: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys, defaultWatchdog: WatchdogConfig
    ) throws -> ModeConfig {
        let nested = try c.nestedContainer(keyedBy: ModeConfig.CodingKeys.self, forKey: key)
        let sceneName = try nested.decode(String.self, forKey: .sceneName)
        let saveFolder = try nested.decode(String.self, forKey: .saveFolder)
        let watchdog = try nested.decodeIfPresent(WatchdogConfig.self, forKey: .watchdog) ?? defaultWatchdog
        return ModeConfig(sceneName: sceneName, saveFolder: saveFolder, watchdog: watchdog)
    }
}

enum ConfigStore {
    static var configDirectory: URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/RecBar", isDirectory: true)
    }

    static var configURL: URL {
        configDirectory.appendingPathComponent("config.json")
    }

    /// Loads config.json, creating it with defaults on first run so the user has something to edit.
    static func load() -> RecBarConfig {
        let url = configURL
        guard let data = try? Data(contentsOf: url) else {
            let defaults = RecBarConfig.default
            save(defaults)
            return defaults
        }
        guard let decoded = try? JSONDecoder().decode(RecBarConfig.self, from: data) else {
            NSLog("RecBar: config.json is invalid, falling back to defaults (not overwriting your file)")
            return .default
        }
        // Migration: older config.json files predate the per-mode watchdog block and/or the
        // idle-scene/camera-release fields. Persist the defaulted values so they become
        // visible/editable in the user's own file.
        if needsMigrationSave(rawData: data) {
            save(decoded)
        }
        return decoded
    }

    private static func needsMigrationSave(rawData: Data) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: rawData) as? [String: Any] else { return false }
        if json["idleSceneName"] == nil || json["cameraRelease"] == nil
            || json["screenRelease"] == nil || json["desktopAudioRelease"] == nil { return true }
        if json["micBuiltInRelease"] == nil || json["micWiredRelease"] == nil { return true }
        for key in ["salesMode", "guideMode", "otherMode"] {
            guard let mode = json[key] as? [String: Any] else { continue }
            guard let watchdog = mode["watchdog"] as? [String: Any] else { return true }
            if watchdog["confirmExtensionSeconds"] == nil { return true }
        }
        return false
    }

    static func save(_ config: RecBarConfig) {
        do {
            try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(config)
            try data.write(to: configURL, options: .atomic)
        } catch {
            NSLog("RecBar: failed to write config.json: \(error)")
        }
    }
}
