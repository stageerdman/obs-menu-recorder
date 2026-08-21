# RecBar — Progress / Handoff Notes

Paused mid-build at the user's request on 2026-08-21. This is a working note for picking the
session back up — not a permanent project doc (unlike `CLAUDE.md`/`README.md`, which are
already accurate to what's built so far and should stay).

## Where things stand

**Repo:** https://github.com/stageerdman/obs-menu-recorder (public, pushed, `main` branch).
One commit so far (`chore: initial RecBar scaffold`). Section 10's git workflow (build →
commit → push after every discrete change) has been followed and should continue to be.

**Code:** All core app code is written and builds cleanly (`./build.sh` succeeds, produces
`dist/RecBar.app`, ad-hoc signed). Verified so far:
- `swift build` toolchain works (no Xcode.app installed — only Command Line Tools — so this
  is a SwiftPM executable target, not an `.xcodeproj`; documented in `CLAUDE.md`).
- `MicrophonePriority.resolve()` tested standalone against real hardware — correctly
  classifies devices (excludes the wired jack mic, a virtual "Magic Bee" device, and a Loom
  virtual audio device; falls back to built-in when no USB mic is connected).
- The built `.app` launches successfully (fixed one crash: an `NSApp.setActivationPolicy`
  call in `RecBarApp.init()` force-unwrapped a not-yet-populated `NSApp` global — removed it;
  `Info.plist`'s `LSUIElement=true` alone is correct and sufficient, confirmed via
  `plutil` + a screenshot showing the menu bar icon with no Dock icon).
- Have **not yet** clicked the popover open (no GUI automation available for native macOS
  apps in this environment, only Chrome browser automation) — needs a human click, or revisit
  with a different verification approach.
- Have **not yet** done a real end-to-end recording test (needs OBS's WebSocket server
  actually turned on — see blocker below).

## Task list state (see TaskList tool for live status)

1. ✅ Git init / GitHub repo
2. ✅ SwiftPM skeleton + Info.plist
3. ✅ Config.swift + config.json handling
4. ✅ OBSClient.swift (v5 websocket, SHA256 auth, request/response, events, reconnect)
5. ✅ MicrophonePriority.swift (CoreAudio enumeration)
6. ✅ AppState.swift (state machine orchestrating OBSClient + MicrophonePriority)
7. ✅ SelectionView / RecordingView / RecBarApp entry
8. ✅ Click sound (synthesized at runtime, no bundled asset) + menu bar icons (SF Symbols)
9. ✅ build.sh (with `--install` flag) + ad-hoc codesign
10. ✅ CLAUDE.md + README.md written
11. 🟡 **In progress** — build/install/end-to-end verification (this is where we paused)

## Local (gitignored, not in repo) state already set up

- `~/Library/Application Support/RecBar/config.json` — written with the real values already
  in use on this Mac (OBS host/port/password, scene names, source names, save folders).
  **The password is only in this file, never in the repo.**
- The three save folders (`~/Documents/Recordings/{Sales Meetings,Guides,Other Meetings}`)
  already exist.
- `dist/RecBar.app` has been built at least once but **not yet installed** to
  `/Applications` — `./build.sh --install` was about to run when we paused.

## Known blocker — needs the user

**OBS's WebSocket server is currently disabled** (`server_enabled: false` in
`~/Library/Application Support/obs-studio/plugin_config/obs-websocket/config.json`, port 4455,
password already set). RecBar can't connect until the user turns it on in OBS itself:
*Tools → WebSocket Server Settings → Enable WebSocket Server*. I deliberately did not edit
that file directly since OBS is running and owns it live.

## Next steps when resuming

1. Ask the user to enable the WebSocket server in OBS (above).
2. `./build.sh --install`, confirm `/Applications/RecBar.app` launches.
3. Walk the Section 11 checklist with the user's help for anything needing a real click or
   real hardware (clicking the menu bar icon to see both views; pause/resume/stop/discard;
   plugging/unplugging their actual USB mic mid-flow; confirming files land in all three save
   folders).
4. Only after the user explicitly confirms real end-to-end usage works (Section 12 requires
   this — don't self-certify), do Section 13: delete `INIT.md`, commit, push. Also safe to
   delete this `PROGRESS.md` at that point, or fold anything still relevant into `CLAUDE.md`.
