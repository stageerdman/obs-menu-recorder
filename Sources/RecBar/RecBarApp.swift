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
        }
        .menuBarExtraStyle(.window)

        // A single-instance window (not WindowGroup, which would spawn a new instance on
        // every openWindow(id:) call with no built-in dedup) listing every tracked recording
        // across the 3 save folders — see LibraryView. Requires macOS 14 (Package.swift was
        // bumped from .v13 for this Scene type specifically).
        Window("Library", id: "library") {
            LibraryView(appState: appState)
        }
    }
}

private struct PopoverContent: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button {
                    openWindow(id: "library")
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
        // This still has to be a real `Image` (not an arbitrary custom View) for
        // .renderingMode/.foregroundStyle to have any effect — that combination is what fixed
        // a real menu-bar-color bug (see CLAUDE.md's "Green didn't actually render"), so the
        // brand glyphs below are pre-rendered to NSImage (MenuBarGlyphs.render) rather than
        // drawn live, purely so this line of code — proven to work — doesn't have to change.
        Image(nsImage: glyph)
            .renderingMode(isColored ? .original : .template)
            .foregroundStyle(tint)
    }

    private var isColored: Bool {
        appState.watchdogPromptDeadline != nil || appState.recordingState != .idle
    }

    private var glyph: NSImage {
        // Takes priority over the recording/paused glyphs: this is the one glanceable signal
        // that doesn't depend on the popover being open or on notification permission having
        // been granted (see AppState.tickWatchdog / WatchdogNotifier). Kept as the system's
        // own warning triangle rather than a custom shape — it's a universal semantic symbol,
        // not part of RecBar's own brand mark, so there's no benefit to replacing it.
        if appState.watchdogPromptDeadline != nil { return MenuBarGlyphs.watchdog }
        switch appState.recordingState {
        case .idle: return MenuBarGlyphs.idle
        case .recording: return MenuBarGlyphs.recording
        case .paused: return MenuBarGlyphs.paused
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

/// RecBar's own menu bar glyphs — echoing the capsule/dot/bars mark from the app's
/// Finder/Dock icon (`Resources/AppIcon.iconset`) instead of the previous plain SF Symbols,
/// so the same visual identity carries into the one place users actually look at repeatedly.
/// Drawn as SwiftUI shapes (no bundled image assets, same ethos as everything else in this
/// file) and rasterized once via `ImageRenderer` into a cached `NSImage`, since
/// `MenuBarIcon` needs a real `Image` to keep using `.renderingMode`/`.foregroundStyle` — see
/// the comment there. Sized for an ~18pt-tall status item, matching the previous SF Symbols'
/// footprint. Not yet visually verified live (no GUI automation in this environment — see
/// CLAUDE.md's "Testing notes"), including whether idle's template rendering still blends
/// with the system menu bar and inverts on click the same way the SF Symbol version did.
@MainActor
private enum MenuBarGlyphs {
    static let idle = render(IdleMark())
    static let recording = render(RecordingMark())
    static let paused = render(PausedMark())
    static let watchdog = render(Image(systemName: "exclamationmark.triangle.fill"))

    private static func render<V: View>(_ view: V) -> NSImage {
        let renderer = ImageRenderer(content: view.frame(width: 18, height: 18))
        renderer.scale = 2
        return renderer.nsImage ?? NSImage()
    }

    /// A hollow capsule with an unfilled "record" dot at its left end — the idle/ready state,
    /// echoing the app icon's white-capsule-plus-red-dot silhouette but entirely in outline
    /// form so it stays template-compatible (monochrome, blends with the system menu bar).
    private struct IdleMark: View {
        var body: some View {
            ZStack {
                Capsule().stroke(lineWidth: 1.6).frame(width: 16, height: 9)
                Circle().stroke(lineWidth: 1.6).frame(width: 6, height: 6).offset(x: -4)
            }
            .frame(width: 18, height: 18)
        }
    }

    /// A plain filled dot — the universal "recording" indicator, tinted green by
    /// `MenuBarIcon.tint`. Deliberately simpler than the idle capsule: menu bar glyphs read
    /// fastest as a single bold shape once a state actually needs to grab attention.
    private struct RecordingMark: View {
        var body: some View {
            Circle().frame(width: 12, height: 12)
                .frame(width: 18, height: 18)
        }
    }

    /// Two vertical rounded bars — the universal pause glyph, drawn with the same rounded-bar
    /// language as the app icon's waveform, tinted red by `MenuBarIcon.tint`.
    private struct PausedMark: View {
        var body: some View {
            HStack(spacing: 3) {
                Capsule().frame(width: 4, height: 12)
                Capsule().frame(width: 4, height: 12)
            }
            .frame(width: 18, height: 18)
        }
    }
}
