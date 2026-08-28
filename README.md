# RecBar

A tiny menu-bar-only remote control for OBS Studio. It lives in the top menu bar (never the
Dock, never Cmd+Tab), and lets you start/stop/pause recordings in OBS with one click, across
three modes:

- 💵 **Sales Call**
- 🎥 **Guide**
- 🎙️ **Other Call**

Click the menu bar icon: if nothing's recording, you get three big red buttons — pick one and
it switches OBS to the right scene, points the right microphone at OBS, sets the save folder,
and starts recording. While recording, the same popover shows pause/stop/discard controls, a
live elapsed timer, and an optional debug drawer with live mic/desktop audio level meters.

## Prerequisites

1. **OBS Studio** installed. RecBar will launch it for you (hidden, no window/Dock icon) if
   it isn't already running when you start a recording — see "Launching OBS automatically"
   below for a one-time setting you need to enable in OBS first.
2. **obs-websocket enabled**: in OBS, go to *Tools → WebSocket Server Settings*, turn on
   "Enable WebSocket Server", and note the port + password. These need to match
   `~/Library/Application Support/RecBar/config.json` (created automatically on first launch
   with the values already in use on this Mac — edit it if you ever change the port/password
   in OBS).
3. Two scenes already exist in OBS: **`Meet Recording Setup`** (used by both Sales Call and
   Other Call) and **`Guide Recording Setup`** (used by Guide), each containing:
   - A mic source named `Macbook` (built-in mic)
   - A mic source named `Headphones Mic` (wired jack mic — RecBar never auto-selects this)
   - The global Mic/Aux source, named `USB PnP`
   - A `Desktop Sounds` source

   If you rename any of these in OBS, update the matching field in `config.json`.

## Build & install

```sh
./build.sh --install
```

This builds the app (no Xcode required — just the Swift toolchain from Command Line Tools),
assembles `dist/RecBar.app`, ad-hoc signs it, and copies it to `/Applications/RecBar.app`.

Since it isn't notarized, macOS Gatekeeper may complain the first time you open it — either
right-click the app in `/Applications` and choose **Open**, or approve it in
**System Settings → Privacy & Security**.

To just build without installing: `./build.sh` (output lands in `dist/RecBar.app`).

## Day-to-day use

1. Make sure OBS is open with its WebSocket server running.
2. Click the RecBar icon in the menu bar.
3. Pick a mode — RecBar switches scenes, picks the right mic (preferring a connected USB mic
   over the built-in one; it never auto-selects a Bluetooth or wired-headphone mic), and
   starts recording in OBS.
4. Use the pause/resume, stop, or trash (discard — stops **and deletes** the file) buttons.
   Click **•••** to expand a debug view showing which mic was picked and live audio levels.
5. Reopening the icon always reflects what OBS is actually doing right now, even if you
   started/stopped the recording from inside OBS directly instead of from RecBar.

### Where recordings go

| Mode | Folder |
|---|---|
| Sales Call | `~/Documents/Recordings/Sales Meetings` |
| Guide | `~/Documents/Recordings/Guides` |
| Other Call | `~/Documents/Recordings/Other Meetings` |

(Overridable in `config.json`.)

## Silence / presence watchdog

While recording, RecBar watches the live level of whichever mic it's actually using (never
desktop audio — so a loud screen-share doesn't mask you having gone quiet). If it stays below
**-50dB for 30 seconds**, RecBar shows an **"Are you there?"** prompt — inline in the popover
with a countdown, and as a macOS notification with an "I'm here" action, so it reaches you
even if the popover's closed. You get **60 seconds** to respond; any confirmation (either
button) resets the clock and recording continues normally. If the window elapses with no
response, RecBar stops the recording — **keeping the file, never discarding it** — drops back
to the mode picker, and sends a confirming notification explaining why.

The watchdog is suppressed entirely while manually paused, and only reacts to sustained
silence — brief pauses in speech don't trigger it.

**Guide mode has the watchdog off by default**, since guides are often narrated on-screen
with long stretches of intentional on-mic silence — that's not the "walked away mid-call"
case this feature is meant to catch. Sales Call and Other Call have it on by default.

All of it is configurable per-mode in `config.json`, under each mode's `watchdog` block:

```json
"watchdog": {
  "enabled": true,
  "silenceThresholdDB": -50,
  "silenceDurationSeconds": 30,
  "responseWindowSeconds": 60
}
```

The first time this prompts, macOS will ask for notification permission — approve it, or
you'll only get the inline popover prompt (no notification) if the popover happens to be
closed when it fires.

## Launching OBS automatically

If OBS isn't already running when you pick a mode, RecBar launches it itself — hidden, no
window or Dock icon — instead of making you open it manually first.

**One-time setup required in OBS**, since this can't be set via the API: open OBS's own
*Settings → General → System Tray*, and enable both **"Run OBS in System Tray when
minimized"** and **"Minimize to Tray instead of Taskbar"**. Without these, an OBS instance
RecBar launches may still briefly flash a window or Dock icon on its way up.

RecBar only ever launches an OBS instance — it never quits one, including its own, and
including when RecBar itself quits. If you already had OBS open, RecBar leaves it alone, same
as one it launched itself. This is deliberate: quitting OBS is what triggers a known OBS-side
crash bug (see below), so RecBar sidesteps it entirely by never quitting OBS at all. Quit OBS
yourself when you're done with it.

