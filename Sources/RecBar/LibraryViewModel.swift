import Foundation
import AppKit
import Combine

/// Drives the Library window: owns the tracked-recordings list, periodic filesystem
/// reconciliation (mirrors AppState's own Timer-based tick — there's no FSEvents/
/// DispatchSource infra anywhere in this codebase, and a plain repeating Timer is the
/// established idiom here), renames, local moves, and orchestrates OneDrive uploads via
/// OneDriveAuth/OneDriveClient. Kept separate from AppState — cloud/library concerns don't
/// belong in the single most complex existing type, matching the existing separation of
/// OBSClient/MicrophonePriority/OBSLauncher/WatchdogNotifier as distinct collaborators.
@MainActor
final class LibraryViewModel: ObservableObject {
    @Published private(set) var items: [RecordingMetadata] = []
    @Published var signInPrompt: DeviceCodeResponse?
    @Published var signInError: String?

    private let config: RecBarConfig
    private let auth = OneDriveAuth()
    private let client = OneDriveClient()
    private var timer: Timer?
    private var uploadTasks: [UUID: Task<Void, Never>] = [:]

    init(config: RecBarConfig) {
        self.config = config
        auth.clientId = config.oneDrive.clientId
    }

    func start() {
        reconcile()
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reconcile() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func reconcile() {
        items = LibraryStore.reconcile(config: config)
    }

    // MARK: - Rename

    /// Renames both copies when both exist — if the local file is already gone, only the
    /// cloud item (if any) is renamed, per the app's spec.
    func rename(_ item: RecordingMetadata, to newBaseName: String) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        var updated = items[index]
        let ext = (updated.fileName as NSString).pathExtension
        let newName = ext.isEmpty ? newBaseName : "\(newBaseName).\(ext)"
        guard newName != updated.fileName else { return }

        if let path = updated.lastKnownLocalPath {
            let newPath = ((path as NSString).deletingLastPathComponent as NSString).appendingPathComponent(newName)
            do {
                try FileManager.default.moveItem(atPath: path, toPath: newPath)
                updated.lastKnownLocalPath = newPath
            } catch {
                NSLog("RecBar: failed to rename local file \(path): \(error)")
                return
            }
        }
        updated.fileName = newName
        items[index] = updated
        LibraryStore.update(updated)

        if let itemId = updated.cloudItemId {
            let client = self.client
            let auth = self.auth
            Task {
                do {
                    try await client.rename(itemId: itemId, newName: newName, auth: auth)
                } catch {
                    NSLog("RecBar: failed to rename cloud item: \(error)")
                }
            }
        }
    }

    // MARK: - Local move / reveal

    func revealInFinder(_ item: RecordingMetadata) {
        guard let path = item.lastKnownLocalPath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    /// "Move to Folder…" — a guaranteed-reliable fallback alongside real Finder drag-out (see
    /// FilePromiseDragHandle), kept because this dev environment has no way to visually
    /// exercise drag-and-drop.
    func moveToFolder(_ item: RecordingMetadata) {
        guard let path = item.lastKnownLocalPath else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Move Here"
        guard panel.runModal() == .OK, let destinationFolder = panel.url else { return }
        let destination = destinationFolder.appendingPathComponent((path as NSString).lastPathComponent)
        do {
            try FileManager.default.moveItem(atPath: path, toPath: destination.path)
            reconcile()
        } catch {
            NSLog("RecBar: failed to move \(path) to \(destination.path): \(error)")
        }
    }

    /// Called after a real Finder drag-out (`FilePromiseDragHandle`) completes — the app
    /// doesn't need to know *where* the file went, only that it's no longer at its origin
    /// path, which the ordinary reconcile pass already handles.
    func fileMovedOut() {
        reconcile()
    }

    // MARK: - Cloud upload

    func startCloudUpload(for item: RecordingMetadata) {
        guard item.cloudUploadState == .none || item.cloudUploadState == .failed else { return }
        guard let path = item.lastKnownLocalPath else { return }
        guard !config.oneDrive.clientId.isEmpty else {
            signInError = "Set oneDrive.clientId in config.json first — see README for setup steps."
            return
        }

        uploadTasks[item.id]?.cancel()
        uploadTasks[item.id] = Task { [weak self] in
            await self?.runUpload(itemId: item.id, localPath: path)
        }
    }

    private func runUpload(itemId: UUID, localPath: String) async {
        setState(itemId, .creatingLink)
        do {
            if !auth.isSignedIn {
                try await signIn()
            }
            guard var item = items.first(where: { $0.id == itemId }) else { return }

            let fileName = (localPath as NSString).lastPathComponent
            let folderId = try await client.ensureFolder(
                rootName: config.oneDrive.rootFolderName,
                categoryName: item.category.title, auth: auth
            )
            let created = try await client.createPlaceholderAndLink(
                fileName: fileName, folderId: folderId, auth: auth
            )
            item.cloudItemId = created.itemId
            item.cloudWebUrl = created.webUrl
            item.cloudUploadState = .uploading
            item.cloudBytesSent = 0
            updateItem(item)

            try await client.uploadFile(itemId: created.itemId, localPath: localPath, auth: auth) { [weak self] sent, _ in
                Task { @MainActor in self?.updateProgress(itemId, sent: sent) }
            }

            guard var finished = items.first(where: { $0.id == itemId }) else { return }
            finished.cloudUploadState = .uploaded
            updateItem(finished)
        } catch {
            NSLog("RecBar: OneDrive upload failed: \(error)")
            setState(itemId, .failed, error: error.localizedDescription)
        }
    }

    private func signIn() async throws {
        let device = try await auth.requestDeviceCode()
        signInPrompt = device
        defer { signInPrompt = nil }
        try await auth.pollForToken(device)
    }

    private func setState(_ id: UUID, _ state: CloudUploadState, error: String? = nil) {
        guard var item = items.first(where: { $0.id == id }) else { return }
        item.cloudUploadState = state
        item.cloudErrorMessage = error
        updateItem(item)
    }

    /// Chunk-level progress: updates the in-memory published list every chunk for a live
    /// progress bar, but only persists to disk on state transitions (see `updateItem`) — a
    /// resumed upload after relaunch restarts from scratch anyway (see OneDriveClient), so
    /// per-chunk disk writes here would just be wasted IO.
    private func updateProgress(_ id: UUID, sent: Int64) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].cloudBytesSent = sent
    }

    private func updateItem(_ item: RecordingMetadata) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index] = item
        LibraryStore.update(item)
    }
}
