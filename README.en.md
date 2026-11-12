# display-guard

A small resident tool for macOS that keeps the system from treating a display that is not really in use as alive (the "zombie screen" that windows wander onto). Apple Silicon Macs only.

## Behavior

| Situation | Action |
|---|---|
| No MonsGeek keyboard (wired or dongle) is visible to the Mac | Switch the Dell to DP 1 over DDC, then disconnect it |
| A keyboard is back | Reconnect the Dell and switch it to HDMI 1 over DDC |
| The Mac is locked | Disconnect every display except the Dell |
| This Mac's Sunshine has a session | Disconnect every display except the Dell |
| Back to normal | Reconnect |

- "Disconnect" is `CGSConfigureDisplayEnabled` (a private API).
- The input is switched with DDC/CI through IOAVService (a VCP 0x60 write). Reading the input back is not reliable on this monitor, so it is not used; the keyboards are the cue.
- It never leaves the Mac with zero active displays.
- USB changes arrive as IOKit notifications; the lock state and Sunshine are checked every 1.5 s.

## Notes

- It uses private APIs and may stop working after a macOS update.
- The monitor (Dell G2725D) and the keyboard (MonsGeek, USB vendor `0x3151`) are hard-coded. For other models, change the settings at the top of `Sources/display-guard/main.swift`.
- Sunshine is asked only on this Mac's LAN / Tailscale addresses, port `:47989` (never `127.0.0.1`).

## Usage

```bash
swift build -c release
mkdir -p ~/.local/bin
cp .build/release/display-guard ~/.local/bin/
~/.local/bin/display-guard status     # show the current state
~/.local/bin/display-guard restore    # bring back the displays it disconnected
~/.local/bin/display-guard run        # run resident
```

To start it at login, replace `__HOME__` in `com.local.display-guard.plist.template` with your home folder, save it as `~/Library/LaunchAgents/com.local.display-guard.plist`, and run:

```bash
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.local.display-guard.plist
```

A binary on an external volume can hang when launched by launchd; keep it in `~/.local/bin` or similar.

## License

MIT
