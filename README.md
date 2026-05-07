# Mute Button

ESP32 hardware mute button for Microsoft Teams on macOS.

## Wiring

- Button: one side to `GND`, other side to `GPIO0/P0`.
- RGB LED: common anode/longest pin to `3V3`.
- RGB red leg through a resistor to `GPIO18`.
- RGB green leg through a resistor to `GPIO19`.
- Current resistors in use: `1k` works but dim; `300 ohm` is brighter.

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

The installed `~/.hammerspoon/init.lua` should load the repo config. Hammerspoon listens to `/dev/cu.usbserial-0001`, watches for `pressed-toggle`, activates Microsoft Teams, and sends an app-targeted `Command+Shift+M`. Teams is intentionally left focused after each button press. Alerts use the ESP32 state: `Mic is muted` for red and `Mic is hot!` for green.

Responsiveness knobs:

- Firmware debounce is `15ms` in `ButtonSerialTest/ButtonSerialTest.ino`.
- Hammerspoon waits `0.15s` after activating Teams, then sends the shortcut only after Teams is confirmed frontmost.
- Hammerspoon closes stale serial objects and reconnects when the ESP32 is unplugged/replugged.
- Firmware avoids heartbeat spam during normal operation; use the debug log only when needed.

Debug log:

```bash
tail -f /Users/rob/repos/mute-button/hammerspoon-debug.log
```

## Hardware cleanup ideas

- Put the ESP32 in a small off-the-shelf ABS project box, mint tin, or reused plastic case.
- Use a panel-mount button and mount it through the case lid; add a small drilled hole or hot-glued light pipe for the RGB LED.
- Move the resistors and LED wiring onto a tiny perfboard or solderable breadboard so Dupont jumpers are not carrying the final build.
- Add strain relief where the USB cable and button wires enter the box: zip tie, cable gland, hot glue, or adhesive cable clip.
- If soldering feels too final, use Wago-style lever nuts or screw terminals inside the box for removable button/LED leads.
