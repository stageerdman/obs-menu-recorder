<!--
  This CLAUDE.md is compiled from the AI Control global modules
  (~/.ai-control/modules: CODING, WORKFLOW, STRUCTURE, UX) — the "Working
  agreement" section below — followed by RecBar's own project knowledge, which
  is preserved verbatim under "Project knowledge". See .project for the marker.
-->

# Working agreement (AI Control)

Compiled from the global modules this project uses (`coding`, `workflow`, `structure`, `ux`).
These are the standing rules for how work is done here; the RecBar-specific knowledge follows.

## Structure
- Carry the standard scaffold: `.project`, `CLAUDE.md`, `.gitignore` (always covers `.env`),
  `.env` (never committed), `updates/`, `issues.txt`.
- Each update is a folder `updates/YYYY-MM-DD NAME - OPEN|CLOSED/` holding `update vX.md`
  (goal + phased roadmap + live status) and `wiki.md` (durable decisions/lessons). Reopen by
  flipping `CLOSED`→`OPEN`.
- Follow the ecosystem's own norms (here: SwiftPM layout — `Sources/`, `Package.swift`). Keep
  it flat and simple; add folders only when the project genuinely grows into them.

## Coding
- Modular by default: every piece understandable and fixable in isolation, with small explicit
  interfaces and low cross-module coupling — a bug should have one obvious home.
- Keep it minimal: build only what's truly needed; no speculative abstraction. Prefer reuse
  over duplication, but don't over-generalize before a second real caller.
- Test what matters (core logic, risky paths, silent-regression risks); skip trivial glue.
- Idiomatic to the ecosystem — read the neighbours first; new code should look like it belongs.

## Workflow
- Commit after every working change — small, focused, one logical unit; honest messages; never
  commit secrets. Everything lives on GitHub and is pushed regularly.
- Non-trivial work starts with a phased roadmap recorded in the update's `update vX.md`; most
  phases end with tests. Keep status current as you go.
- New API / unfamiliar library / genuinely new design → a throwaway research spike run *outside*
  the main code, inside the update folder; capture findings in the update's `wiki.md`.
- Act as an orchestrator: delegate to focused agents and synthesize.
- Verify by running the actual thing, not just a green test. (Caveat for RecBar: no GUI
  automation for native macOS apps here — real clicks / real OBS / real hardware are walked
  through with the user, never self-certified. See "Testing notes" below.)

## UX
- Any user-facing surface: bring in a dedicated UX-expert agent (several in parallel for a
  multi-part surface) to think it through.
- Cut everything unnecessary — every element must earn its place. Minimal visual system: few
  fonts/colors/sizes on a deliberate scale.
- Build from standardized, reusable, isolated components with clear interfaces. Accessible and
  responsive by default; sensible defaults, fast feedback, honest error states over decoration.

---

# Project knowledge

# RecBar

RecBar is a macOS menu-bar-only (no Dock icon) SwiftUI app that remote-controls OBS Studio
over `obs-websocket` v5 to start/stop/pause recordings across four preconfigured modes
(Meetings / Audio / Guide / Captain Log), each mapped to an OBS scene and a save folder. It
shows a compact horizontal popover: a 4-button mode picker when idle, transport controls +
elapsed time + an expandable live-audio-level debug drawer while recording.

## Architecture

- `Sources/RecBar/RecBarApp.swift` — `@main` SwiftUI `App`, `MenuBarExtra` (`.window` style),
  and the `PopoverContent` switch between `SelectionView`/`RecordingView` based on
  `AppState.recordingState`. Dock/Cmd+Tab hiding is done purely via `LSUIElement=true` in
  `Resources/Info.plist` — do not add a runtime `NSApp.setActivationPolicy` call in `init()`;
  that crashes on launch because `NSApp` isn't populated yet at that point in the SwiftUI
  `App` lifecycle for a plain SwiftPM executable (hit and fixed during initial build).
- `Sources/RecBar/AppState.swift` — the single `@MainActor ObservableObject` source of truth:
  `recordingState` (`.idle`/`.recording`/`.paused`), `currentMode`, `elapsed`,
  `connectionState`, `channelLevels`, `resolvedMicDescription`, `debugDrawerExpanded`,
  `watchdogPromptDeadline`. Orchestrates `OBSClient` + `MicrophonePriority` + `OBSLauncher` +
  `WatchdogNotifier` for start/pause/resume/stop/discard, and reconciles state from OBS's own
  events so the UI stays truthful even if OBS is driven directly (not just through this app).
  `tickWatchdog()` runs once a second off the same timer that drives `elapsed` (and is
  skipped along with it while paused — see "Silence / presence watchdog" below).
  `goIdleInOBS()`/`releaseCameraIfConfigured()`/`restoreCameraForGuideMode()` implement idle
  resource minimization (see "Idle resource minimization" below) since RecBar no longer quits
  OBS at all.
- `Sources/RecBar/OBSClient.swift` — hand-rolled `obs-websocket` v5 client over
  `URLSessionWebSocketTask` (no third-party dependency). Handles the `Hello`/`Identify`
  handshake including SHA256 challenge/salt auth, request/response correlation by
  `requestId`, event dispatch, and reconnect-with-backoff. `reconnectNow()` skips the rest of
  a backoff delay and retries immediately — used right after `OBSLauncher` launches or
  detects an OBS instance, so RecBar doesn't sit out a stale backoff window.
- `Sources/RecBar/OBSLauncher.swift` — launches OBS hidden (`NSWorkspace.openApplication`,
  `--minimize-to-tray` + `activates = false`, then `.hide()` as backup) when
  `AppState.beginRecording` needs it and it isn't already running. Tracks the launched
  `NSRunningApplication` in `launchedApp` (currently informational only) so it's clear which
  instance, if any, RecBar itself started — an OBS the user already had open is never touched.
  RecBar **never quits OBS**, for any reason, including its own exit — see "OBS quit-time
  crash bug" below for why this was deliberately removed rather than just made opt-in.
- `Sources/RecBar/MicrophonePriority.swift` — CoreAudio device enumeration
  (`kAudioHardwarePropertyDevices` + `kAudioDevicePropertyTransportType`) and priority
  resolution. Re-run on every recording start.
- `Sources/RecBar/Config.swift` — loads/creates `~/Library/Application Support/RecBar/config.json`.
- `Sources/RecBar/ClickSound.swift` — synthesizes a short click (`AVAudioEngine` +
  a generated decaying sine burst) at runtime instead of bundling a licensed audio asset.
