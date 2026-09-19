// Among Us for the actual HTN 2026 badge (ESP32-C3).
// Full native client: ST7789 screen + I2C-expander buttons + WS2812 LEDs,
// talking to the laptop game server over WiFi. Pins are filled in from
// the firmware reverse-engineering (see PIN MAP below).
//
// Build: arduino-cli compile --fqbn esp32:esp32:esp32c3:CDCOnBoot=cdc firmware/badge
// Libraries: GFX Library for Arduino, Adafruit NeoPixel.

#include <WiFi.h>
#include <Arduino_GFX_Library.h>
#include <Adafruit_NeoPixel.h>

// ==================== PIN MAP (recovered from stock firmware) ====================
#define PIN_LCD_SCLK  1
#define PIN_LCD_MOSI  10
#define PIN_LCD_CS    2
#define PIN_LCD_DC    0
#define PIN_LCD_RST   4
#define PIN_LCD_BL    -1   // backlight hardwired on, no GPIO

#define PIN_LED       3
#define NUM_LEDS      6

// Buttons: 7 face buttons on a 74HC165 shift register, START direct on GPIO9.
#define PIN_165_DATA  7    // QH serial out
#define PIN_165_LATCH 20   // SH/LD, idles high; pulse low to load
#define PIN_165_CLK   21   // CLK, idles low; pulse high to shift
#define PIN_START_BTN 9    // direct (also BOOT strap), active-low

enum { KA, KB, KUP, KDOWN, KLEFT, KRIGHT, KHOME, KSTART, KN };
// which 74HC165 stage (0-7) each face button sits on. Calibrated on
// hardware. START is the direct GPIO9 pin, not a shift-register stage.
int stageOf[KN] = { 0, 1, 6, 3, 4, 5, 2, /*START direct*/ -1 };
#define DEBUG_BTN 0  // 1 = print raw shift-register byte over serial

// ==================== config ====================
#define WIFI_SSID "amongus"
#define WIFI_PASS "sussussus"
#define SERVER_IP "192.168.2.1"
#define SERVER_PORT 4269
#define PLAYER_NAME ""

#ifndef BLACK
#define BLACK 0x0000
#define WHITE 0xFFFF
#endif

Arduino_DataBus *bus = nullptr;
Arduino_GFX *gfx = nullptr;
Adafruit_NeoPixel leds(NUM_LEDS, PIN_LED < 0 ? 0 : PIN_LED, NEO_GRB + NEO_KHZ800);

// ==================== game state (mirror of the thin client) ====================
WiFiClient sock;
char lineBuf[512];
int lineLen = 0;
unsigned long lastHello = 0, lastDraw = 0, lastBtn = 0;

int myPid = 0;
bool isImp = false, haveRole = false, dead = false;
int myTasks[3] = { 0, 0, 0 };
int phase = 0, taskPct = 0, cd = 0;
char winner[8] = "";
int alive[16], nAlive = 0;
bool inTask = false;
int taskStation = 0, taskKind = 0, mashCount = 0, simonStep = 0, simonSeq[4];
int voteSel = 0;
bool voteCast = false;
uint16_t btnPrev = 0;

// ==================== tiny json (same as thin client) ====================
int jsonInt(const char *s, const char *key, int fb) {
  char pat[32]; snprintf(pat, sizeof(pat), "\"%s\":", key);
  const char *p = strstr(s, pat); return p ? atoi(p + strlen(pat)) : fb;
}
bool jsonStr(const char *s, const char *key, char *out, int n) {
  char pat[32]; snprintf(pat, sizeof(pat), "\"%s\":\"", key);
  const char *p = strstr(s, pat); if (!p) return false;
  p += strlen(pat); int i = 0;
  while (*p && *p != '"' && i < n - 1) out[i++] = *p++;
  out[i] = 0; return true;
}
int jsonArr(const char *s, const char *key, int *out, int maxN) {
  char pat[32]; snprintf(pat, sizeof(pat), "\"%s\":[", key);
  const char *p = strstr(s, pat); if (!p) return 0;
  p += strlen(pat); int n = 0;
  while (*p && *p != ']' && n < maxN) {
    if (isdigit(*p)) { out[n++] = atoi(p); while (isdigit(*p)) p++; } else p++;
  }
  return n;
}

