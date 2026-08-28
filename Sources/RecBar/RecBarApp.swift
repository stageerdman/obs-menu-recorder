import SwiftUI

@main
struct RecBarApp: App {
    @StateObject private var appState: AppState

    init() {
        _appState = StateObject(wrappedValue: AppState())
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverContent()
                .environmentObject(appState)
        } label: {
            MenuBarIcon()
                .environmentObject(appState)
        }
        .menuBarExtraStyle(.window)
    }
}

private struct PopoverContent: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        switch appState.recordingState {
        case .idle:
            SelectionView()
        case .recording, .paused:
            RecordingView()
        }
    }
}

private struct MenuBarIcon: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        // NSStatusItem buttons render SwiftUI Images as template (monochrome, auto-inverting
        // on highlight) by default, which silently drops any .foregroundStyle color — this is
        // why plain foregroundStyle alone doesn't reliably show real color in the menu bar.
        // .renderingMode(.original) opts out of that for the colored states specifically, so
        // the actual tint shows through; idle stays template so it still blends with the
        // system's black/white menu bar icons and inverts correctly when highlighted/clicked.
        Image(systemName: iconName)
            .renderingMode(isColored ? .original : .template)
            .foregroundStyle(tint)
    }

    private var isColored: Bool {
        appState.watchdogPromptDeadline != nil || appState.recordingState != .idle
    }

    private var iconName: String {
        // Takes priority over the recording/paused icons: this is the one glanceable signal
        // that doesn't depend on the popover being open or on notification permission having
        // been granted (see AppState.tickWatchdog / WatchdogNotifier).
        if appState.watchdogPromptDeadline != nil { return "exclamationmark.triangle.fill" }
        switch appState.recordingState {
        case .idle: return "video.circle"
        case .recording: return "record.circle.fill"
        case .paused: return "pause.circle.fill"
        }
    }

    private var tint: Color {
        if appState.watchdogPromptDeadline != nil { return .orange }
        switch appState.recordingState {
        case .idle: return .primary
        case .recording: return RecBarColor.green
        case .paused: return RecBarColor.red
        }
    }
}