- `Sources/RecBar/Views/` — `SelectionView.swift` (View 1), `RecordingView.swift` (View 2,
  debug drawer, and the watchdog's inline "Are you there?" banner).
- `Sources/RecBar/WatchdogNotifier.swift` — posts the silence watchdog's "Are you there?"
  prompt and its auto-stop confirmation as `UNUserNotificationCenter` notifications, so the
  prompt reaches the user even with the popover closed. The prompt notification carries an
  "I'm here" `UNNotificationAction`; either that action or tapping the notification body
  counts as a presence confirmation (`onConfirm` closure, wired to `AppState.confirmPresence()`).
- **Menu bar icon tried as a custom brand glyph, then reverted (2026-09-10).** A custom
  hollow-capsule-plus-dot idle mark (rasterized via `ImageRenderer` into an `NSImage`, meant
  to echo `Resources/AppIcon.iconset`'s mark) was tried and explicitly rejected by the user as
  unclear/too small ("shitty logo") — reverted back to a plain `Image(systemName:)`. The idle
  icon changed from `video.circle` to **`video.fill`** (a bolder filled camera glyph, request
  was specifically "something like a camera or a movie tape" — this is the same symbol
  already used for the Meetings mode icon elsewhere in this app) with an explicit
  `.font(.system(size: 15, weight: .medium))` added so it renders larger/bolder than the
  default menu-bar-icon size. Recording/paused/watchdog icons are unchanged
  (`record.circle.fill`/`pause.circle.fill`/`exclamationmark.triangle.fill`). Lesson: don't
  replace a working, simple SF-Symbol-based menu bar icon with custom-drawn art without
  checking first — the tiny status-item glyph is a poor place for a detailed brand mark,
  unlike the Finder/Dock `AppIcon.icns`, which is unaffected by this and unchanged.
- Menu bar / mode icons are SF Symbols rendered directly (no bundled image assets needed) —
  they pick up template/dark-light behavior for free, and are explicitly tinted rather than
  left to the system's default template rendering, regardless of appearance: actively
  recording is `RecBarColor.green` (Apple's system green, #34C759 — 2026-08-28, explicit user
  request for a "shining green" recording indicator), paused is `RecBarColor.red`, and an
  in-flight watchdog prompt overrides both to orange (see `MenuBarIcon.tint` in
  `RecBarApp.swift`; `RecBarColor` lives in `Theme.swift`). **Green didn't actually render
  (2026-08-28, real-usage report — stayed black/white)**: `NSStatusItem` buttons render
  SwiftUI `Image`s as *template* images by default (monochrome, auto-inverting on
  highlight/click), which silently drops any `.foregroundStyle` color unless told otherwise.
  Fixed by adding `.renderingMode(.original)` to the menu bar `Image`, but only while a
  non-default color is actually wanted (`MenuBarIcon.isColored`: recording, paused, or an
  in-flight watchdog prompt) — idle deliberately stays `.template` so it still blends with the
  system's monochrome menu bar icons and correctly inverts when the item is highlighted/
  clicked, which a permanently-`.original` image would lose. Not yet visually verified (no GUI
  automation for native macOS apps in this environment — see "Testing notes"); if the color
  still doesn't show after this, the next suspect is a third-party menu-bar-icon manager (e.g.
  Bartender/Ice/Hidden Bar) forcing all icons monochrome at a layer RecBar can't control from
  its own code.
- `Sources/RecBar/LibraryStore.swift`, `LibraryViewModel.swift`, `Views/LibraryView.swift`,
  `FilePromiseDragHandle.swift`, `KeychainHelper.swift`, `OneDriveAuth.swift`,
  `OneDriveClient.swift` — the Library window (see "Library window & OneDrive sharing" below),
  opened via a small button added to `PopoverContent`'s header calling
  `openWindow(id: "library")`, which resolves to a new single-instance `Window("Library", id:
  "library")` scene in `RecBarApp.swift`. `Window` (as opposed to `WindowGroup`, which spawns a
  new instance per `openWindow` call with no built-in dedup) requires macOS 14, which is why
  `Package.swift`/`Resources/Info.plist`'s `LSMinimumSystemVersion` were bumped from 13 to 14
  for this feature (2026-09-09) — low risk on this single-machine, non-App-Store build. Since
  RecBar is `LSUIElement`, `LibraryView` toggles `NSApp.setActivationPolicy(.regular/
  .accessory)` itself from its own `onAppear`/`onDisappear` (never from `init()` — see the
  crash warning above, which is about launch-time timing specifically; well after launch, from
  a window's own lifecycle, this is safe) so the window can come to the foreground/Cmd-Tab
  despite the app having no Dock icon otherwise.

## obs-websocket requests actually used

Confirmed against the installed OBS 32.2.1 (bundled `obs-websocket` build `30131037208`) by
grepping the plugin binary for request-type strings before writing any code:

`SetCurrentProgramScene`, `SetRecordDirectory` (this OBS version *does* support it — no
`GetProfileParameter`/`SetProfileParameter` fallback was needed), `SetInputSettings`,
`SetInputMute`, `StartRecord`, `StopRecord`, `PauseRecord`, `ResumeRecord`, `GetRecordStatus`.
Subscribed events: `RecordStateChanged` (event subscription bit `Outputs`, `1<<6`) and
`InputVolumeMeters` (bit `1<<16`, must be explicitly requested — not part of `All`).

Added for idle resource minimization (2026-08-22, confirmed working against the same OBS
install): `GetSceneList`, `CreateScene`, `GetInputList`, `GetInputSettings`, `RemoveInput`,
`CreateInput`, `GetSceneItemList` (via `OBSClient.findSceneItem`), `SetSceneItemEnabled`,
`SetSceneItemTransform`.

## OBS scenes & sources this app depends on

Scene collection has two scenes already built by the user: `Meet Recording Setup` (used by
both Meetings and Audio modes — only the save folder differs between them, so the
save-folder-set step always runs, every mode, every time) and `Guide Recording Setup`. As of
2026-09-09 `Screen`/`Desktop Sounds` are shared globally across *all three* modes rather than
Meet-only — see "Recording modes" below.

Each scene already contains **three separate mic sources** rather than one generic "Mic"
source with a swappable device: `Macbook` (device UID `BuiltInMicrophoneDevice`),
`Headphones Mic` (device UID `BuiltInHeadphoneInputDevice` — the wired 3.5mm jack input),
and the global Mic/Aux source, literally named `USB PnP` (this is OBS's built-in Aux Audio
Device 1, not a per-scene source — its name just happens to be "USB PnP" because it was last
pointed at a USB mic). There's also a `Desktop Sounds` source (`sck_audio_capture`) that must
always stay unmuted.

**Source/scene names, and the three save-folder paths, are configurable** in
`~/Library/Application Support/RecBar/config.json` (see `Config.swift` for the schema) rather
than hardcoded — the current defaults match the values above and the paths in the original
spec, but if the user renames a scene or source in OBS, or adds a config with different
paths, edit that file (it's gitignored, never committed).

## Recording modes: Meetings / Audio / Guide (renamed + restructured 2026-09-09)

The three modes were renamed and Guide's scene composition + all three modes' audio-track
layout changed together, on explicit user request:

- **Renamed, display-only**: `RecordingMode.sales` now shows as **"Meetings"**, `.other` as
  **"Audio"** (`.guide` unchanged). Deliberately **only** `.title`/`.symbolName` changed —
  the Swift enum case names/raw values (`sales`/`guide`/`other`) and `RecBarConfig`'s
  `salesMode`/`otherMode` property and JSON key names were all left exactly as they were, so
  already-persisted `library.json` entries (which store `RecordingMode`'s raw value as
  `category`) and `config.json`'s existing keys keep working with **zero migration code** —
  see the comment on `RecordingMode.title` in `AppState.swift` and on `RecBarConfig.default`
  in `Config.swift`. Icons: Meetings got the camera icon Guide used to have
  (`video.fill`), Audio kept its existing microphone icon (`mic.fill`, unchanged), Guide got
  a new screen/click icon (`cursorarrow.click`).
- **Save folders physically renamed on disk** (explicit user choice over just relabeling):
  `~/Documents/Recordings/Sales Meetings` → `Meetings`, `Other Meetings` → `Audio` (`mv`, not
  copy — verified identical file counts before/after). `config.json`'s
  `salesMode.saveFolder`/`otherMode.saveFolder` and `RecBarConfig.default`'s hardcoded paths
  in `Config.swift` were updated to match, and every existing `library.json` entry's
  `lastKnownLocalPath` was rewritten to the new paths (a plain string replace, verified
  afterward that every entry's path still resolves to a real file) — done this way, by hand,
  specifically to avoid losing any already-uploaded OneDrive link's association with its local
  file, which a naive "let the next reconcile pass rediscover everything" approach would have
  orphaned (a moved-then-rediscovered file would look "brand new" with no memory of its
  existing cloud state).
- **Guide gets a screen recording + camera PiP + desktop audio — previously it was
  camera-only, full-frame, no screen or desktop audio at all.** `AppState.beginRecording` no
  longer branches `screenRelease`/`desktopAudioRelease` restoration on `mode != .guide` — both
  are now restored into whichever scene is current (`sceneNameOverride: modeConfig.sceneName`)
  for **every** mode, the same shared-global-input pattern already used for the mic sources
  (see `RecBarConfig.screenRelease`'s updated doc comment). `cameraRelease` is still
  Guide-only. Since `Screen`/`Desktop Sounds` are single shared OBS inputs (not per-scene),
  reusing whatever transform was already snapshotted from `Meet Recording Setup` (full-frame)
  naturally produces the same full-frame placement in `Guide Recording Setup` too — no new
  transform needed for either. The camera *did* need a new transform: Guide's `cameraRelease`
  was previously full-frame (`scaleX`/`scaleY`: 1, `boundsType`: `OBS_BOUNDS_NONE`) from when
  Guide was camera-only; hand-edited directly in `config.json`'s
  `cameraRelease.lastKnownTransformJSON` to a bottom-right square PiP:
  `boundsType: OBS_BOUNDS_SCALE_OUTER` (scales-to-cover-then-crops, the "CSS `background-size:
  cover`" of OBS bounds types — the right choice for cropping a 16:9 webcam feed down to a
  square without letterboxing) at 360×360 canvas pixels, `boundsAlignment: 0` (center crop),
  `alignment: 10` (right|bottom, so `positionX`/`positionY` anchor the PiP's bottom-right
  corner) at `(1686, 1083)` — a 24px margin from the corner of the real canvas resolution
  (`1710×1107`, confirmed live via `GetVideoSettings` against the real OBS instance). Like
  every other release/restore transform, this is just the *initial* value — if the user
  repositions/resizes the camera square by hand in OBS, the next idle transition snapshots
  and keeps whatever they set, same as always.
- **Audio-track routing** (`AppState.applyAudioTrackRouting`, new, called from
  `beginRecording` right after `applyMicrophonePriority` for every mode): previously every
  source was implicitly routed to every one of OBS's 6 mixer tracks (confirmed identical audio
  across all 6 tracks in a real saved file during the original silence-watchdog investigation,
  see "Silence / presence watchdog" above) — now `SetInputAudioTracks` explicitly splits it:
  **Track 1 = the full mix** (resolved mic + desktop audio both routed here), **Track 2 =
  mic only**, **Track 3 = desktop audio only**; the non-resolved mic and the wired mic are
  routed to no tracks at all. Tracks 4-6 are left empty. Confirmed via
  `GetProfileParameter` against the real OBS instance (2026-09-09) that no output-format/mode
  change was needed for this: `Output`/`Mode` is `Simple`, but `SimpleOutput`/`RecTracks` is
  already `63` (all 6 tracks recorded into the `hybrid_mov` file regardless) — so this was
  purely a per-source routing change, not a recording-pipeline change.
- **Audio mode transcodes to mp3-only** (`AppState.transcodeToMP3ThenRegister`, called from
  `stop(discard:)` in place of the ordinary `LibraryStore.registerCompletedRecording` call,
  only for `.other`/"Audio"): shells out to `ffmpeg` (`-vn -acodec libmp3lame -q:a 2` —
  audio-only extraction; no built-in AVFoundation export preset produces mp3, it isn't a
  codec Apple bundles a licensed encoder for) to extract the audio track, deletes the original
  `.mov` once the mp3 file actually exists, then registers whichever file survives into the
  Library. Runs `nonisolated`, detached from `AppState`'s `MainActor` via `Task.detached` —
  by the time this runs, `stop()`'s own synchronous flow has already finished and
  `recordingState` is back to `.idle`, so there's no reason to tie a potentially-slow
  subprocess to the main actor. Falls back to registering the original `.mov` untouched (never
  silently loses the recording) if `ffmpeg` isn't found at any of the common install paths
  checked (`/opt/homebrew/bin`, `/usr/local/bin`, `/usr/bin`, `/opt/local/bin`) or the process
  exits non-zero. `LibraryStore`'s tracked-extensions set (renamed from `videoExtensions` to
  `mediaExtensions`) includes `mp3` now so the folder-scan reconciliation pass also recognizes
  these files.

**Follow-up from the first real test (2026-09-09, user report): camera hidden behind the
screen, sometimes off entirely; Audio mode showed only a `.mov`, no `.mp3`.** Three separate
fixes:

- **Camera z-order**: `restoreInput` restored the camera before the screen in `beginRecording`
  with no explicit z-order control, and whichever scene item gets created *later* apparently
  renders on top in this OBS version — so the screen (created second) was covering the camera
  entirely. Fixed with a new `AppState.bringCameraToFront()`, called for Guide right after all
  of that recording's inputs are restored: looks up every scene item in `Guide Recording
  Setup` (new `OBSClient.getSceneItemList`) and explicitly moves the camera to the highest
  index (index 0 is the back of the stack/rendered first; the highest index is the front,
  rendered last/on top) via the new `OBSClient.setSceneItemIndex` — asserting a definite
  z-order every time regardless of creation order, rather than depending on it.
- **Camera "sometimes off"**: `restoreInput` previously no-op'd entirely whenever
  `GetInputList` already showed the input present — correct for a genuinely-fresh input, but
  wrong for the already-documented "Camera stuck open" case (see "Idle resource
  minimization" above: `RemoveInput` can report success while the underlying capture session
  never actually tears down), where the leftover item keeps whatever stale
  enabled-state/placement it already had *forever*, since nothing ever re-applies fresh
  values to an item that already "exists". Fixed by making `restoreInput` self-healing: an
  already-present input now still gets `SetSceneItemEnabled`/`SetSceneItemTransform`
  re-applied via `findSceneItem`, rather than skipping straight to nothing — so a stuck
  leftover camera gets nudged back to the right enabled-state/PiP placement on every restore,
  not just the first time it's freshly created. (Doesn't fix the underlying stuck-capture-
  session bug itself — there's still no known websocket-reachable fix for that, per the
  existing "Camera stuck open" investigation; this only stops the *symptom* of a stuck item
  silently keeping stale settings forever.)
- **Audio mode's `.mov`-only result, root cause confirmed (2026-09-09): a race in
  `stop(discard:)` itself, unrelated to ffmpeg — affected every mode's registration, not just
  Audio's transcode.** A hand-run reproduction of the exact `ffmpeg`/`Process` invocation
  against a real saved file worked perfectly (exit 0, valid mp3 — command used:
  `ffmpeg -y -i input.mov -vn -acodec libmp3lame -q:a 2 output.mp3`), and file-based tracing
  (`log show`/NSLog output wasn't showing up for this ad-hoc-signed process at all, so a
  temporary plain-file trace was added and then removed once this was confirmed) showed the
  transcode function was never even being *entered* — the registration branch in
  `stop(discard:)` was being skipped entirely. Root cause: `stop(discard:)` reads
  `currentMode` *after* `await waitForEvent("RecordStateChanged", ...)` — but that same
  `RecordStateChanged`/`STOPPED` event is also handled by `handleRecordStateChanged`, which
  calls `resetToIdle()` (nil-ing `currentMode`) **synchronously**, as part of the very same
  event dispatch that resumes `stop()`'s suspended continuation. That reset could win the
  race and complete before `stop()`'s own continuation resumed, so `let mode = currentMode`
  after the await could already see `nil`, silently skipping the entire
  registration/transcode branch — exactly matching a real recording finishing and being
  staged correctly (confirmed: real files were landing in the temp staging folder) but never
  getting processed into an mp3. Fixed by capturing `let mode = currentMode` **before** the
  function's first `await`, at the very top of `stop(discard:)`, so it reflects whatever was
  actually recording when stop was invoked regardless of anything `resetToIdle()` does to
  `self.currentMode` afterward. This bug predates this session's changes and could in theory
  have affected Meetings/Guide registration too on unlucky timing, not just Audio's transcode
  — Audio mode's extra processing step just made the failure visible and reproducible. Two
  recordings stranded in the temp staging folder by the pre-fix builds were manually
  recovered (converted to mp3 by hand, moved into the real Audio folder) rather than lost.
  **Confirmed fixed by the user with a real Audio-mode recording (2026-09-09)**: mp3 appeared
  correctly, no leftover `.mov`.
  - Separately, real ffmpeg-invocation issues found and fixed while investigating (still
    correct/worth keeping regardless of the race above): **staging folder** — Audio mode
    records into a temp directory (`AppState.audioStagingDirectory()`, under
    `FileManager.default.temporaryDirectory`) instead of its real save folder, so the real
    Audio folder only ever shows the finished mp3 (or, on failure, the moved-back `.mov`),
    never a transient in-progress file. **stderr is no longer discarded** — the original
    version redirected both `stdout`/`stderr` to `/dev/null`; now captured via a `Pipe`, read
    via `readDataToEndOfFile()` **before** `waitUntilExit()` (reading first avoids a classic
    Process+Pipe deadlock if the child writes enough to fill the pipe before exiting), and
    logged via `NSLog` on any non-zero exit. **`-map 0:a:0`** added to explicitly select track
    1 (the full mix) now that the source file has multiple audio streams.

- **Confirmed working end-to-end by the user (2026-09-09)**: camera renders on top and stays
  enabled in Guide, and an Audio-mode recording correctly ends up as mp3-only with the `.mov`
  gone. **Still not specifically re-confirmed**: whether the camera PiP's exact crop/corner
  looks visually right (functionally on top and enabled, per the above, but framing/size
  wasn't separately called out), and whether the three audio tracks actually contain what
  they're supposed to (mix/mic-only/desktop-only) — worth a quick `ffmpeg -i file.mov` stream
  check next time either area is touched.

## Captain Log mode (added 2026-09-11)

A fourth mode, alongside Meetings/Audio/Guide: full-screen camera only (no screen capture, no
desktop audio), using the same mic-priority resolution as every other mode but explicitly
excluding desktop audio from muting/routing/the watchdog's watched channels — the same shape
Guide had before its 2026-09-09 screen+PiP restructure (see "Recording modes" above), just as
its own mode rather than reusing Guide's. `RecordingMode.captainLog`; title **"Captain Log"**;
icon `person.fill.viewfinder` (a person framed by a camera viewfinder — reads as
"selfie/face-recording" without needing any bundled art, consistent with this app's
SF-Symbols-only icon policy — see the menu-bar-icon lesson in "Architecture" above).

- **New `RecBarConfig.captainLogMode: ModeConfig`** (`sceneName: "Captain Log Recording
  Setup"`, `saveFolder: "~/Documents/Recordings/Captain Log"`, `watchdog: .defaultOff`, same
  reasoning as Guide's off-by-default: a solo-facing-camera recording is expected to have long
  silent stretches while thinking/reading, not the "walked away" case the watchdog exists for).
  Decoded migration-safely like every other field on this struct — an older config.json
  missing the whole `captainLogMode` block (checked via `contains(.captainLogMode)`, not just
  a missing sub-field) falls back to `RecBarConfig.default.captainLogMode` entirely, and
  `ConfigStore.needsMigrationSave` persists it into the user's real file the first time it
  loads.
- **No manual OBS scene setup required, unlike Meetings/Guide's hand-built scenes** — this is
  the one genuinely new piece of machinery this mode needed. Every source Captain Log uses
  (the shared camera input, both shared mic inputs) is already created dynamically via the
  existing `restoreInput`/`releaseInput` mechanism (see "Idle resource minimization" below),
  so the only missing piece for a scene nobody has built yet is the scene itself existing at
  all. `AppState.beginRecording` now calls a new `ensureSceneExists(_:)` (extracted from the
  idle scene's own `ensureIdleSceneExists`, which just calls it with `config.idleSceneName`)
  for **every** mode's scene right before switching to it — a no-op `GetSceneList` check for
  Meetings/Audio/Guide's already-existing scenes, but this is what lets "Captain Log Recording
  Setup" bootstrap itself via `CreateScene` on the very first Captain Log recording, with zero
  manual OBS setup.
- **Shares `cameraRelease` (the same OBS input Guide uses) rather than getting its own
  `ReleasableInputConfig`** — it's the same physical camera device and only one mode ever has
  it live at a time, so there's no risk of the two-configs-racing-for-one-shared-input bug
  already documented for the mic sources (see "First attempt at the mic sources was wrong" in
  "Idle resource minimization" below) — that bug was about the *same scene set* fighting over
  which config's snapshot wins; here it's strictly one live scene at a time. Restored via
  `restoreInput(at: \.cameraRelease, sceneNameOverride: modeConfig.sceneName)`, the same
  shared-input-into-whichever-scene pattern already used for the mic sources.
- **Camera transform forced full-frame every time, not trusted to the snapshot** — Guide's own
  cameraRelease snapshot holds whatever PiP placement Guide last left it at (bottom-right
  square, see "Guide gets a screen recording + camera PiP" above), which would otherwise leak
  into Captain Log's scene via the ordinary restore/snapshot mechanism. New
  `AppState.forceCameraFullFrame(sceneName:)`, called right after `restoreInput` for Captain
  Log only, explicitly sets `boundsType: OBS_BOUNDS_SCALE_OUTER` (scale-to-cover-then-crop —
  same technique as Guide's PiP, just sized to the whole canvas instead of a 360×360 corner)
  with `boundsWidth`/`boundsHeight` read fresh from a live `GetVideoSettings` call each time
  (no dedicated `OBSClient` wrapper exists for this yet — called via the generic
  `obs.request(_:)` — so this is the one caller) rather than hardcoding the canvas resolution,
  so a future canvas-resolution change can't leave this silently wrong.
- **`applyMicrophonePriority`/`applyAudioTrackRouting` both gained an `includeDesktopAudio`
  parameter** (`beginRecording` passes `mode != .captainLog`) rather than being unconditional
  again — Captain Log never restores `desktopAudioRelease` at all (skipped alongside
  `screenRelease` in `beginRecording`, both gated on `mode != .captainLog`), so muting or
  track-routing a source that doesn't exist in OBS would fail with obs-websocket's
  `ResourceNotFound` (600) — the exact "OBS request failed (600): No source was found" class of
  bug already hit and fixed for Guide once before this mode existed (see "Guide-only" entries
  under "Idle resource minimization" below); this reintroduces that same conditional
  deliberately rather than repeating the mistake for a fourth mode.
- **Library/OneDrive window needed zero changes** — `LibraryStore.reconcile`/
  `registerCompletedRecording` and `LibraryView` are already fully generic over
  `RecordingMode.allCases`/`mode.config(config).saveFolder`, so Captain Log recordings are
  tracked, folder-scanned, and shareable exactly like every other mode's the moment the save
  folder (`~/Documents/Recordings/Captain Log`, created on disk alongside the others) has
  anything in it.
- **`SelectionView`'s mode-picker row widened from 300pt to 320pt** (matching
  `RecordingView`'s existing width, so the popover doesn't change width between the idle and
  recording views) and its `HStack` spacing/padding tightened (14→10 / 16→12) to fit a 4th
  button without the row feeling cramped.
- **Not yet verified end-to-end with real hardware** (no GUI automation for native macOS apps
  in this environment — see "Testing notes" below): the scene bootstraps correctly per a clean
  `./build.sh --install` + relaunch and the migrated `config.json` showing the right
  `captainLogMode` block, but a real Captain Log recording (camera actually appears full-frame
  with no screen/desktop-audio, mic priority resolves correctly, the file lands in
  `~/Documents/Recordings/Captain Log`) still needs a walkthrough with the user.

## Microphone priority rule

Priority, highest first: **USB mic > built-in mic**. Bluetooth and wired (headphone-jack)
mics are **never** auto-selected, even as a last resort — if neither a USB nor the built-in
mic can be found, surface an error instead of silently falling back to Bluetooth/wired.
Anything else (virtual devices like a Loom/Zoom virtual audio driver, unrecognized transport
types) is also excluded.

Do not classify by CoreAudio transport type alone: on this hardware, the wired headphone-jack
mic (`External Microphone` / `BuiltInHeadphoneInputDevice`) reports the **same**
`kAudioDeviceTransportTypeBuiltIn` transport as the real built-in mic
(`MacBook Air Microphone` / `BuiltInMicrophoneDevice`). They're told apart by device UID:
`MicrophonePriority.resolve()` only accepts `uid == "BuiltInMicrophoneDevice"` for the
built-in candidate, never any other built-in-transport device.

Because OBS's `USB PnP` (Aux) source's saved `device_id` goes stale the moment the physical
USB mic is unplugged/replugged (this was confirmed as a live bug in the user's existing OBS
setup before this app existed — it was silently falling back to capturing MacBook audio even
with the USB mic connected), `AppState.applyMicrophonePriority(_:)` **always rewrites**
`USB PnP`'s `device_id` via `SetInputSettings` immediately before every recording start when
a USB device is present, rather than trusting whatever's already saved. It then mutes every
mic source except the resolved one (`Headphones Mic` is always muted, never auto-selected)
and force-unmutes `Desktop Sounds`.

## Silence / presence watchdog

While recording, `AppState.tickWatchdog()` (called once a second from the same tick that
drives `elapsed`, so it's automatically suppressed while paused) watches the live level of
whichever mic source `MicrophonePriority` actually resolved to for the current recording —
tracked separately in `resolvedMicSourceName`, deliberately not just "any tracked channel",
since `channelLevels` also includes desktop audio and RecBar must not let a loud screen-share
mask the presenter having gone silent on-mic.

Levels arrive from OBS's `InputVolumeMeters` event as linear multipliers (`inputLevelsMul`),
the same feed that powers the debug drawer's meters — the watchdog reuses that subscription
rather than opening a second one. `silenceThresholdDB` (config, dB) is converted to that same
linear scale via `10^(dB/20)` for comparison.

State machine, all driven off `micLastAboveThresholdDate` and `watchdogPromptDeadline`:
below-threshold for `silenceDurationSeconds` → `watchdogPromptDeadline` gets set
`responseWindowSeconds` out and a `WatchdogNotifier` prompt fires → any confirmation (inline
"I'm here" button, or the notification's action/tap) resets `micLastAboveThresholdDate` and
clears the deadline → recording continues. No confirmation before the deadline →
`autoStopForSilence()` calls the same `stop(discard: false)` path a manual stop button would
(so the file is always kept — `stop()` never quits OBS, same as any other stop), then posts a
confirming notification.

**Prompt not being noticed, root cause confirmed and fix verified end-to-end (2026-08-28).**
User report: a real silence auto-stop fired with no warning seen or heard —
recording just stopped. Both the `UNUserNotificationCenter` banner and the inline popover
banner are conditional in ways a real away-from-keyboard call can easily hit: the system
notification depends on notification permission having actually been granted (requested once,
fire-and-forget, at `WatchdogNotifier.init()` — the result is silently ignored, so a
never-answered or denied permission dialog produces no banner and no error), and the inline
`WatchdogBanner` in `RecordingView` only renders while the popover happens to be open, which
it usually isn't during a call. Neither failure mode leaves any trace for the user to notice
before the 60s window elapses. Fixed with two channels that depend on neither: `AlertSound`
(new file, same synthesized-buffer pattern as `ClickSound`) plays a two-tone chime through
this process's own `AVAudioEngine` — no OS permission involved — the moment the prompt starts
and then repeats every `watchdogAlertRepeatInterval` (8s) for as long as it's unconfirmed,
rather than once, specifically so it can be heard even if the first chime is missed; and the
menu bar icon itself switches to an orange `exclamationmark.triangle.fill` for the duration of
the prompt (`MenuBarIcon` in `RecBarApp.swift`, keyed off `watchdogPromptDeadline != nil`,
takes priority over the normal recording/paused icon) as a glanceable signal that needs
neither the popover open nor any permission grant. The existing notification + inline banner
are kept as additional channels, not replaced.

**Follow-up (2026-08-28, same investigation): the menu bar icon alone was judged too easy to
miss** — it only changes a small glyph in the corner of the screen, no different in kind from
the problem the notification/inline-banner already had. Added a fourth, more assertive channel:
`WatchdogOverlayWindow` (new file, `WatchdogOverlay.swift`) shows a borderless always-on-top
`NSPanel` — styled like the inline `WatchdogBanner` (red background, countdown text, "I'm
here" button wired to the same `confirmPresence()`) — pinned to the top-right corner of the
main screen for as long as the prompt is unconfirmed. `styleMask: [.borderless,
.nonactivatingPanel]` + `becomesKeyOnlyIfNeeded = true` so clicking "I'm here" doesn't steal
focus from whatever call/app has it; `level = .statusBar` + `collectionBehavior:
[.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]` specifically so it still
appears over a **full-screen** Zoom/Meet call, which is exactly the situation this prompt
exists for and the one case none of the other three channels reliably cover (a
`UNUserNotificationCenter` banner can be suppressed by focus modes/DND, the inline popover
banner needs the popover open, and the menu bar icon is invisible behind a full-screen app's
hidden menu bar). Shown from `AppState.tickWatchdog()` at the same point the deadline is set,
hidden from `clearWatchdogPrompt()` (covering confirm, auto-stop, pause, and any other path
back to idle, since `autoStopForSilence()` was refactored to call `clearWatchdogPrompt()`
instead of duplicating its own nil-out + notifier-clear). Countdown text re-renders every
second via `TimelineView(.periodic(from:by:))` rather than depending on `AppState` being
`@ObservedObject` from this separate `NSHostingView`, keeping the overlay decoupled from
`AppState` (takes a `deadline` + `onConfirm` closure only). **Caveat worth flagging**: like the existing
`ClickSound` (already played on every Stop/Pause/Discard button press), `AlertSound` plays
through the default system output device, which Sales/Other Call's `Desktop Sounds`
(`sck_audio_capture`) source can pick up — so the repeating alert chime may itself get baked
into the saved recording's audio while the prompt is active. Not addressed here since silencing
the one channel proven to actually reach the user wasn't the right tradeoff, but worth knowing
if a saved recording has an unexpected chime in it. **Verified end-to-end with real silence by
the user (2026-08-28, after the -35dB threshold fix below): confirmed working perfectly** —
the chime, the menu bar icon, and the top-right overlay panel all appeared as designed and the
"I'm here" flow worked.

**-50dB default threshold unreachable in practice, root cause confirmed from a real recording
(2026-08-28).** User report: recorded 90+ real seconds of silence in a Sales Call and the
watchdog never fired at all — not a missed-notification problem this time, the prompt itself
never started. Root-caused by analyzing the actual saved file
(`~/Documents/Recordings/Sales Meetings/2026-08-28 18-00-48.mov`) with `ffmpeg`'s
`silencedetect` filter at several thresholds: the recording's noise floor never dropped below
roughly -40dBFS for its entire 98s duration (zero silent stretches at -40dB or -50dB, even
1s ones; -35dB fragmented into stretches no longer than ~18s; only -30dB and above produced a
continuous stretch past the 30s `silenceDurationSeconds` requirement). So "-50dB for 30
continuous seconds" was mathematically unreachable in this room/mic setup regardless of how
quiet the user actually was — not a bug in the comparison logic itself. Caveat: OBS had
written identical audio into all 6 output tracks in that file (every source apparently routed
to every track, not split per-source), so this analysis is of the full mixed program audio
(mic + `Desktop Sounds` together), not an isolated mic reading — the true mic-only floor could
be somewhat different, but -50dB being unreachable is unlikely to be an artifact of that.
Fixed two ways: (1) `WatchdogConfig.defaultOn`/`defaultOff` in `Config.swift` changed from
-50dB to -35dB (a deliberately conservative pick based on this one sample — see the comment
there), and the user's existing `config.json` was hand-updated to match for `salesMode`/
`otherMode` (Guide stays at the old default since its watchdog is off anyway and the field is
otherwise unused). (2) More durable fix: the debug drawer (`DebugDrawer` in
`RecordingView.swift`) now shows each tracked channel's live level as an actual dB number
(computed from `peakLevel` via `20*log10`), labels the specific channel the watchdog is
reading `(watched)` (`AppState.resolvedMicSourceName` was `private`, changed to `private(set)`
so the view can read it), and turns that row's text red in real time whenever it's actually
under the active mode's configured threshold — so future threshold tuning can be done by
watching a live number during a real quiet test instead of guessing from a recording
afterward, which is how this bug had to be diagnosed in the first place. Rebuilt, installed to
`/Applications/RecBar.app`, and relaunched. **Verified by the user (2026-08-28): confirmed
working perfectly** — the prompt now actually fires at -35dB and the full watchdog flow
(chime, menu bar icon, overlay panel, auto-stop) completed correctly. Case closed; no further
action pending on the silence watchdog unless a future report reopens it.

Suppression points, all of which clear `watchdogPromptDeadline` (never leave a prompt
in-flight into a state where it shouldn't apply): entering `.paused` (manual or external),
`resetToIdle()` (any path back to idle — manual stop/discard, external stop, an errored
start), and a mode's `watchdog.enabled == false`. Resuming from pause resets
`micLastAboveThresholdDate` to now rather than counting the pause itself as silence.

Per-mode config lives in each `ModeConfig.watchdog` (`WatchdogConfig`: `enabled`,
`silenceThresholdDB`, `silenceDurationSeconds`, `responseWindowSeconds`,
`confirmExtensionSeconds`) rather than a single global block, specifically because Guide
mode's default differs from Sales Call/Other Call's (see `RecBarConfig.default` in
`Config.swift`) — Guide is narrated on-screen with long stretches of intentional on-mic
silence, so it defaults to **off**, while Sales/Other default to **on** (-35dB / 180s / 60s /
420s). `RecBarConfig.decodeModeConfig(_:forKey:defaultWatchdog:)` exists specifically so each
mode can fall back to its own default when loading an older `config.json` that predates this
field — a bug during initial rollout (fixed same day) had this fall through `ModeConfig`'s own
`Decodable init` instead, which has no way to know which mode it's decoding and so defaulted
every mode to "on" including Guide.

**Confirm-extension deadline and all-channel monitoring (2026-08-28, explicit user request).**
Two changes to the trigger condition, on top of the existing threshold/duration mechanics
above:

- `silenceDurationSeconds` default raised from 30s to **3 minutes (180s)**, and a new
  `confirmExtensionSeconds` field (default **7 minutes / 420s**) added: pressing "I'm here"
  now buys `confirmExtensionSeconds` of slack *from the moment of the press*, not just the
  ordinary `silenceDurationSeconds` from last activity — a confirmed "I'm here" is stronger
  evidence of presence than an ordinary pause in talking, so it earns more headroom.
  `AppState.confirmPresence()` sets `watchdogExtendedDeadline = now +
  confirmExtensionSeconds` alongside its existing `micLastAboveThresholdDate` reset.
  `tickWatchdog()` compares two candidate deadlines each tick — the ordinary
  `micLastAboveThresholdDate + silenceDurationSeconds`, and `watchdogExtendedDeadline` (if
  set) — and only actually opens the prompt once **the later of the two** is reached, per this
  user-specified example: press "I'm here" at t=0 (extension deadline t=7min); if real speech
  happens at t=5min and then goes silent again at t=6min, the ordinary deadline recomputes to
  6+3=9min, which is later than the t=7min extension, so *that* wins and the prompt doesn't
  fire until t=9min — not t=7min, and not a naive t=6+3 ignoring the extension either, since
  9 > 7 either way in this example; but if speech happens right after the press and stops
  again almost immediately, the ordinary deadline would recompute to only ~t=3min, which is
  *earlier* than the still-active t=7min extension, so the extension wins instead and the
  prompt fires at t=7min, not t=3min. No extra bookkeeping is needed to make the ordinary
  deadline "win" once it's actually later — `micLastAboveThresholdDate` only advances during
  real activity, so the ordinary deadline it produces only ever grows, meaning it naturally
  overtakes the fixed extension deadline exactly when it should. The extension is cleared
  (`watchdogExtendedDeadline = nil`) the moment either deadline is actually reached and the
  prompt opens, so a stale extension never lingers into the *next* silence cycle.
- The watchdog now monitors **every currently-active audio channel**, not just the resolved
  mic — `AppState.watchdogChannelNames` (resolved mic + `desktopAudioSourceName` for
  Sales/Other Call, resolved mic only for Guide since it never has desktop audio live) is set
  in `beginRecording` and read by `tickWatchdog()`'s `maxWatchedLevel()`, which takes the max
  peak across every channel in that set — any one of them being active counts as "someone's
  here," since a loud screen-share is just as much presence as the presenter's own mic.
  Deliberately excludes the *other*, currently-muted mic source (e.g. built-in mic while a USB
  mic is resolved): a muted source can still pick up ambient room noise that contributes
  nothing to the actual recording, which would mask real silence on the channels that matter
  if it were included. The debug drawer's "(watched)" label and red-below-threshold
  highlighting in `RecordingView.swift` now key off membership in `watchdogChannelNames`
  rather than equality with a single `resolvedMicSourceName`.

Not yet verified end-to-end with real silence (unlike the original watchdog flow, confirmed
2026-08-28 before this change) — the "later deadline wins" logic and multi-channel monitoring
have only been verified by reading the code and by a successful `./build.sh` compile; still
needs a real walkthrough (silence → prompt at ~3min, confirm, speak then re-silence at various
offsets to check both branches of the later-wins comparison, and confirm desktop audio alone
staying loud during Sales/Other Call prevents the prompt from firing even with the mic dead
silent).

**Live on/off toggle in the debug drawer (2026-08-28, explicit user request).** The debug
drawer (expand via the ellipsis button in `RecordingView`) now has a `Toggle` at the top,
labeled with the literal `dog.fill` SF Symbol per the user's request, bound to
`AppState.watchdogEnabled` via `toggleWatchdogEnabled()`. This is a **session-local override
only** — `watchdogEnabled` is seeded from `modeConfig.watchdog.enabled` in `beginRecording`
and reset to `false` in `resetToIdle`, but toggling it never writes to config.json, so the
mode's own configured default (Guide off, Sales/Other on) is unaffected for the *next*
recording. Deliberately no UI for threshold/duration/extension — only on/off, per explicit
request ("I don't want to be able to adjust timing"); those still only come from config.json.
`tickWatchdog()` gates on `watchdogEnabled` (not `watchdog.enabled` from config directly) but
still reads every other field (`silenceThresholdDB`, `silenceDurationSeconds`,
`responseWindowSeconds`, `confirmExtensionSeconds`) from the mode's config as before. Turning
it off while a prompt is already in flight immediately clears it (`toggleWatchdogEnabled`
calls `clearWatchdogPrompt()` + drops `watchdogExtendedDeadline`) rather than letting it
resolve into an auto-stop for a watchdog the user just disabled.

**Debug drawer ellipsis unresponsive during active recording, and couldn't be collapsed once
opened — root cause confirmed, not a timing/race issue (2026-08-28).** User report: pressing
the ellipsis (⋯) button to expand the debug drawer did nothing while actively recording, only
worked once paused, and even then a second press wouldn't collapse it again. Root cause:
`RecBarApp.swift`'s `PopoverContent` had `.onAppear { appState.debugDrawerExpanded = false }`
attached to the `Group` wrapping the `SelectionView`/`RecordingView` switch, intended (per its
own comment) to reset the drawer only when the *popover itself* was freshly reopened. In
practice `.onAppear` on that conditional content re-fired on effectively every AppState-driven
re-render — most consequentially the once-a-second `elapsed` tick (`tickElapsed`/
`tickWatchdog`, which only run while `recordingState == .recording`, never while `.paused` —
exactly matching why the bug was paused-only-workable) — forcibly resetting
`debugDrawerExpanded` back to `false` within roughly a second of any toggle, so the drawer
could never stay open long enough to register as "opened" while actively recording, and even
while paused (where the churn is far less frequent, from meter events, but not zero) a second
press to collapse would just as easily race a spurious auto-reset that had already happened
moments earlier. Fixed by deleting the `.onAppear` reset entirely and moving the collapse to
`AppState.resetToIdle()` (`debugDrawerExpanded = false` alongside the other end-of-recording
resets) — a real, one-time state transition (a recording actually ending) rather than a
render-frequency-dependent hook, so each new recording still starts with the drawer collapsed
without anything fighting the user's own toggle while one is in progress. Verified only by
reading the code and a clean `./build.sh` compile — not yet walked through live (see
`CLAUDE.md`'s "Testing notes" for why: no GUI automation for native macOS apps in this
environment); worth confirming the ellipsis now toggles freely in both directions while
actively recording, not just while paused.

## Idle resource minimization

Since RecBar never quits OBS (see "OBS auto-launch/quit" above), a hidden-but-running OBS
would otherwise sit indefinitely on whatever scene it was last recording with — live screen
capture, desktop audio, and mic sources, plus (worse) the camera — burning CPU and, for the
camera specifically, leaving the hardware indicator lit for no reason. `AppState.goIdleInOBS()`
runs from every path back to idle (`resetToIdle()`, so: manual/external/watchdog-auto stop,
and `syncFromOBS()` finding OBS already idle at connect time) and from a failed `start()` (to
recover from a partial setup), and does two things:

- **Switches to an idle scene** (`config.idleSceneName`, default `"RecBar Idle"`,
  auto-created via `CreateScene` the first time it's needed). Confirmed by direct testing
  (2026-08-22) that a *real* scene switch — unlike merely disabling scene items in place,
  which was tried first and does **not** work, see "Graceful-shutdown investigation" above —
  does stop a `sck_audio_capture`/`screen_capture` source's underlying capture thread: CPU
  dropped from ~15% to ~11% on this machine switching off a scene with `Desktop Sounds` +
  `Screen`, and a subsequent quit no longer crashed (the ScreenCaptureKit thread was
  genuinely gone, not just hidden).
- **Removes capture inputs that OBS keeps live regardless of the active scene** — the camera
  (`config.cameraRelease`), screen capture (`config.screenRelease`), desktop audio
  (`config.desktopAudioRelease`), and the two mic sources shared by every mode, `Macbook` and
  `Headphones Mic` (`config.micBuiltInRelease` / `config.micWiredRelease`) — via the same
  generalized `AppState.releaseInput(at:)` / `restoreInput(at:sceneNameOverride:)` pair, keyed
  by a `WritableKeyPath<RecBarConfig, ReleasableInputConfig>`. The scene-switch trick does
  **not** work for any of these: direct testing showed the `macos-avcapture-fast` camera
  source (misleadingly named `Capture Card Device` in this scene collection — it's actually
  the built-in FaceTime HD Camera) opens the physical device once, at OBS launch/scene-
  collection-load time, and holds it open for the entire OBS session regardless of which scene
  is current — switching away and back produced no new "Capturing" log line — and OBS mixes
  audio-producing sources (mic/aux capture, desktop audio capture) globally rather than gating
  them by the active scene, so `Macbook`/`Headphones Mic` stayed open the same way even after
  the idle-scene switch (2026-08-22 follow-up report: Meet Recording Setup still showed live
  capture and both mic sources "on" after going idle — screen/desktop-audio were already
  covered by then, mics weren't yet). So `releaseInput(at:)` actually removes the input
  (`RemoveInput`) whenever RecBar goes idle, snapshotting its live kind/settings/enabled-state/
  scene-item-transform into that keyPath's `lastKnown*` fields first (via
  `OBSClient.findSceneItem`, filtered to the writable transform keys — see
  `AppState.writableTransformKeys` — since `GetSceneItemList` also returns several read-only
  computed ones like `sourceWidth`/`sourceHeight` that `SetSceneItemTransform` doesn't accept)
  so it can be recreated identically — including placement, so a manually resized/repositioned
  source doesn't reset to full-frame every cycle. `restoreInput(at:)` recreates it
  (`CreateInput` + `SetSceneItemEnabled` + `SetSceneItemTransform`) right before a recording
  that needs it starts: camera for **Guide** mode, screen + desktop audio for
  **Sales Call/Other Call**, and both mic sources for every mode, recreated into whichever
  real scene (`modeConfig.sceneName`) the mode about to start actually uses, via
  `restoreInput`'s `sceneNameOverride` parameter. Both directions are no-ops if the source is
  already in the state they'd produce (already removed, or already present), and
  `releaseInput(at:)` silently no-ops if the source was never seen live yet (nothing to
  snapshot).
  - **First attempt at the mic sources was wrong, root cause confirmed (2026-08-22).**
    `Macbook`/`Headphones Mic` are each a single shared OBS input, but the first
    implementation gave each one **two** `ReleasableInputConfig` entries (one per real scene,
    same `inputName`) mirroring camera/screen/desktop-audio's single-scene shape. Since
    `goIdleInOBS` always released the Meet entry before the Guide entry, and it's the *same*
    global input, the Meet release always won the live snapshot (`GetInputSettings` succeeds,
    `RemoveInput` fires) and the Guide release's own `GetInputSettings` then always found it
    already gone — so the Guide entry's snapshot stayed empty forever and its `restoreInput`
    silently no-op'd on every single Guide attempt. `Macbook`/`Headphones Mic` then never
    existed at all in Guide Recording Setup, and `applyMicrophonePriority` unconditionally
    tries to mute them by name — failing with `OBS request failed (600): No source was found`,
    obs-websocket's real `ResourceNotFound`, not a UI placeholder (initially misdiagnosed as
    the camera's own "No sources were found" placeholder text before confirming otherwise from
    OBS's own per-request log at `~/Library/Application Support/obs-studio/logs/`, which is far
    more useful for this than the noisy unified system log). Fixed by collapsing back to a
    single config per mic source with the target scene passed explicitly at restore time
    (`sceneNameOverride`) instead of baked into `ReleasableInputConfig.sceneName` — correct
    because these are audio-only sources with no meaningful per-scene transform to preserve
    anyway, so there's no real reason to snapshot them per-scene in the first place.
  - **`USB PnP` (the global Aux Audio Device 1 slot, not a scene item — see "OBS scenes &
    sources" above) was never included in any of this, root cause confirmed (2026-08-28,
    real-usage bug report: macOS's mic-in-use menu bar indicator stayed lit after stopping a
    recording that had used the USB mic).** Since it's a global source rather than a scene
    item, it can't go through `releaseInput`/`restoreInput`'s `CreateInput`-into-a-scene
    machinery at all — and nothing else ever muted or released it at idle either, so once a
    recording used the USB mic, its physical device stayed open indefinitely (same underlying
    reason `Macbook`/`Headphones Mic` needed real `RemoveInput` treatment above: OBS's audio
    plugins keep the CoreAudio device open for metering/mixing regardless of mute state, so
    muting alone was never going to release it, even if `goIdleInOBS` had muted it). Fixed
    with a narrower, USB-PnP-specific method, `AppState.releaseUSBMicIfLive()` (called from
    `goIdleInOBS`, not part of the generic `ReleasableInputConfig` mechanism since there's no
    scene item to snapshot): mutes it and clears its `device_id` to `""`. Clearing (rather
    than removing the input outright, which isn't meaningful for a global Aux slot) is enough
    here because `applyMicrophonePriority` already unconditionally rewrites a fresh
    `device_id` immediately before every recording start when a USB mic is present (see
    "Microphone priority rule" above) — so there's nothing to snapshot/restore the way there
    is for the removed/recreated scene-item inputs. Not yet verified end-to-end with real
    hardware (a real USB mic unplug/replug or a real stop-then-check-the-menu-bar-dot) — only
    by reading the code and a clean `./build.sh` compile.
- `RemoveInput` was originally believed to be merely **flaky/eventually-consistent** on this
  OBS build (a `GetInputList` sometimes still showed the "removed" input for several seconds
  before it actually disappeared, no clear trigger found). **Confirmed worse (2026-08-22,
  real-usage bug report — see "Camera stuck open after a real recording" below): once the
  camera source has actually been through one live recording, `RemoveInput` can report
  success while the underlying `AVCaptureSession` never tears down at all** — reproduced
  directly against a live instance, stuck 10+ minutes and multiple retries (including
  disabling the scene item first, and clearing the `device` setting first), with zero
  corresponding OBS log activity either way. The only thing that reliably cleared it was
  quitting and relaunching OBS by hand. `releaseCameraIfConfigured()` now re-issues
  `RemoveInput` up to 3 times with a verifying `GetInputList` between attempts (in case it's
  genuinely just slow sometimes, per the original flakiness report) and `NSLog`s loudly if the
  camera is still present afterward, rather than silently claiming success like before — but
  there's no known websocket-reachable fix for the underlying stuck case itself.

**Idle-transition/beginRecording race, real bug but not the reported one (2026-08-22).** User
report: pressing Guide repeatedly failed with an OBS error, and the OBS log showed
`Capture Card Device` created three separate times with heavy scene-bouncing between attempts.
Investigated by reading `~/Library/Application Support/obs-studio/logs/` directly (the
structured per-request OBS log, more useful here than the noisy unified system log): scene
switches were firing every ~0.4s starting immediately at OBS launch/connect, well before any
mode button was pressed. `resetToIdle()` (called from `stop()`, from an external
`RecordStateChanged` stop event, and from `syncFromOBS()` finding OBS already idle at connect)
can't `await` from its synchronous context, so it kicked off `goIdleInOBS()` as a bare
`Task { ... }` and returned immediately — `isBusy` cleared right away even though that
detached task could still be mid-flight for several seconds (now cycling through every scene,
up to 3 attempts, for 5 separate released inputs since mic release was added — see "Idle
resource minimization" above). Nothing stopped `beginRecording()` from starting concurrently
with that stale task once `isBusy` was clear, so both were calling `SetCurrentProgramScene` at
the same time. This is a real bug and worth having fixed regardless (`AppState.idleTransitionTask`
now tracks whatever `goIdleInOBS()` task `resetToIdle()` last kicked off; `beginRecording()`
awaits it, if still running, before doing anything else — no cancellation, just waits for the
in-flight cleanup to actually finish first) — **but it turned out not to be what was actually
causing the reported error.** The user's exact error text, obtained on a follow-up report
("still the same error"), was `OBS request failed (600): No source was found` — a real
obs-websocket `ResourceNotFound` response, not OBS's own camera-placeholder text as first
(wrongly) guessed from the vaguer initial report. The real causes were two separate bugs, both
in the mic-source handling added alongside screen/desktop-audio release — see the "First
attempt at the mic sources was wrong" entry under "Idle resource minimization" above, and the
`includeDesktopAudio` fix on `applyMicrophonePriority` described next.

**`applyMicrophonePriority` unconditionally muting a Guide-nonexistent source, root cause
confirmed (2026-08-22).** The other half of the same `OBS request failed (600)` report:
`applyMicrophonePriority` always called `SetInputMute` on `sources.desktopAudioSourceName`
("Desktop Sounds") regardless of mode. That source is only ever restored in the Sales/Other
Call branch of `beginRecording` (Guide never uses it — see `config.desktopAudioRelease`),
while `goIdleInOBS()` unconditionally releases (removes) it on every idle transition — so
after any idle transition following a Sales/Other Call recording, i.e. any time Guide was
tried after the other modes had been used at all, the source no longer existed by the time
Guide's `applyMicrophonePriority` tried to mute it. This is why it only ever affected Guide.
Fixed: `applyMicrophonePriority` now takes an `includeDesktopAudio` flag
(`AppState.beginRecording` passes `mode != .guide`) and skips the desktop-audio mute entirely
for Guide.

**Guide-only "OBS request failed (600): No source was found", root cause confirmed
(2026-08-22).** Same investigation, a second distinct bug: `applyMicrophonePriority` always
unconditionally muted `sources.desktopAudioSourceName` ("Desktop Sounds") regardless of mode.
`desktopAudioSourceName` is only ever restored in the Sales/Other Call branch of
`beginRecording` (Guide never uses it — see `config.desktopAudioRelease`), while
`goIdleInOBS()` unconditionally releases (removes) it on every idle transition. So after any
idle transition following a Sales/Other Call recording — i.e. any time Guide is tried after
the other modes have been used at all — the source doesn't exist anymore by the time Guide's
`applyMicrophonePriority` tries to mute it, hence the 600 (`ResourceNotFound`). This is why it
only ever affected Guide and nothing else. Fixed: `applyMicrophonePriority` now takes an
`includeDesktopAudio` flag (`AppState.beginRecording` passes `mode != .guide`) and skips the
desktop-audio mute entirely for Guide.

Not yet verified: none of this has been walked through via RecBar itself end-to-end (only via
a standalone probe script issuing the identical obs-websocket requests against the real
running OBS instance — see "Idle resource minimization, verified via probe" in Testing notes)
since GUI automation for native macOS apps isn't available in this environment.

## Library window & OneDrive sharing

Added 2026-09-09 (explicit user request) on top of the recording pipeline above: a separate
window (not the menu-bar popover) listing every recording RecBar has made across the three
per-mode save folders in one place, tagged by category, with local move/rename and an optional
per-file OneDrive share link.

- **Tracking**: `LibraryStore` persists an array of `RecordingMetadata` (stable `UUID` identity,
  independent of filename/path) to its own `~/Library/Application Support/RecBar/library.json`,
  mirroring `ConfigStore`'s exact load/save shape (same directory, same atomic
  `[.prettyPrinted, .sortedKeys]` write). Entries are created the instant a kept recording
  finishes — `AppState.stop(discard:)` calls `LibraryStore.registerCompletedRecording(path:
  mode:)` using the `outputPath` OBS's `StopRecord` response already returns, *before*
  `resetToIdle()` nils `currentMode` — rather than waiting for a folder scan to notice a new
  file. `LibraryStore.reconcile(config:)` (run on `LibraryViewModel`'s `start()` and then every
  4s on a plain `Timer` while the Library window is open — no FSEvents/DispatchSource infra
  exists anywhere in this codebase, so this mirrors the elapsed-time timer's own established
  idiom rather than introducing new machinery) separately folder-scans all three `saveFolder`s
  for untracked video files (pre-existing recordings, or a mode never opened in the Library
  before) and prunes entries whose local file is gone: gone-and-never-cloud-linked (`
  cloudWebUrl == nil`) is deleted outright ("just disappears," per spec), gone-but-cloud-linked
  keeps its entry with `lastKnownLocalPath` cleared (cloud-only from then on) — `cloudWebUrl`
  rather than `cloudUploadState` is the signal for "has a live cloud presence worth keeping,"
  since a link already exists (and was already shown to the user) the moment the placeholder
  is created, before the real upload even starts.
- **Local actions**: rename (`LibraryViewModel.rename`) moves the local file in place and, if
  a cloud item exists, also `PATCH`es its name via `OneDriveClient.rename` — local-only if the
  file's already gone, cloud-only is not possible to *initiate* (rename UI needs a row, which
  always has at least one of the two) but is exactly what happens if the local half of that
  same call fails to find a path. "Reveal in Finder" (`NSWorkspace.activateFileViewerSelecting`)
  and a "Move to Folder…" `NSOpenPanel` + `FileManager.moveItem` fallback live in a row's `…`
  menu.
- **Drag-to-move**: real move-to-Finder semantics (the file actually leaves the folder, not a
  copy) need `NSFilePromiseProvider` — plain SwiftUI `.onDrag`/`.draggable` backed by a file
  `URL` only produces a Finder copy. `FilePromiseDragHandle` (`NSViewRepresentable`) wraps a
  minimal custom `NSView`/`NSDraggingSource` just for the row's grip glyph; AppKit's promise
  callback (`writePromiseTo:`) does the actual `FileManager.moveItem` to wherever Finder chose,
  then hops back to `LibraryViewModel.fileMovedOut()` → `reconcile()` — the app never needs to
  know *where* the file went, only that it's gone, which the existing prune logic already
  handles. **Row list must not be a SwiftUI `List` on macOS** — confirmed by real-usage report
  (2026-09-09): drag did nothing at all while every other control (buttons, rename) worked
  fine, because `List` is backed by `NSTableView`, which intercepts `mouseDown` for its own row
  tracking before it ever reaches a custom subview's `NSView`. Fixed by using a plain
  `ScrollView`/`LazyVStack` instead, which has no competing event handling. Also worth noting:
  the drag-handle `NSView` draws nothing itself (it's a pure hit-target) — `RecordingRow`
  overlays a static `line.3.horizontal` SF Symbol underneath it purely as a visible affordance,
  since a real user (not just a script) needs to see something to grab. **Verified working by
  the user, 2026-09-09.**
- **OneDrive sharing** (hand-rolled against Microsoft Graph, no MSAL/third-party SDK — same
  zero-dependency ethos as `OBSClient`'s own hand-rolled obs-websocket protocol; **not yet
  verified end-to-end** — needs a real Azure app registration + populated `config.json`
  `oneDrive.clientId`, which hadn't happened as of this writing):
  - `OneDriveAuth` — OAuth2 **device code flow** against the `consumers` tenant (personal
    Microsoft accounts, per explicit user choice over work/school), scopes `Files.ReadWrite
    offline_access`. Chosen over an embedded-webview/redirect auth-code flow because this is a
    menu-bar app with no webview and no registered custom URL scheme. Only the refresh token
    is persisted (`KeychainHelper`, plain `Security` framework calls — no entitlements needed,
    RecBar isn't sandboxed); the access token lives in memory only, re-minted on demand.
    Requires the Azure app registration to have **"Allow public client flows" enabled**, or
    device code flow fails outright (`AADSTS7000218`) since there's deliberately no client
    secret in this design (a public client's device-code/refresh tokens don't need one).
  - `OneDriveClient`'s upload sequence, in order, is the mechanism behind "see the link
    immediately, then the real video replaces the placeholder without the link changing":
    (1) resolve/create `{oneDrive.rootFolderName}/{category}` folder, (2) `PUT` a tiny
    placeholder file to get a real `DriveItem` id, (3) `POST .../createLink` (anonymous,
    view-only) on that id — shown to the user right away, before any real bytes move —
    (4) `POST .../createUploadSession` **scoped to that same existing item id** (not a new
    item) and `PUT` sequential chunks (8 MiB, a multiple of Graph's required 320 KiB
    granularity) via `FileHandle` so multi-GB recordings never load fully into memory; scoping
    the session to the existing id is what's expected to preserve the same id/link once
    content-replacement finishes — this is the one Graph-behavior assumption in the whole
    design that most needs confirming against a real account. An app relaunch mid-upload does
    **not** attempt to resume the interrupted session (Graph's upload-session validity window
    isn't something to bet on with confidence) — it just restarts `createUploadSession` from
    byte 0 against the same item id next time the row's cloud button is retried.
  - **Delete/restore (2026-09-10, explicit user request — supersedes the earlier "no
    delete-from-cloud action" design note below).** A row's `…` menu now offers "Copy Link"
    (when `cloudWebUrl != nil`), "Delete Locally" (when a local copy exists), and "Delete from
    Cloud" (when `cloudUploadState == .uploaded`) — both deletes are per-*side*, not
    per-entry, gated behind a `confirmationDialog` since the local delete uses
    `FileManager.trashItem` (Trash, not a hard delete) but the cloud delete has no equivalent
    undo. `LibraryViewModel.deleteLocal`/`deleteCloud` only drop the `RecordingMetadata` entry
    entirely (`LibraryStore.remove`) once **both** sides are gone; losing just one side leaves
    the entry in a restorable state instead — a cloud-only entry (local side gone, cloud
    still live — the same state `reconcile`'s prune logic already produces for an
    externally-deleted file with a cloud link) gets a "Restore Locally" menu item
    (`LibraryViewModel.restoreLocal`, `OneDriveClient.downloadFile`, streamed straight to disk
    via `URLSession.download` rather than `data(for:)` so a multi-GB recording is never fully
    memory-resident) that re-downloads it into `item.category.config(config).saveFolder`; a
    local-only entry after a cloud delete needs no separate "restore" action since the
    existing upload button (already gated on `cloudUploadState == .none`, which the cloud
    delete resets it to) already serves as "restore to cloud." `OneDriveClient.delete` treats
    a `404` as success (already-gone is the desired end state either way). None of this is
    yet verified against a real OneDrive account — same caveat as the rest of this section.
  - `RecBarConfig.oneDrive: OneDriveConfig` (`clientId` empty by default, `rootFolderName`
    defaulting to `"RecBar Recordings"`) follows the same migration-safe
    `decodeIfPresent(...) ?? default` pattern as every other field added to this struct — an
    empty `clientId` makes the Library window's cloud button surface a clear "set
    oneDrive.clientId in config.json first" message rather than failing silently.

## Build / install

No Xcode.app is installed on this machine (only Command Line Tools), so this is a Swift
Package (`Package.swift`, executable target), not an `.xcodeproj` — `xcodebuild` is
unavailable. `build.sh` runs `swift build -c release`, then hand-assembles
`dist/RecBar.app` (`Contents/MacOS`, `Contents/Info.plist` from `Resources/Info.plist`) and
ad-hoc code-signs it (`codesign --force --deep --sign -`). `./build.sh --install` also copies
it to `/Applications/RecBar.app`. `Package.swift`'s `platforms` minimum was bumped from
`.v13` to `.v14` (and `Resources/Info.plist`'s `LSMinimumSystemVersion` to match) on
2026-09-09 specifically for the Library window's single-instance `Window` scene type, which
isn't available on macOS 13 — see "Library window & OneDrive sharing".

## Git workflow

Small, frequent, buildable commits — run `./build.sh` before every commit, fix before
committing if it fails, then `git add -A && git commit && git push`. Don't batch unrelated
changes into one commit.

## Testing notes

- **Meetings/Audio/Guide rename + restructure (2026-09-09)**: build/install/launch/quit
  confirmed clean, folder rename verified (identical file counts before/after, every
  `library.json` entry's rewritten path confirmed to still resolve to a real file). First
  real Guide/Audio recording surfaced 3 bugs (camera hidden behind screen + sometimes off,
  Audio mode leaving only a `.mov`) — see "Recording modes" above for the fixes, including
  the real root cause of the Audio bug (a `currentMode`-nil'd-before-read race in
  `stop(discard:)`, not an ffmpeg problem). **Confirmed fixed by the user with real
  recordings (2026-09-09)**: camera renders on top and stays enabled in Guide; Audio mode
  correctly produces an mp3 with no leftover `.mov`. Still not specifically re-confirmed:
  camera PiP framing/crop quality, and whether the three audio tracks actually split as
  intended (inspect a saved file with `ffmpeg -i file.mov` to check per-track content) — worth
  a quick look next time either area is touched, but not blocking.

Confirmed end-to-end with real hardware (2026-08-21): built, installed to
`/Applications/RecBar.app`, launched (menu bar icon appears, no Dock icon), connected to a
running OBS with its WebSocket server manually enabled first, and completed a full
start → pause → resume → stop cycle with the file landing in the right save folder.

No Xcode/simulator and no GUI automation for native macOS apps is available in this
environment (only Chrome browser automation) — anything requiring an actual click, a real
OBS instance, or real audio hardware needs to be walked through with the user rather than
self-certified. This applies especially to:

- **Library window — local file management, verified 2026-09-09**: window opens via the new
  popover header button, lists tracked recordings, and drag-out-to-Finder (real move, not
  copy) confirmed working by the user after fixing the `List`/`NSTableView` mouseDown
  interception bug (see "Library window & OneDrive sharing"). Rename and "Move to Folder…"
  were not specifically called out as tested in that pass — worth confirming if either is
  touched again.
- **Library window — OneDrive sharing, confirmed working end-to-end (2026-09-09)**: an Azure
  app registration was created (public client, "Allow public client flows" on,
  `Files.ReadWrite`/`offline_access` delegated permissions against `consumers`) and its Client
  ID set in `config.json`'s `oneDrive.clientId`. The user confirmed the full flow works:
  device-code sign-in, the placeholder+link creation, upload progress, and the completed
  green-checkmark state. This validates the one real Graph-behavior assumption the design
  depended on — that scoping `createUploadSession` to the placeholder's existing item id keeps
  the same id/link valid once the real content replaces it. Not specifically re-confirmed in
  that pass: rename syncing to the cloud copy, and behavior once the local file is later moved
  or deleted after a successful upload (cloud-only state) — worth a follow-up check if either
  is touched again.
- **Auto-launch-hidden-OBS** (`OBSLauncher`): needs manual verification that OBS actually
  comes up with no window/Dock flash (depends on the user having enabled OBS's own *Settings
  → General → System Tray* → "Run OBS in System Tray when minimized" + "Minimize to Tray
  instead of Taskbar" first — this can't be driven via the API, see README's "Launching OBS
  automatically"), and that the subsequent recording start proceeds normally once connected.
- **Ownership boundary**: start a recording with OBS *already* open (opened by the user, not
  RecBar) and confirm RecBar neither hides nor quits that instance at any point — trivially
  true now that RecBar never quits OBS at all, but still worth confirming it doesn't hide a
  pre-existing window either.

RecBar no longer auto-quits OBS under any circumstances (see "OBS quit-time crash bug"
below) — the previous `quitObsAfterEachRecording` config flag and the auto-quit-on-RecBar-exit
path were both removed rather than left opt-in, so there's nothing left to verify here.

**Idle resource minimization, verified via probe only (2026-08-22)** — see "Idle resource
minimization" above for the design. Every individual obs-websocket call this feature makes
(`CreateScene`, `SetCurrentProgramScene` to the idle scene, `GetInputSettings` +
`GetSceneItemList`/enabled/transform snapshot, `RemoveInput`, `CreateInput`,
`SetSceneItemEnabled`, `SetSceneItemTransform`) was driven directly against the real running
OBS instance via a standalone probe script and confirmed to do exactly what `AppState`'s code
does — including a full release → recreate cycle for the real `Capture Card Device`
(camera) source, confirmed via the OBS log re-showing `Capturing 'FaceTime HD Camera'` on
recreation, and the recreated scene item landing with the same kind/settings/enabled/transform
as the snapshot. What's **not yet verified** is the same flow driven through RecBar's actual
UI (clicking Start/Stop, not a probe script issuing the identical requests) — needs a real
walkthrough with the user:
- Start and stop a Sales/Other Call recording, confirm OBS lands on the idle scene afterward
  (not left on `Meet Recording Setup`) and stays there until the next recording starts.
- Start and stop a **Guide** recording specifically, and confirm the camera indicator
  (assuming it's actually enabled/used in that scene) turns off again afterward, not just
  that the source gets removed under the hood.
- If the camera source is ever manually repositioned/resized in OBS while enabled, confirm a
  release → restore cycle preserves that placement rather than resetting to full-frame.
- Confirm the camera indicator turns off within a few seconds of stopping a Guide recording
  (see "Camera stuck open after a real recording" below — as of 2026-08-22 this cannot yet be
  guaranteed; watch for it specifically).
- Confirm a fresh install (no `lastKnownSettingsJSON` cached yet) doesn't error on the first
  Guide recording before RecBar has ever seen the camera live — `restoreCameraForGuideMode()`
  should just no-op silently in that case, not block the recording from starting.

**Silence / presence watchdog — core flow verified end-to-end with real audio (2026-08-28).**
Built and config-migration-tested since 2026-08-21; the actual silence → prompt → auto-stop
sequence, including the -35dB threshold fix and all four alert channels (inline banner,
notification, `AlertSound` chime, menu bar icon, top-right `WatchdogOverlayWindow`), was
walked end-to-end by the user with real silence and **confirmed working perfectly** — see
"Prompt not being noticed" and "-50dB default threshold unreachable" above. Case closed for
the core flow. A few finer-grained edge cases from the original checklist were not
specifically called out as tested and are worth keeping in mind if the watchdog is touched
again or a new report comes in:
- Whether the `WatchdogOverlayWindow` panel specifically survives a **full-screen** (not just
  windowed) Zoom/Meet call — this was the whole reason for that panel's `.fullScreenAuxiliary`
  collection behavior, but wasn't singled out in the confirmation.
- Whether pausing mid-recording during an active prompt correctly suppresses it, and that
  resuming doesn't immediately re-trigger.
- Whether Guide mode still correctly never prompts (watchdog off by default there).
- One bug already caught and fixed before any of the above: the initial migration path
  defaulted Guide's watchdog to "on" instead of "off" for pre-existing `config.json` files
  (see "Silence / presence watchdog" architecture section above) — this machine's real
  `config.json` was hand-corrected after the fix; a fresh install wouldn't have hit it.

**Resolved investigation, root cause confirmed (2026-08-21): OBS Studio 32.2.2 has a
pre-existing crash bug triggered by quitting it, unrelated to RecBar.** Eight crash reports
the same evening (`~/Library/Logs/DiagnosticReports/OBS-*.ips`), all the *identical*
signature: segfault in `copy_audio_data` ← `obs_source_output_audio` (libobs internals) on an
audio IO thread (`com.apple.audio.IOThread.client`, CoreAudio HAL) or the ScreenCaptureKit
desktop-audio callback (`screen_stream_audio_update`, the `Desktop Sounds` source), same
invalid address (`0x0000000000000038`) every time. Root-caused via a standalone diagnostic
harness (`obsprobe`/`obslaunch`/`obsquit` — three small Swift CLI scripts talking
obs-websocket and `NSRunningApplication` directly, not part of the app, not committed) that
could launch/configure/quit OBS with fine-grained control independent of RecBar:

- Two initial theories were tested and **ruled out**: (1) that manual `osascript ... quit`
  test commands were the cause — disproven, since three of the eight crashes predate any
  testing this session; (2) that RecBar's `SetInputSettings`/`SetInputMute` calls race OBS's
  audio subsystem right after a cold launch — disproven by a trial where the probe recorded,
  stopped, and waited 8s with **zero** crash, then crashed a few seconds into an external
  `terminate()` call with no further RecBar interaction at all.
- **Confirmed root cause**: OBS crashes during its own shutdown teardown, racing an actively-
  capturing audio source's IO thread against its own destruction — reproduced even with a
  `terminate()` sent to an instance the probe never once connected to (so zero requests of
  any kind were sent). This makes it OBS's own bug, not fixable from RecBar's side; a
  `--disable-shutdown-check` CLI flag was tried as a mitigation for the resulting Safe Mode
  prompt but **does not exist** in this OBS version (confirmed via `OBS --help`) and was a
  bad assumption — removed from `OBSLauncher`. There's no supported flag to suppress that
  dialog; `--safe-mode` exists but disables the websocket plugin RecBar depends on.
- **Practical consequence**: every OBS crash marks its state as "unclean," so the *next*
  launch shows OBS's own modal "did not shut down properly, start in Safe Mode?" prompt —
  which `.hide()` does not reliably suppress — blocking `obs-websocket` from coming up until
  a human answers it. This was originally mitigated by defaulting `quitObsAfterEachRecording`
  to `false` to minimize how often RecBar triggered a quit; as of 2026-08-22, RecBar was
  changed to **never quit OBS at all** (see `OBSLauncher`/`AppState`/`RecBarApp` — the config
  flag, the post-stop quit call, and the `applicationWillTerminate` quit-on-exit path were all
  removed), which sidesteps the crash entirely rather than just reducing exposure to it. The
  tradeoff is that a RecBar-launched OBS instance now always lingers after RecBar exits or
  after a recording stops — the user quits OBS by hand when they're done with it.
- **Still open**: whether the underlying crash is fixed in a newer/older OBS build (this
  machine is on 32.2.2, up from the 32.2.1 originally documented — see "Graceful-shutdown
  investigation" below for why no app-side workaround was found). RecBar's 3s post-cold-launch
  settle delay (`justLaunchedOBS` in `AppState.beginRecording`) was kept since it's harmless,
  but it was never actually addressing this bug (the bug is quit-time, not launch-time) —
  don't mistake its presence for a fix.

**Graceful-shutdown investigation, negative result (2026-08-22).** Before removing auto-quit
entirely, tried to find a quit sequence that avoids the crash, using a standalone
obs-websocket probe script (scratch-only, not committed) against the real running OBS
instance, with `System Events` accessibility queries (window/button titles — never
`screencapture`, to avoid capturing whatever else is on screen) to detect the resulting Safe
Mode dialog without a screenshot:
- Plain quit (`osascript quit`/`NSRunningApplication.terminate()` equivalent) from an idle,
  fully-loaded instance: crashed, identical signature to the original 8 (`copy_audio_data` ←
  `obs_source_output_audio` ← `screen_stream_audio_update` on
  `com.screenCaptureKit.audioSampleHandlerQueue`).
- **Disabling every scene item first** (`SetSceneItemEnabled: false` on all items in the
  active scene, including `Desktop Sounds`), waited, then quit: **still crashed, identical
  signature.** Confirms `SetSceneItemEnabled` doesn't actually stop a
  ScreenCaptureKit-backed source's underlying `SCStream` — disabling only affects
  rendering/mixing, not the capture backend, so the audio callback thread stays live
  regardless of scene visibility.
- **Removing a ScreenCaptureKit source outright while OBS keeps running** (`RemoveInput` on a
  throwaway `sck_audio_capture` test source/scene created and torn down for this purpose,
  never the real `Desktop Sounds`/scenes): **did not crash.** So destroying this source type
  is safe in general — the bug is specifically in OBS's own process-exit teardown *ordering*
  (something gets torn down out of order only during actual process shutdown), not in
  destroying the source itself.
- **Conclusion**: there's no websocket-reachable way to make quit-time teardown safe. The one
  theoretical workaround (remove every capture source right before quitting, so none are
  "active" when the process actually exits) was ruled out as impractical: it would need to
  mutate the user's real scene collection immediately before every quit and reliably restore
  it after, and offers no real safety margin anyway, since RecBar has no way to quit
  "immediately" after removal without the removal itself being persisted mid-session. This
  result is what settled the decision (see "OBS auto-launch/quit" above) to remove auto-quit
  entirely rather than keep chasing a safe quit sequence.

**Camera stuck open after a real recording, root cause confirmed (2026-08-22).** User report:
camera indicator stayed lit well after stopping a Guide recording, contradicting the "verified
via probe" idle-resource-minimization claim above. Root-caused by connecting a standalone
websocket probe script (scratch-only, not committed) directly to the user's live OBS instance,
bypassing RecBar entirely:
- `RemoveInput` on `Capture Card Device` returned success (`{}`), but a follow-up
  `GetInputList` still showed it present — repeated polling over 30s, then again several
  minutes later, then a third direct retry: **still present every time**, 10+ minutes total,
  well past the "several seconds" flakiness the original probe testing had documented.
- Tried disabling the scene item first, then removing: no change. Tried clearing the input's
  `device` setting directly (to force the plugin to tear down its capture pipeline): no
  change, and no corresponding OBS log line either way — `GetSourceActive` even reported
  `videoActive: false` the whole time, so OBS's own bookkeeping considered the source
  inactive while the physical `AVCaptureSession` stayed open regardless.
- **This only reproduced after the source had been through one real `StartRecord`/
  `StopRecord` cycle** — the original "verified via probe" testing likely only ever exercised
  a bare create-then-remove without an actual recording in between, which is why it looked
  fine at the time.
- **Resolution**: had the user manually quit and relaunch OBS (safe here since the idle scene
  has no live ScreenCaptureKit audio thread — see "Resolved investigation" above for why *that*
  specific crash trigger requires an active capture thread at quit time). Confirmed via a fresh
  probe against the relaunched instance: `Capture Card Device` was gone from `GetInputList`,
  and the OBS log showed `[scene_load_item] Source Capture Card Device not found!` on load.
  Camera light confirmed off by the user afterward.
- **Code change**: `releaseCameraIfConfigured()` now retries `RemoveInput` up to 3 times with
  a verifying `GetInputList` in between, and `NSLog`s a loud warning if the camera is still
  present after all 3 — see the "Idle resource minimization" section above. This makes future
  occurrences visible in logs instead of silently claiming success, but does **not** fix the
  underlying stuck case — there's no known websocket-reachable way to force it. If the camera
  indicator stays lit after a Guide recording again, the user needs to manually quit/relaunch
  OBS; there's no in-app remediation for this.
