# Mute-O-Matic: A Big Physical Mute Button for Zoom and Teams on macOS

```text
        ___________________________
       /                           \
      |   M U T E - O - M A T I C   |
      |                             |
      |   RED   = muted             |
      |   GREEN = mic is hot        |
       \____ button goes BONK ______/
```

## Short Version

This project turns an ESP32, a chunky physical button, and a red/green LED into a desk-friendly mute controller for Zoom and Microsoft Teams on macOS.

The important trick is that the ESP32 owns the truth. Every button press flips the LED and sends the new state to the Mac:

- Red means `muted`.
- Green means `unmuted`, also known as `mic is hot`.

Hammerspoon listens over USB serial, picks the most likely meeting app, and nudges that app until it matches the LED. If the app refuses to confirm the change, Hammerspoon stops instead of hammering the mute control forever. We like physical buttons, not haunted toggle loops.

## Editable Graphics

Use these files for Instructables images, blog diagrams, and future edits:

- [Figma design board](https://www.figma.com/design/ZorewgAc0ObJYZJHdDFAW9): cover image, wiring cards, and visual assets.
- [FigJam system flow](https://www.figma.com/board/YSxSCPhi9Viuwuc8APxjnH): process diagrams, including `Mute Button System Flow` and `Latest LED Wins State Machine`.

Suggested exports:

- `01 Cover - Mute-O-Matic`: hero image.
- `02 Wiring Diagram`: button and LED wiring step.
- `03 LED State Cards`: red/green state explainer.
- `Mute Button System Flow`: how hardware, serial, Hammerspoon, Zoom, and Teams fit together.
- `Latest LED Wins State Machine`: why rapid button presses do not become a software slap fight.

## What You Need

- ESP32 dev board.
- Momentary pushbutton.
- Common-anode RGB LED, using only red and green.
- Two LED resistors. `1k` is safe but dim; `330 ohm` or `220 ohm` should be brighter.
- Jumper wires.
- USB cable for the ESP32.
- macOS.
- Hammerspoon.
- Arduino CLI and the ESP32 board package.
- Optional enclosure parts: project box, mint tin, perfboard, heat-shrink, zip ties, hot glue, adhesive cable clips, screw terminals, or Wago-style lever nuts.

## How It Works

The firmware uses `GPIO0/P0` as a pull-up button input. The pin normally reads HIGH. Pressing the button connects it to ground, so pressed reads LOW.

When the firmware sees a debounced press, it toggles an internal state:

- `muted`: red LED on, green LED off, onboard LED off.
- `unmuted`: red LED off, green LED on, onboard LED on.

It then prints a serial line like this:

```text
pressed-toggle raw=LOW pressed=yes state=muted red=on green=off
```

Hammerspoon watches for `pressed-toggle`, extracts `state=muted` or `state=unmuted`, and treats that LED state as the source of truth.

Meeting app priority is intentionally simple:

1. If Zoom is running, control Zoom.
2. Otherwise, if Teams is running, control Teams.

This matches the normal desk reality: Teams may be open all day, but Zoom is usually open because there is a Zoom call.

## Why Not Just Send a Keyboard Shortcut?

Keyboard shortcuts are fast, but they are also context-sensitive. If Teams or Zoom is not focused, the shortcut can go to Terminal, chat, a browser, or somewhere even dumber. Earlier versions of this project triggered weird macOS Terminal help windows. Not ideal.

This build uses app-aware controls instead:

- Zoom: read the `Meeting` menu and select `Mute audio` or `Unmute audio`.
- Teams: use Accessibility to find the call mic button, then mouse-click the button center.

There is no keyboard shortcut fallback.

## Step 1: Wire the Button

Wire one side of the button to `GND`.

Wire the other side of the button to `P0/GPIO0`.

```text
ESP32 P0  -------- button terminal A
ESP32 GND -------- button terminal B
```

The firmware uses `INPUT_PULLUP`, so no external button resistor is needed.

## Step 2: Wire the LED

This build uses a common-anode RGB LED. The common pin goes to `3V3`, not ground.

Each color leg gets its own resistor:

```text
RGB common/anode ---- 3V3
RGB red leg --------- resistor -------- GPIO18
RGB green leg ------- resistor -------- GPIO19
RGB blue leg -------- unused
```

Because this LED is common-anode, the GPIO logic is inverted:

- GPIO LOW turns that color on.
- GPIO HIGH turns that color off.

If your LED is painfully dim with `1k` resistors, try `330 ohm` or `220 ohm` for the red and green legs.

## Step 3: Flash the ESP32

The sketch lives at:

```text
ButtonSerialTest/ButtonSerialTest.ino
```

Compile and upload:

```bash
arduino-cli compile --fqbn esp32:esp32:esp32 ButtonSerialTest
arduino-cli upload -p /dev/cu.usbserial-0001 --fqbn esp32:esp32:esp32 ButtonSerialTest
```

Open the serial monitor:

```bash
arduino-cli monitor -p /dev/cu.usbserial-0001 --config baudrate=115200,dtr=off,rts=off --timestamp
```

Press the button. You should see `pressed-toggle` lines that include `state=muted` and `state=unmuted`.

## Step 4: Install Hammerspoon

Install Hammerspoon, then grant it Accessibility permission:

```text
System Settings -> Privacy & Security -> Accessibility -> Hammerspoon
```

The repo config is:

```text
hammerspoon/init.lua
```

The installed `~/.hammerspoon/init.lua` should load the repo config:

```lua
dofile("/Users/rob/repos/mute-button/hammerspoon/init.lua")
```

Reload or restart Hammerspoon after editing the config.

## Step 5: Test the Whole Contraption

Start a Zoom or Teams call, then press the button.

Expected behavior:

- Red LED: the meeting app should be muted.
- Green LED: the meeting app should be live.
- If the meeting app already matches the LED, Hammerspoon should not click anything.
- If Zoom and Teams are both open, Zoom wins.
- If no supported meeting app or call mic control is found, Hammerspoon should show a short explanatory alert that still includes the LED state.

Debug log:

```bash
tail -f /Users/rob/repos/mute-button/hammerspoon-debug.log
```

## The Rapid-Tap Problem

The hard part was not the button. The hard part was making rapid button presses behave sanely when Zoom or Teams took a moment to update their UI.

The final rule is:

```text
The LED state wins. The app must converge to the LED, not the other way around.
```

Hammerspoon uses a small controller:

- It coalesces rapid presses for `0.20s`, so a quick double tap becomes the final LED state.
- It reads the current app mute state before acting.
- It sends at most one app command for a given LED-state version.
- After sending a command, it waits `0.90s` before trusting the app UI again.
- It requires two matching observations before declaring the app stable.
- If the app does not confirm the command, it stops and shows `app did not confirm` instead of cycling forever.

That last point is important. A mute button should fail safe and visibly, not become a tiny robot that clicks mute/unmute until everyone loses faith in machines.

## Troubleshooting

If the LED changes but the meeting app does not, make sure you are in an active call. Chat windows and idle app windows often do not expose the same mic controls.

If Zoom is open and you meant to control Teams, quit Zoom. The current priority is Zoom first, Teams second.

If Teams says you are live but nobody hears you, check the selected microphone inside Teams. During setup, Teams was using `HD Webcam C615` while speakers were using `Scarlett Solo USB`.

If the LED is too dim, the resistor is probably too large for your taste. `1k` is safe but dim; `330 ohm` or `220 ohm` should be brighter.

If macOS opens weird Terminal help windows, make sure there is no keyboard shortcut fallback configured. This repo intentionally avoids `Command+Shift+M`.

If Hammerspoon says `app did not confirm`, the LED still tells you what the button thinks should be true. Check the meeting app manually, then press the button again if needed.

## Make the Desk Build Less Cursed

No 3D printer required. Good enclosure options:

- Off-the-shelf ABS project box.
- Altoids or mint tin, with insulation inside.
- Reused plastic case.
- Small wood block or scrap acrylic panel.

Tidy-build ideas:

- Mount the panel button through the lid.
- Drill a small LED hole, or hot-glue the LED behind translucent plastic as a light pipe.
- Move resistors and LED wiring to perfboard so jumper wires are not structural.
- Add strain relief where the USB cable and button wires leave the box.
- Use screw terminals or Wago-style lever nuts if you want removable button and LED leads.
- Label the top: `RED = MUTED`, `GREEN = LIVE`.

## Files in This Project

- `ButtonSerialTest/ButtonSerialTest.ino`: ESP32 firmware.
- `hammerspoon/init.lua`: macOS meeting-app controller.
- `README.md`: repo setup notes.
- `INSTRUCTABLE.md`: this publishable write-up.

## Closing Thought

The best interface is the one your hand can find without looking. A big red/green mute button is silly, tactile, and genuinely useful, which is exactly the kind of desk gadget worth building.
