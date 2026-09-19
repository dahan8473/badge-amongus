# WiFi client-server setup

New architecture: boards are thin WiFi clients, the laptop runs the game.
The board only draws screens and sends button presses, so board memory
stops mattering. No mesh, no badge-to-badge radio.

## 1. Laptop hotspot (2.4 GHz)

ESP32 chips only speak 2.4 GHz.

- Easiest: a phone hotspot with "maximize compatibility" (forces 2.4 GHz),
  laptop and boards both join it.
- Or on the Mac: System Settings -> General -> Sharing -> Internet Sharing,
  share from anything to Wi-Fi, set channel to a 2.4 GHz one (1-11),
  network name `amongus`, password `sussussus`.

Then find the laptop's address on that network (`ipconfig getifaddr en0`
or the hotspot interface) and put it in `SERVER_IP` in the sketch.

## 2. Run the server

```
python3 server/server.py --debug     # short timers while testing
```

Type `start` in the server terminal when everyone has joined.
`status` shows players, `reset` returns to lobby.

Prove it works without any hardware:

```
python3 server/fake_players.py       # plays a full 4-player game
```

## 3. Flash a board

The sketch is `firmware/amongus/amongus.ino`. Set the four defines at
the top: `WIFI_SSID`, `WIFI_PASS`, `SERVER_IP`, and pins if you wired
buttons. It compiles for any ESP32 (classic, C3, S3) in Arduino IDE
with the esp32 board package, no libraries required for the base build.

With no wiring at all it is still playable for testing: screens print
to the serial monitor at 115200, and typing letters there presses
buttons (a b u d l r s = A, B, up, down, left, right, start).

Controls on a wired board while playing: START opens your next task,
B reports a body, UP calls your emergency meeting. Impostors pick a
target with LEFT/RIGHT and kill with A. Voting is LEFT/RIGHT then A.

## Flashing the actual HTN badge: read this first

The badge is an ESP32-C3, so this firmware can run on it, but:

1. Back up the stock firmware first, or the badge's own apps, your
   provisioning, and your meal QR are gone with no way back:
   `python3 -m esptool --port /dev/cu.usbmodem101 read_flash 0 0x400000 backup.bin`
2. Check secure boot first: `python3 -m esptool get_security_info`.
   If secure boot is on, custom firmware will not boot at all.
3. Button/screen/LED pins for the badge are not published. Expect to
   recover them from the backup image or ask in #hacker-badges.
4. Restore stock any time:
   `python3 -m esptool write_flash 0 backup.bin`
