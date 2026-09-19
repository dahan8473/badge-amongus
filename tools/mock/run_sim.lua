-- Plays a full game of Among Us on the laptop: 1 host + 3 players,
-- with simulated radio, distance-based signal strength, and 15% packet loss.
-- Run from the repo root:  lua tools/mock/run_sim.lua
--
-- The scenario: everyone joins, the game starts, a crewmate finishes a task,
-- the impostor sneaks up and kills someone, the body gets found and reported,
-- a meeting happens, everyone votes the impostor out, crew wins.

local mock = dofile("tools/mock/badge_mock.lua")
mock.app_path = "app/main.lua"

local checks, fails = 0, 0
local function check(ok, what)
  checks = checks + 1
  if ok then
    print("  ok: " .. what)
  else
    fails = fails + 1
    print("  FAIL: " .. what)
  end
end

local W = mock.new_world(tonumber(arg and arg[1] or 42) or 42, 0.15)
local ship = W:spawn("SHIP", 0, 0)
local p1 = W:spawn("ALICE", 1, 1)
local p2 = W:spawn("BOB", 6, 0)
local p3 = W:spawn("CARL", 0, 6)
local p4 = W:spawn("DANA", -6, 0)
W:enter_all()

print("== lobby ==")
W:press(ship, "START") W:press(ship, "A") -- ship hosts (A confirms radio)
for _, p in ipairs({ p1, p2, p3, p4 }) do -- players join, confirming radio
  W:press(p, "A") W:press(p, "A")
end
-- the host sees the player count on the ship screen and waits for
-- everyone, so the sim does too (up to 30s)
for _ = 1, 60 do
  W:run(500)
  if p1.env._DBG.pid ~= 0 and p2.env._DBG.pid ~= 0
    and p3.env._DBG.pid ~= 0 and p4.env._DBG.pid ~= 0 then break end
end
check(p1.env._DBG.pid ~= 0, "ALICE joined (pid " .. p1.env._DBG.pid .. ")")
check(p2.env._DBG.pid ~= 0, "BOB joined (pid " .. p2.env._DBG.pid .. ")")
check(p3.env._DBG.pid ~= 0, "CARL joined (pid " .. p3.env._DBG.pid .. ")")
check(p4.env._DBG.pid ~= 0, "DANA joined (pid " .. p4.env._DBG.pid .. ")")

print("== start ==")
W:press(ship, "START")
-- wait until every badge is seeded AND the impostor role frame landed
-- (both repeat from the host every 3s, losses recover)
for _ = 1, 40 do
  W:run(500)
  local all, imps = true, 0
  for _, p in ipairs({ p1, p2, p3, p4 }) do
    if not p.env._DBG.me.seeded then all = false end
    if p.env._DBG.role == 2 then imps = imps + 1 end
  end
  if all and imps == 1 then break end
end

local imp, crew = nil, {}
for _, p in ipairs({ p1, p2, p3, p4 }) do
  if p.env._DBG.role == 2 then imp = p else crew[#crew + 1] = p end
end
check(imp ~= nil, "exactly one impostor assigned (" .. (imp and imp.name or "?") .. ")")
check(#crew == 3, "three crewmates")
for _, p in ipairs({ p1, p2, p3, p4 }) do W:press(p, "A") end -- leave role screen

print("== task ==")
local worker = crew[1]
W:press(worker, "START") -- debug NFC tap opens a minigame
local g = worker.env._DBG.game
if g.kind == 0 then
  for _ = 1, 12 do W:press(worker, "B") end
elseif g.kind == 1 then
  local names = { "UP", "DOWN", "LEFT", "RIGHT" }
  for i = 1, 4 do W:press(worker, names[g.seq[i] + 1]) end
else
  local tries = 0
  while worker.env._DBG.me.tasks_done == 0 and tries < 400 do
    W:run(20)
    if g.pos >= 42 and g.pos <= 58 then W:press(worker, "A") end
    tries = tries + 1
  end
end
-- beacons at 1Hz and state at 0.5Hz both survive losses given time
for _ = 1, 20 do
  W:run(500)
  if p1.env._DBG.gv.task_pct > 0 then break end
end
check(worker.env._DBG.me.tasks_done == 1, worker.name .. " finished a task")
check(p1.env._DBG.gv.task_pct > 0, "ship task percent went up (" ..
  p1.env._DBG.gv.task_pct .. "%)")

-- a real player presses when the prompt shows, and presses again if
-- nothing happened; the sim does the same
local function press_until(inst, btn, done)
  for _ = 1, 4 do
    W:press(inst, btn)
    W:run(1500)
    if done() then return end
  end
end

print("== kill ==")
local victim = crew[2]
W:move(imp, victim.x + 0.3, victim.y) -- impostor walks up to the victim
W:run(6000) -- beacons arrive, smoothed signal climbs past the kill line
press_until(imp, "A", function() return victim.env._DBG.me.dead end)
check(victim.env._DBG.me.dead, victim.name .. " was killed")

print("== report ==")
W:move(worker, victim.x + 0.3, victim.y) -- worker finds the body
W:run(5000)
press_until(worker, "B", function() return p1.env._DBG.gv.phase >= 2 end)
check(p1.env._DBG.gv.phase == 2 or p1.env._DBG.gv.phase == 3,
  "meeting called (phase " .. p1.env._DBG.gv.phase .. ")")

print("== vote ==")
-- talk timer (6s in debug) runs out, then wait until every living badge
-- has its vote screen up
for _ = 1, 30 do
  W:run(500)
  local ready = true
  for _, p in ipairs({ worker, crew[3], imp }) do
    if p.env._DBG.gv.phase ~= 3 then ready = false end
  end
  if ready then break end
end
check(imp.env._DBG.gv.phase == 3, "voting open")
W:run(200)

-- ballot order is SKIP then living players by number, so count the
-- RIGHT presses needed to land on the impostor
local function vote_for(voter, target_pid)
  local gv = voter.env._DBG.gv
  local ids = { 0 }
  for pid = 1, 15 do
    local alive = math.floor(gv.alive / 2 ^ (pid - 1)) % 2 == 1
    if alive and pid ~= voter.env._DBG.me.pid then ids[#ids + 1] = pid end
  end
  for j, pid in ipairs(ids) do
    if pid == target_pid then
      for _ = 1, j - 1 do W:press(voter, "RIGHT") end
      break
    end
  end
  W:press(voter, "A")
end

vote_for(worker, imp.env._DBG.pid) -- worker votes the impostor
vote_for(crew[3], imp.env._DBG.pid) -- so does the third crewmate
vote_for(imp, 0) -- impostor votes skip
-- host tallies when all votes land or the timer ends, whichever first
for _ = 1, 40 do
  W:run(500)
  if ship.env._DBG.winner ~= 0 then break end
end
W:run(3000) -- let the result reach every badge

print("== end ==")
check(ship.env._DBG.winner == 1, "host says crew wins")
check(p1.env._DBG.winner == 1 and p2.env._DBG.winner == 1
  and p3.env._DBG.winner == 1 and p4.env._DBG.winner == 1,
  "every badge shows crew wins")

print("")
print(checks .. " checks, " .. fails .. " failures")
os.exit(fails == 0 and 0 or 1)
