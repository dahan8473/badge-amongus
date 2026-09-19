// Among Us thin client for ESP32-family boards.
// The board does almost nothing: connect to the laptop's 2.4GHz hotspot,
// keep a TCP line open to the game server, send button presses, draw
// whatever the current state says. All game logic lives on the laptop.
//
// Works on a bare devkit with zero wiring: every screen is also printed
// to the serial monitor (115200) and buttons can be typed there as
// letters. Wire real buttons / LEDs / a TFT later by filling in the pins.
//
// Libraries: none required for the base build. Optional:
//   - Adafruit NeoPixel (set LED_PIN >= 0)
//   - TFT_eSPI          (set USE_TFT 1, configure User_Setup.h)

#include <WiFi.h>

// -------------------------------------------------- configuration

#define WIFI_SSID "amongus"      // laptop hotspot, 2.4 GHz
#define WIFI_PASS "sussussus"
#define SERVER_IP "192.168.2.1"  // the laptop's address on the hotspot
#define SERVER_PORT 4269
#define PLAYER_NAME ""           // empty = server names us P<pid>

// button GPIOs, -1 to disable. Buttons short the pin to ground.
#define PIN_A 9   // most devkits: GPIO9 is the BOOT button, usable as A
#define PIN_B -1
#define PIN_UP -1
#define PIN_DOWN -1
#define PIN_LEFT -1
#define PIN_RIGHT -1
#define PIN_START -1

#define LED_PIN -1               // NeoPixel data pin, -1 = off
#define NUM_LEDS 6
#define USE_TFT 0

#if LED_PIN >= 0
#include <Adafruit_NeoPixel.h>
Adafruit_NeoPixel leds(NUM_LEDS, LED_PIN, NEO_GRB + NEO_KHZ800);
#endif
#if USE_TFT
#include <TFT_eSPI.h>
TFT_eSPI tft;
#endif

// -------------------------------------------------- game state

enum Btn { BTN_A, BTN_B, BTN_UP, BTN_DOWN, BTN_LEFT, BTN_RIGHT, BTN_START, BTN_N };
const int btnPins[BTN_N] = { PIN_A, PIN_B, PIN_UP, PIN_DOWN,
                             PIN_LEFT, PIN_RIGHT, PIN_START };
const char btnKeys[BTN_N] = { 'a', 'b', 'u', 'd', 'l', 'r', 's' };
bool btnWas[BTN_N];

WiFiClient sock;
char lineBuf[512];
int lineLen = 0;
unsigned long lastHello = 0, lastDraw = 0;

int myPid = 0;
bool isImp = false, haveRole = false, dead = false;
int myTasks[3] = { 0, 0, 0 };
int phase = 0, taskPct = 0, cd = 0; // 0 lobby 1 play 2 talk 3 vote 4 end
char winner[8] = "";
int alive[16], nAlive = 0;

// task minigame
bool inTask = false;
int taskStation = 0, taskKind = 0, mashCount = 0, simonStep = 0;
int simonSeq[4];
// voting
int voteSel = 0;
bool voteCast = false;

// -------------------------------------------------- tiny json helpers
// the server sends small flat json; find fields by key, no library needed

int jsonInt(const char *s, const char *key, int fallback) {
  char pat[32];
  snprintf(pat, sizeof(pat), "\"%s\":", key);
  const char *p = strstr(s, pat);
  if (!p) return fallback;
  return atoi(p + strlen(pat));
}

bool jsonStr(const char *s, const char *key, char *out, int outLen) {
  char pat[32];
  snprintf(pat, sizeof(pat), "\"%s\":\"", key);
  const char *p = strstr(s, pat);
  if (!p) return false;
  p += strlen(pat);
  int i = 0;
  while (*p && *p != '"' && i < outLen - 1) out[i++] = *p++;
  out[i] = 0;
  return true;
}

int jsonIntArray(const char *s, const char *key, int *out, int maxN) {
  char pat[32];
  snprintf(pat, sizeof(pat), "\"%s\":[", key);
  const char *p = strstr(s, pat);
  if (!p) return 0;
  p += strlen(pat);
  int n = 0;
  while (*p && *p != ']' && n < maxN) {
    if (isdigit(*p)) { out[n++] = atoi(p); while (isdigit(*p)) p++; }
    else p++;
  }
  return n;
}

// -------------------------------------------------- networking

void sendLine(const char *s) {
  if (sock.connected()) { sock.print(s); sock.print("\n"); }
}

void sendHello() {
  char buf[128];
  snprintf(buf, sizeof(buf),
           "{\"t\":\"hello\",\"mac\":\"%s\",\"name\":\"%s\"}",
           WiFi.macAddress().c_str(), PLAYER_NAME);
  sendLine(buf);
}

