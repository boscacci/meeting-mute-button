const uint8_t BUTTON_PIN = 0;
const uint8_t RED_LED_PIN = 18;
const uint8_t GREEN_LED_PIN = 19;
#ifndef LED_BUILTIN
const uint8_t LED_PIN = 2;
#else
const uint8_t LED_PIN = LED_BUILTIN;
#endif
const unsigned long DEBOUNCE_MS = 30;
const unsigned long HEARTBEAT_MS = 1000;

int lastRawReading = HIGH;
int stableReading = HIGH;
bool muted = false;
unsigned long lastRawChangeAt = 0;
unsigned long lastHeartbeatAt = 0;

void setExternalLeds(bool redOn, bool greenOn) {
  digitalWrite(RED_LED_PIN, redOn ? LOW : HIGH);
  digitalWrite(GREEN_LED_PIN, greenOn ? LOW : HIGH);
}

void applyMuteLeds() {
  setExternalLeds(muted, !muted);
  digitalWrite(LED_PIN, muted ? LOW : HIGH);
}

void runLedDiagnostic() {
  Serial.println("LED diagnostic: red blink, green blink, both blink");

  for (uint8_t i = 0; i < 3; i++) {
    setExternalLeds(true, false);
    delay(250);
    setExternalLeds(false, false);
    delay(250);
  }

  for (uint8_t i = 0; i < 3; i++) {
    setExternalLeds(false, true);
    delay(250);
    setExternalLeds(false, false);
    delay(250);
  }

  for (uint8_t i = 0; i < 3; i++) {
    setExternalLeds(true, true);
    delay(250);
    setExternalLeds(false, false);
    delay(250);
  }

  applyMuteLeds();
}

void printState(const char *label, int reading) {
  Serial.print(label);
  Serial.print(" raw=");
  Serial.print(reading == LOW ? "LOW" : "HIGH");
  Serial.print(" pressed=");
  Serial.print(reading == LOW ? "yes" : "no");
  Serial.print(" state=");
  Serial.print(muted ? "muted" : "unmuted");
  Serial.print(" red=");
  Serial.print(muted ? "on" : "off");
  Serial.print(" green=");
  Serial.println(muted ? "off" : "on");
}

void setup() {
  pinMode(BUTTON_PIN, INPUT_PULLUP);
  pinMode(RED_LED_PIN, OUTPUT);
  pinMode(GREEN_LED_PIN, OUTPUT);
  pinMode(LED_PIN, OUTPUT);
  applyMuteLeds();
  Serial.begin(115200);
  delay(500);

  stableReading = digitalRead(BUTTON_PIN);
  lastRawReading = stableReading;

  Serial.println();
  Serial.println("ButtonSerialTest ready");
  Serial.println("Wiring: GND -> one side of switch, GPIO0/P0 -> other side");
  Serial.println("Using INPUT_PULLUP: released=HIGH, pressed=LOW");
  Serial.print("Red LED pin: ");
  Serial.println(RED_LED_PIN);
  Serial.print("Green LED pin: ");
  Serial.println(GREEN_LED_PIN);
  Serial.println("RGB LED mode: common anode, common pin wired to 3V3");
  Serial.print("Onboard LED mirrors live state on pin ");
  Serial.println(LED_PIN);
  Serial.println("Toggle mode: each debounced press flips red/green");
  runLedDiagnostic();
  printState("initial", stableReading);
}

void loop() {
  const unsigned long now = millis();
  const int rawReading = digitalRead(BUTTON_PIN);

  if (rawReading != lastRawReading) {
    lastRawReading = rawReading;
    lastRawChangeAt = now;
    printState("raw-change", rawReading);
  }

  if ((now - lastRawChangeAt) >= DEBOUNCE_MS && rawReading != stableReading) {
    stableReading = rawReading;
    if (stableReading == LOW) {
      muted = !muted;
      applyMuteLeds();
      printState("pressed-toggle", stableReading);
    } else {
      printState("released", stableReading);
    }
  }

  if ((now - lastHeartbeatAt) >= HEARTBEAT_MS) {
    lastHeartbeatAt = now;
    printState("heartbeat", stableReading);
  }
}
