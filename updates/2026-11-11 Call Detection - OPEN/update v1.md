# Call detection: suggest recording when a call starts

## Goal (explicit user request, 2026-11-11)
"I often forget to start recording when I'm on the call." Calls happen only in Google Meet
(Chrome, used for nothing else) and WhatsApp desktop. When either starts using the mic while
RecBar is idle, prompt to start a recording — hard to miss. False positives (a WhatsApp voice
message) are explicitly acceptable; a missed call is not.

## Design
- `CallDetector` polls CoreAudio's per-process objects once a second
  (`kAudioHardwarePropertyProcessObjectList` → `kAudioProcessPropertyIsRunningInput` +
  `kAudioProcessPropertyBundleID`, macOS 14+) and reports the first allowlisted app capturing
  input. Allowlist, not "anything on the mic": the user also runs a dictation app, and OBS
  itself holds the mic while recording. Debounce: 60s to start (was 2s; raised on user request
  2026-11-11 after the 2s version was confirmed working, to skip voice messages), 5s to end (a Meet mute / device switch shouldn't end the "call").
- `config.json` → `callDetection { enabled, apps: [{bundleIDPrefix, name}] }`, default Chrome
  ("Google Meet") + WhatsApp. Prefix match because Chrome captures in `com.google.Chrome.helper`.
- `CallPrompt`: corner panel (shared `CornerPanel` shell, extracted from the watchdog overlay —
  shows over full-screen apps, never steals focus). "Call detected: <app> / Not recording yet",
  **Record** (starts Meetings) + ✕. Graphite with a red dot, distinct from the watchdog's red.
  Chime on show + once more at 20s (not more: it plays out loud during a live call). Menu bar
  icon: red outline `record.circle` while pending. VoiceOver announcement on show.
- `AppState`: one prompt per call. Hidden when any recording starts (incl. from OBS), or the
  call app releases the mic. ✕ / stopping mid-call → no re-prompt until the mic is released.

## Phases
1. Spike: confirm the CoreAudio process API + real bundle IDs on this machine — **done**
   (`spike/miclisteners.swift`, see wiki.md).
2. Detector + config + prompt + AppState wiring, build — **done**.
3. Real walkthrough with the user — **2s version confirmed working (WhatsApp voice
   message, 2026-11-11)**; 60s version pending: start a Meet (green room is enough) and a
   WhatsApp call with RecBar idle → prompt + chime after ~1 min; Record starts a Meetings
   recording; ✕ stays quiet for the rest of that call; ending the call hides the prompt.

## Where we left off (2026-11-11)
- All code committed + pushed on `call-detection` (branched from `live-mic-failover`, which
  isn't merged into `main` yet). Installed build in /Applications is the 60s version.
- Next: user confirms the 60s version on a real call (phase 3), then merge both branches to
  `main` and flip this folder to CLOSED.
- Spike scripts kept in `spike/` for re-debugging: `miclisteners.swift` (one-shot list) and
  `watch.swift` (live log of every process/device using the mic — build with `swiftc -O
  watch.swift -o <scratch>/micwatch`; can't `swift watch.swift` from inside this folder).
- Known gap: a mic release during the first minute (one 1s blip) restarts the 60s clock.