// ==================== net ====================
void sendLine(const char *s) { if (sock.connected()) { sock.print(s); sock.print("\n"); } }
void sendHello() {
  char b[128];
  snprintf(b, sizeof(b), "{\"t\":\"hello\",\"mac\":\"%s\",\"name\":\"%s\"}",
           WiFi.macAddress().c_str(), PLAYER_NAME);
  sendLine(b);
}
void handleMsg(const char *m) {
  char t[16]; if (!jsonStr(m, "t", t, sizeof(t))) return;
  if (!strcmp(t, "welcome")) myPid = jsonInt(m, "pid", 0);
  else if (!strcmp(t, "role")) {
    char r[8]; jsonStr(m, "role", r, sizeof(r));
    isImp = !strcmp(r, "imp"); haveRole = true; dead = false;
    jsonArr(m, "tasks", myTasks, 3);
  } else if (!strcmp(t, "dead")) dead = true;
  else if (!strcmp(t, "state")) {
    int was = phase;
    phase = jsonInt(m, "phase", phase);
    taskPct = jsonInt(m, "taskPct", taskPct);
    cd = jsonInt(m, "cd", cd);
    nAlive = jsonArr(m, "alive", alive, 16);
    jsonStr(m, "winner", winner, sizeof(winner));
    if (phase == 0 && was != 0) { haveRole = dead = inTask = false; }
    if (phase == 3 && was != 3) { voteSel = 0; voteCast = false; }
    if (haveRole && myPid && phase != 0) {
      bool am = false; for (int i = 0; i < nAlive; i++) if (alive[i] == myPid) am = true;
      if (!am) dead = true;
    }
  }
}
void pumpNet() {
  while (sock.connected() && sock.available()) {
    char c = sock.read();
    if (c == '\n') { lineBuf[lineLen] = 0; handleMsg(lineBuf); lineLen = 0; }
    else if (lineLen < (int)sizeof(lineBuf) - 1) lineBuf[lineLen++] = c;
  }
  if (!sock.connected() && WiFi.status() == WL_CONNECTED && millis() - lastHello > 3000) {
    lastHello = millis();
    static bool gw = false;
    bool ok = gw ? sock.connect(WiFi.gatewayIP(), SERVER_PORT)
                 : sock.connect(SERVER_IP, SERVER_PORT);
    gw = !gw; if (ok) sendHello();
  }
}

// ==================== buttons (74HC165 shift register + direct START) ====================
// returns 8 raw stages as a byte, bit i = stage i, already inverted so
// 1 = pressed (the register lines are active-low).
uint8_t readShift() {
  digitalWrite(PIN_165_LATCH, LOW);   // load parallel inputs
  delayMicroseconds(5);
  digitalWrite(PIN_165_LATCH, HIGH);  // back to shift mode
  uint8_t v = 0;
  for (int i = 0; i < 8; i++) {
    if (digitalRead(PIN_165_DATA)) v |= (1 << i);
    digitalWrite(PIN_165_CLK, HIGH);
    delayMicroseconds(5);
    digitalWrite(PIN_165_CLK, LOW);
  }
  return ~v; // active-low -> 1 means pressed
}

uint16_t readButtons() {
  uint8_t raw = readShift();
  uint16_t mask = 0;
  for (int k = 0; k < KN; k++)
    if (stageOf[k] >= 0 && (raw & (1 << stageOf[k]))) mask |= (1 << k);
  if (digitalRead(PIN_START_BTN) == LOW) mask |= (1 << KSTART);
  return mask;
}

void onPress(int k);
uint8_t rawPrev = 0;
void pumpButtons() {
  if (DEBUG_BTN) {
    uint8_t raw = readShift();
    if (raw != rawPrev) {
      Serial.printf("shift stages pressed:");
      for (int i = 0; i < 8; i++) if (raw & (1 << i)) Serial.printf(" %d", i);
      if (digitalRead(PIN_START_BTN) == LOW) Serial.printf(" START(gpio9)");
      Serial.println();
      rawPrev = raw;
    }
  }
  uint16_t now = readButtons();
  for (int k = 0; k < KN; k++)
    if ((now & (1 << k)) && !(btnPrev & (1 << k))) onPress(k);
  btnPrev = now;
  while (Serial.available()) { // serial fallback for testing
    char c = tolower(Serial.read());
    const char keys[] = { 'a', 'b', 'u', 'd', 'l', 'r', 'h', 's' };
    for (int k = 0; k < KN; k++) if (c == keys[k]) onPress(k);
  }
}

