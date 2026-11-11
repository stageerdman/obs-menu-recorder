import AppKit
import SwiftUI

/// A borderless, always-on-top panel pinned to the top-right corner of the main screen —
/// the shared shell for RecBar's must-not-miss prompts (silence watchdog, call detected).
/// Needs no OS permission and doesn't depend on the popover being open. `.fullScreenAuxiliary`
/// + `.canJoinAllSpaces` so it still appears over a full-screen Meet/WhatsApp call;
/// non-activating so clicking it never steals focus from the call.
@MainActor
final class CornerPanel {
    private var panel: NSPanel?

    var isVisible: Bool { panel != nil }

    func show<Content: View>(size: NSSize, accessibilityLabel: String, @ViewBuilder content: () -> Content) {
        hide()

        let hosting = NSHostingView(rootView: content())
        hosting.frame = NSRect(origin: .zero, size: size)

        let panel = NSPanel(
            contentRect: hosting.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true

        if let screen = NSScreen.main {
            let margin: CGFloat = 12
            panel.setFrameOrigin(NSPoint(
                x: screen.visibleFrame.maxX - size.width - margin,
                y: screen.visibleFrame.maxY - size.height - margin
            ))
        }

        panel.orderFrontRegardless()
        self.panel = panel
        // The panel never takes focus, so announce it for VoiceOver users.
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [.announcement: accessibilityLabel, .priority: NSAccessibilityPriorityLevel.high.rawValue]
        )
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}
