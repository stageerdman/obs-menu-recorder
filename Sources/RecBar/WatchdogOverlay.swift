import AppKit
import SwiftUI

/// A borderless, always-on-top panel showing the silence watchdog's "Are you there?" prompt
/// in the top-right corner of the screen — a third, permission-free channel alongside
/// `AlertSound` and the menu bar icon (see AppState.tickWatchdog / CLAUDE.md's "Prompt not
/// being noticed" entry). Unlike `UNUserNotificationCenter`, this needs no OS authorization
/// and can't silently fail to appear; unlike the inline `WatchdogBanner` in `RecordingView`,
/// it doesn't require the popover to be open. `.fullScreenAuxiliary` + `.canJoinAllSpaces`
/// specifically so it still shows up while the user is in a full-screen call (Zoom/Meet in
/// full screen is exactly the situation this prompt exists for).
@MainActor
final class WatchdogOverlayWindow {
    private var panel: NSPanel?

    func show(deadline: Date, onConfirm: @escaping () -> Void) {
        hide()

        let hosting = NSHostingView(rootView: WatchdogOverlayView(deadline: deadline, onConfirm: onConfirm))
        hosting.frame = NSRect(x: 0, y: 0, width: 340, height: 84)

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
            let origin = NSPoint(
                x: screen.visibleFrame.maxX - hosting.frame.width - margin,
                y: screen.visibleFrame.maxY - hosting.frame.height - margin
            )
            panel.setFrameOrigin(origin)
        }

        panel.orderFrontRegardless()
        self.panel = panel
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}

private struct WatchdogOverlayView: View {
    let deadline: Date
    let onConfirm: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = max(0, Int(deadline.timeIntervalSince(context.date).rounded(.up)))
            HStack(spacing: 10) {
                Image(systemName: "waveform.slash")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Are you there?")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                    Text("No mic activity — auto-stopping in \(remaining)s")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.85))
                }
                Spacer(minLength: 8)
                Button("I'm here", action: onConfirm)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(.white)
            }
            .padding(12)
            .frame(width: 320)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(RecBarColor.red)
            )
            .padding(10)
        }
    }
}
