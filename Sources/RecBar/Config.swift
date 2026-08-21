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

struct ModeConfig: Codable {
    var sceneName: String
    var saveFolder: String
}

struct RecBarConfig: Codable {
    var obsHost: String
    var obsPort: Int
    var obsPassword: String
    var sources: SceneSourceNames
    var salesMode: ModeConfig
    var guideMode: ModeConfig
    var otherMode: ModeConfig

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
            saveFolder: "/Users/stage/Documents/Recordings/Sales Meetings"
        ),
        guideMode: ModeConfig(
            sceneName: "Guide Recording Setup",
            saveFolder: "/Users/stage/Documents/Recordings/Guides"
        ),
        otherMode: ModeConfig(
            sceneName: "Meet Recording Setup",
            saveFolder: "/Users/stage/Documents/Recordings/Other Meetings"
        )
    )
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
        return decoded
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
