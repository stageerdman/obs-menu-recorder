import Foundation
import CryptoKit

/// Minimal obs-websocket v5 client over URLSessionWebSocketTask.
/// Handles the Hello/Identify handshake (with SHA256 challenge auth), request/response
/// correlation by requestId, and event dispatch. No third-party dependency.
final class OBSClient {
    enum ConnectionState: Equatable {
        case disconnected
        case connecting
        case connected
    }

    enum OBSError: Error, LocalizedError {
        case notConnected
        case requestFailed(comment: String, code: Int)
        case malformedResponse

        var errorDescription: String? {
            switch self {
            case .notConnected: return "Not connected to OBS."
            case .requestFailed(let comment, let code): return "OBS request failed (\(code)): \(comment)"
            case .malformedResponse: return "OBS sent a malformed response."
            }
        }
    }

    var onConnectionStateChanged: ((ConnectionState) -> Void)?
    /// eventType, eventData
    var onEvent: ((String, [String: Any]) -> Void)?

    private let host: String
    private let port: Int
    private let password: String

    private var session: URLSession
    private var task: URLSessionWebSocketTask?
    private var reconnectAttempt = 0
    private var wantsConnection = false

    private(set) var connectionState: ConnectionState = .disconnected {
        didSet {
            if oldValue != connectionState {
                let newValue = connectionState
                DispatchQueue.main.async { [weak self] in
                    self?.onConnectionStateChanged?(newValue)
                }
            }
        }
    }

    private var pendingRequests: [String: CheckedContinuation<[String: Any], Error>] = [:]
    private let queue = DispatchQueue(label: "com.recbar.obsclient")
    /// Guards pendingRequests, which is written from both the caller's thread (request(_:))
    /// and the URLSession delegate queue thread (handleRequestResponse/failAllPendingRequests).
    private let stateLock = NSLock()

    // eventSubscriptions bitmask: Outputs (1<<6) | InputVolumeMeters (1<<16)
    private static let eventSubscriptions: Int = (1 << 6) | (1 << 16)

    init(host: String, port: Int, password: String) {
        self.host = host
        self.port = port
        self.password = password
        self.session = URLSession(configuration: .default)
    }

    func connect() {
        wantsConnection = true
        guard connectionState == .disconnected else { return }
        openSocket()
    }

    func disconnectPermanently() {
        wantsConnection = false
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        connectionState = .disconnected
    }

    /// Skips the rest of the current backoff delay and tries connecting immediately. Used
    /// right after RecBar launches (or detects) an OBS instance, instead of waiting out
    /// whatever reconnect delay had already been building up.
    func reconnectNow() {
        guard wantsConnection, connectionState == .disconnected else { return }
        reconnectAttempt = 0
        openSocket()
    }

    private func openSocket() {
        guard let url = URL(string: "ws://\(host):\(port)") else { return }
        connectionState = .connecting
        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()
        receiveLoop(on: task)
    }

