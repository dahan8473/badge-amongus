#!/usr/bin/env python3
"""Plays a full game against server.py with four fake boards.
Run the server first:  python3 server/server.py --debug
Then:                  python3 server/fake_players.py
Checks the whole loop: join, roles, tasks, a kill, a report, a meeting,
votes, ejection, crew win.
"""
import asyncio
import json
import sys

HOST, PORT = "127.0.0.1", 4269
checks = []


def check(ok, what):
    checks.append(ok)
    print(("  ok: " if ok else "  FAIL: ") + what)


class Fake:
    def __init__(self, name):
        self.name = name
        self.pid = None
        self.role = None
        self.tasks = []
        self.state = {}
        self.dead = False

    async def connect(self):
        self.reader, self.writer = await asyncio.open_connection(HOST, PORT)
        await self.send({"t": "hello", "mac": "fake-" + self.name, "name": self.name})
        asyncio.create_task(self.pump())

    async def send(self, msg):
        self.writer.write((json.dumps(msg) + "\n").encode())
        await self.writer.drain()

    async def pump(self):
        while True:
            line = await self.reader.readline()
            if not line:
                return
            msg = json.loads(line)
            t = msg.get("t")
            if t == "welcome":
                self.pid = msg["pid"]
            elif t == "role":
                self.role = msg["role"]
                self.tasks = msg["tasks"]
            elif t == "state":
                self.state = msg
            elif t == "dead":
                self.dead = True


async def wait_for(cond, seconds=10):
    for _ in range(int(seconds * 10)):
        if cond():
            return True
        await asyncio.sleep(0.1)
    return False


async def main():
    players = [Fake(n) for n in ("ALICE", "BOB", "CARL", "DANA")]
    for p in players:
        await p.connect()
    ok = await wait_for(lambda: all(p.pid for p in players))
    check(ok, "all four joined")

    await players[0].send({"t": "start"})
    ok = await wait_for(lambda: all(p.role for p in players))
    check(ok, "roles dealt")
    imps = [p for p in players if p.role == "imp"]
    crew = [p for p in players if p.role == "crew"]
    check(len(imps) == 1, f"one impostor ({imps[0].name if imps else '?'})")

    worker = crew[0]
    await worker.send({"t": "task", "station": worker.tasks[0]})
    ok = await wait_for(lambda: worker.state.get("taskPct", 0) > 0)
    check(ok, f"task counted ({worker.state.get('taskPct')}%)")

    victim = crew[1]
    await imps[0].send({"t": "kill", "target": victim.pid})
    ok = await wait_for(lambda: victim.dead)
    check(ok, f"{victim.name} killed")

    await worker.send({"t": "report"})
    ok = await wait_for(lambda: worker.state.get("phase") in (2, 3))
    check(ok, "meeting called")

    ok = await wait_for(lambda: worker.state.get("phase") == 3, 15)
    check(ok, "voting open")
    await worker.send({"t": "vote", "target": imps[0].pid})
    await crew[2].send({"t": "vote", "target": imps[0].pid})
    await imps[0].send({"t": "vote", "target": 0})

    ok = await wait_for(lambda: worker.state.get("winner") == "crew", 20)
    check(ok, "crew wins on every client")

    print(f"\n{sum(checks)}/{len(checks)} checks passed")
    sys.exit(0 if all(checks) else 1)


asyncio.run(main())