### Known issue: OBS can crash on quit (not a RecBar bug)

This machine's OBS Studio 32.2.2 has a reproducible crash when it's quit while an actively-
capturing audio source (a mic, or the ScreenCaptureKit-based "Desktop Sounds" source) is
loaded — confirmed independent of RecBar entirely (it reproduces even quitting a freshly
launched, completely untouched OBS instance). Every crash then marks OBS's next launch as
"unclean," so it shows its own modal **"OBS did not shut down properly — start in Safe
Mode?"** prompt — which isn't reliably hidden by RecBar's hidden launch, so you may
occasionally need to click it yourself ("Run in Normal Mode" is the right choice; Safe Mode
disables the WebSocket plugin RecBar needs). There's no supported way to suppress this dialog
via the OBS command line.

This isn't something RecBar can fix — it's inside OBS's own shutdown code. If it happens
often, check whether a newer OBS version has fixed it, or consider downgrading. In the
meantime, RecBar never quits OBS itself for any reason, which sidesteps the bug entirely
rather than just minimizing exposure to it.

## Idle resource use

Because RecBar never quits OBS, an OBS instance it launched would otherwise sit hidden
indefinitely on whatever scene it last recorded with — live screen capture, desktop audio, and
mic sources all still running, plus the camera left on. RecBar minimizes this whenever it
isn't actively recording:

- **Switches OBS to an idle scene** (`RecBar Idle` — auto-created the first time it's needed;
  you'll see it appear in your OBS scene list). This measurably cuts CPU use for anything
  that's actually scene-gated.
- **Removes and later recreates the camera, screen capture, desktop audio, and both mic
  sources (`Macbook`, `Headphones Mic`)** — a scene switch alone does *not* release any of
  these, since OBS opens the camera once at launch and holds it for the entire session
  regardless of which scene is showing, and mixes audio-producing sources (mic/aux capture,
  desktop audio capture) globally rather than gating them by the active scene. RecBar detects
  each source by name (`Capture Card Device`, `Screen`, `Desktop Sounds`, `Macbook`,
  `Headphones Mic` by default — configurable in `config.json` as `cameraRelease.inputName`,
  `screenRelease.inputName`, `desktopAudioRelease.inputName`,
  `micBuiltInRelease{Meet,Guide}.inputName`, `micWiredRelease{Meet,Guide}.inputName`) and only
  recreates each right before a recording that needs it starts: the camera and both mic
  sources for **Guide** mode, screen capture, desktop audio, and both mic sources for
  **Sales Call/Other Call**. If you resize or reposition any of them in OBS, that placement is
  preserved across release/recreate cycles. The first time any of these ever runs it just
  snapshots the source as-is; nothing is removed until RecBar has seen it live at least once.

You can disable any of these individually by setting that source's `*Release.enabled` to
`false` in `config.json`, or point `idleSceneName`/the `*Release` entries at different names
if you rename things in OBS.

## Troubleshooting

- **Buttons are greyed out / "OBS not connected" shown**: OBS isn't running, or its
  WebSocket server isn't enabled, or the port/password in `config.json` doesn't match OBS's
  *Tools → WebSocket Server Settings*.
- **Wrong microphone gets picked**: RecBar always prefers a connected USB mic over the
  built-in mic, and never a Bluetooth or wired-headphone-jack mic. Open the debug drawer
  (•••) while recording to see exactly which physical mic it resolved to. If a USB mic is
  plugged in but not picked, unplug/replug it and start a new recording — RecBar re-detects
  microphones fresh every time a recording starts.
- **App doesn't appear in the menu bar**: check `/Applications/RecBar.app` exists and was
  opened without a Gatekeeper block (see Build & install above); check Activity Monitor for
  a running `RecBar` process.
- **"Timed out waiting for OBS to start and connect"**: RecBar launched OBS but didn't see
  the websocket connection come up within 45s. Check whether OBS is sitting behind its own
  "did not shut down properly" Safe Mode prompt (see "Known issue: OBS can crash on quit"
  above) — that's the most common cause, since the dialog blocks `obs-websocket` from
  starting until answered. Also check that "Enable WebSocket Server" in OBS is actually
  turned on (a fresh OBS launch always starts with whatever it last had saved, so if it was
  previously disabled it'll still be disabled) and that the port/password in `config.json`
  are correct.
- **A hidden OBS window/icon briefly flashes when RecBar launches it**: make sure OBS's own
  *Settings → General → System Tray* has both "Run OBS in System Tray when minimized" and
  "Minimize to Tray instead of Taskbar" enabled (see "Launching OBS automatically" above) —
  this can't be set via the API, so it needs to be done once by hand.
- **No "Are you there?" notification appears, only the inline popover prompt**: macOS
  notification permission probably wasn't granted — check *System Settings → Notifications →
  RecBar*.
- **Watchdog fires when you don't expect it (e.g. during Guide mode)**: check that
  mode's `watchdog.enabled` in `config.json` — Guide defaults to off; Sales Call and Other
  Call default to on. Also check `silenceThresholdDB`/`silenceDurationSeconds` if it's firing
  too eagerly during normal pauses.
