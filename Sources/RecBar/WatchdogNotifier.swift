import UserNotifications

/// Posts the silence watchdog's "Are you there?" prompt and its auto-stop confirmation as
/// macOS user notifications, so the prompt reaches the user even when the popover is closed.
/// Tapping the notification (or its "I'm here" action) counts as a presence confirmation,
/// mirroring the inline popover button.
@MainActor
final class WatchdogNotifier: NSObject, UNUserNotificationCenterDelegate {
    private nonisolated static let promptCategoryID = "RECBAR_WATCHDOG_PROMPT"
    private nonisolated static let confirmActionID = "RECBAR_WATCHDOG_CONFIRM"
    private nonisolated static let promptRequestID = "RecBar.watchdog.prompt"
    private nonisolated static let autoStoppedRequestID = "RecBar.watchdog.autostopped"

    /// Wired to AppState.confirmPresence() at init.
    var onConfirm: (() -> Void)?

    override init() {
        super.init()
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }

        let confirmAction = UNNotificationAction(identifier: Self.confirmActionID, title: "I'm here", options: [])
        let category = UNNotificationCategory(
            identifier: Self.promptCategoryID, actions: [confirmAction], intentIdentifiers: [], options: []
        )
        center.setNotificationCategories([category])
    }

    func postPrompt(responseWindowSeconds: TimeInterval) {
        let content = UNMutableNotificationContent()
        content.title = "Are you there?"
        content.body = "No mic activity detected. Recording auto-stops in \(Int(responseWindowSeconds))s unless you confirm."
        content.categoryIdentifier = Self.promptCategoryID
        content.sound = .default
        let request = UNNotificationRequest(identifier: Self.promptRequestID, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func clearPrompt() {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [Self.promptRequestID])
        center.removePendingNotificationRequests(withIdentifiers: [Self.promptRequestID])
    }

    func postAutoStopped() {
        let content = UNMutableNotificationContent()
        content.title = "Recording stopped"
        content.body = "RecBar auto-stopped the recording after sustained mic silence. The file was kept."
        content.sound = .default
        let request = UNNotificationRequest(identifier: Self.autoStoppedRequestID, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if response.notification.request.identifier == Self.promptRequestID {
            Task { @MainActor in self.onConfirm?() }
        }
        completionHandler()
    }
}
