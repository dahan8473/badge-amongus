#!/usr/bin/env python3
"""Among Us game server. The laptop runs the whole game; boards are thin
clients over WiFi. Protocol: newline-delimited JSON over plain TCP.

Run:  python3 server/server.py [--debug]
--debug shortens timers for testing.

Client -> server:
  {"t":"hello","mac":"aa:bb:...","name":"DAVE"}     join / rejoin
  {"t":"task","station":3}                          task minigame finished
  {"t":"kill","target":2}                           impostor kill
  {"t":"report"}                                    report a body
  {"t":"meet"}                                      emergency meeting
  {"t":"vote","target":2}                           0 = skip
  {"t":"rssi","peers":{"2":-48}}                    optional proximity info

Server -> client:
  {"t":"welcome","pid":1}
  {"t":"role","role":"imp"|"crew","tasks":[3,7,1]}
  {"t":"state",...}                                 full state, 1 Hz + on change
  {"t":"end","winner":"crew"|"imp"}
"""
import argparse
import asyncio
import json
import random
import time

parser = argparse.ArgumentParser()
parser.add_argument("--debug", action="store_true", help="short timers")
parser.add_argument("--port", type=int, default=4269)
parser.add_argument("--min-players", type=int, default=3)
args = parser.parse_args()

TALK_S = 6 if args.debug else 45
VOTE_S = 10 if args.debug else 30
KILL_CD_S = 5 if args.debug else 25
TASKS_PER_PLAYER = 3
NUM_STATIONS = 8
# when boards report peer signal strength, kills need the target close;
# without reports the target list is everyone alive (social enforcement)
KILL_RSSI = -56

LOBBY, PLAY, TALK, VOTE, END = 0, 1, 2, 3, 4


class Player:
    def __init__(self, pid, mac, name, writer):
        self.pid = pid
        self.mac = mac
        self.name = name or f"P{pid}"
        self.writer = writer
        self.role = None  # "imp" | "crew"
        self.alive = False
        self.tasks = []
        self.tasks_done = 0
        self.last_kill = 0.0
        self.voted = None
        self.used_meet = False
        self.rssi = {}  # pid -> dBm, freshest report


class Game:
    def __init__(self):
        self.players = {}  # pid -> Player
        self.by_mac = {}
        self.phase = LOBBY
        self.phase_until = 0.0
        self.winner = None
        self.ejected = 0
        self.meeting_reason = ""

    # ------------------------------------------------------------ helpers

    def send(self, pl, msg):
        if pl.writer is None or pl.writer.is_closing():
            return
        try:
            pl.writer.write((json.dumps(msg) + "\n").encode())
        except Exception:
            pl.writer = None

    def broadcast(self, msg):
        for pl in self.players.values():
            self.send(pl, msg)

    def state_msg(self):
        alive = [p.pid for p in self.players.values() if p.alive]
        total = TASKS_PER_PLAYER * len(self.players) or 1
        done = sum(p.tasks_done for p in self.players.values())
        cd = max(0, int(self.phase_until - time.time())) if self.phase in (TALK, VOTE) else 0
        return {
            "t": "state", "phase": self.phase, "alive": alive,
            "names": {p.pid: p.name for p in self.players.values()},
            "taskPct": int(100 * done / total), "cd": cd,
            "ejected": self.ejected, "winner": self.winner,
            "reason": self.meeting_reason,
        }

    def push_state(self):
        self.broadcast(self.state_msg())

    # ------------------------------------------------------------ flow

    def start_game(self):
        if len(self.players) < args.min_players or self.phase != LOBBY:
            return
        n_imp = 2 if len(self.players) >= 8 else 1
        imps = random.sample(list(self.players), n_imp)
        for pid, pl in self.players.items():
            pl.role = "imp" if pid in imps else "crew"
            pl.alive = True
            pl.tasks = random.sample(range(1, NUM_STATIONS + 1), TASKS_PER_PLAYER)
            pl.tasks_done = 0
            pl.used_meet = False
            self.send(pl, {"t": "role", "role": pl.role, "tasks": pl.tasks})
        self.phase = PLAY
        self.winner = None
        self.ejected = 0
        print(f"[game] started, impostor(s): "
              f"{[self.players[i].name for i in imps]}")
        self.push_state()

    def check_win(self):
        if self.winner or self.phase in (LOBBY, END):
            return
        imps = sum(1 for p in self.players.values() if p.alive and p.role == "imp")
        crew = sum(1 for p in self.players.values() if p.alive and p.role == "crew")
        total = TASKS_PER_PLAYER * len(self.players) or 1
        done = sum(p.tasks_done for p in self.players.values())
        if imps == 0 or done >= total:
            self.winner = "crew"
        elif imps >= crew:
            self.winner = "imp"
        if self.winner:
            self.phase = END
            print(f"[game] over: {self.winner} wins")
            self.push_state()
            self.broadcast({"t": "end", "winner": self.winner})

    def start_meeting(self, reason):
        if self.phase != PLAY:
            return
        self.phase = TALK
        self.meeting_reason = reason
        self.phase_until = time.time() + TALK_S
        for pl in self.players.values():
            pl.voted = None
        print(f"[game] meeting: {reason}")
        self.push_state()

    def tally(self):
        counts = {}
        for pl in self.players.values():
            if pl.alive and pl.voted is not None:
                counts[pl.voted] = counts.get(pl.voted, 0) + 1
        counts.pop(0, None)
        self.ejected = 0
        if counts:
            top = max(counts.values())
            leaders = [t for t, n in counts.items() if n == top]
            if len(leaders) == 1 and leaders[0] in self.players:
                self.ejected = leaders[0]
                self.players[self.ejected].alive = False
                print(f"[game] ejected {self.players[self.ejected].name}")
        self.phase = PLAY
        self.meeting_reason = ""
        self.push_state()
        self.check_win()

    def reset(self):
        self.phase = LOBBY
        self.winner = None
        self.ejected = 0
        for pl in self.players.values():
            pl.role, pl.alive, pl.tasks_done = None, False, 0
        self.push_state()

    # ------------------------------------------------------------ messages

    def handle(self, pl, msg):
        t = msg.get("t")
        if t == "task" and self.phase == PLAY:
            station = msg.get("station")
            if station in pl.tasks:
                pl.tasks.remove(station)
                pl.tasks_done += 1
                self.push_state()
                self.check_win()
        elif t == "kill" and self.phase == PLAY and pl.alive and pl.role == "imp":
            target = self.players.get(msg.get("target"))
            now = time.time()
            if not target or not target.alive or target.role == "imp":
                return
            if now - pl.last_kill < KILL_CD_S:
                return
            # when the killer's board reports signal strength, require close
            r = pl.rssi.get(target.pid)
            if r is not None and r < KILL_RSSI:
                return
            pl.last_kill = now
            target.alive = False
            self.send(target, {"t": "dead"})
            print(f"[game] {pl.name} killed {target.name}")
            self.push_state()
            self.check_win()
        elif t == "report" and self.phase == PLAY and pl.alive:
            if any(not p.alive for p in self.players.values()):
                self.start_meeting("body found")
        elif t == "meet" and self.phase == PLAY and pl.alive and not pl.used_meet:
            pl.used_meet = True
            self.start_meeting("emergency button")
        elif t == "vote" and self.phase == VOTE and pl.alive and pl.voted is None:
            target = msg.get("target", 0)
            if target == 0 or (target in self.players and self.players[target].alive):
                pl.voted = target
        elif t == "rssi":
            pl.rssi = {int(k): v for k, v in msg.get("peers", {}).items()}
        elif t == "start":  # host command, also available from the console
            self.start_game()


