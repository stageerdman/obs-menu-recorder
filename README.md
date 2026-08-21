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

1. **OBS Studio** installed and running.
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
