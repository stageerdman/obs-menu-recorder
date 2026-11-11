import AppKit
import SwiftUI

/// The silence watchdog's "Are you there?" prompt in the top-right corner of the screen — a
/// permission-free channel alongside `AlertSound` and the menu bar icon (see
/// AppState.tickWatchdog / CLAUDE.md's "Prompt not being noticed" entry). The panel shell
/// (always-on-top, shows over full-screen calls, never steals focus) lives in `CornerPanel`.
@MainActor
final class WatchdogOverlayWindow {
    private let panel = CornerPanel()

    func show(deadline: Date, onConfirm: @escaping () -> Void) {
        panel.show(size: NSSize(width: 340, height: 84),
                   accessibilityLabel: "Are you there? Recording will auto-stop unless you confirm.") {
            WatchdogOverlayView(deadline: deadline, onConfirm: onConfirm)
        }
    }

    func hide() {
        panel.hide()
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
