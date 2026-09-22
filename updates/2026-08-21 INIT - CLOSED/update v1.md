# INIT.md — Build Instructions for the OBS Menu Bar Recorder App

> **How to use this file:** Feed this entire document to an AI coding agent (e.g. Claude Code) running inside an empty project folder on the target Mac. The agent should work through the sections in order, checking off the "Definition of Done" items in Section 12 before finishing, and must complete Section 13 (self-cleanup) as the very last step of the whole project.

---

## 0. Purpose

Build a native macOS **menu bar–only** app (no Dock icon) that controls OBS Studio to start/stop/pause recordings across three preconfigured modes, with a compact horizontal control bar, a playful "record mode" picker, and a debug view showing live audio channel activity. The app must build to a real `.app` bundle installable in `/Applications`, be tracked in git, and be pushed to a new **public** GitHub repository, with a commit + rebuild after every change made during development.

---

## 1. Project Summary

**Working name:** `RecBar` (agent may rename if a better name is proposed to the user first — do not silently rename mid-project).

**What it does:**
- Lives only in the macOS menu bar (top bar), never in the Dock, never in Cmd+Tab.
- Clicking the menu bar icon opens a small horizontal popover with two possible views:
  - **View 1 — Selection View**: three playful red buttons (Sales Call / Guide / Other Call) that start a recording in OBS.
  - **View 2 — Recording View**: transport controls (pause/resume, stop, discard) + elapsed time + an expandable debug drawer showing live mic/desktop channel activity.
- Reopening the bar always shows whichever view matches the current state (idle → View 1, recording/paused → View 2).
- All actual recording happens inside **OBS Studio**; this app is a remote-control front end via `obs-websocket` (v5 protocol, built into OBS 28+).

---

## 2. Tech Stack & Requirements

- **Language/UI:** Swift + SwiftUI, using `MenuBarExtra` (macOS 13+) with `.window` style so the content view is a fully custom (horizontal) layout rather than a native dropdown list. If `MenuBarExtra` proves too limiting for the "reopen shows current view" + custom popover width behavior, fall back to `NSStatusItem` + `NSPopover` hosting a `SwiftUIView` — agent's judgment, but the Dock-hidden requirement is non-negotiable either way (`LSUIElement = true` in Info.plist / `Application is agent (UIElement)` in target settings).
- **Minimum target:** macOS 13.0 (Ventura) or later — confirm this is acceptable given the user's actual macOS version; if the Mac runs an older OS, lower the deployment target and use the `NSStatusItem`/`NSPopover` approach instead of `MenuBarExtra`.
- **OBS control:** `obs-websocket` v5 protocol over a native `URLSessionWebSocketTask` (no third-party dependency needed — the protocol is plain JSON over WebSocket). Do not shell out to `obs-cli` or similar; talk to the WebSocket directly.
- **Audio device enumeration:** `CoreAudio` (`AudioObjectGetPropertyData` with `kAudioHardwarePropertyDevices`) to detect connected input devices and classify them as USB / built-in / Bluetooth / wired-headset for the priority logic in Section 6.3.
- **Sound effect:** `AVFoundation` (`AVAudioPlayer` or `NSSound`) playing a short bundled "click" sound on button press. Source a simple, license-free UI click sound (or synthesize one) and bundle it as a resource — do not link to or embed anything with unclear licensing.
- **Packaging:** Xcode project (`.xcodeproj` or Swift Package with an executable target + Info.plist), built via `xcodebuild` from a shell script — no manual "click Build in Xcode" as the only path; there must be a scriptable build.

---

## 3. Repository & Git Setup (do this first, before writing app code)

1. `git init` in the project root.
2. Create `.gitignore` for a Swift/Xcode project (`.build/`, `DerivedData/`, `*.xcuserstate`, `.DS_Store`, `xcuserdata/`, build products, and — critically — any local secrets file described in Section 7).
3. Confirm the GitHub CLI (`gh`) is installed and authenticated (`gh auth status`). If not authenticated, **stop and ask the user** to run `gh auth login` themselves — do not attempt to handle GitHub credentials on the user's behalf.
4. Ask the user (once, up front) what they want the repository named, or propose `recbar` / `obs-menu-recorder` and let them confirm.
5. Create the repo and push:
   ```bash
   gh repo create <chosen-name> --public --source=. --remote=origin
   git add -A
   git commit -m "chore: initial project scaffold"
   git push -u origin main
   ```
6. From this point forward, follow the workflow in **Section 10** for every subsequent change.

---

## 4. App Architecture

Suggested module breakdown (agent may adjust, but keep concerns separated):