game = Game()


async def handle_client(reader, writer):
    peer = writer.get_extra_info("peername")
    pl = None
    try:
        while True:
            line = await asyncio.wait_for(reader.readline(), timeout=60)
            if not line:
                break
            try:
                msg = json.loads(line)
            except json.JSONDecodeError:
                continue
            if msg.get("t") == "hello":
                mac = msg.get("mac", str(peer))
                if mac in game.by_mac:  # rejoin keeps pid, role, progress
                    pl = game.by_mac[mac]
                    pl.writer = writer
                else:
                    if game.phase != LOBBY or len(game.players) >= 15:
                        writer.write(b'{"t":"full"}\n')
                        continue
                    pid = len(game.players) + 1
                    pl = Player(pid, mac, msg.get("name"), writer)
                    game.players[pid] = pl
                    game.by_mac[mac] = pl
                    print(f"[join] {pl.name} (pid {pid}) from {peer}")
                game.send(pl, {"t": "welcome", "pid": pl.pid})
                if pl.role:  # rejoin mid-game gets role back
                    game.send(pl, {"t": "role", "role": pl.role, "tasks": pl.tasks})
                game.send(pl, game.state_msg())
            elif pl:
                game.handle(pl, msg)
    except (asyncio.TimeoutError, ConnectionError):
        pass
    finally:
        if pl and pl.writer is writer:
            pl.writer = None  # keeps the player; they can rejoin by mac
        writer.close()


async def ticker():
    while True:
        await asyncio.sleep(1)
        now = time.time()
        if game.phase == TALK and now > game.phase_until:
            game.phase = VOTE
            game.phase_until = now + VOTE_S
            game.push_state()
        elif game.phase == VOTE:
            voters = [p for p in game.players.values() if p.alive]
            if all(p.voted is not None for p in voters) or now > game.phase_until:
                game.tally()
        game.push_state()  # 1 Hz heartbeat keeps clients honest


async def console():
    # type on the server: start / reset / status
    loop = asyncio.get_event_loop()
    while True:
        try:
            cmd = (await loop.run_in_executor(None, input)).strip()
        except EOFError:
            return  # headless run: no console, keep serving
        if cmd == "start":
            game.start_game()
        elif cmd == "reset":
            game.reset()
        elif cmd == "status":
            for p in game.players.values():
                print(f"  {p.pid} {p.name} role={p.role} alive={p.alive} "
                      f"tasks={p.tasks_done}/{TASKS_PER_PLAYER}")


async def main():
    server = await asyncio.start_server(handle_client, "0.0.0.0", args.port)
    print(f"[server] listening on :{args.port} "
          f"({'debug' if args.debug else 'normal'} timers)")
    print("[server] commands: start | reset | status")
    await asyncio.gather(server.serve_forever(), ticker(), console())


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
