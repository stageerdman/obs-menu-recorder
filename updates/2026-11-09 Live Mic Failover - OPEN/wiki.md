# Live mic failover — durable decisions

- **Polling on the existing 1s `tickElapsed` timer, not a CoreAudio device-change listener.**
  `MicrophonePriority.inputDevices()` is a handful of cheap `AudioObjectGetPropertyData` calls,
  not worth a second timer or a `kAudioHardwarePropertyDevices` listener callback — and reusing
  the same cadence the silence watchdog already runs on keeps there being exactly one "per-second
  while recording" hook in `AppState` instead of two.
- **2-tick (~2s) debounce before actually switching.** A raw bad USB connection can report
  present/absent on consecutive enumeration calls; switching on every single blip would thrash
  OBS (`SetInputSettings`/`SetInputMute`/`SetInputAudioTracks` round trips every second) for no
  benefit. Only a *sustained* change in presence triggers a live switch.
- **A momentary blank across mic *and* desktop audio at the exact instant of a USB disconnect is
  believed to be a CoreAudio HAL-wide hiccup** (device remove/re-add can briefly disrupt every
  open audio client on the system, not just the removed device's own stream) — not something
  fixable from RecBar's side. This feature can't erase that single instant; it turns "silent
  until someone notices and fixes it" into a sub-2-second self-healing blip by failing over to
  the built-in mic automatically, and back to USB once it's reliably present again.
- **Headphone/wired mic stays excluded from auto-selection**, live-failover included — same rule
  `MicrophonePriority`'s doc comment already states for the initial resolution at recording
  start. The user confirmed USB-or-built-in is always available on this hardware, so there was
  no reason to add a third fallback tier here.
- **Reused `applyMicrophonePriority`/`applyAudioTrackRouting` verbatim for the live switch**
  rather than writing separate OBS calls — same mute/unmute/track-routing/USB `device_id`
  rewrite logic `beginRecording` already relies on and has already been shaken out (see
  CLAUDE.md's "Idle resource minimization"/"Audio-track routing" history), just invoked again
  mid-recording against a freshly-resolved mic.