void onPress(int k) {
  char b[64];
  if (inTask) {
    if (taskKind == 0 && k == KB) {
      if (++mashCount >= 12) { snprintf(b, sizeof(b), "{\"t\":\"task\",\"station\":%d}", taskStation); sendLine(b); inTask = false; }
    } else if (taskKind == 1) {
      int d = k == KUP ? 0 : k == KDOWN ? 1 : k == KLEFT ? 2 : k == KRIGHT ? 3 : -1;
      if (d >= 0) {
        if (d == simonSeq[simonStep]) { if (++simonStep >= 4) { snprintf(b, sizeof(b), "{\"t\":\"task\",\"station\":%d}", taskStation); sendLine(b); inTask = false; } }
        else simonStep = 0;
      }
    }
    return;
  }
  if (phase == 1 && !dead) {
    if (k == KSTART) {
      for (int i = 0; i < 3; i++) if (myTasks[i] > 0) {
        taskStation = myTasks[i]; myTasks[i] = 0; taskKind = taskStation % 2;
        mashCount = simonStep = 0; for (int j = 0; j < 4; j++) simonSeq[j] = random(4);
        inTask = true; break;
      }
    } else if (k == KA && isImp && nAlive && alive[voteSel % nAlive] != myPid) {
      snprintf(b, sizeof(b), "{\"t\":\"kill\",\"target\":%d}", alive[voteSel % nAlive]); sendLine(b);
    } else if (k == KLEFT || k == KRIGHT) {
      voteSel += (k == KRIGHT) ? 1 : nAlive - 1;
    } else if (k == KB) sendLine("{\"t\":\"report\"}");
    else if (k == KUP) sendLine("{\"t\":\"meet\"}");
  } else if (phase == 3 && !dead && !voteCast) {
    if (k == KLEFT || k == KRIGHT) voteSel += (k == KRIGHT) ? 1 : nAlive;
    else if (k == KA) {
      int t = (voteSel % (nAlive + 1)) == 0 ? 0 : alive[voteSel % (nAlive + 1) - 1];
      snprintf(b, sizeof(b), "{\"t\":\"vote\",\"target\":%d}", t); sendLine(b); voteCast = true;
    }
  }
}

