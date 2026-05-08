# Mute Button

ESP32 hardware mute button for Microsoft Teams on macOS.

```text
      .----------------.
      |  MUTE-O-MATIC  |
      |  red    green  |
      '-----.____.-----'
            / || \
          GND P0 USB
```

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

Hammerspoon listens to `/dev/cu.usbserial-0001`, watches for `pressed-toggle`, activates Microsoft Teams, and leaves Teams focused.

State is intentionally one-way:

- `muted` means red LED, onboard LED off, and Teams should be muted.
- `unmuted` means green LED, onboard LED on, and Teams should be live.

Hammerspoon uses Accessibility to find and read Teams' in-call mic button. Teams currently exposes that control deep in the Accessibility tree, so the search depth is intentionally `24`. `Mute mic` means Teams is currently unmuted; `Unmute mic` means Teams is currently muted. If Teams already matches the ESP32/LED state, Hammerspoon does nothing.

Teams' WebView can report a successful Accessibility press without changing call state, so Hammerspoon uses Accessibility only to locate/read the button, then sends a mouse-level click at the button center when a state change is needed. There is no keyboard shortcut fallback; `Command+Shift+M` can leak into Terminal and open man-page windows.

Responsiveness knobs:

- Firmware debounce is `15ms` in `ButtonSerialTest/ButtonSerialTest.ino`.
- Hammerspoon waits `0.15s` after activating Teams, then acts only after Teams is confirmed frontmost.
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
