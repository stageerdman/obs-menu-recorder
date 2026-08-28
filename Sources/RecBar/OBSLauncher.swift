import AppKit

/// Launches OBS hidden when RecBar needs it and isn't already running. RecBar never quits OBS
/// itself (see CLAUDE.md's launch/quit crash investigation — quitting OBS was found to
/// reliably trigger a pre-existing OBS Studio crash, so RecBar no longer attempts it at all;
/// the user quits OBS manually when they're done).
@MainActor
final class OBSLauncher {
    static let bundleIdentifier = "com.obsproject.obs-studio"

    /// Non-nil only while RecBar is holding an OBS instance it launched this session.
    private(set) var launchedApp: NSRunningApplication?

    func isOBSRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier).isEmpty
    }

    /// No-ops if OBS is already running, so RecBar never claims ownership of a pre-existing
    /// instance. `--minimize-to-tray` plus `activates = false` keeps it from stealing focus;
    /// `.hide()` afterwards is a backup in case that alone doesn't fully hide it — though
    /// neither reliably hides OBS's own "did not shut down properly, start in Safe Mode?"
    /// prompt if OBS's last exit wasn't clean (see CLAUDE.md's launch/quit crash investigation
    /// — there's no supported OBS CLI flag to suppress that dialog; `--safe-mode` exists but
    /// would disable the websocket plugin RecBar depends on, so it isn't usable here). Since
    /// OBS has no Dock icon while hidden this way, a dialog blocking startup would otherwise be
    /// completely invisible to the user — see `bringToForegroundIfLaunchedByUs()`, called from
    /// AppState when the connect wait times out, specifically to surface it.
    func launchHiddenIfNeeded() async throws {
        guard !isOBSRunning() else { return }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleIdentifier) else {
            throw simpleError("OBS.app isn't installed (bundle id \(Self.bundleIdentifier) not found)")
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.arguments = ["--minimize-to-tray"]

        let app = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        app.hide()
        launchedApp = app
    }

    /// Un-hides and activates the OBS instance RecBar itself launched this session, if any —
    /// used when the websocket connect wait times out, so a hidden Safe Mode dialog (the most
    /// common cause of that timeout) actually becomes visible instead of blocking forever with
    /// no way for the user to know it's there. No-ops if RecBar didn't launch this session's
    /// instance (nothing to safely surface) or if it already exited.
    func bringToForegroundIfLaunchedByUs() {
        guard let app = launchedApp, !app.isTerminated else { return }
        app.unhide()
        app.activate()
    }

    private func simpleError(_ message: String) -> Error {
        NSError(domain: "RecBar.OBSLauncher", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
