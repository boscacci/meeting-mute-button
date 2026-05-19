# Mute-O-Matic: A Big Physical Mute Button for Teams on macOS

```text
        ___________________________
       /                           \
      |   M U T E - O - M A T I C   |
      |                             |
      |   [ red = muted ]           |
      |   [ green = mic is hot ]    |
       \____ button goes BONK ______/
```

## Instructables Graphics

Use these editable Figma files for the cover image, wiring diagram, state legend, and process diagram:

- Figma design board: [Mute-O-Matic Instructable Graphics](https://www.figma.com/design/ZorewgAc0ObJYZJHdDFAW9)
- FigJam flow diagram: [Mute-O-Matic System Flow](https://www.figma.com/board/YSxSCPhi9Viuwuc8APxjnH)

Suggested image exports from the Figma design board:

- `01 Cover - Mute-O-Matic`: Instructable cover image.
- `02 Wiring Diagram`: Wiring step image.
- `03 LED State Cards`: Mute-state explainer image.
- `04 Step Graphics`: Optional step-card collage.

## What We Built

This project turns an ESP32, a chunky physical button, and a red/green LED into a desk-friendly mute controller for Microsoft Teams on macOS.

The ESP32 owns the truth. Every button press toggles a single state:

- Red LED means `muted`.
- Green LED means `unmuted`, also known as `mic is hot`.

The Mac listens over serial with Hammerspoon. When the ESP32 reports a state change, Hammerspoon brings the current Teams call forward, finds the mic control with Accessibility, and clicks it only if Teams does not already match the LED.

## Supplies

- ESP32 dev board.
- Momentary pushbutton.
- Common-anode RGB LED, using only red and green.
- Two LED resistors. `1k` works and is safe but dim; `330 ohm` or `220 ohm` should be brighter.
- Jumper wires.
- USB cable for the ESP32.
- macOS with Hammerspoon installed.
- Optional cleanup bits: small project box, mint tin, perfboard, heat-shrink, zip ties, hot glue, adhesive cable clips, or screw terminals.

## Step 1: Wire the Button

Wire one side of the button to `GND`.

Wire the other side of the button to `P0/GPIO0`.

The firmware uses the ESP32 internal pull-up resistor, so the input normally reads HIGH. Pressing the button connects the pin to ground, so pressed reads LOW.

```text
ESP32 P0  -------- button terminal A
ESP32 GND -------- button terminal B
```

## Step 2: Wire the Red/Green LED

This build uses a common-anode RGB LED. The common pin goes to `3V3`, not ground.

Each color leg gets its own resistor.

```text
RGB common/anode ---- 3V3
RGB red leg --------- resistor -------- GPIO18
RGB green leg ------- resistor -------- GPIO19
RGB blue leg -------- unused
```

Because this is common-anode wiring, the GPIO logic is inverted:

- GPIO LOW turns that LED color on.
- GPIO HIGH turns that LED color off.

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

Press the button. You should see `pressed-toggle` lines that include `state=muted` or `state=unmuted`.

## Step 4: Install the Hammerspoon Config

The repo config is:

```text
hammerspoon/init.lua
```

The installed Hammerspoon config should load it:

```lua
dofile("/Users/rob/repos/mute-button/hammerspoon/init.lua")
```

Hammerspoon needs macOS Accessibility permission so it can inspect Teams and click the in-call mic button.

## Step 5: Test the Whole Contraption

Start a Teams call, then press the button.

Expected behavior:

- Red LED: Teams should be muted.
- Green LED: Teams should be live.
- If Teams already matches the LED, Hammerspoon should not click anything.
- If Teams is not in a call, Hammerspoon should explain that no call mic button was found while still reporting the LED state.

Debug log:

```bash
tail -f /Users/rob/repos/mute-button/hammerspoon-debug.log
```

## Step 6: Make the Desk Build Less Cursed

No 3D printer required. The fastest tidy version is an off-the-shelf project box or mint tin:

- Drill one hole for the panel button.
- Drill a tiny hole for the RGB LED, or hot-glue the LED behind a translucent bit of plastic as a light pipe.
- Move the resistors and LED wiring to perfboard so jumper wires are not doing permanent structural work.
- Add strain relief where wires leave the box.
- Use screw terminals or Wago-style lever nuts if you want the button and LED removable.
- Label the box: `RED = MUTED`, `GREEN = LIVE`.

## Troubleshooting

If the LED changes but Teams does not, make sure you are in an active call. Teams does not expose the same mic button when you are just in chat.

If Teams says you are live but nobody hears you, check the selected microphone inside Teams. During this build, Teams was using `HD Webcam C615` while the speakers were using `Scarlett Solo USB`.

If the LED is too dim, the `1k` resistors are probably doing their job a little too politely. Try `330 ohm` or `220 ohm` resistors for the red and green legs.

If macOS opens weird Terminal help windows, make sure there is no keyboard shortcut fallback configured. This repo intentionally avoids `Command+Shift+M`; Teams WebView was happier with a mouse-level click on the actual mic control.
