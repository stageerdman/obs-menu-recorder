# Live mic failover during an active recording

## Problem
Mic priority (USB > built-in) is only resolved once, immediately before `StartRecord`
(`AppState.beginRecording` → `applyMicrophonePriority`). If the USB mic ("USB PnP") has a
flaky connection and drops mid-recording, nothing notices — the source just goes silent (and,
per the user's report, the desktop-audio track can blank too for that same instant, consistent
with a brief CoreAudio HAL-wide hiccup on device add/remove, not something RecBar can fully
suppress). There is no live fallback to the built-in mic, and no automatic recovery back to
USB once it reconnects.

## Goal (explicit user request, 2026-11-09)
While actively recording, continuously watch for the USB mic's physical presence and
live-switch OBS's routing both ways with no stop/restart of the recording:
- USB mic detected connected at any point → switch to it.
- USB mic not present → switch to the built-in Mac mic.

Headphone/wired mic stays excluded from auto-selection either way, matching the existing
priority rule (`MicrophonePriority`'s doc comment) — the user said they always have USB-or-Mac
available, so no third fallback tier is needed.

## Design
Reuse the exact mechanism `beginRecording` already uses to apply a resolved mic
(`applyMicrophonePriority` + `applyAudioTrackRouting`), just invoked again mid-recording
instead of only once at the start:

1. **Detection**: piggyback on the existing once-a-second `tickElapsed()` timer (already drives
   `tickWatchdog()`) rather than adding a second timer or a CoreAudio device-change listener —
   this is a simple polling check (`MicrophonePriority.inputDevices()`), not an expensive
   operation, and keeping it on the same cadence as the watchdog keeps the timing model in one
   place.
2. **Debounce**: require the *desired* role (USB-present → `.usb`, else `.builtIn`) to differ
   from the currently-active role for 2 consecutive ticks (~2s) before acting, so a single
   transient CoreAudio enumeration blip doesn't cause a spurious switch. This mirrors the
   existing settle-delay pattern already used in `applyMicrophonePriority` for the opposite
   reason (giving a newly-live device a moment to actually start producing samples).
3. **Switch**: re-run `applyMicrophonePriority`/`applyAudioTrackRouting` against the newly
   resolved mic (re-muting/re-routing both mic sources, rewriting `USB PnP`'s `device_id` fresh
   when switching back to USB, exactly as `beginRecording` already does). Update
   `resolvedMicDescription`/`resolvedMicSourceName`/`watchdogChannelNames`/the new
   `currentMicRole` tracking var afterward so the debug drawer and silence watchdog stay
   truthful about which source is actually live.
4. **Guards**: a `micFailoverInFlight` flag prevents overlapping switches (the OBS round trips
   + the existing 300ms USB settle delay can outlast one 1s tick); re-check
   `recordingState == .recording` before and after the async OBS calls so a failover in flight
   during a manual Stop doesn't race `resetToIdle()`.

## Phases
1. **Extract shared "apply resolved mic state" helper** — pull the
   resolvedMicDescription/resolvedMicSourceName/watchdogChannelNames assignment block out of
   `beginRecording` into a small private method, used by both `beginRecording` and the new
   failover path, plus a `currentMicRole` tracking var set alongside it. No behavior change;
   build + sanity check only.
2. **Add live detection + debounced switch** — `tickMicFailover()` called from `tickElapsed()`,
   the pending-change debounce, and `performLiveMicFailover(to:mode:)` doing the actual
   re-apply via the existing `applyMicrophonePriority`/`applyAudioTrackRouting`. Reset all new
   state in `resetToIdle()`.
3. **Build, install, and a real walkthrough with the user** — start a recording on the built-in
   mic, plug in the USB mic mid-recording and confirm it switches over (and the saved file's
   audio actually comes from USB after that point), then unplug it and confirm it falls back to
   built-in — this needs real hardware, not scriptable from this environment (see CLAUDE.md's
   "Testing notes": no GUI automation for native macOS apps here).

## Status
- Phase 1: done (`AppState.applyResolvedMicState`, `currentMicRole` added, `./build.sh` clean).
- Phase 2: done (`tickMicFailover`/`performLiveMicFailover` added, wired into `tickElapsed`,
  reset in `resetToIdle`, `./build.sh` clean).
- Phase 3: not started — needs a real walkthrough with the user (real USB mic plug/unplug
  during a live recording, and inspecting the saved file's audio around the switch point). No
  GUI automation / real audio hardware available in this environment (see CLAUDE.md's "Testing
  notes") — this cannot be self-certified.
