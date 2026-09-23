import Foundation

/// Hand-rolled Microsoft Graph client for the OneDrive "create a link immediately, then
/// upload the real content into the same item" flow described in CLAUDE.md. No third-party
/// SDK (no MSAL/Graph SDK) — same zero-dependency ethos as OBSClient.swift's own hand-rolled
/// obs-websocket protocol.
///
/// Not yet verified end-to-end against a real Microsoft account (no GUI automation available
/// in this dev environment — see CLAUDE.md's "Testing notes") — needs a real walkthrough with
/// the user once an Azure app registration + config.json clientId exist.
final class OneDriveClient {
    enum GraphError: Error, LocalizedError {
        case requestFailed(Int, String)
        case malformedResponse

        var errorDescription: String? {
            switch self {
            case .requestFailed(let code, let body): return "OneDrive request failed (\(code)): \(body)"
            case .malformedResponse: return "OneDrive sent a malformed response."
            }
        }
    }

    private static let base = "https://graph.microsoft.com/v1.0"
    /// Each chunk must be a multiple of 320 KiB except the final one — 8 MiB is comfortably
    /// inside that requirement and keeps memory flat for multi-GB recordings via FileHandle.
    private static let chunkSize: Int64 = 8 * 1024 * 1024

    /// A large recording is hundreds of chunks; a slow residential upstream drops/stalls/
    /// throttles at least one of them often enough that "one blip kills the whole upload" made
    /// multi-GB files rarely finish (real-usage failures: network-connection-lost, timed-out,
    /// cannot-parse-response — all mid-upload, all NSURLError-class transients). So each chunk
    /// tolerates this many *consecutive* failures (reset to 0 on any success) before the whole
    /// upload gives up — enough to ride out a transient outage without masking a genuinely dead
    /// connection or an unrecoverable client error.
    private static let maxChunkRetries = 5

