import SwiftUI

struct SelectionView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 8) {
            if let error = appState.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(RecBarColor.red)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
            }

            HStack(spacing: 14) {
                ForEach(RecordingMode.allCases) { mode in
                    ModeButton(mode: mode)
                }
            }
            .padding(16)

            if appState.connectionState != .connected {
                Label("OBS not connected", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 12)
            }
        }
        .frame(width: 300)
    }
}

private struct ModeButton: View {
    @EnvironmentObject var appState: AppState
    let mode: RecordingMode
    @State private var pressed = false

    private var disabled: Bool { appState.connectionState != .connected || appState.isBusy }

    var body: some View {
        Button {
            ClickSound.play()
            appState.start(mode: mode)
        } label: {
            VStack(spacing: 6) {
                Image(systemName: mode.symbolName)
                    .font(.system(size: 20, weight: .semibold))
                Text(mode.title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(RecBarColor.red)
            )
            .foregroundStyle(.white)
            .scaleEffect(pressed ? 0.94 : 1.0)
        }
        .buttonStyle(.plain)
        .opacity(disabled ? 0.5 : 1.0)
        .disabled(disabled)
        .help(disabled ? "OBS not connected" : "")
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in pressed = true }
                .onEnded { _ in pressed = false }
        )
        .animation(.spring(response: 0.25, dampingFraction: 0.6), value: pressed)
    }
}
