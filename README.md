# Mute Button

ESP32 hardware mute button for Zoom and Microsoft Teams on macOS.

```text
      .----------------.
      |  MUTE-O-MATIC  |
      |  red    green  |
      '-----.____.-----'
            / || \
          GND P0 USB
```

## Docs And Graphics

Publishing draft / blog-post source: [`INSTRUCTABLE.md`](INSTRUCTABLE.md)

Editable graphics:

- [Figma design board](https://www.figma.com/design/ZorewgAc0ObJYZJHdDFAW9)
- [FigJam system flow](https://www.figma.com/board/YSxSCPhi9Viuwuc8APxjnH)

The FigJam board includes editable diagrams named `Mute Button System Flow` and `Latest LED Wins State Machine`.

## Wiring

- Button: one side to `GND`, other side to `GPIO0/P0`.
- RGB LED: common anode/longest pin to `3V3`.
- RGB red leg through a resistor to `GPIO18`.
- RGB green leg through a resistor to `GPIO19`.
- Resistors: `1k` works but is dim; about `300 ohm` is brighter.

## Firmware

Sketch: `ButtonSerialTest/ButtonSerialTest.ino`

Compile and upload:

```bash
arduino-cli compile --fqbn esp32:esp32:esp32 ButtonSerialTest
arduino-cli upload -p /dev/cu.usbserial-0001 --fqbn esp32:esp32:esp32 ButtonSerialTest
```

Serial monitor:

```bash
arduino-cli monitor -p /dev/cu.usbserial-0001 --config baudrate=115200,dtr=off,rts=off --timestamp
```

## Hammerspoon

Repo config: `hammerspoon/init.lua`

The installed `~/.hammerspoon/init.lua` should load the repo config:

```lua
dofile("/Users/rob/repos/mute-button/hammerspoon/init.lua")
```

Hammerspoon listens to `/dev/cu.usbserial-0001`, watches for `pressed-toggle`, then picks the first running meeting app in priority order:

1. Zoom
2. Microsoft Teams

This is intentionally pragmatic: Zoom is rarely open unless it is the real call, so Zoom wins when both apps are running. A future Google Meet handler should fit between Zoom and Teams by detecting an active Meet browser tab.

State is intentionally one-way:

- `muted` means red LED, onboard LED off, and the meeting app should be muted.
- `unmuted` means green LED, onboard LED on, and the meeting app should be live.

Hammerspoon uses Accessibility to find and read Teams' in-call mic button. Teams currently exposes that control deep in the Accessibility tree, so the search depth is intentionally `24`. `Mute mic` means Teams is currently unmuted; `Unmute mic` means Teams is currently muted. If Teams already matches the ESP32/LED state, Hammerspoon does nothing.

Teams' WebView can report a successful Accessibility press without changing call state, so Hammerspoon uses Accessibility only to locate/read the button, then sends a mouse-level click at the button center when a state change is needed. There is no keyboard shortcut fallback; `Command+Shift+M` can leak into Terminal and open man-page windows.

Zoom is cleaner: Hammerspoon reads Zoom's `Meeting` menu and selects the `Mute audio` / `Unmute audio` menu command only when it does not match the ESP32/LED state. It does not inspect meeting tiles or participant text.

Responsiveness knobs:

- Firmware debounce is `15ms` in `ButtonSerialTest/ButtonSerialTest.ino`.
- Hammerspoon accepts every firmware-reported button press; there is no extra duplicate-drop window on the Mac side.
- Hammerspoon stores the latest LED state as `desiredMuteState`; that state is the source of truth.
- Rapid presses are coalesced for `0.20s` before Hammerspoon touches Zoom or Teams, so a quick double tap usually becomes one final desired state instead of two app commands.
- After any app mute command, Hammerspoon waits `0.90s` before trusting the app's reported mic state. This avoids being fooled by Zoom's briefly stale menu state.
- The controller observes the app state twice before declaring it stable, and sends a new command only if the settled app state still disagrees with the LED.
- For safety, Hammerspoon sends at most one app command for each LED-state version. If Zoom or Teams does not confirm that command, Hammerspoon shows an `app did not confirm` alert instead of repeating the command.
- Status alerts replace the previous alert and last `0.6s`, so the toast should never feel like a cooldown.
- Hammerspoon closes stale serial objects and reconnects when the ESP32 is unplugged/replugged.
- Firmware avoids heartbeat spam during normal operation.

Debug log:

```bash
tail -f /Users/rob/repos/mute-button/hammerspoon-debug.log
```

If Teams shows live/green but nobody hears you, check Teams' selected microphone. During setup, Teams was found listening to `HD Webcam C615` while speakers were on `Scarlett Solo USB`.

## Hardware cleanup ideas

- Put the ESP32 in a small off-the-shelf ABS project box, mint tin, or reused plastic case.
- Use a panel-mount button and mount it through the case lid; add a small drilled hole or hot-glued light pipe for the RGB LED.
- Move the resistors and LED wiring onto a tiny perfboard or solderable breadboard so Dupont jumpers are not carrying the final build.
- Add strain relief where the USB cable and button wires enter the box: zip tie, cable gland, hot glue, or adhesive cable clip.
- If soldering feels too final, use Wago-style lever nuts or screw terminals inside the box for removable button/LED leads.