- `RecBarApp.swift` — app entry point, `MenuBarExtra` (or `NSStatusItem`) setup, Dock-hidden config.
- `AppState.swift` — single observable source of truth: current mode (`.sales`, `.guide`, `.other`, or `nil`), recording state (`.idle`, `.recording`, `.paused`), elapsed time, connection status to OBS, live channel levels.
- `OBSClient.swift` — WebSocket connection, auth handshake (obs-websocket v5 uses a challenge/salt SHA256 auth if a password is set), request/response + event handling (subscribe to `RecordStateChanged`, `InputVolumeMeters` or similar for level metering).
- `MicrophonePriority.swift` — CoreAudio device enumeration + priority resolution (Section 6.3).
- `Views/SelectionView.swift` — View 1.
- `Views/RecordingView.swift` — View 2, including the expandable debug drawer.
- `Config.swift` — loads the user-editable config described in Section 7.
- `Resources/` — click sound asset, menu bar icon assets (idle + recording-state variants, template-image style so they adapt to light/dark menu bar).

---

## 5. Feature Spec

### 5.1 Menu bar behavior
- App shows **only** a menu bar icon (top bar), never a Dock icon, never in the Cmd+Tab app switcher.
- The icon should visually indicate state at a glance (e.g. plain icon when idle, a small red dot or filled variant while recording, a paused-looking variant while paused) — use template images so macOS handles dark/light menu bar automatically, and tint the recording indicator red regardless of light/dark mode.
- Clicking the icon toggles a popover/window anchored under it.
- The popover **always reflects current state**: if idle → View 1; if recording or paused → View 2 (with the debug drawer collapsed by default even if it was previously expanded — don't persist drawer-expanded state across closes).

### 5.2 View 1 — Selection View
- A single horizontal row of three buttons, evenly spaced, styled as attractive, playful, rounded red buttons (not flat/system-default — see Section on visual polish below).
- Button 1: dollar-sign icon (`$`, e.g. SF Symbol `dollarsign.circle.fill`) → **Sales Call mode**.
- Button 2: camera icon (SF Symbol `video.fill` or `camera.fill`) → **Guide mode**.
- Button 3: microphone icon (SF Symbol `mic.fill`) → **Other Calls mode**.
- On press: play the click sound immediately, trigger the corresponding mode's start-recording flow (Section 6), and once OBS confirms recording has started, transition the popover to View 2. If OBS fails to start (not connected, scene missing, etc.), show a brief inline error in View 1 instead of transitioning — do not silently fail.

### 5.3 View 2 — Recording View
Single horizontal row:
- **Left cluster:**
  - Pause/Play toggle button. Pause → calls OBS `PauseRecord`, icon changes to a play glyph. Play/Resume → calls OBS `ResumeRecord`, icon reverts to pause glyph.
  - Stop button → calls OBS `StopRecord`, keeps the recording, then returns to View 1.
  - Trash/discard button → stops the recording **and deletes the resulting file** from disk (OBS itself has no "discard" primitive, so: call `StopRecord`, capture the output file path from the stop response or from `GetRecordDirectory`/last known filename, delete that file once OBS confirms it's fully written/closed), then returns to View 1. Confirm this destructive action is fast/no dialog needed since it's a deliberate physical button press, but log what was deleted (see debug drawer / console) in case of a mistake.
- **Right side:** live elapsed recording time (`HH:MM:SS`, ticking every second, pausing visually while paused).
- **Far right:** a "•••" (three dots) button. Pressing it **expands the bar vertically** (not replacing the horizontal controls — they stay visible) to reveal a debug section underneath showing:
  - Each active audio channel/source configured for the current mode (e.g. "Mic (USB — Blue Yeti)" and "Desktop Audio") with a live level meter (simple horizontal bar or waveform-style meter driven by OBS's volume meter events).
  - Which physical microphone is currently selected as the priority-resolved input device (see 6.3), so the user can visually confirm the priority logic picked the right one.
  - Pressing the three dots again collapses the drawer back down.

### 5.4 Visual polish
This is a small, frequently-glanced-at control — invest in it looking intentional:
- Rounded, slightly padded buttons with a solid red fill (not a garish pure `#FF0000` — pick a warm, saturated red with good contrast, e.g. in the `#E63946`–`#D62839` range) and a subtle press/scale animation.
- Consistent iconography (SF Symbols, filled style, matching weight).
- Respect macOS light/dark appearance for the chrome around the buttons even though the buttons themselves stay red.
- Read `/mnt/skills` design guidance is not available on this machine — use your own good judgment for spacing, corner radius, and typography; keep it compact since this is a menu-bar popover, not a full window.

---

## 6. OBS Integration

### 6.1 Connection
- Connect to `ws://127.0.0.1:4455` (default obs-websocket v5 port) on app launch and reconnect automatically with backoff if OBS isn't running yet or the connection drops.
- Support an optional password (read from the config file in Section 7). Implement the v5 `Hello`/`Identify` handshake including the SHA256 challenge-response auth when a password is configured.
- Show connection status somewhere accessible (e.g. a small indicator in the debug drawer, and/or disable the View 1 buttons with a tooltip like "OBS not connected" if the socket isn't live).

### 6.2 Scenes & Modes mapping
| Mode | OBS Scene | Save Folder |
|---|---|---|
| 1 — Sales Call | `Meet Recording Setup` | `/Users/stage/Documents/Recordings/Sales Meetings` |
| 2 — Guide | `Guide Recording Setup` | `/Users/stage/Documents/Recordings/Guides` |
| 3 — Other Call | `Meet Recording Setup` (same scene as Mode 1) | `/Users/stage/Documents/Recordings/Other Meetings` |

Flow for starting a recording in any mode:
1. `SetCurrentProgramScene` → the scene for that mode.
2. Resolve and apply the correct microphone per Section 6.3.
3. Set the OBS record output directory to the mode's folder before starting — obs-websocket v5 exposes this via the record-directory request (confirm exact request name against the OBS version installed, e.g. `SetRecordDirectory`; if that request isn't available in the user's OBS version, fall back to reading/writing the relevant field via `GetProfileParameter`/`SetProfileParameter` for the `SimpleOutput`/`AdvOutput` `RecFilePath`, and document whichever approach was actually used in CLAUDE.md).
4. `StartRecord`.
5. Subscribe to `RecordStateChanged` events to know for certain when recording has actually begun (don't just assume the request succeeded) before flipping the UI to View 2.

Scene collection note: since Mode 1 and Mode 3 use the identical scene, only the save-folder step differs between them — make sure step 3 always runs for every mode, every time, rather than only when the folder differs from last time.

### 6.3 Microphone priority logic
Priority order, highest first:
1. Any connected **USB** microphone.
2. The **built-in laptop microphone**.
3. Explicitly **excluded** from consideration: Bluetooth microphones and wired (headphone-jack) microphones — these must never be auto-selected even if they're the only other option besides "nothing." (If literally no USB mic and no built-in mic can be found, surface an error rather than silently falling back to a Bluetooth/wired device.)

Implementation:
- Enumerate input devices via CoreAudio (`kAudioHardwarePropertyDevices`, checking `kAudioDevicePropertyTransportType` for `kAudioDeviceTransportTypeUSB` vs `kAudioDeviceTransportTypeBuiltIn` vs `kAudioDeviceTransportTypeBluetooth`/`kAudioDeviceTransportTypeBluetoothLE` vs `kAudioDeviceTransportTypeThunderbolt`/wired-jack aggregate types).
- Re-run this resolution **every time a recording starts** (not just once at launch), since USB mics may be plugged/unplugged between recordings.
- Once resolved, set it as the input device on the relevant OBS audio input source via `SetInputSettings` (targeting the mic source's `device_id`). The exact source name inside each OBS scene (e.g. `"Mic/Aux"`) must be confirmed with the user or read from the config file (Section 7) — do not hardcode a guessed name without confirming it matches what's actually in "Meet Recording Setup" / "Guide Recording Setup."

### 6.4 Channel layout per mode
- Mode 1 (Sales) & Mode 3 (Other): microphone on Channel 1, desktop audio on Channel 2 (separate tracks/channels), screen recording may share Channel 1.
- Mode 2 (Guide): everything on a single Channel 1.
- These are OBS-side audio track/channel assignments already set up in the named scenes per the user — the app's job is just to select the right scene and the right physical mic device, **not** to re-architect the channel routing. Confirm this understanding with the user before assuming any channel-routing changes are needed.

---

## 7. Config File / Secrets Handling

Create a small local config (e.g. `~/Library/Application Support/RecBar/config.json`, **not** committed to git) holding anything environment-specific:
- OBS WebSocket host/port/password.
- The exact OBS source names to target per mode (mic source, desktop audio source).
- The three save-folder paths (still default to the paths in Section 6.2, but make them overridable here rather than hardcoded, in case they ever change).

Add this file's path pattern to `.gitignore`. Never commit an OBS WebSocket password or any credential. If the user hasn't set a password in OBS, the config's password field can simply be empty/omitted.

---

## 8. Build & Packaging

1. Provide a `build.sh` (or a `Makefile` target) that:
   - Runs `xcodebuild -scheme RecBar -configuration Release -derivedDataPath build clean build`.
   - Locates the resulting `RecBar.app` in the derived data products folder.
   - Copies it to a predictable `dist/RecBar.app` in the repo (gitignored — don't commit built binaries) and prints its path.
2. Provide a one-line "install" step, either as part of `build.sh` with an `--install` flag or as a separate `install.sh`, that copies `dist/RecBar.app` into `/Applications/RecBar.app` (replacing any existing copy) so the user can launch it from Spotlight/Launchpad like any other app.
3. Code signing: ad-hoc sign is sufficient for local personal use (`codesign --force --deep --sign - dist/RecBar.app`) so Gatekeeper doesn't repeatedly complain; mention in the README that on first launch the user may need to right-click → Open once, or approve it in System Settings → Privacy & Security, since it isn't notarized.
4. Confirm the Info.plist sets `LSUIElement = YES` (or the Xcode target's "Application is agent (UIElement)" checkbox) so it never appears in the Dock, and that it requests microphone access appropriately if the app itself ever touches audio directly (it likely doesn't need to, since OBS handles capture — but CoreAudio device enumeration alone typically doesn't require the mic permission; if Xcode/macOS flags it, add `NSMicrophoneUsageDescription` explaining it's used only to detect which mic is connected, not to record).

---

## 9. Documentation to Produce

### 9.1 `CLAUDE.md`
Written for a future AI coding session working in this repo. Should include:
- One-paragraph project summary.
- Architecture map (which file does what, per Section 4).
- The obs-websocket request names actually used (confirmed against the installed OBS version, including whichever record-directory approach was actually used per Section 6.2 step 3).
- The exact OBS scene names and source names this app depends on, and where those are configurable (Section 7).
- The microphone priority rule, stated plainly, so future changes don't accidentally reintroduce Bluetooth/wired mics into the auto-selection.
- How to run `build.sh` / `install.sh`.
- A reminder of the git workflow in Section 10 (commit + build after every change).

### 9.2 `README.md`
Written for the user (non-AI audience). Should include:
- What the app does, in plain language, with the three modes explained.
- Prerequisites (OBS Studio installed and running, obs-websocket enabled with the port/password matching `config.json`, the two named scenes already created in OBS with the right sources).
- How to build and install it (`./build.sh --install` or equivalent).
- How to use it day-to-day (click the menu bar icon → pick a mode → controls appear → pause/stop/discard).
- Where recordings end up for each mode (the three folder paths).
- Basic troubleshooting (OBS not connected, wrong mic picked, app not appearing in menu bar).

---

## 10. Git Workflow During the Build

For **every** discrete change made while building this project (not just at the end):
1. Make the change.
2. Run `build.sh` to confirm it still builds successfully. If the build fails, fix it before moving on — do not commit known-broken states.
3. `git add -A && git commit -m "<concise, conventional message describing the change>"`.
4. `git push`.

This applies throughout implementation, not only after the app is "done" — small, frequent, buildable commits, not one giant commit at the end.

---

## 11. Testing Checklist Before Calling This Done

- [ ] App launches with **no Dock icon** and **no entry in Cmd+Tab**.
- [ ] Menu bar icon appears and is clickable.
- [ ] View 1 shows exactly 3 correctly-iconed, correctly-colored, correctly-ordered buttons, and each plays a click sound on press.
- [ ] Pressing each of the 3 buttons correctly: switches OBS to the right scene, resolves and applies the right mic per the priority rule, sets the right save folder, starts recording, and transitions to View 2.
- [ ] View 2's pause button pauses OBS and flips to a play icon; pressing play resumes and flips back.
- [ ] View 2's stop button stops and **keeps** the file, returns to View 1.
- [ ] View 2's trash button stops **and deletes** the file, returns to View 1.
- [ ] Elapsed time counts correctly and visually pauses while paused.
- [ ] The "•••" button expands/collapses the debug drawer, and it shows live, moving channel-level indicators for the actual configured sources per mode (not placeholder/static values).
- [ ] Reopening the popover always matches true current state (idle vs. recording vs. paused), even if OBS's state changed from something outside this app (e.g. someone pressed stop inside OBS itself directly).
- [ ] Unplugging a USB mic mid-flow and testing a fresh recording correctly falls back to the built-in mic (and never to a Bluetooth/wired one).
- [ ] `build.sh` and the install step both work from a clean checkout on this machine, and `/Applications/RecBar.app` launches correctly after install.
- [ ] All three save-folder paths actually receive files when tested end-to-end.

---

## 12. Definition of Done

All boxes in Section 11 checked, `CLAUDE.md` and `README.md` exist and are accurate to what was actually built (not just what was planned), the repo is pushed to GitHub as public, and the app is installed and confirmed launching from `/Applications`.

---

## 13. Final Step — Remove These Instructions

Once, and only once, Section 12's "Definition of Done" is fully satisfied and confirmed working by the user (ask them to confirm real end-to-end usage — don't self-certify this step):

1. Delete this file (`INIT.md`) from the repository.
2. Commit: `git commit -am "chore: remove build instructions after project completion"`.
3. Push.

`CLAUDE.md` and `README.md` remain permanently as the project's ongoing documentation — only this bootstrap file is removed.