void handleMsg(const char *m) {
  char t[16];
  if (!jsonStr(m, "t", t, sizeof(t))) return;
  if (!strcmp(t, "welcome")) {
    myPid = jsonInt(m, "pid", 0);
  } else if (!strcmp(t, "role")) {
    char r[8];
    jsonStr(m, "role", r, sizeof(r));
    isImp = !strcmp(r, "imp");
    haveRole = true;
    dead = false;
    jsonIntArray(m, "tasks", myTasks, 3);
  } else if (!strcmp(t, "dead")) {
    dead = true;
  } else if (!strcmp(t, "state")) {
    int was = phase;
    phase = jsonInt(m, "phase", phase);
    taskPct = jsonInt(m, "taskPct", taskPct);
    cd = jsonInt(m, "cd", cd);
    nAlive = jsonIntArray(m, "alive", alive, 16);
    jsonStr(m, "winner", winner, sizeof(winner));
    if (phase == 0 && was != 0) { haveRole = false; dead = false; inTask = false; }
    if (phase == 3 && was != 3) { voteSel = 0; voteCast = false; }
    // dead if the game says so
    if (haveRole && myPid) {
      bool am = false;
      for (int i = 0; i < nAlive; i++) if (alive[i] == myPid) am = true;
      if (!am && phase != 0) dead = true;
    }
  }
}

void pumpNet() {
  while (sock.connected() && sock.available()) {
    char c = sock.read();
    if (c == '\n') {
      lineBuf[lineLen] = 0;
      handleMsg(lineBuf);
      lineLen = 0;
    } else if (lineLen < (int)sizeof(lineBuf) - 1) {
      lineBuf[lineLen++] = c;
    }
  }
  if (!sock.connected() && WiFi.status() == WL_CONNECTED
      && millis() - lastHello > 3000) {
    lastHello = millis();
    // try the configured address, then the gateway: when the laptop runs
    // the hotspot, the laptop IS the gateway, so no config is needed
    static bool tryGateway = false;
    bool ok = tryGateway ? sock.connect(WiFi.gatewayIP(), SERVER_PORT)
                         : sock.connect(SERVER_IP, SERVER_PORT);
    tryGateway = !tryGateway;
    if (ok) sendHello();
  }
}

// -------------------------------------------------- input

void press(int b);

void pumpButtons() {
  for (int i = 0; i < BTN_N; i++) {
    if (btnPins[i] < 0) continue;
    bool down = digitalRead(btnPins[i]) == LOW;
    if (down && !btnWas[i]) press(i);
    btnWas[i] = down;
  }
  while (Serial.available()) { // type a/b/u/d/l/r/s in the serial monitor
    char c = tolower(Serial.read());
    for (int i = 0; i < BTN_N; i++) if (c == btnKeys[i]) press(i);
  }
}

void press(int b) {
  char buf[64];
  if (inTask) {
    if (taskKind == 0 && b == BTN_B) {
      if (++mashCount >= 12) {
        snprintf(buf, sizeof(buf), "{\"t\":\"task\",\"station\":%d}", taskStation);
        sendLine(buf);
        inTask = false;
      }
    } else if (taskKind == 1) {
      int dir = b == BTN_UP ? 0 : b == BTN_DOWN ? 1 : b == BTN_LEFT ? 2
                : b == BTN_RIGHT ? 3 : -1;
      if (dir >= 0) {
        if (dir == simonSeq[simonStep]) {
          if (++simonStep >= 4) {
            snprintf(buf, sizeof(buf), "{\"t\":\"task\",\"station\":%d}", taskStation);
            sendLine(buf);
            inTask = false;
          }
        } else simonStep = 0;
      }
    }
    return;
  }
  if (phase == 1 && !dead) { // playing
    if (b == BTN_START) { // open the next unfinished task
      for (int i = 0; i < 3; i++) if (myTasks[i] > 0) {
        taskStation = myTasks[i];
        myTasks[i] = 0; // server confirms via taskPct; local list just advances
        taskKind = taskStation % 2;
        mashCount = 0; simonStep = 0;
        for (int j = 0; j < 4; j++) simonSeq[j] = random(4);
        inTask = true;
        break;
      }
    } else if (b == BTN_A && isImp) {
      // kill: cycle through living targets with LEFT/RIGHT, A sends
      if (alive[voteSel % nAlive] != myPid) {
        snprintf(buf, sizeof(buf), "{\"t\":\"kill\",\"target\":%d}",
                 alive[voteSel % nAlive]);
        sendLine(buf);
      }
    } else if (b == BTN_LEFT || b == BTN_RIGHT) {
      voteSel += (b == BTN_RIGHT) ? 1 : nAlive - 1;
    } else if (b == BTN_B) {
      sendLine("{\"t\":\"report\"}");
    } else if (b == BTN_UP) {
      sendLine("{\"t\":\"meet\"}");
    }
  } else if (phase == 3 && !dead && !voteCast) { // voting
    if (b == BTN_LEFT || b == BTN_RIGHT) {
      voteSel += (b == BTN_RIGHT) ? 1 : nAlive;
    } else if (b == BTN_A) {
      int t = (voteSel % (nAlive + 1)) == 0 ? 0 : alive[voteSel % (nAlive + 1) - 1];
      snprintf(buf, sizeof(buf), "{\"t\":\"vote\",\"target\":%d}", t);
      sendLine(buf);
      voteCast = true;
    }
  }
}

