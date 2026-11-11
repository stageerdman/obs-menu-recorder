import SwiftUI

/// "Call detected: WhatsApp — Not recording yet [Record] [x]" in the top-right corner, shown
/// when CallDetector sees a call app take the mic while RecBar is idle. Graphite with a red
/// record dot (not the watchdog's solid red, which means "something's wrong"). Chimes when it
/// appears and once more after `secondChimeDelay` if still unanswered — no more, since the
/// chime plays out loud during a live call.
@MainActor
final class CallPrompt {
    private let panel = CornerPanel()
    private var secondChime: Task<Void, Never>?
    private let secondChimeDelay: UInt64 = 20_000_000_000

    var isVisible: Bool { panel.isVisible }

    func show(appName: String, onRecord: @escaping () -> Void, onDismiss: @escaping () -> Void) {
        panel.show(size: NSSize(width: 340, height: 84),
                   accessibilityLabel: "Call detected in \(appName). Not recording.") {
            CallPromptView(appName: appName, onRecord: onRecord, onDismiss: onDismiss)
        }
        AlertSound.play()
        secondChime?.cancel()
        secondChime = Task { [weak self, secondChimeDelay] in
            try? await Task.sleep(nanoseconds: secondChimeDelay)
            guard !Task.isCancelled, self?.isVisible == true else { return }
            AlertSound.play()
        }
    }

    func hide() {
        secondChime?.cancel()
        secondChime = nil
        panel.hide()
    }
}

private struct CallPromptView: View {
    let appName: String
    let onRecord: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "record.circle.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(RecBarColor.red)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Call detected: \(appName)")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                Text("Not recording yet")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.85))
            }
            Spacer(minLength: 8)
            Button("Record", action: onRecord)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(RecBarColor.red)
                .accessibilityLabel("Record call")
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .buttonStyle(.plain)
            .help("Not now")
            .accessibilityLabel("Not now")
        }
        .padding(12)
        .frame(width: 320)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(RecBarColor.graphite)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Call detected in \(appName). Not recording.")
        .padding(10)
    }
}
