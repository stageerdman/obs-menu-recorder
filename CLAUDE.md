# RecBar

RecBar is a macOS menu-bar-only (no Dock icon) SwiftUI app that remote-controls OBS Studio
over `obs-websocket` v5 to start/stop/pause recordings across three preconfigured modes
(Sales Call / Guide / Other Call), each mapped to an OBS scene and a save folder. It shows a
compact horizontal popover: a 3-button mode picker when idle, transport controls + elapsed
time + an expandable live-audio-level debug drawer while recording.

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
- Menu bar / mode icons are SF Symbols rendered directly (no bundled image assets needed) —
  they pick up template/dark-light behavior for free, and the recording/paused states are
  explicitly tinted red via `RecBarColor.red` (`Theme.swift`) regardless of appearance.

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
both Sales Call and Other Call modes — only the save folder differs between them, so the
save-folder-set step always runs, every mode, every time) and `Guide Recording Setup`.

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
`silenceThresholdDB`, `silenceDurationSeconds`, `responseWindowSeconds`) rather than a single
global block, specifically because Guide mode's default differs from Sales Call/Other Call's
(see `RecBarConfig.default` in `Config.swift`) — Guide is narrated on-screen with long
stretches of intentional on-mic silence, so it defaults to **off**, while Sales/Other default
to **on** (-50dB / 30s / 60s). `RecBarConfig.decodeModeConfig(_:forKey:defaultWatchdog:)`
exists specifically so each mode can fall back to its own default when loading an older
`config.json` that predates this field — a bug during initial rollout (fixed same day) had
this fall through `ModeConfig`'s own `Decodable init` instead, which has no way to know which
mode it's decoding and so defaulted every mode to "on" including Guide.

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

## Build / install

No Xcode.app is installed on this machine (only Command Line Tools), so this is a Swift
Package (`Package.swift`, executable target), not an `.xcodeproj` — `xcodebuild` is
unavailable. `build.sh` runs `swift build -c release`, then hand-assembles
`dist/RecBar.app` (`Contents/MacOS`, `Contents/Info.plist` from `Resources/Info.plist`) and
ad-hoc code-signs it (`codesign --force --deep --sign -`). `./build.sh --install` also copies
it to `/Applications/RecBar.app`.

## Git workflow

Small, frequent, buildable commits — run `./build.sh` before every commit, fix before
committing if it fails, then `git add -A && git commit && git push`. Don't batch unrelated
changes into one commit.

## Testing notes

Confirmed end-to-end with real hardware (2026-08-21): built, installed to
`/Applications/RecBar.app`, launched (menu bar icon appears, no Dock icon), connected to a
running OBS with its WebSocket server manually enabled first, and completed a full
start → pause → resume → stop cycle with the file landing in the right save folder.

No Xcode/simulator and no GUI automation for native macOS apps is available in this
environment (only Chrome browser automation) — anything requiring an actual click, a real
OBS instance, or real audio hardware needs to be walked through with the user rather than
self-certified. This applies especially to:

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