// -------------------------------------------------- drawing

void drawLine(int row, const char *text) {
#if USE_TFT
  tft.drawString(text, 10, 20 + row * 24, 2);
#endif
  Serial.println(text);
}

void draw() {
  char buf[64];
#if USE_TFT
  tft.fillScreen(TFT_BLACK);
#endif
  Serial.println("----------------------------");
  if (WiFi.status() != WL_CONNECTED) { drawLine(0, "joining wifi..."); return; }
  if (!sock.connected()) { drawLine(0, "finding server..."); return; }
  if (!strcmp(winner, "crew") || !strcmp(winner, "imp")) {
    drawLine(0, !strcmp(winner, "crew") ? "CREW WINS" : "IMPOSTORS WIN");
    return;
  }
  if (phase == 0) {
    snprintf(buf, sizeof(buf), "LOBBY - you are P%d", myPid);
    drawLine(0, myPid ? buf : "LOBBY - joining...");
    drawLine(1, "waiting for the ship to start");
  } else if (dead) {
    drawLine(0, "YOU WERE KILLED");
    drawLine(1, "ghost mode, tell no one");
  } else if (inTask) {
    if (taskKind == 0) {
      snprintf(buf, sizeof(buf), "GARBAGE: mash B %d/12", mashCount);
      drawLine(0, buf);
    } else {
      const char *names[] = { "UP", "DOWN", "LEFT", "RIGHT" };
      snprintf(buf, sizeof(buf), "WIRING %d/4: %s %s %s %s", simonStep,
               names[simonSeq[0]], names[simonSeq[1]],
               names[simonSeq[2]], names[simonSeq[3]]);
      drawLine(0, buf);
    }
  } else if (phase == 1) {
    drawLine(0, isImp ? "IMPOSTOR" : "CREW");
    snprintf(buf, sizeof(buf), "ship %d%%  tasks: %d %d %d", taskPct,
             myTasks[0], myTasks[1], myTasks[2]);
    drawLine(1, buf);
    if (isImp) {
      snprintf(buf, sizeof(buf), "L/R target P%d  A kill",
               nAlive ? alive[voteSel % nAlive] : 0);
      drawLine(2, buf);
    }
    drawLine(3, "S task  B report  U meeting");
  } else if (phase == 2) {
    snprintf(buf, sizeof(buf), "MEETING  %ds", cd);
    drawLine(0, buf);
  } else if (phase == 3) {
    int pick = voteSel % (nAlive + 1);
    snprintf(buf, sizeof(buf), "VOTE %ds: %s%d  (A votes)", cd,
             pick == 0 ? "SKIP " : "P", pick == 0 ? 0 : alive[pick - 1]);
    drawLine(0, voteCast ? "voted, waiting..." : buf);
  }
}

// -------------------------------------------------- arduino

void setup() {
  Serial.begin(115200);
  for (int i = 0; i < BTN_N; i++)
    if (btnPins[i] >= 0) pinMode(btnPins[i], INPUT_PULLUP);
#if LED_PIN >= 0
  leds.begin();
#endif
#if USE_TFT
  tft.init();
  tft.setRotation(1);
#endif
  WiFi.mode(WIFI_STA);
  WiFi.begin(WIFI_SSID, WIFI_PASS);
}

void loop() {
  pumpNet();
  pumpButtons();
  if (millis() - lastDraw > 500) {
    lastDraw = millis();
    draw();
#if LED_PIN >= 0
    uint32_t c = dead ? leds.Color(80, 0, 0)
               : phase == 2 || phase == 3 ? leds.Color(120, 30, 0)
               : isImp && haveRole ? leds.Color(60, 0, 0)
               : leds.Color(0, 20, 50);
    for (int i = 0; i < NUM_LEDS; i++) leds.setPixelColor(i, c);
    leds.show();
#endif
  }
  delay(5);
}
