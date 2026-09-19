-- Player side: lobby, HUD, tasks, kills, reports, meetings, voting.
-- Loaded by main.lua when the user picks "join". Shares globals from main.
-- Kept lean on purpose: this file must compile inside tight badge RAM.

local M = {}

local me = { pid = 0, nonce = 0, role = 0, tasks_done = 0, tasks = {},
             dead = false, last_kill_ms = -999999 }
local peers = {} -- pid -> { rssi, last_ms }
local corpses = {} -- pid -> { rssi, last_ms }
local vote_sel, vote_cast = 0, false
local last_beacon_ms, last_corpse_ms, last_join_ms = 0, 0, 0
-- one-shot actions retry until the game state proves they landed
local pending_report, pending_kill, my_vote, last_vote_ms = nil, nil, nil, 0
local game = { kind = 0, step = 0, seq = {}, count = 0, station = 0 }

local function pname(pid) return "P" .. pid end

-- ------------------------------------------------------------- screens

local function show_lobby()
  screen = "lobby"
  clear_screen()
  lbl("LOBBY", "center", 0, -70, "large")
  ui.status = lbl("looking for a ship...", "center", 0, -20)
  lbl("stay on this screen", "center", 0, 60, "small", COL_DIM)
end

local function show_role()
  screen = "role"
  clear_screen()
  if me.role == ROLE_IMP then
    lbl("IMPOSTOR", "center", 0, -30, "large", COL_IMP)
    lbl("get close + A to kill", "center", 0, 10)
    leds_all(120, 0, 0)
  else
    lbl("CREWMATE", "center", 0, -30, "large", COL_CREW)
    lbl("do tasks, watch your back", "center", 0, 10)
    leds_all(0, 60, 120)
  end
  lbl("A: continue", "center", 0, 70, "small", COL_DIM)
end

local function show_hud()
  screen = "hud"
  clear_screen()
  local rc = me.role == ROLE_IMP and COL_IMP or COL_CREW
  lbl(me.role == ROLE_IMP and "IMPOSTOR" or "CREW", "top_left", 6, 4, "small", rc)
  ui.taskpct = lbl("0%", "top_right", -6, 4, "small")
  ui.tasks = lbl("", "center", 0, -30)
  ui.action = lbl("", "center", 0, 15)
  lbl("START: tap task", "bottom_mid", 0, -6, "small", COL_DIM)
end

local function show_dead()
  screen = "dead"
  clear_screen()
  lbl("YOU WERE KILLED", "center", 0, -30, "large", COL_IMP)
  lbl("ghost mode: finish your tasks", "center", 0, 10)
  leds_all(120, 0, 0)
end

local function show_meeting(reason)
  corpses = {}
  _DBG.corpses = corpses
  if me.dead then return end
  screen = "meeting"
  clear_screen()
  lbl("MEETING", "center", 0, -60, "large", COL_IMP)
  lbl(reason == 1 and "a body was found" or "called by the ship", "center", 0, -20)
  ui.cd = lbl("", "center", 0, 20, "large")
end

local function show_vote()
  screen = "vote"
  clear_screen()
  vote_sel, vote_cast, my_vote = 0, false, nil
  lbl("VOTE", "center", 0, -75, "large")
  ui.cd = lbl("", "top_right", -6, 4, "small")
  ui.target = lbl("", "center", 0, -15, "large")
  lbl("LEFT/RIGHT pick  A vote", "center", 0, 40, "small", COL_DIM)
end

local function show_end()
  screen = "end"
  clear_screen()
  if gv.winner == 1 then
    lbl("CREW WINS", "center", 0, -20, "large", COL_CREW)
    leds_all(0, 140, 60)
  else
    lbl("IMPOSTORS WIN", "center", 0, -20, "large", COL_IMP)
    leds_all(160, 0, 0)
  end
  lbl("HOME: exit", "center", 0, 60, "small", COL_DIM)
end

local function show_task(station)
  screen = "task"
  clear_screen()
  game.station = station
  game.kind = station % 2 -- 0 mash, 1 simon
  if game.kind == 0 then
    game.count = 0
    lbl("EMPTY GARBAGE", "center", 0, -50, "large")
    ui.action = lbl("mash B! 0/12", "center", 0, 0)
  else
    game.seq = {}
    for i = 1, 4 do game.seq[i] = badge.sys.random(4) end
    game.step = 0
    local names = { "UP", "DOWN", "LEFT", "RIGHT" }
    local s = ""
    for i = 1, 4 do s = s .. names[game.seq[i] + 1] .. " " end
    lbl("FIX WIRING", "center", 0, -50, "large")
    lbl(s, "center", 0, -10)
    ui.action = lbl("press the sequence", "center", 0, 25, "small", COL_DIM)
  end
end

-- ------------------------------------------------------------- game bits

