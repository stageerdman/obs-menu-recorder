import SwiftUI

@main
struct RecBarApp: App {
    @StateObject private var appState = AppState()

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
        Group {
            switch appState.recordingState {
            case .idle:
                SelectionView()
            case .recording, .paused:
                RecordingView()
            }
        }
        // Reopening the popover always starts with the drawer collapsed.
        .onAppear { appState.debugDrawerExpanded = false }
    }
}

private struct MenuBarIcon: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Image(systemName: iconName)
            .foregroundStyle(tint)
    }

    private var iconName: String {
        switch appState.recordingState {
        case .idle: return "video.circle"
        case .recording: return "record.circle.fill"
        case .paused: return "pause.circle.fill"
        }
    }

    private var tint: Color {
        switch appState.recordingState {
        case .idle: return .primary
        case .recording, .paused: return RecBarColor.red
        }
    }
}
