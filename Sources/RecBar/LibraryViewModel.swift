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
    @Published private(set) var quota: OneDriveClient.DriveQuota?
    @Published private(set) var account: OneDriveClient.DriveAccount?
    @Published private(set) var isSignedIn = false
    @Published var signInPrompt: DeviceCodeResponse?
    @Published var signInError: String?

    /// Whether OneDrive is usable at all — an empty `clientId` means there's no app registration
    /// configured, so the cloud menu shows a "set clientId" hint rather than sign-in controls.
    var isCloudConfigured: Bool { !config.oneDrive.clientId.isEmpty }

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
        resumeInterruptedUploads()
        refreshQuota()
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

    /// Any recording persisted as mid-upload (`.creatingLink`/`.uploading`) can only have gotten
    /// there in a *previous* app session — an in-flight upload lives in an in-memory `Task`
    /// (`uploadTasks`) that can't survive a relaunch or a quit/crash/computer-restart mid-upload.
    /// Rather than giving up on it, automatically pick it back up on launch: `runUpload` reuses
    /// the persisted upload session (`cloudUploadUrl`) and `OneDriveClient.uploadFile` resumes
    /// from the byte OneDrive last received, so progress genuinely survives a restart (and falls
    /// back to restarting from byte 0 only if the server-side session has expired). Any
    /// placeholder+link already created (`cloudItemId`/`cloudWebUrl`) is preserved so the same
    /// share link stays valid. Called after `reconcile()` so `items` is populated first — the
    /// resume Task reads the entry out of `items` (see `runUpload`).
    ///
    /// The one unresumable case is a local file that's since gone missing: nothing to upload, so
    /// surface it as `.failed` (which unblocks the row's rename/move/delete and shows a retry).
    private func resumeInterruptedUploads() {
        for item in items
        where item.cloudUploadState == .uploading || item.cloudUploadState == .creatingLink {
            // Don't disturb an upload already running in this session — `start()` re-runs every
            // time the Library window is reopened, but the live `Task` (and its progress) persist
            // in this `@StateObject` across close/reopen. Only pick up genuinely orphaned ones.
            guard uploadTasks[item.id] == nil else { continue }
            guard let path = item.lastKnownLocalPath,
                  FileManager.default.fileExists(atPath: path) else {
                var failed = item
                failed.cloudUploadState = .failed
                failed.cloudErrorMessage = "Upload interrupted and the local file is missing."
                updateItem(failed)
                continue
            }
            uploadTasks[item.id]?.cancel()
            uploadTasks[item.id] = Task { [weak self] in
                await self?.runUpload(itemId: item.id, localPath: path)
            }
        }
    }

    /// Reloads the tracked-recordings list from disk every 4s (see `start()`) — but an item
    /// actively uploading only has its `cloudBytesSent` progress updated in memory (see
    /// `updateProgress`), never persisted per-chunk, so a naive full overwrite here would stomp
    /// the live, smoothly-climbing progress bar with the stale `cloudBytesSent` still on disk
    /// from when the upload started, every single tick — confirmed real-usage report
    /// (2026-09-11): the progress bar visibly jumped back to 0 every ~4s during an upload,
    /// then climbed again until the next tick. Fixed by keeping the in-memory item as-is for
    /// anything still `.uploading` rather than replacing it with the freshly-loaded disk copy;
    /// once it settles to `.uploaded`/`.failed` (which *is* persisted immediately via
    /// `updateItem`), the disk copy already matches and reconcile proceeds normally.
    func reconcile() {
        let fresh = LibraryStore.reconcile(config: config)
        let liveUploading = Dictionary(
            uniqueKeysWithValues: items.filter { $0.cloudUploadState == .uploading }.map { ($0.id, $0) }
        )
        items = fresh.map { liveUploading[$0.id] ?? $0 }
    }

    // MARK: - Rename

    /// Renames both copies when both exist — if the local file is already gone, only the
    /// cloud item (if any) is renamed, per the app's spec.
    ///
    /// Refuses while a cloud upload is in flight (`.creatingLink`/`.uploading`) — root cause
    /// of a real stuck-upload bug (2026-09-14): `startCloudUpload` snapshots `lastKnownLocalPath`
    /// once into a detached `Task`, and `OneDriveClient.uploadFile` doesn't open the file
    /// (`FileHandle(forReadingFrom:)`) until after a couple of network round-trips
    /// (`ensureFolder`/`createPlaceholderAndLink`/`createUploadSession`) — a rename landing in
    /// that window moves the file out from under the snapshot, so the eventual `FileHandle`
    /// open fails with "file doesn't exist" and the upload dies. Worse, since the rename
    /// changes `lastKnownLocalPath` on the *existing* tracked entry, the next `reconcile()`
    /// folder-scan sees the new filename as untracked and creates a second, brand-new entry
    /// for the same physical recording — leaving one dead entry (stale path, failed upload)
    /// and one live one. See `moveToFolder`/`FilePromiseDragHandle` for the same hazard.
    func rename(_ item: RecordingMetadata, to newBaseName: String) {
        guard item.cloudUploadState != .creatingLink, item.cloudUploadState != .uploading else { return }
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
        // Same stale-path-during-upload hazard as `rename` above — refuse while in flight.
        guard item.cloudUploadState != .creatingLink, item.cloudUploadState != .uploading else { return }
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

    // MARK: - Delete / restore
    //
    // Deleting is per-side (local vs. cloud), not per-entry: an entry only actually
    // disappears once *both* sides are gone. Losing just one side leaves the entry around in
    // a "restorable" state — cloud-only (offer to download back to disk) or local-only after
    // a cloud delete (the existing upload button already serves as "restore to cloud", no
    // separate action needed for that direction).

    /// Moves the local file to the Trash (reversible via macOS's own Trash, not a hard
    /// delete) and drops `lastKnownLocalPath`. If there's no cloud copy either, nothing is
    /// left worth tracking and the entry is removed outright; otherwise it becomes a
    /// cloud-only entry, restorable via `restoreLocal`.
    func deleteLocal(_ item: RecordingMetadata) {
        guard let path = item.lastKnownLocalPath else { return }
        do {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
        } catch {
            NSLog("RecBar: failed to trash local file \(path): \(error)")
            return
        }
        var updated = item
        updated.lastKnownLocalPath = nil
        if updated.cloudWebUrl == nil {
            items.removeAll { $0.id == item.id }
            LibraryStore.remove(id: item.id)
        } else {
            updateItem(updated)
        }
    }

    /// Deletes the cloud copy via Graph and clears its cloud fields. If there's no local copy
    /// either (this was a cloud-only entry), nothing is left worth tracking and the entry is
    /// removed outright; otherwise it becomes a local-only entry, whose existing upload
    /// button already serves as "restore to cloud".
    func deleteCloud(_ item: RecordingMetadata) {
        guard let itemId = item.cloudItemId else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.client.delete(itemId: itemId, auth: self.auth)
                await MainActor.run {
                    guard var current = self.items.first(where: { $0.id == item.id }) else { return }
                    current.cloudUploadState = .none
                    current.cloudItemId = nil
                    current.cloudWebUrl = nil
                    current.cloudBytesSent = 0
                    current.cloudErrorMessage = nil
                    current.cloudUploadUrl = nil
                    if current.lastKnownLocalPath == nil {
                        self.items.removeAll { $0.id == item.id }
                        LibraryStore.remove(id: item.id)
                    } else {
                        self.updateItem(current)
                    }
                    self.refreshQuota() // bytes freed on the cloud — update free space
                }
            } catch {
                NSLog("RecBar: failed to delete cloud item \(itemId): \(error)")
                await MainActor.run { self.signInError = "Failed to delete from OneDrive: \(error.localizedDescription)" }
            }
        }
    }

    /// Restores a cloud-only entry (local copy previously deleted) back onto disk by
    /// downloading it from OneDrive into its category's save folder.
    func restoreLocal(_ item: RecordingMetadata) {
        guard item.lastKnownLocalPath == nil, let itemId = item.cloudItemId else { return }
        let saveFolder = item.category.config(config).saveFolder
        let destinationPath = (saveFolder as NSString).appendingPathComponent(item.fileName)
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.client.downloadFile(itemId: itemId, to: destinationPath, auth: self.auth)
                await MainActor.run {
                    guard var current = self.items.first(where: { $0.id == item.id }) else { return }
                    current.lastKnownLocalPath = destinationPath
                    let attrs = try? FileManager.default.attributesOfItem(atPath: destinationPath)
                    current.sizeBytes = (attrs?[.size] as? NSNumber)?.int64Value
                    self.updateItem(current)
                }
            } catch {
                NSLog("RecBar: failed to restore \(item.fileName) from OneDrive: \(error)")
                await MainActor.run { self.signInError = "Failed to restore from OneDrive: \(error.localizedDescription)" }
            }
        }
    }

    // MARK: - Cloud quota

    /// Refreshes the signed-in OneDrive's storage picture. Only runs when there's actually a
    /// usable sign-in (clientId configured + a stored refresh token) — otherwise it would either
    /// fail immediately or, worse, pop a device-code sign-in sheet just from opening the Library,
    /// which the user never asked for. Transient failures are swallowed quietly (the existing
    /// quota reading just stays stale) rather than surfaced as an error; this is ambient info,
    /// not an action the user is waiting on.
    func refreshQuota() {
        isSignedIn = auth.isSignedIn
        guard isCloudConfigured, auth.isSignedIn else {
            quota = nil
            account = nil
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                let info = try await self.client.getDriveInfo(auth: self.auth)
                await MainActor.run {
                    self.quota = info.quota
                    self.account = info.account
                }
            } catch {
                NSLog("RecBar: failed to fetch OneDrive drive info: \(error)")
            }
        }
    }

    /// Signs out of the current OneDrive account (drops the stored refresh token) and clears the
    /// cached quota/account so the UI reflects it immediately. Existing recordings and their
    /// already-created share links are untouched — this only forgets the credential.
    func signOutOfCloud() {
        auth.signOut()
        isSignedIn = false
        quota = nil
        account = nil
    }

    /// Starts an interactive device-code sign-in (the same sheet an upload triggers), then
    /// refreshes the account/quota once it completes. Used by the "Sign In" menu action so the
    /// user can sign in from the Library without having to kick off an upload first.
    func signInToCloud() {
        guard isCloudConfigured else {
            signInError = "Set oneDrive.clientId in config.json first — see README for setup steps."
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.signIn()
                self.refreshQuota()
            } catch {
                if Task.isCancelled { return }
                self.signInError = "OneDrive sign-in failed: \(error.localizedDescription)"
            }
        }
    }

    /// Switches which OneDrive account recordings upload into: forgets the current credential,
    /// then immediately starts a fresh sign-in so the user can pick a different account. The
    /// Microsoft sign-in page may still remember the old account — signing out there, or picking
    /// "Use another account", is what actually changes it.
    func switchCloudAccount() {
        signOutOfCloud()
        signInToCloud()
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

    /// Aborts an in-flight upload the user changed their mind about, and best-effort deletes
    /// the cloud placeholder created for it so no orphaned link/tiny file is left behind, then
    /// resets the entry to `.none` so the row shows the plain upload button again — ready to
    /// re-upload later if wanted. The in-flight `runUpload`'s awaited network call throws on
    /// task cancellation, but its catch ignores cancellation (see there) so it doesn't race
    /// this reset back to `.failed`.
    func cancelUpload(_ item: RecordingMetadata) {
        uploadTasks[item.id]?.cancel()
        uploadTasks[item.id] = nil

        if let cloudItemId = item.cloudItemId {
            let client = self.client
            let auth = self.auth
            Task { try? await client.delete(itemId: cloudItemId, auth: auth) }
        }

        guard var current = items.first(where: { $0.id == item.id }) else { return }
        current.cloudUploadState = .none
        current.cloudItemId = nil
        current.cloudWebUrl = nil
        current.cloudBytesSent = 0
        current.cloudErrorMessage = nil
        current.cloudUploadUrl = nil
        updateItem(current)
    }

    private func runUpload(itemId: UUID, localPath: String) async {
        guard let existing = items.first(where: { $0.id == itemId }) else { return }
        // A resume already has its placeholder+link, so jump straight to `.uploading` rather than
        // flashing `.creatingLink`; a fresh start still has to create the link first.
        let resuming = existing.cloudItemId != nil && existing.cloudWebUrl != nil
        setState(itemId, resuming ? .uploading : .creatingLink)
        do {
            if !auth.isSignedIn {
                try await signIn()
            }
            guard var item = items.first(where: { $0.id == itemId }) else { return }

            let fileName = (localPath as NSString).lastPathComponent
            // Reuse the existing cloud item + link if one was already created (a retry, or an
            // interrupted upload resumed on launch): `createUploadSession` is scoped to that
            // same id, so the already-shown share link stays valid — rather than orphaning it
            // and minting a fresh placeholder+link on every retry.
            let uploadItemId: String
            if let existingItemId = item.cloudItemId, item.cloudWebUrl != nil {
                uploadItemId = existingItemId
            } else {
                let folderId = try await client.ensureFolder(
                    rootName: config.oneDrive.rootFolderName,
                    categoryName: item.category.title, auth: auth
                )
                let created = try await client.createPlaceholderAndLink(
                    fileName: fileName, folderId: folderId, auth: auth
                )
                item.cloudItemId = created.itemId
                item.cloudWebUrl = created.webUrl
                uploadItemId = created.itemId
            }
            item.cloudUploadState = .uploading
            item.cloudErrorMessage = nil
            updateItem(item)

            try await client.uploadFile(
                itemId: uploadItemId, localPath: localPath, auth: auth,
                resumeUploadUrl: item.cloudUploadUrl,
                onSession: { [weak self] url in
                    Task { @MainActor in self?.persistUploadUrl(itemId, url: url) }
                },
                onProgress: { [weak self] sent, _ in
                    Task { @MainActor in self?.updateProgress(itemId, sent: sent) }
                }
            )

            guard var finished = items.first(where: { $0.id == itemId }) else { return }
            finished.cloudUploadState = .uploaded
            finished.cloudUploadUrl = nil // session consumed; nothing left to resume
            updateItem(finished)
            refreshQuota() // a whole recording's worth of bytes just landed — update free space

        } catch {
            // A user-initiated cancel (see `cancelUpload`) cancels this task, which surfaces
            // here as a thrown error — but cancelUpload already reset the entry to `.none`, so
            // don't clobber that back to `.failed`.
            if Task.isCancelled { return }
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

    /// Chunk-level progress: updates the in-memory published list for a live progress bar and
    /// persists the byte count to disk each chunk, so a relaunch/restart can show roughly where
    /// the upload left off before the resume's `nextExpectedRanges` query (the authoritative
    /// offset) lands. The per-chunk disk write is cheap (8 MiB per write on a tiny JSON file) and
    /// no longer "wasted" now that uploads actually resume. reconcile's `liveUploading` guard
    /// still protects the smoothly-climbing in-memory bar from being stomped by a stale disk read.
    private func updateProgress(_ id: UUID, sent: Int64) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].cloudBytesSent = sent
        LibraryStore.update(items[index])
    }

    /// Persists the resumable upload-session URL the moment `OneDriveClient` creates one, so an
    /// interruption at any point after this can resume from the server's next-expected byte
    /// rather than starting the upload over (see `resumeInterruptedUploads`).
    private func persistUploadUrl(_ id: UUID, url: String) {
        guard var item = items.first(where: { $0.id == id }) else { return }
        item.cloudUploadUrl = url
        updateItem(item)
    }

    private func updateItem(_ item: RecordingMetadata) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index] = item
        LibraryStore.update(item)
    }
}