// ==================== drawing ====================
void center(const char *s, int y, uint16_t col, int size) {
  gfx->setTextColor(col); gfx->setTextSize(size);
  int16_t x1, y1; uint16_t w, h;
  gfx->getTextBounds(s, 0, 0, &x1, &y1, &w, &h);
  gfx->setCursor((320 - w) / 2, y); gfx->print(s);
}
void draw() {
  if (!gfx) return;
  char b[64];
  uint16_t IMP = RGB565(226, 60, 60), CREW = RGB565(53, 196, 240), DIM = RGB565(120, 120, 140);
  gfx->fillScreen(BLACK);
  if (WiFi.status() != WL_CONNECTED) { center("joining wifi...", 110, WHITE, 2); return; }
  if (!sock.connected()) { center("finding server...", 110, WHITE, 2); return; }
  if (!strcmp(winner, "crew") || !strcmp(winner, "imp")) {
    center(!strcmp(winner, "crew") ? "CREW WINS" : "IMPOSTORS WIN", 100, !strcmp(winner, "crew") ? CREW : IMP, 3);
    return;
  }
  if (phase == 0) { center("LOBBY", 60, WHITE, 4); snprintf(b, sizeof(b), "you are P%d", myPid); center(myPid ? b : "joining...", 130, DIM, 2); }
  else if (dead) { center("KILLED", 70, IMP, 4); center("ghost: finish tasks", 140, DIM, 2); }
  else if (inTask) {
    if (taskKind == 0) { snprintf(b, sizeof(b), "MASH B  %d/12", mashCount); center("GARBAGE", 60, WHITE, 3); center(b, 130, CREW, 3); }
    else { const char *nm[] = { "UP", "DN", "LF", "RT" }; snprintf(b, sizeof(b), "%s %s %s %s", nm[simonSeq[0]], nm[simonSeq[1]], nm[simonSeq[2]], nm[simonSeq[3]]); center("WIRING", 50, WHITE, 3); center(b, 120, CREW, 3); snprintf(b, sizeof(b), "%d/4", simonStep); center(b, 170, DIM, 2); }
  } else if (phase == 1) {
    center(isImp ? "IMPOSTOR" : "CREW", 20, isImp ? IMP : CREW, 3);
    snprintf(b, sizeof(b), "ship %d%%", taskPct); center(b, 70, WHITE, 2);
    snprintf(b, sizeof(b), "tasks: %d %d %d", myTasks[0], myTasks[1], myTasks[2]); center(b, 100, DIM, 2);
    if (isImp && nAlive) { snprintf(b, sizeof(b), "target P%d  A=kill", alive[voteSel % nAlive]); center(b, 150, IMP, 2); }
    center("START task  B report  UP meet", 210, DIM, 1);
  } else if (phase == 2) { snprintf(b, sizeof(b), "MEETING  %ds", cd); center(b, 100, IMP, 3); }
  else if (phase == 3) {
    if (voteCast) center("voted...", 100, DIM, 3);
    else { int p = voteSel % (nAlive + 1); if (p == 0) snprintf(b, sizeof(b), "SKIP"); else snprintf(b, sizeof(b), "P%d", alive[p - 1]); center("VOTE", 40, WHITE, 3); center(b, 110, IMP, 4); snprintf(b, sizeof(b), "%ds  L/R  A=vote", cd); center(b, 180, DIM, 2); }
  }
}
void drawLeds() {
  if (PIN_LED < 0) return;
  uint32_t c = dead ? leds.Color(80, 0, 0)
             : (phase == 2 || phase == 3) ? leds.Color(120, 30, 0)
             : (isImp && haveRole) ? leds.Color(60, 0, 0)
             : leds.Color(0, 20, 50);
  for (int i = 0; i < NUM_LEDS; i++) leds.setPixelColor(i, c);
  leds.show();
}

// ==================== arduino ====================
void setup() {
  Serial.begin(115200);
  if (PIN_LCD_BL >= 0) { pinMode(PIN_LCD_BL, OUTPUT); digitalWrite(PIN_LCD_BL, HIGH); }
  if (PIN_LCD_SCLK >= 0) {
    bus = new Arduino_ESP32SPI(PIN_LCD_DC, PIN_LCD_CS, PIN_LCD_SCLK, PIN_LCD_MOSI, GFX_NOT_DEFINED);
    gfx = new Arduino_ST7789(bus, PIN_LCD_RST, 1 /*rotation*/, true /*IPS*/, 240, 320);
    gfx->begin(40000000);
    gfx->fillScreen(BLACK);
  }
  pinMode(PIN_165_LATCH, OUTPUT); digitalWrite(PIN_165_LATCH, HIGH);
  pinMode(PIN_165_CLK, OUTPUT); digitalWrite(PIN_165_CLK, LOW);
  pinMode(PIN_165_DATA, INPUT);
  pinMode(PIN_START_BTN, INPUT_PULLUP);
  if (PIN_LED >= 0) { leds.setPin(PIN_LED); leds.begin(); leds.show(); }
  WiFi.mode(WIFI_STA);
  WiFi.begin(WIFI_SSID, WIFI_PASS);
}
void loop() {
  pumpNet();
  if (millis() - lastBtn > 30) { lastBtn = millis(); pumpButtons(); }
  if (millis() - lastDraw > 250) { lastDraw = millis(); draw(); drawLeds(); }
#if DEBUG_BTN
  static unsigned long hb = 0;
  if (millis() - hb > 700) {
    hb = millis();
    Serial.printf("alive t=%lus wifi=%d raw165=0x%02X start=%d\n",
                  millis() / 1000, WiFi.status() == WL_CONNECTED,
                  (uint8_t)~readShift() & 0xFF, digitalRead(PIN_START_BTN));
  }
#endif
  delay(2);
}
