# Among Us

Among Us, played in real life on Hack the North 2026 badges.

Your badge is your character. Walking up to someone is how you kill them.
NFC stickers on the walls are your tasks. Meetings and voting happen on the
badge screen. One badge sits on a table as the "ship" and runs the game.

Built for the Best Badge Hack prize at Hack the North 2026.

## How it works

- **One badge hosts.** It assigns roles, tracks who is alive, counts tasks,
  runs meetings, and rebroadcasts the full game state every 2 seconds. Lost
  packets never desync anyone, because the next state broadcast fixes it.
- **Kills use signal strength.** Every player badge broadcasts a small
  presence beacon once a second. The impostor's badge measures how strong
  those beacons are. Strong signal = physically close. Get within about
  arm's length of someone and the kill prompt appears.
- **Tasks are NFC stickers.** Cheap NTAG stickers placed around the venue.
  Tap the bottom of your badge on your assigned sticker and a minigame
  opens: mash a button, repeat a D-pad sequence, or stop a moving bar.
- **Bodies stay where they fell.** A dead player's badge quietly broadcasts
  "there is a corpse here". Walk close to it and you get a report prompt,
  which calls a meeting.
- **Voting is on the badge.** Left/right to pick a player, A to vote.
  Majority gets ejected. Crew wins by tasks or ejecting the impostors.
  Impostors win when they equal the remaining crew.

Everything fits in 44-byte radio messages, which is the badge's limit.

## Repo layout

```
app/            the badge app (manifest.cfg + main.lua)
tools/badge.py  command line tool: push apps, run console commands, monitor serial
tools/mock/     desktop mock of the badge API + a full game simulation
GAME_PLAN.md    the design doc
```

## Run the simulation (no badge needed)

The simulator plays a full 4-player game on your laptop with fake radio,
distance-based signal strength, and 15% packet loss: join, roles, a task,
a kill, a body report, a meeting, a vote, an ejection, and a crew win.

```
brew install lua
lua tools/mock/run_sim.lua        # 13 checks
lua tools/mock/run_sim.lua 7      # any number picks a different random run
```

Passes 60 out of 60 random runs.

## Install on a badge

Option 1, the official web IDE: open badge.hackthenorth.com/ide/, paste
`app/manifest.cfg` and `app/main.lua` into the matching files, connect the
badge over USB, push.

Option 2, command line:

```
pip3 install pyserial
python3 tools/badge.py push app
```

Turn the badge off before plugging in USB, then turn it on. Don't hold Start.

## Play

- One badge presses **START** on the menu: that badge is the ship. Leave it
  on a table.
- Everyone else presses **A** to join. Names come from the badge itself.
- Ship presses START again when everyone is in (minimum 3 players, 1
  impostor under 8 players, 2 from 8 up).
- Crew: finish your tasks. Impostor: don't get caught.
- **A** kills (impostor, close range). **B** reports a body (close range).
  **AUX1** calls your one emergency meeting. **HOME** quits.

## Current state

- Full game loop works in simulation with packet loss.
- `DEBUG = true` in main.lua shortens timers and lets START on the play
  screen simulate an NFC tap, so the game is playable before stickers are
  written. Set it to false and write NTAG stickers for the real thing.
- Kill and report signal thresholds (`KILL_RSSI`, `BODY_RSSI`) need one
  calibration walk at the venue with two badges.