    /// Dedicated session rather than `URLSession.shared` specifically because of the chunk PUTs
    /// in `uploadFile`: shared's default `timeoutIntervalForRequest` is 60s, so any 8 MiB chunk
    /// that can't finish within a minute (a residential upstream slower than ~1.1 Mbps, or a
    /// brief stall) threw `NSURLErrorTimedOut` and failed the whole upload. 300s gives each chunk
    /// ample room; `timeoutIntervalForResource` caps a full multi-GB upload at a sane ceiling.
    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 300
        cfg.timeoutIntervalForResource = 6 * 60 * 60
        return URLSession(configuration: cfg)
    }()

    /// Resolves (creating if needed) `{rootName}/{categoryName}` in the user's OneDrive,
    /// returning the category subfolder's item id. Not cached to disk — a user renaming/
    /// moving the OneDrive folder externally shouldn't leave a stale id behind across relaunches.
    func ensureFolder(rootName: String, categoryName: String, auth: OneDriveAuth) async throws -> String {
        let rootId = try await ensureChildFolder(name: rootName, parentPath: "root", auth: auth)
        return try await ensureChildFolder(name: categoryName, parentPath: "items/\(rootId)", auth: auth)
    }

    private func ensureChildFolder(name: String, parentPath: String, auth: OneDriveAuth) async throws -> String {
        let token = try await auth.validAccessToken()
        let encodedName = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name

        var getRequest = URLRequest(url: URL(string: "\(Self.base)/me/drive/\(parentPath):/\(encodedName)")!)
        getRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (getData, getResponse) = try await session.data(for: getRequest)
        if (getResponse as? HTTPURLResponse)?.statusCode == 200,
           let json = try? JSONSerialization.jsonObject(with: getData) as? [String: Any],
           let id = json["id"] as? String {
            return id
        }

        var createRequest = URLRequest(url: URL(string: "\(Self.base)/me/drive/\(parentPath)/children")!)
        createRequest.httpMethod = "POST"
        createRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        createRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        createRequest.httpBody = try JSONSerialization.data(withJSONObject: [
            "name": name, "folder": [String: String](), "@microsoft.graph.conflictBehavior": "rename"
        ])
        let (createData, createResponse) = try await session.data(for: createRequest)
        guard let status = (createResponse as? HTTPURLResponse)?.statusCode, (200...201).contains(status),
              let json = try? JSONSerialization.jsonObject(with: createData) as? [String: Any],
              let id = json["id"] as? String else {
            throw GraphError.requestFailed((createResponse as? HTTPURLResponse)?.statusCode ?? -1,
                                            String(data: createData, encoding: .utf8) ?? "")
        }
        return id
    }

    /// Creates a small placeholder in `folderId` and an anonymous view-only sharing link for
    /// it, returning (itemId, webUrl) — the link is valid and copyable immediately, before any
    /// of the real video's bytes are uploaded.
    func createPlaceholderAndLink(fileName: String, folderId: String, auth: OneDriveAuth) async throws -> (itemId: String, webUrl: String) {
        let token = try await auth.validAccessToken()
        let encodedName = fileName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? fileName

        var uploadRequest = URLRequest(url: URL(string: "\(Self.base)/me/drive/items/\(folderId):/\(encodedName):/content")!)
        uploadRequest.httpMethod = "PUT"
        uploadRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        uploadRequest.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        uploadRequest.httpBody = Data("RecBar is uploading this recording…".utf8)
        let (data, response) = try await session.data(for: uploadRequest)
        guard let status = (response as? HTTPURLResponse)?.statusCode, (200...201).contains(status),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let itemId = json["id"] as? String else {
            throw GraphError.requestFailed((response as? HTTPURLResponse)?.statusCode ?? -1,
                                            String(data: data, encoding: .utf8) ?? "")
        }

        var linkRequest = URLRequest(url: URL(string: "\(Self.base)/me/drive/items/\(itemId)/createLink")!)
        linkRequest.httpMethod = "POST"
        linkRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        linkRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        linkRequest.httpBody = try JSONSerialization.data(withJSONObject: ["type": "view", "scope": "anonymous"])
        let (linkData, linkResponse) = try await session.data(for: linkRequest)
        guard let linkStatus = (linkResponse as? HTTPURLResponse)?.statusCode, (200...201).contains(linkStatus),
              let linkJson = try? JSONSerialization.jsonObject(with: linkData) as? [String: Any],
              let link = linkJson["link"] as? [String: Any],
              let webUrl = link["webUrl"] as? String else {
            throw GraphError.requestFailed((linkResponse as? HTTPURLResponse)?.statusCode ?? -1,
                                            String(data: linkData, encoding: .utf8) ?? "")
        }
        return (itemId, webUrl)
    }

    /// Replaces `itemId`'s content with the real file via a resumable upload session — scoping
    /// the session to the existing item (rather than creating a new one) is what keeps the
    /// same id, and therefore the sharing link already created for it, valid once this
    /// finishes. Reads via FileHandle so multi-GB recordings never load fully into memory.
    /// Deliberately doesn't try to resume an interrupted upload across app relaunches (Graph's
    /// upload-session validity window isn't something to bet on with confidence) — a relaunch
    /// mid-upload just restarts this call from byte 0 against the same existing item id.
    func uploadFile(itemId: String, localPath: String, auth: OneDriveAuth,
                     onProgress: @escaping (Int64, Int64) -> Void) async throws {
        let token = try await auth.validAccessToken()
        var sessionRequest = URLRequest(url: URL(string: "\(Self.base)/me/drive/items/\(itemId)/createUploadSession")!)
        sessionRequest.httpMethod = "POST"
        sessionRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        sessionRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        sessionRequest.httpBody = try JSONSerialization.data(withJSONObject: [
            "item": ["@microsoft.graph.conflictBehavior": "replace"]
        ])
        let (sessionData, sessionResponse) = try await session.data(for: sessionRequest)
        guard (sessionResponse as? HTTPURLResponse)?.statusCode == 200,
              let sessionJson = try? JSONSerialization.jsonObject(with: sessionData) as? [String: Any],
              let uploadUrlString = sessionJson["uploadUrl"] as? String,
              let uploadUrl = URL(string: uploadUrlString) else {
            throw GraphError.requestFailed((sessionResponse as? HTTPURLResponse)?.statusCode ?? -1,
                                            String(data: sessionData, encoding: .utf8) ?? "")
        }

        let fileHandle = try FileHandle(forReadingFrom: URL(fileURLWithPath: localPath))
        defer { try? fileHandle.close() }
        let attrs = try? FileManager.default.attributesOfItem(atPath: localPath)
        let totalSize = (attrs?[.size] as? NSNumber)?.int64Value ?? 0

        var offset: Int64 = 0
        var consecutiveFailures = 0
        while offset < totalSize {
            try Task.checkCancellation()
            let end = min(offset + Self.chunkSize, totalSize) - 1
            try fileHandle.seek(toOffset: UInt64(offset))
            let chunk = try fileHandle.read(upToCount: Int(end - offset + 1)) ?? Data()

            do {
                // No Authorization header on chunk PUTs — the upload URL itself is pre-authenticated.
                var chunkRequest = URLRequest(url: uploadUrl)
                chunkRequest.httpMethod = "PUT"
                chunkRequest.setValue("bytes \(offset)-\(end)/\(totalSize)", forHTTPHeaderField: "Content-Range")
                let (_, chunkResponse) = try await session.upload(for: chunkRequest, from: chunk)
                let status = (chunkResponse as? HTTPURLResponse)?.statusCode ?? -1
                guard (200...202).contains(status) else {
                    throw GraphError.requestFailed(status, "chunk upload failed at byte \(offset)")
                }
                consecutiveFailures = 0
                offset = end + 1
                onProgress(offset, totalSize)
            } catch {
                // A cancel (user aborted the upload) must propagate, not be retried.
                if Task.isCancelled { throw error }
                // A 4xx other than 429 (throttling) is a genuine client error — bad token,
                // deleted item, malformed request — that re-sending can't fix, so fail fast
                // rather than burning the whole retry budget on it. Everything else (network
                // drops/timeouts, 5xx, 429) is a transient worth retrying.
                if case GraphError.requestFailed(let code, _) = error,
                   (400...499).contains(code), code != 429 {
                    throw error
                }
                consecutiveFailures += 1
                if consecutiveFailures > Self.maxChunkRetries { throw error }
                // Exponential backoff (capped at 30s), then resume from the byte OneDrive
                // actually still expects — a chunk may have been partially received before the
                // drop, so trusting the server's own offset beats blindly re-sending our last one.
                let delaySeconds = min(pow(2.0, Double(consecutiveFailures)), 30)
                try await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
                if let serverNext = await nextExpectedOffset(uploadUrl: uploadUrl) {
                    offset = serverNext
                    onProgress(offset, totalSize)
                }
            }
        }
    }

    /// Queries a resumable upload session for the next byte OneDrive still expects, so a retry
    /// after a mid-upload failure resumes from where the server actually left off (it may have
    /// partially received the chunk we were sending) instead of re-sending from our last offset.
    /// Returns nil if the session can't be queried — the caller then just retries the same offset.
    private func nextExpectedOffset(uploadUrl: URL) async -> Int64? {
        var request = URLRequest(url: uploadUrl)
        request.httpMethod = "GET"
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ranges = json["nextExpectedRanges"] as? [String],
              let firstStart = ranges.first?.split(separator: "-").first,
              let start = Int64(firstStart) else {
            return nil
        }
        return start
    }

    func rename(itemId: String, newName: String, auth: OneDriveAuth) async throws {
        let token = try await auth.validAccessToken()
        var request = URLRequest(url: URL(string: "\(Self.base)/me/drive/items/\(itemId)")!)
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["name": newName])
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200...201).contains(status) else {
            throw GraphError.requestFailed(status, String(data: data, encoding: .utf8) ?? "")
        }
    }

    /// Deletes the cloud item outright (moves it to the OneDrive recycle bin, same as deleting
    /// via the web UI — not a RecBar-side undo). 404 is treated as success: the item is already
    /// gone, which is the caller's desired end state either way.
    func delete(itemId: String, auth: OneDriveAuth) async throws {
        let token = try await auth.validAccessToken()
        var request = URLRequest(url: URL(string: "\(Self.base)/me/drive/items/\(itemId)")!)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200...299).contains(status) || status == 404 else {
            throw GraphError.requestFailed(status, String(data: data, encoding: .utf8) ?? "")
        }
    }

    /// Downloads a cloud item back to a local path — used to "restore" a cloud-only entry
    /// (local copy deleted, cloud copy still live) back onto disk. Streams straight to disk via
    /// `URLSession.download`, never loading a multi-GB recording fully into memory.
    func downloadFile(itemId: String, to destinationPath: String, auth: OneDriveAuth) async throws {
        let token = try await auth.validAccessToken()
        var request = URLRequest(url: URL(string: "\(Self.base)/me/drive/items/\(itemId)/content")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (tempURL, response) = try await session.download(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode, (200...299).contains(status) else {
            throw GraphError.requestFailed((response as? HTTPURLResponse)?.statusCode ?? -1, "download failed")
        }
        let destinationURL = URL(fileURLWithPath: destinationPath)
        try? FileManager.default.removeItem(at: destinationURL)
        try FileManager.default.moveItem(at: tempURL, to: destinationURL)
    }
}
