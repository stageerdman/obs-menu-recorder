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
  `connectionState`, `channelLevels`, `resolvedMicDescription`, `debugDrawerExpanded`.
  Orchestrates `OBSClient` + `MicrophonePriority` for start/pause/resume/stop/discard, and
  reconciles state from OBS's own events so the UI stays truthful even if OBS is driven
  directly (not just through this app).
- `Sources/RecBar/OBSClient.swift` — hand-rolled `obs-websocket` v5 client over
  `URLSessionWebSocketTask` (no third-party dependency). Handles the `Hello`/`Identify`
  handshake including SHA256 challenge/salt auth, request/response correlation by
  `requestId`, event dispatch, and reconnect-with-backoff.
- `Sources/RecBar/MicrophonePriority.swift` — CoreAudio device enumeration
  (`kAudioHardwarePropertyDevices` + `kAudioDevicePropertyTransportType`) and priority
  resolution. Re-run on every recording start.
- `Sources/RecBar/Config.swift` — loads/creates `~/Library/Application Support/RecBar/config.json`.
- `Sources/RecBar/ClickSound.swift` — synthesizes a short click (`AVAudioEngine` +
  a generated decaying sine burst) at runtime instead of bundling a licensed audio asset.
- `Sources/RecBar/Views/` — `SelectionView.swift` (View 1), `RecordingView.swift` (View 2 +
  debug drawer).
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
