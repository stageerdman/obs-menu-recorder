import SwiftUI
import AppKit

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
                // Left-click still opens the popover (MenuBarExtra's own behaviour); this only
                // adds a right-click menu (Show / Quit) on top, since MenuBarExtra exposes no
                // built-in way to do both. Additive by design — if the status button can't be
                // found the right-click simply does nothing and left-click is unaffected.
                .background(StatusItemRightClickMenu(appState: appState))
        }
        .menuBarExtraStyle(.window)
        // The Library window is intentionally NOT a SwiftUI Window/WindowGroup scene — it's an
        // AppKit NSWindow owned by LibraryWindowManager, so RecBar can toggle its Dock icon on
        // (window open) and off (window closed) reliably. See LibraryWindowManager for why.
    }
}

private struct PopoverContent: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button {
                    LibraryWindowManager.shared.show(appState: appState)
                } label: {
                    Image(systemName: "rectangle.stack")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
                .help("Open Library")
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)

            switch appState.recordingState {
            case .idle:
                SelectionView()
            case .recording, .paused:
                RecordingView()
            }
        }
        .frame(maxWidth: .infinity)
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
            .font(.system(size: 15, weight: .medium))
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
        // A bold filled camera glyph rather than the thinner "video.circle" outline (2026-09-10,
        // explicit user request — the custom capsule/dot mark tried before this read as too
        // small/unclear in the menu bar) — same "video.fill" symbol already used for the
        // Meetings mode icon elsewhere in this app, so the idle state reads as "this is a
        // recording app" at a glance.
        case .idle: return "video.fill"
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

/// Adds a right-click menu (Show / Quit) to the MenuBarExtra's status-item button.
///
/// MenuBarExtra (`.window` style) owns the button's left-click to toggle the popover and gives
/// no hook for a right-click menu, so we place this zero-size NSView inside the button (via
/// `.background` on the label), walk up to the NSStatusBarButton it lives in, and attach a
/// right-mouse-only click gesture recognizer that pops up an NSMenu. This is purely additive:
/// it never touches the button's existing left-click action, and if the button can't be found
/// the recogniser just isn't installed — left-click keeps working either way.
private struct StatusItemRightClickMenu: NSViewRepresentable {
    let appState: AppState

    func makeCoordinator() -> Coordinator { Coordinator(appState: appState) }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject {
        private let appState: AppState
        private let menu = NSMenu()

        init(appState: AppState) {
            self.appState = appState
            super.init()
            let show = NSMenuItem(title: "Show", action: #selector(showApp), keyEquivalent: "")
            show.target = self
            let quit = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
            quit.target = self
            menu.addItem(show)
            menu.addItem(.separator())
            menu.addItem(quit)
        }

        func attach(to view: NSView) {
            // The view isn't in the window hierarchy yet during makeNSView, so defer the
            // superview walk to the next runloop tick once it's been mounted inside the button.
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let view else { return }
                var candidate: NSView? = view.superview
                while let current = candidate, !(current is NSButton) {
                    candidate = current.superview
                }
                guard let button = candidate else { return }
                let recognizer = NSClickGestureRecognizer(
                    target: self, action: #selector(self.handleRightClick(_:)))
                recognizer.buttonMask = 0x2 // secondary (right) button only
                recognizer.numberOfClicksRequired = 1
                button.addGestureRecognizer(recognizer)
            }
        }

        @objc private func handleRightClick(_ sender: NSGestureRecognizer) {
            guard let button = sender.view else { return }
            menu.popUp(positioning: nil,
                       at: NSPoint(x: 0, y: button.bounds.height + 4),
                       in: button)
        }

        @objc private func showApp() {
            LibraryWindowManager.shared.show(appState: appState)
        }

        @objc private func quitApp() {
            NSApp.terminate(nil)
        }
    }
}