    private func receiveLoop(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure:
                self.handleDisconnect()
            case .success(let message):
                if case .string(let text) = message {
                    self.handleMessage(text)
                }
                // keep listening as long as this is still the active task
                if self.task === task {
                    self.receiveLoop(on: task)
                }
            }
        }
    }

    private func handleDisconnect() {
        let wasConnected = connectionState != .disconnected
        task = nil
        connectionState = .disconnected
        failAllPendingRequests(OBSError.notConnected)
        guard wantsConnection else { return }
        if wasConnected { reconnectAttempt = 0 }
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        reconnectAttempt += 1
        let delay = min(30.0, pow(2.0, Double(reconnectAttempt)))
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.wantsConnection, self.connectionState == .disconnected else { return }
            self.openSocket()
        }
    }

    private func failAllPendingRequests(_ error: Error) {
        stateLock.lock()
        let requests = pendingRequests
        pendingRequests.removeAll()
        stateLock.unlock()
        for (_, continuation) in requests {
            continuation.resume(throwing: error)
        }
    }

    // MARK: - Message handling

    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let op = json["op"] as? Int,
              let d = json["d"] as? [String: Any] else { return }

        switch op {
        case 0: handleHello(d)
        case 2: handleIdentified(d)
        case 5: handleEvent(d)
        case 7: handleRequestResponse(d)
        default: break
        }
    }

    private func handleHello(_ d: [String: Any]) {
        var identifyPayload: [String: Any] = [
            "rpcVersion": 1,
            "eventSubscriptions": Self.eventSubscriptions
        ]

        if let auth = d["authentication"] as? [String: Any],
           let challenge = auth["challenge"] as? String,
           let salt = auth["salt"] as? String {
            identifyPayload["authentication"] = Self.computeAuth(password: password, challenge: challenge, salt: salt)
        }

        send(op: 1, d: identifyPayload)
    }

    private func handleIdentified(_ d: [String: Any]) {
        reconnectAttempt = 0
        connectionState = .connected
    }

    private func handleEvent(_ d: [String: Any]) {
        guard let eventType = d["eventType"] as? String else { return }
        let eventData = d["eventData"] as? [String: Any] ?? [:]
        DispatchQueue.main.async { [weak self] in
            self?.onEvent?(eventType, eventData)
        }
    }

    private func handleRequestResponse(_ d: [String: Any]) {
        guard let requestId = d["requestId"] as? String else { return }
        stateLock.lock()
        let continuation = pendingRequests.removeValue(forKey: requestId)
        stateLock.unlock()
        guard let continuation else { return }

        let status = d["requestStatus"] as? [String: Any]
        let result = status?["result"] as? Bool ?? false
        if result {
            continuation.resume(returning: d["responseData"] as? [String: Any] ?? [:])
        } else {
            let comment = status?["comment"] as? String ?? "unknown error"
            let code = status?["code"] as? Int ?? -1
            continuation.resume(throwing: OBSError.requestFailed(comment: comment, code: code))
        }
    }

    // MARK: - Sending

    private func send(op: Int, d: [String: Any]) {
        let payload: [String: Any] = ["op": op, "d": d]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(text)) { _ in }
    }

    /// Sends a Request (op 6) and awaits its RequestResponse (op 7), correlated by requestId.
    @discardableResult
    func request(_ type: String, data: [String: Any] = [:]) async throws -> [String: Any] {
        guard connectionState == .connected else { throw OBSError.notConnected }

        let requestId = UUID().uuidString
        return try await withCheckedThrowingContinuation { continuation in
            stateLock.lock()
            pendingRequests[requestId] = continuation
            stateLock.unlock()
            var payload: [String: Any] = [
                "requestType": type,
                "requestId": requestId
            ]
            if !data.isEmpty { payload["requestData"] = data }
            send(op: 6, d: payload)
        }
    }

    private static func computeAuth(password: String, challenge: String, salt: String) -> String {
        let secretDigest = SHA256.hash(data: Data((password + salt).utf8))
        let secretBase64 = Data(secretDigest).base64EncodedString()
        let authDigest = SHA256.hash(data: Data((secretBase64 + challenge).utf8))
        return Data(authDigest).base64EncodedString()
    }

    // MARK: - High-level requests

    func setCurrentProgramScene(_ sceneName: String) async throws {
        try await request("SetCurrentProgramScene", data: ["sceneName": sceneName])
    }

    func setRecordDirectory(_ path: String) async throws {
        try await request("SetRecordDirectory", data: ["recordDirectory": path])
    }

    func setInputSettings(inputName: String, settings: [String: Any]) async throws {
        try await request("SetInputSettings", data: [
            "inputName": inputName,
            "inputSettings": settings,
            "overlay": true
        ])
    }

    func setInputMute(inputName: String, muted: Bool) async throws {
        try await request("SetInputMute", data: ["inputName": inputName, "inputMuted": muted])
    }

    func startRecord() async throws {
        try await request("StartRecord")
    }

    /// Returns the output file path if OBS reports one.
    @discardableResult
    func stopRecord() async throws -> String? {
        let response = try await request("StopRecord")
        return response["outputPath"] as? String
    }

    func pauseRecord() async throws {
        try await request("PauseRecord")
    }

    func resumeRecord() async throws {
        try await request("ResumeRecord")
    }

    struct RecordStatus {
        let active: Bool
        let paused: Bool
    }

    func getRecordStatus() async throws -> RecordStatus {
        let response = try await request("GetRecordStatus")
        return RecordStatus(
            active: response["outputActive"] as? Bool ?? false,
            paused: response["outputPaused"] as? Bool ?? false
        )
    }

    // MARK: - Idle-scene / camera-release requests

    func getSceneList() async throws -> [String] {
        let response = try await request("GetSceneList")
        let scenes = response["scenes"] as? [[String: Any]] ?? []
        return scenes.compactMap { $0["sceneName"] as? String }
    }

    func createScene(_ name: String) async throws {
        try await request("CreateScene", data: ["sceneName": name])
    }

    func getInputList() async throws -> [String] {
        let response = try await request("GetInputList")
        let inputs = response["inputs"] as? [[String: Any]] ?? []
        return inputs.compactMap { $0["inputName"] as? String }
    }

    func getInputSettings(inputName: String) async throws -> (kind: String, settings: [String: Any]) {
        let response = try await request("GetInputSettings", data: ["inputName": inputName])
        return (response["inputKind"] as? String ?? "", response["inputSettings"] as? [String: Any] ?? [:])
    }

    func removeInput(inputName: String) async throws {
        try await request("RemoveInput", data: ["inputName": inputName])
    }

    /// Returns the new scene item's ID.
    @discardableResult
    func createInput(sceneName: String, inputName: String, inputKind: String, settings: [String: Any]) async throws -> Int? {
        let response = try await request("CreateInput", data: [
            "sceneName": sceneName,
            "inputName": inputName,
            "inputKind": inputKind,
            "inputSettings": settings
        ])
        return response["sceneItemId"] as? Int
    }

    struct SceneItemInfo {
        let sceneItemId: Int
        let enabled: Bool
        let transform: [String: Any]
    }

    /// Finds a scene item by its source name. Returns nil if that source isn't in the scene.
    func findSceneItem(sceneName: String, sourceName: String) async throws -> SceneItemInfo? {
        let response = try await request("GetSceneItemList", data: ["sceneName": sceneName])
        let items = response["sceneItems"] as? [[String: Any]] ?? []
        guard let item = items.first(where: { ($0["sourceName"] as? String) == sourceName }),
              let id = item["sceneItemId"] as? Int else {
            return nil
        }
        return SceneItemInfo(
            sceneItemId: id,
            enabled: item["sceneItemEnabled"] as? Bool ?? true,
            transform: item["sceneItemTransform"] as? [String: Any] ?? [:]
        )
    }

    func setSceneItemEnabled(sceneName: String, sceneItemId: Int, enabled: Bool) async throws {
        try await request("SetSceneItemEnabled", data: [
            "sceneName": sceneName, "sceneItemId": sceneItemId, "sceneItemEnabled": enabled
        ])
    }

    func setSceneItemTransform(sceneName: String, sceneItemId: Int, transform: [String: Any]) async throws {
        try await request("SetSceneItemTransform", data: [
            "sceneName": sceneName, "sceneItemId": sceneItemId, "sceneItemTransform": transform
        ])
    }
}
