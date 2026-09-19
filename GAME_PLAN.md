# Badge Among Us — Game Plan

$2,500 Best Badge Hack entry. Venue-scale social deduction on HTN 2026 badges.
Timed 10-15 min rounds, up to 15 players + 1 dedicated host badge (the "ship").

## Hardware primitives used
- Radio: 44-byte LUA1 BLE broadcasts, on_recv(mac, rssi, payload), 8-slot ring
- NFC: read tag UID + NDEF text (task stations, NTAG213/215 stickers)
- Accel: shake(), tilt via accel() (minigames)
- 6 RGB LEDs, 320x240 screen, 8 buttons
- Share app for distribution (cap: 48KB bundle, 16 files)

## Kill range (RSSI)
- Alive players beacon at 1Hz (player id, alive, task count)
- Per-player smoothed RSSI: EMA over last 3-5 beacons
- KILL available: smoothed >= ~-55dBm for 2+ consecutive beacons (~arm's length to 2m chest-worn)
- REPORT body: >= ~-62dBm
- Impostor HUD shows proximity meter (LED bar). Kill cooldown 30-45s, host-enforced.
- Calibrate Saturday AM: 2 badges, walk test 1/2/5m, log RSSI via serial (badge.py monitor).
- Debug overlay: hold AUX1 shows live RSSI per player.
- Accepted lag: ~2s (1Hz beacons). Reads as "get close and linger."

## Tasks (NFC stations)
- 8-12 NTAG213/215 stickers around a bounded play area, written via phone (NFC Tools)
- NDEF text: `AU1:<station_id>:<minigame>` — our own tags, no clash with HTN scavenger stickers
- Player gets 3-4 assigned stations at START. Tap bottom of badge on sticker -> minigame.
- NFC enabled only inside the task screen (power).
- Minigames (~20 lines each):
  - wires: repeat 5-step D-pad Simon sequence
  - engine: stop moving bar in zone with A
  - garbage: shake 3s
  - stabilize: tilt-hold bubble level 3s
  - shields: mash B x20 in 5s

## Architecture
- Dedicated host badge = ship, on a table, LEDs = game phase. Single source of truth.
- Backbone: host rebroadcasts full STATE every 2s (phase, alive bitmask [2B for 16 players],
  task %, meeting countdown). Clients render latest state. Timers = countdowns in frames
  (no wall clock exists).
- Honest-client model: every badge hears all frames; app hides roles. Role frames XORed
  with per-player nonce sent at JOIN.

### Protocol frames (all <= 44B)
- LOBBY_ANNOUNCE (host, in lobby)
- JOIN_REQ (client: name from badge.me.name(), nonce) / JOIN_ACK (host: player id)
- ROSTER chunks (host, resent on request)
- ROLE (host -> player, XOR nonce)
- START (task seed, impostor count)
- BEACON (alive clients, 1Hz)
- KILL_REQ (impostor) -> host validates cooldown/alive/phase -> DEATH (all)
- BODY (dead badge beacons until discovered) / REPORT (finder in range)
- MEETING (host + gossip relay: every alive badge rebroadcasts new meeting seq a few times)
- VOTE (client, retried until TALLY seen) / TALLY / EJECT (host)
- Win: tasks 100% OR impostors ejected; impostors win when alive imp >= alive crew

### Flow
lobby -> roles -> play (tasks/kills/bodies) -> meeting (60s talk IRL + 30s vote on D-pad,
A confirm, skip allowed) -> eject animation -> play ... -> end screen (role reveal + LED show)

### Death/ghosts
Victim screen blacks out, LEDs pulse red, then ghost mode: dimmed, can still do tasks,
no vote/report, beacon flagged dead.

## Platform constraints absorbed
- Foreground-only -> timed rounds, app stays open. manifest: wake_lock=1, confirm_home=1
- Leaving a radio app reboots the badge -> natural quit deterrent; host times out silent
  players (10s) and supports rejoin by MAC
- No pcall in sandbox -> defensive validation, no try/catch
- Share cap 48KB/16 files is the tightest constraint -> watch size from day one;
  fallback install over USB via badge.py (no cap)
- Battery: fresh AAs before rounds; help desk has spares

## Testing
1. Desktop Lua mock of badge.* API: run/fuzz host+client state machine with packet loss, no hardware
2. Single-badge UI testing via console `press` (inject buttons) + `shot` (screenshots)
3. Real radio: 1 teammate badge for ~1h RSSI calibration walk

## Build order (~24-28h, parallelizes)
1. Protocol + host state machine on desktop mock (6-8h)
2. Client screens: lobby, HUDs, death, meeting, voting (6h)
3. Minigames (4h)
4. NFC stations + tag writing (2h)
5. On-badge radio bring-up + RSSI calibration (4h)
6. LED polish, end screens, Share-size trim (3h)

## Shopping
- NTAG213/215 sticker pack (~$10/30) or HTN hardware desk
- Fresh AAs

## Judging demo
Pre-share app to 4-6 recruits, tags on nearby walls, one 5-min round,
judge plays impostor (gets the kill moment). Onboarding a judge via Share: <1 min.
Slogan: "kill someone (in Among Us)".

## Risks, ranked
1. RSSI feel -> calibration + proximity meter + debug overlay
2. 48KB Share cap -> size budget from day one, USB fallback
3. Venue BLE congestion -> 1Hz beacons + 2s state rebroadcast tolerate heavy loss
4. Player churn mid-round -> timeouts + rejoin
