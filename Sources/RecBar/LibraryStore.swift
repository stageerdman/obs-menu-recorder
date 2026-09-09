import Foundation

/// Per-video cloud state, driving the Library window's cloud button/progress UI. `.none` and
/// `.failed` both mean "no live cloud presence" for pruning purposes — see
/// `LibraryStore.reconcile`'s use of `cloudWebUrl` rather than this enum to decide what to
/// keep, since a link can already exist even while a later chunk upload is `.failed`.
enum CloudUploadState: String, Codable {
    case none
    case creatingLink
    case uploading
    case uploaded
    case failed
}

/// One tracked recording — created the instant a kept recording finishes
/// (`AppState.stop(discard:)`) or discovered by `LibraryStore.reconcile`'s folder scan.
/// Identity is a stable `UUID`, independent of filename/path, so a rename or a move-out of
/// the watched folder never loses track of a file's cloud upload state.
struct RecordingMetadata: Codable, Identifiable {
    var id: UUID
    var category: RecordingMode
    var fileName: String
    /// nil once the file is confirmed gone from wherever RecBar last saw it — either moved
    /// out (see FilePromiseDragHandle/"Move to Folder…") or deleted directly.
    var lastKnownLocalPath: String?
    var sizeBytes: Int64?
    var createdAtEpoch: Int
    var cloudUploadState: CloudUploadState
    var cloudItemId: String?
    var cloudWebUrl: String?
    var cloudBytesSent: Int64
    var cloudErrorMessage: String?

    enum CodingKeys: String, CodingKey {
        case id, category, fileName, lastKnownLocalPath, sizeBytes, createdAtEpoch
        case cloudUploadState, cloudItemId, cloudWebUrl, cloudBytesSent, cloudErrorMessage
    }

    init(id: UUID, category: RecordingMode, fileName: String, lastKnownLocalPath: String?,
         sizeBytes: Int64?, createdAtEpoch: Int, cloudUploadState: CloudUploadState = .none,
         cloudItemId: String? = nil, cloudWebUrl: String? = nil,
         cloudBytesSent: Int64 = 0, cloudErrorMessage: String? = nil) {
        self.id = id
        self.category = category
        self.fileName = fileName
        self.lastKnownLocalPath = lastKnownLocalPath
        self.sizeBytes = sizeBytes
        self.createdAtEpoch = createdAtEpoch
        self.cloudUploadState = cloudUploadState
        self.cloudItemId = cloudItemId
        self.cloudWebUrl = cloudWebUrl
        self.cloudBytesSent = cloudBytesSent
        self.cloudErrorMessage = cloudErrorMessage
    }

    /// Migration-safe decode, matching Config.swift's models — every field beyond the
    /// original core set defaults rather than failing to decode an older library.json.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        category = try c.decode(RecordingMode.self, forKey: .category)
        fileName = try c.decode(String.self, forKey: .fileName)
        lastKnownLocalPath = try c.decodeIfPresent(String.self, forKey: .lastKnownLocalPath)
        sizeBytes = try c.decodeIfPresent(Int64.self, forKey: .sizeBytes)
        createdAtEpoch = try c.decodeIfPresent(Int.self, forKey: .createdAtEpoch) ?? 0
        cloudUploadState = try c.decodeIfPresent(CloudUploadState.self, forKey: .cloudUploadState) ?? .none
        cloudItemId = try c.decodeIfPresent(String.self, forKey: .cloudItemId)
        cloudWebUrl = try c.decodeIfPresent(String.self, forKey: .cloudWebUrl)
        cloudBytesSent = try c.decodeIfPresent(Int64.self, forKey: .cloudBytesSent) ?? 0
        cloudErrorMessage = try c.decodeIfPresent(String.self, forKey: .cloudErrorMessage)
    }
}

/// Persists the Library window's tracked-recordings list to its own JSON file, mirroring
/// `ConfigStore`'s load/save shape exactly (same directory, same atomic write via
/// `[.prettyPrinted, .sortedKeys]`).
enum LibraryStore {
    private static let videoExtensions: Set<String> = ["mov", "mp4", "m4v", "mkv", "avi"]

    static var libraryURL: URL {
        ConfigStore.configDirectory.appendingPathComponent("library.json")
    }

    static func load() -> [RecordingMetadata] {
        guard let data = try? Data(contentsOf: libraryURL),
              let decoded = try? JSONDecoder().decode([RecordingMetadata].self, from: data) else {
            return []
        }
        return decoded
    }

    static func save(_ items: [RecordingMetadata]) {
        do {
            try FileManager.default.createDirectory(at: ConfigStore.configDirectory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(items)
            try data.write(to: libraryURL, options: .atomic)
        } catch {
            NSLog("RecBar: failed to write library.json: \(error)")
        }
    }

    /// Called the instant a kept recording finishes (`AppState.stop(discard:)`) — the
    /// primary way entries are created, rather than waiting for the Library window's own
    /// folder scan to notice a new file. No-ops if this path is already tracked.
    static func registerCompletedRecording(path: String, mode: RecordingMode) {
        var items = load()
        guard !items.contains(where: { $0.lastKnownLocalPath == path }) else { return }
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value
        items.append(RecordingMetadata(
            id: UUID(), category: mode, fileName: (path as NSString).lastPathComponent,
            lastKnownLocalPath: path, sizeBytes: size,
            createdAtEpoch: Int(Date().timeIntervalSince1970)
        ))
        save(items)
    }

    /// Run whenever the Library window is open: finds recordings on disk with no tracked
    /// entry yet (pre-existing files, or a mode never opened in the Library before) and
    /// registers them, then reconciles every existing entry against what's actually still on
    /// disk. A file that's gone locally and never had a cloud link created for it just
    /// disappears entirely (nothing worth keeping); a file that's gone locally but does have
    /// a live cloud link keeps its entry — cloud-only from here on, per the app's spec that a
    /// share link, once created, always remains accessible regardless of the local copy.
    static func reconcile(config: RecBarConfig) -> [RecordingMetadata] {
        var items = load()
        let knownPaths = Set(items.compactMap(\.lastKnownLocalPath))

        for mode in RecordingMode.allCases {
            let folder = mode.config(config).saveFolder
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: folder) else { continue }
            for name in entries {
                guard videoExtensions.contains((name as NSString).pathExtension.lowercased()) else { continue }
                let path = (folder as NSString).appendingPathComponent(name)
                guard !knownPaths.contains(path) else { continue }
                let attrs = try? FileManager.default.attributesOfItem(atPath: path)
                let size = (attrs?[.size] as? NSNumber)?.int64Value
                let created = (attrs?[.creationDate] as? Date).map { Int($0.timeIntervalSince1970) }
                    ?? Int(Date().timeIntervalSince1970)
                items.append(RecordingMetadata(
                    id: UUID(), category: mode, fileName: name, lastKnownLocalPath: path,
                    sizeBytes: size, createdAtEpoch: created
                ))
            }
        }

        items = items.compactMap { item -> RecordingMetadata? in
            guard let path = item.lastKnownLocalPath else { return item }
            if FileManager.default.fileExists(atPath: path) { return item }
            guard item.cloudWebUrl != nil else { return nil } // never made it to the cloud
            var gone = item
            gone.lastKnownLocalPath = nil
            return gone
        }

        items.sort { $0.createdAtEpoch > $1.createdAtEpoch }
        save(items)
        return items
    }

    static func update(_ item: RecordingMetadata) {
        var items = load()
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index] = item
        save(items)
    }
}
