import SwiftUI
import Foundation

struct RecordingView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            if let deadline = appState.watchdogPromptDeadline {
                WatchdogBanner(deadline: deadline)
                    .padding(.horizontal, 14)
                    .padding(.top, 14)
            }

            HStack(spacing: 16) {
                Button {
                    ClickSound.play()
                    appState.togglePause()
                } label: {
                    Image(systemName: appState.recordingState == .paused ? "play.fill" : "pause.fill")
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(TransportButtonStyle())
                .disabled(appState.isBusy)

                Button {
                    ClickSound.play()
                    appState.stop(discard: false)
                } label: {
                    Image(systemName: "stop.fill")
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(TransportButtonStyle())
                .disabled(appState.isBusy)

                Button {
                    ClickSound.play()
                    appState.stop(discard: true)
                } label: {
                    Image(systemName: "trash.fill")
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(TransportButtonStyle(destructive: true))
                .disabled(appState.isBusy)

                Spacer()

                Text(elapsedString)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(appState.recordingState == .paused ? .secondary : .primary)

                Button {
                    appState.debugDrawerExpanded.toggle()
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .bold))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
            }
            .padding(14)

            if appState.debugDrawerExpanded {
                Divider()
                DebugDrawer()
                    .padding(14)
            }
        }
        .frame(width: 320)
        .animation(.easeInOut(duration: 0.2), value: appState.debugDrawerExpanded)
    }

    private var elapsedString: String {
        let total = max(0, Int(appState.elapsed))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }
}

private struct WatchdogBanner: View {
    @EnvironmentObject var appState: AppState
    let deadline: Date

    private var remainingSeconds: Int {
        max(0, Int(deadline.timeIntervalSinceNow.rounded(.up)))
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform.slash")
                .foregroundStyle(RecBarColor.red)
            VStack(alignment: .leading, spacing: 2) {
                Text("Are you there?")
                    .font(.system(size: 12, weight: .semibold))
                Text("No mic activity — auto-stopping in \(remainingSeconds)s")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("I'm here") {
                ClickSound.play()
                appState.confirmPresence()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(RecBarColor.red.opacity(0.12))
        )
    }
}

private struct TransportButtonStyle: ButtonStyle {
    var destructive: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(destructive ? RecBarColor.red : Color.primary)
            .background(
                Circle().fill(Color.secondary.opacity(configuration.isPressed ? 0.28 : 0.12))
            )
            .scaleEffect(configuration.isPressed ? 0.92 : 1.0)
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

private struct DebugDrawer: View {
    @EnvironmentObject var appState: AppState

    /// The active mode's configured silence threshold, so the watched mic's row can be
    /// highlighted red in real time when it's actually under it — lets the threshold be
    /// tuned by watching a live number instead of guessing from a recording afterward.
    private var thresholdDB: Double? {
        appState.currentMode?.config(appState.config).watchdog.silenceThresholdDB
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Circle()
                    .fill(appState.connectionState == .connected ? Color.green : RecBarColor.red)
                    .frame(width: 6, height: 6)
                Text(appState.connectionState == .connected ? "Connected to OBS" : "Not connected")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let mic = appState.resolvedMicDescription {
                Text("Mic: \(mic)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let thresholdDB {
                Text("Watchdog threshold: \(Int(thresholdDB)) dB")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if appState.channelLevels.isEmpty {
                Text("No level data yet")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(appState.channelLevels) { channel in
                    let isWatched = channel.name == appState.resolvedMicSourceName
                    let db = Self.dbValue(for: channel.peakLevel)
                    let belowThreshold = isWatched && thresholdDB.map { db < $0 } == true
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(isWatched ? "\(channel.name) (watched)" : channel.name)
                            Spacer()
                            Text(Self.dbText(for: db))
                                .font(.system(.caption2, design: .monospaced))
                        }
                        .font(.caption2)
                        .foregroundStyle(belowThreshold ? RecBarColor.red : .secondary)
                        LevelMeter(level: channel.peakLevel)
                    }
                }
            }
        }
    }

    private static func dbValue(for level: Float) -> Double {
        guard level > 0.0001 else { return -96 }
        return 20 * Double(log10(level))
    }

    private static func dbText(for db: Double) -> String {
        db <= -96 ? "≤ -96 dB" : String(format: "%.0f dB", db)
    }
}

private struct LevelMeter: View {
    let level: Float

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.secondary.opacity(0.2))
                RoundedRectangle(cornerRadius: 3)
                    .fill(level > 0.85 ? Color.orange : RecBarColor.red)
                    .frame(width: max(2, geo.size.width * CGFloat(level)))
            }
        }
        .frame(height: 6)
        .animation(.linear(duration: 0.08), value: level)
    }
}
