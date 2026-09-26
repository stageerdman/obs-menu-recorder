import SwiftUI
import AppKit

/// Owns the Library window as a plain AppKit `NSWindow` rather than a SwiftUI `Window` scene.
///
/// RecBar is normally a menu-bar-only app (`LSUIElement` / `.accessory` — no Dock icon). While
/// the Library window is open we switch to `.regular` so it gets a Dock icon and normal window
/// behaviour, and back to `.accessory` the moment it closes so that Dock icon disappears again,
/// leaving only the menu-bar item.
///
/// This used to be driven from `LibraryView`'s SwiftUI `onAppear`/`onDisappear` against a
/// `Window("Library", id:)` scene, but toggling the activation policy that way proved
/// unreliable across several attempts (real-usage reports, 2026-09-26): the Dock tile lingered
/// after close, or bounced, or the window then refused to reopen. Owning the `NSWindow`
/// directly lets us drive the policy deterministically from the window's own lifecycle
/// (`makeKeyAndOrderFront` to show, `windowWillClose` to hide) instead of SwiftUI scene churn.
@MainActor
final class LibraryWindowManager: NSObject, NSWindowDelegate {
    static let shared = LibraryWindowManager()
    private var window: NSWindow?

    func show(appState: AppState) {
        // Become a regular (Dock-visible) app and come to the front before showing the window.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let hosting = NSHostingView(rootView: LibraryView(appState: appState))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Library"
        window.contentView = hosting
        window.delegate = self
        // Keep our own reference alive across the close so ARC frees it only when we drop it in
        // windowWillClose — a fresh window is then built on the next show, avoiding stale state.
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        // Drop the Dock icon — back to a pure menu-bar app with only the status-item icon.
        NSApp.setActivationPolicy(.accessory)
    }
}
