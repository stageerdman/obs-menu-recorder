# Call detection — wiki

- **CoreAudio process objects work unprivileged** (macOS 26.6.1, plain ad-hoc-signed binary,
  no TCC prompt): `kAudioHardwarePropertyProcessObjectList` returned ~29 processes with PID,
  bundle ID and running-input/output flags.
- **Chrome captures audio in a helper**: bundle ID `com.google.Chrome.helper` (main app is
  `com.google.Chrome`) → match by prefix. WhatsApp desktop is `net.whatsapp.WhatsApp`.
- **OBS doesn't hold the mic while RecBar is idle** (no process had input running at idle) —
  consistent with `goIdleInOBS` removing the mic inputs and clearing `USB PnP`'s device_id.
  The allowlist would make that irrelevant anyway.
- **This machine runs a dictation app** (`com.voicedictator.app`) that uses the mic — the
  reason detection is allowlist-based, not "any process on the mic".
- **Couldn't self-test a live capture**: the terminal has no mic permission (ffmpeg
  avfoundation → "Input/output error"), so `IsRunningInput == 1` for Chrome/WhatsApp still
  needs confirming in the real walkthrough.
- `kAudioProcessPropertyBundleID` returns a +1 `CFString` → `takeRetainedValue()`.
