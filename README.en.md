# display-guard

A small resident tool for macOS that keeps the system from treating a display that is not really in use as alive (the "zombie screen" that windows wander onto). Apple Silicon Macs only.

## Behavior

| Situation | Action |
|---|---|
| None of the chosen USB devices (keyboards and the like) is visible to the Mac | Switch the main monitor to another input (e.g. DP 1) over DDC, then disconnect it |
| One of them is back | Reconnect the main monitor and switch it to the Mac's input (e.g. HDMI 1) over DDC |
| The Mac is locked (can be turned off in the settings) | Disconnect every display except the main monitor |
| Sunshine has a session (can be turned off in the settings) | Disconnect every display except the main monitor |
| Back to normal | Reconnect |

- "Disconnect" is `CGSConfigureDisplayEnabled` (a private API).
- The input is switched with DDC/CI through IOAVService (a VCP 0x60 write). Reading the input back is not reliable on this monitor, so it is not used; the USB devices are the cue.
- It never leaves the Mac with zero active displays.
- USB changes arrive as IOKit notifications; the lock state and Sunshine are checked every 1.5 s.

## Notes

- It uses private APIs and may stop working after a macOS update.
- DDC goes through IOAVService, so Apple Silicon Macs only. The input values (`mac_input` / `other_input`) differ between monitors; HDMI 1 = `0x11` and DP 1 = `0x0F` are common.
- By default Sunshine is asked only on this Mac's own LAN / Tailscale addresses, port `:47989` (never `127.0.0.1`, because a port forwarder may answer there with another machine's Sunshine). The address can be set in the settings.

## Usage

```bash
swift build -c release
mkdir -p ~/.local/bin
cp .build/release/display-guard ~/.local/bin/
~/.local/bin/display-guard setup      # answer a few questions, get the settings file
~/.local/bin/display-guard status     # show the current state
~/.local/bin/display-guard restore    # bring back the displays it disconnected
~/.local/bin/display-guard run        # run resident
```

To start it at login, replace `__HOME__` in `com.local.display-guard.plist.template` with your home folder, save it as `~/Library/LaunchAgents/com.local.display-guard.plist`, and run:

```bash
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.local.display-guard.plist
```

A binary on an external volume can hang when launched by launchd; keep it in `~/.local/bin` or similar.

## Settings

`display-guard setup` asks these steps and writes `~/.config/display-guard/config.toml` (arrows move, space selects, return goes on):

1. The main monitor, and its input values
2. The USB devices (several allowed)
3. Disconnect the other displays too? -> the conditions (while locked / while a Sunshine session runs) -> the Sunshine address (default `auto`)
4. Timing

The file can be edited by hand (`DISPLAY_GUARD_CONFIG` moves it).

```toml
[monitor]
vendor      = 0x10AC   # EDID vendor id (Dell)
model       = 0x2014   # EDID product code (G2725D)
mac_input   = 0x11     # input that shows this Mac (HDMI 1)
other_input = 0x0F     # input that shows the other computer (DP 1)

[[keyboard]]           # several allowed; the monitor is used while any is seen
vendor  = 0x3151
product = 0x0006       # leave out to match every device of the vendor

[others]
enabled       = true
when_locked   = true
when_sunshine = true
sunshine_address = "auto"   # or "100.64.0.1", "host:47989"

[timing]
poll_interval    = 1.5      # seconds between lock / Sunshine checks
recheck_delay_ms = 300      # wait before looking again prior to disconnecting
```

Without a settings file `run` does not start; run `setup` first.

## License

MIT