local function my_stations(seed, pid)
  local t, used = {}, {}
  local x = seed + pid * 37
  while #t < TASKS_PER_PLAYER do
    x = (x * 197 + 71) % 65536
    local s = x % NUM_STATIONS + 1
    if not used[s] then used[s] = true; t[#t + 1] = s end
  end
  return t
end

local function finish_task()
  for i = 1, #me.tasks do
    if me.tasks[i] == game.station then
      me.tasks[i] = 0
      me.tasks_done = me.tasks_done + 1
      break
    end
  end
  send(frame("B", me.pid, me.dead and 0 or 1, me.tasks_done))
  if me.dead then show_dead() else show_hud() end
end

local function ema(old, v)
  if old == nil then return v end
  if v > old then return math.floor(old * 0.3 + v * 0.7) end
  return math.floor(old * 0.7 + v * 0.3)
end

local function join(f)
  if f then gv.gid = f.gid end
  send(frame("J", me.nonce))
  last_join_ms = now()
end

local function nearest(list, only_alive)
  local best_pid, best = 0, -999
  for pid, e in pairs(list) do
    if pid ~= me.pid and now() - e.last_ms < (only_alive and PEER_TIMEOUT_MS or 6000)
      and (not only_alive or bit_get(gv.alive, pid)) and e.rssi > best then
      best_pid, best = pid, e.rssi
    end
  end
  return best_pid, best
end

-- ------------------------------------------------------------- frames

function M.handle(f)
  if f.t == "L" and screen == "lobby" and me.pid == 0 then
    join(f)
    ui.status:set_text("ship found, joining...")
  elseif f.t == "K" and f.tmac == my_mac and f.gid == gv.gid then
    me.pid = f.pid
    _DBG.pid = f.pid
    if screen == "lobby" then ui.status:set_text("joined as " .. pname(f.pid)) end
  elseif f.gid ~= gv.gid then
    return
  elseif f.t == "O" and f.tmac == my_mac then
    me.role = (f.xrole - me.nonce) % 256
    _DBG.role = me.role
  elseif f.t == "G" then
    if not me.seeded and me.pid ~= 0 then
      me.seeded = true
      me.tasks = my_stations(f.seed, me.pid)
      me.tasks_done = 0
      me.dead = false
      if me.role == 0 then me.role = ROLE_CREW end
      show_role()
    end
  elseif f.t == "S" then
    local was_phase, was_winner = gv.phase, gv.winner
    gv.phase, gv.joined, gv.alive = f.phase, f.joined, f.alive
    gv.task_pct, gv.cd, gv.mseq = f.task_pct, f.cd, f.mseq
    gv.ejected, gv.was_imp, gv.winner = f.ejected, f.was_imp, f.winner
    _DBG.phase = gv.phase
    _DBG.winner = gv.winner
    if gv.phase == PH_LOBBY and was_phase ~= PH_LOBBY then
      me.seeded, me.role, me.tasks, me.tasks_done, me.dead = false, 0, {}, 0, false
      show_lobby()
    end
    if me.pid ~= 0 and not bit_get(gv.alive, me.pid)
      and bit_get(gv.joined, me.pid) and gv.phase ~= PH_LOBBY
      and not me.dead and me.role ~= 0 then
      me.dead = true
      show_dead()
    end
    if gv.winner ~= 0 and was_winner == 0 then
      show_end()
    elseif gv.phase == PH_TALK and was_phase ~= PH_TALK then
      show_meeting(0)
    elseif gv.phase == PH_VOTE and was_phase ~= PH_VOTE and not me.dead then
      show_vote()
    elseif gv.phase == PH_PLAY and was_phase ~= PH_PLAY and gv.winner == 0
      and me.role ~= 0 then
      if not me.dead then show_hud() else show_dead() end
    end
  elseif f.t == "M" then
    show_meeting(f.reason)
  elseif f.t == "B" then
    local pr = peers[f.pid] or {}
    pr.rssi = ema(pr.rssi, f.rssi)
    pr.last_ms = now()
    peers[f.pid] = pr
  elseif f.t == "C" then
    if not bit_get(gv.alive, f.victim) then
      local c = corpses[f.victim] or {}
      c.rssi = ema(c.rssi, f.rssi)
      c.last_ms = now()
      corpses[f.victim] = c
    end
  elseif f.t == "D" and f.victim == me.pid then
    me.dead = true
    show_dead()
  end
end

-- ------------------------------------------------------------- tick

function M.tick()
  local t = now()
  if screen == "lobby" and me.pid == 0 and gv.gid ~= 0
    and t - last_join_ms > 1500 then
    join(nil)
  end
  if me.pid ~= 0 and gv.phase ~= PH_LOBBY and t - last_beacon_ms > 1000 then
    last_beacon_ms = t
    send(frame("B", me.pid, me.dead and 0 or 1, me.tasks_done))
  end
  if me.dead and gv.phase == PH_PLAY and t - last_corpse_ms > 1000 then
    last_corpse_ms = t
    send(frame("C", me.pid))
  end
  if gv.phase ~= PH_PLAY then
    pending_report, pending_kill = nil, nil
  else
    if pending_kill then
      if not bit_get(gv.alive, pending_kill.pid) or pending_kill.tries > 4 then
        pending_kill = nil
      elseif t > pending_kill.next_ms then
        pending_kill.tries = pending_kill.tries + 1
        pending_kill.next_ms = t + 800
        send(frame("X", me.pid, pending_kill.pid))
      end
    end
    if pending_report then
      if pending_report.tries > 6 then
        pending_report = nil
      elseif t > pending_report.next_ms then
        pending_report.tries = pending_report.tries + 1
        pending_report.next_ms = t + 800
        send(frame("P", me.pid, pending_report.pid))
      end
    end
  end
  if gv.phase == PH_VOTE and vote_cast and my_vote ~= nil
    and t - last_vote_ms > 1000 then
    last_vote_ms = t
    send(frame("V", gv.mseq, me.pid, my_vote))
  end

  if screen == "hud" then
    ui.taskpct:set_text(gv.task_pct .. "%")
    local left = 0
    for i = 1, #me.tasks do if me.tasks[i] > 0 then left = left + 1 end end
    local s = "tasks:"
    for i = 1, #me.tasks do
      if me.tasks[i] > 0 then s = s .. " " .. me.tasks[i] end
    end
    ui.tasks:set_text(left == 0 and "all tasks done" or s)
    if me.role == ROLE_IMP then
      local pid, rssi = nearest(peers, true)
      local cd_left = KILL_CD_S - math.floor((t - me.last_kill_ms) / 1000)
      if cd_left > 0 then
        ui.action:set_text("kill in " .. cd_left .. "s")
        leds_off()
      elseif pid ~= 0 and rssi >= KILL_RSSI then
        ui.action:set_text("A: KILL " .. pname(pid))
        leds_all(160, 0, 0)
      else
        ui.action:set_text(pid == 0 and "no one close" or "hunt " .. pname(pid))
        local n = clamp(math.floor((rssi + 80) / 5), 0, 6)
        badge.led.clear()
        for i = 1, n do badge.led.set(i, 100, 10, 0) end
        badge.led.show()
      end
    else
      local cpid, crssi = nearest(corpses, false)
      if cpid ~= 0 and crssi >= BODY_RSSI then
        ui.action:set_text("B: REPORT BODY")
        leds_all(140, 60, 0)
      else
        ui.action:set_text("")
        leds_off()
      end
    end
  elseif (screen == "meeting" or screen == "vote") and ui.cd then
    ui.cd:set_text(gv.cd .. "s")
    if screen == "vote" then
      local ids = { 0 }
      for pid = 1, MAX_PLAYERS do
        if bit_get(gv.alive, pid) and pid ~= me.pid then ids[#ids + 1] = pid end
      end
      vote_sel = vote_sel % #ids
      local pick = ids[vote_sel + 1]
      ui.target:set_text(vote_cast and "voted"
        or (pick == 0 and "SKIP" or pname(pick)))
      ui.vote_ids = ids
    end
  end
end

-- ------------------------------------------------------------- buttons

function M.button(b)
  local BT = badge.input.BUTTON
  if screen == "role" then
    if b == BT.A then show_hud() end
  elseif screen == "hud" then
    if b == BT.A and me.role == ROLE_IMP and not me.dead then
      local pid, rssi = nearest(peers, true)
      if pid ~= 0 and rssi >= KILL_RSSI
        and now() - me.last_kill_ms > KILL_CD_S * 1000 then
        me.last_kill_ms = now()
        pending_kill = { pid = pid, tries = 0, next_ms = 0 }
      end
    elseif b == BT.B and not me.dead then
      local cpid, crssi = nearest(corpses, false)
      if cpid ~= 0 and crssi >= BODY_RSSI then
        pending_report = { pid = cpid, tries = 0, next_ms = 0 }
      end
    elseif b == BT.START and DEBUG then
      for i = 1, #me.tasks do
        if me.tasks[i] > 0 then show_task(me.tasks[i]) return end
      end
    end
  elseif screen == "task" then
    if game.kind == 0 and b == BT.B then
      game.count = game.count + 1
      ui.action:set_text("mash B! " .. game.count .. "/12")
      if game.count >= 12 then finish_task() end
    elseif game.kind == 1 then
      local dirs = { [BT.UP] = 0, [BT.DOWN] = 1, [BT.LEFT] = 2, [BT.RIGHT] = 3 }
      local d = dirs[b]
      if d ~= nil then
        if d == game.seq[game.step + 1] then
          game.step = game.step + 1
          ui.action:set_text("good: " .. game.step .. "/4")
          if game.step >= 4 then finish_task() end
        else
          game.step = 0
          ui.action:set_text("wrong, start over")
        end
      end
    end
  elseif screen == "vote" then
    if not vote_cast and ui.vote_ids then
      if b == BT.RIGHT then vote_sel = vote_sel + 1
      elseif b == BT.LEFT then vote_sel = vote_sel + #ui.vote_ids - 1
      elseif b == BT.A then
        vote_cast = true
        my_vote = ui.vote_ids[vote_sel % #ui.vote_ids + 1]
        send(frame("V", gv.mseq, me.pid, my_vote))
        last_vote_ms = now()
      end
    end
  end
end

function M.start()
  me.nonce = badge.sys.random(256)
  _DBG.me, _DBG.game, _DBG.peers, _DBG.corpses = me, game, peers, corpses
  show_lobby()
end

return M
