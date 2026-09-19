-- Among Us: social deduction for the HTN 2026 badge.
-- One app, two modes: Host (the "ship", runs the game) or Player.
-- Radio frames are 44 bytes max. The host rebroadcasts full game state
-- every 2s, so lost frames never desync anyone.

DEBUG = true -- shorter timers + Start simulates an NFC task tap

-- ---------------------------------------------------------------- constants

local MAGIC = "A1"
local MAX_PLAYERS = 15
local MIN_PLAYERS = 3
local TASKS_PER_PLAYER = 3
local NUM_STATIONS = 8
local KILL_RSSI = -56 -- smoothed dBm needed to kill (tune at venue)
local BODY_RSSI = -62 -- smoothed dBm needed to report a body
local PEER_TIMEOUT_MS = 12000

local TALK_S = DEBUG and 6 or 45
local VOTE_S = DEBUG and 10 or 30
local KILL_CD_S = DEBUG and 5 or 25

local ROLE_CREW, ROLE_IMP = 1, 2
local PH_LOBBY, PH_PLAY, PH_TALK, PH_VOTE, PH_END = 0, 1, 2, 3, 4

local COL_BG = 0x101018
local COL_CREW = 0x35c4f0
local COL_IMP = 0xe23c3c
local COL_DIM = 0x777788

-- ---------------------------------------------------------------- state

local mode = nil -- "host" | "player"
local screen = "menu"
local widgets = {}
local my_mac = "?"
local inbox = {}

-- shared game view (what STATE frames tell us)
local gv = {
  gid = 0, phase = PH_LOBBY, joined = 0, alive = 0,
  task_pct = 0, cd = 0, mseq = 0, ejected = 0, was_imp = 0, winner = 0,
}

-- player-side
local me = { pid = 0, nonce = 0, role = 0, tasks_done = 0, tasks = {},
             used_emergency = false, dead = false, last_kill_ms = -999999 }
local roster = {} -- pid -> name
local peers = {} -- pid -> { rssi, last_ms }
local corpses = {} -- pid -> { rssi, last_ms }
local vote_sel, vote_cast = 0, false
local last_beacon_ms, last_corpse_ms, last_host_ms, last_join_ms = 0, 0, 0, 0
-- radio drops frames, so one-shot actions are retried until the game
-- state proves they landed (the host ignores duplicates)
local pending_report, pending_kill, my_vote, last_vote_ms = nil, nil, nil, 0
local gossip = { mseq = 0, sent = 0 }

-- host-side
local host = { players = {}, count = 0, phase_until = 0, votes = {},
               last_state_ms = 0, last_roster_ms = 0, roster_next = 1,
               n_imp = 1, body_meeting = 0 }

_DBG = { role = 0, phase = 0, winner = 0, pid = 0 } -- read by the simulator

-- ---------------------------------------------------------------- helpers

local function now() return badge.sys.ms() end
local function clamp(v, a, b) return math.max(a, math.min(b, v)) end

local function bit_get(mask, i)
  return math.floor(mask / 2 ^ (i - 1)) % 2 == 1
end

local function bit_set(mask, i)
  if not bit_get(mask, i) then return mask + 2 ^ (i - 1) end
  return mask
end

local function bit_clear(mask, i)
  if bit_get(mask, i) then return mask - 2 ^ (i - 1) end
  return mask
end

local function popcount(mask)
  local n = 0
  for i = 1, MAX_PLAYERS do if bit_get(mask, i) then n = n + 1 end end
  return n
end

local function pad_name(s)
  s = tostring(s or "GOOSE")
  if #s > 12 then s = string.sub(s, 1, 12) end
  return s .. string.rep(" ", 12 - #s)
end

local function trim(s) return (string.gsub(s, "%s+$", "")) end

-- ---------------------------------------------------------------- protocol

local function frame(t, ...)
  local parts = { MAGIC, t, string.char(gv.gid % 256) }
  local args = { ... }
  for i = 1, #args do
    local a = args[i]
    if type(a) == "number" then a = string.char(a % 256) end
    parts[#parts + 1] = a
  end
  return table.concat(parts)
end

local function send(payload)
  badge.radio.send(payload)
end

-- parse one frame into a table, nil when malformed or wrong game
local function parse(mac, rssi, p)
  if #p < 4 or string.sub(p, 1, 2) ~= MAGIC then return nil end
  local t = string.sub(p, 3, 3)
  local gid = string.byte(p, 4)
  local f = { t = t, gid = gid, mac = mac, rssi = rssi }
  if t == "L" and #p >= 5 then
    f.count = string.byte(p, 5)
  elseif t == "J" and #p >= 5 then
    f.nonce = string.byte(p, 5)
    f.name = trim(string.sub(p, 6))
  elseif t == "K" and #p >= 22 then
    f.tmac = string.sub(p, 5, 21)
    f.pid = string.byte(p, 22)
  elseif t == "O" and #p >= 22 then
    f.tmac = string.sub(p, 5, 21)
    f.xrole = string.byte(p, 22)
  elseif t == "G" and #p >= 7 then
    f.seed = string.byte(p, 5) * 256 + string.byte(p, 6)
    f.n_imp = string.byte(p, 7)
  elseif t == "S" and #p >= 15 then
    f.phase = string.byte(p, 5)
    f.joined = string.byte(p, 6) * 256 + string.byte(p, 7)
    f.alive = string.byte(p, 8) * 256 + string.byte(p, 9)
    f.task_pct = string.byte(p, 10)
    f.cd = string.byte(p, 11)
    f.mseq = string.byte(p, 12)
    f.ejected = string.byte(p, 13)
    f.was_imp = string.byte(p, 14)
    f.winner = string.byte(p, 15)
  elseif t == "B" and #p >= 7 then
    f.pid = string.byte(p, 5); f.flags = string.byte(p, 6)
    f.tasks = string.byte(p, 7)
  elseif t == "X" and #p >= 6 then
    f.killer = string.byte(p, 5); f.victim = string.byte(p, 6)
  elseif t == "D" and #p >= 5 then
    f.victim = string.byte(p, 5)
  elseif t == "C" and #p >= 5 then
    f.victim = string.byte(p, 5)
  elseif t == "P" and #p >= 6 then
    f.reporter = string.byte(p, 5); f.victim = string.byte(p, 6)
  elseif t == "M" and #p >= 7 then
    f.mseq = string.byte(p, 5); f.caller = string.byte(p, 6)
    f.reason = string.byte(p, 7)
  elseif t == "V" and #p >= 7 then
    f.mseq = string.byte(p, 5); f.voter = string.byte(p, 6)
    f.target = string.byte(p, 7)
  elseif t == "R" and #p >= 6 then
    f.pid = string.byte(p, 5)
    f.name = trim(string.sub(p, 6))
  else
    return nil
  end
  return f
end

-- ---------------------------------------------------------------- UI

local root_scr = nil

local function clear_screen()
  for i = 1, #widgets do widgets[i]:delete() end
  widgets = {}
end

local function lbl(text, ax, dx, dy, size, color)
  local w = badge.ui.label(root_scr, text)
  w:align(ax or "center", dx or 0, dy or 0)
  if size then w:set_font_size(size) end
  if color then w:style({ text_color = color }) end
  widgets[#widgets + 1] = w
  return w
end

local function leds_off() badge.led.clear() badge.led.show() end

local function leds_all(r, g, b)
  badge.led.clear()
  badge.led.set_all(r, g, b)
  badge.led.show()
end

-- screens keep references to labels they update every tick
local ui = {}

local function show_menu()
  screen = "menu"
  clear_screen()
  lbl("AMONG US", "center", 0, -60, "large")
  lbl("A: join a game", "center", 0, -10)
  lbl("START: host a game (ship)", "center", 0, 20)
  lbl("HOME: quit", "center", 0, 70, "small", COL_DIM)
  leds_off()
end

local function show_lobby_player()
  screen = "lobby"
  clear_screen()
  lbl("LOBBY", "center", 0, -70, "large")
  ui.status = lbl("looking for a ship...", "center", 0, -20)
  ui.count = lbl("", "center", 0, 10)
  lbl("stay on this screen", "center", 0, 60, "small", COL_DIM)
end

local function show_lobby_host()
  screen = "lobby"
  clear_screen()
  lbl("SHIP (HOST)", "center", 0, -80, "large")
  ui.count = lbl("players: 0", "center", 0, -40)
  ui.names = lbl("", "center", 0, 5)
  ui.status = lbl("START begins the game (min " .. MIN_PLAYERS .. ")",
    "center", 0, 75, "small", COL_DIM)
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
    lbl("finish tasks, watch your back", "center", 0, 10)
    leds_all(0, 60, 120)
  end
  lbl("A: continue", "center", 0, 70, "small", COL_DIM)
end

local function show_hud()
  screen = "hud"
  clear_screen()
  local rc = me.role == ROLE_IMP and COL_IMP or COL_CREW
  ui.top = lbl(me.role == ROLE_IMP and "IMPOSTOR" or "CREW",
    "top_left", 6, 4, "small", rc)
  ui.taskpct = lbl("ship 0%", "top_right", -6, 4, "small")
  ui.tasks = lbl("", "center", 0, -30)
  ui.action = lbl("", "center", 0, 15)
  ui.hint = lbl("START: tap task   hold START: meeting",
    "bottom_mid", 0, -6, "small", COL_DIM)
end

local function show_dead()
  screen = "dead"
  clear_screen()
  lbl("YOU WERE KILLED", "center", 0, -30, "large", COL_IMP)
  lbl("you are a ghost now", "center", 0, 10)
  lbl("finish your tasks, tell no one", "center", 0, 40, "small", COL_DIM)
  leds_all(120, 0, 0)
end

local function show_meeting(reason)
  screen = "meeting"
  clear_screen()
  lbl("EMERGENCY MEETING", "center", 0, -60, "large", COL_IMP)
  lbl(reason == 1 and "a body was found" or "someone hit the button",
    "center", 0, -20)
  ui.cd = lbl("", "center", 0, 20, "large")
  lbl("talk. figure it out.", "center", 0, 70, "small", COL_DIM)
end

local function show_vote()
  screen = "vote"
  clear_screen()
  vote_sel, vote_cast = 0, false
  lbl("VOTE", "center", 0, -75, "large")
  ui.cd = lbl("", "top_right", -6, 4, "small")
  ui.target = lbl("", "center", 0, -15, "large")
  ui.cast = lbl("LEFT/RIGHT pick   A vote", "center", 0, 40, "small", COL_DIM)
end

local function show_end()
  screen = "end"
  clear_screen()
  if gv.winner == 1 then
    lbl("CREW WINS", "center", 0, -30, "large", COL_CREW)
    leds_all(0, 140, 60)
  else
    lbl("IMPOSTORS WIN", "center", 0, -30, "large", COL_IMP)
    leds_all(160, 0, 0)
  end
  local mine = (gv.winner == 1) == (me.role == ROLE_CREW)
  if mode == "player" then
    lbl(mine and "your side won" or "your side lost", "center", 0, 10)
  end
  lbl("HOME: exit", "center", 0, 70, "small", COL_DIM)
end

-- task minigame state
local game = { kind = 0, step = 0, seq = {}, pos = 0, dir = 1, count = 0,
               started = 0, station = 0 }

local function show_task(station)
  screen = "task"
  clear_screen()
  game.station = station
  game.kind = station % 3 -- 0 mash, 1 simon, 2 timing
  game.started = now()
  if game.kind == 0 then
    game.count = 0
    lbl("EMPTY GARBAGE", "center", 0, -50, "large")
    ui.action = lbl("mash B! 0/12", "center", 0, 0)
  elseif game.kind == 1 then
    game.seq = {}
    for i = 1, 4 do game.seq[i] = badge.sys.random(4) end
    game.step = 0
    local names = { "UP", "DOWN", "LEFT", "RIGHT" }
    local s = ""
    for i = 1, 4 do s = s .. names[game.seq[i] + 1] .. " " end
    lbl("FIX WIRING", "center", 0, -50, "large")
    lbl(s, "center", 0, -10)
    ui.action = lbl("press the sequence", "center", 0, 25, "small", COL_DIM)
  else
    game.pos, game.dir = 0, 1
    lbl("CALIBRATE ENGINE", "center", 0, -50, "large")
    ui.bar = badge.ui.bar(root_scr, 0, 100, 0)
    ui.bar:set_size(200, 14)
    ui.bar:align("center", 0, 0)
    widgets[#widgets + 1] = ui.bar
    ui.action = lbl("A when the bar is 40-60", "center", 0, 30, "small", COL_DIM)
  end
end

-- ---------------------------------------------------------------- tasks

local function my_stations(seed, pid)
  -- everyone derives the same assignment from the start seed
  local t, used = {}, {}
  local x = seed + pid * 37
  while #t < TASKS_PER_PLAYER do
    x = (x * 197 + 71) % 65536
    local s = x % NUM_STATIONS + 1
    if not used[s] then used[s] = true; t[#t + 1] = s end
  end
  return t
end

local function tasks_left_text()
  local left = {}
  for i = 1, #me.tasks do
    if me.tasks[i] > 0 then left[#left + 1] = "station " .. me.tasks[i] end
  end
  if #left == 0 then return "all tasks done" end
  return "tasks: " .. table.concat(left, ", ")
end

local function complete_station(station)
  for i = 1, #me.tasks do
    if me.tasks[i] == station then
      me.tasks[i] = 0
      me.tasks_done = me.tasks_done + 1
      return true
    end
  end
  return false
end

-- ---------------------------------------------------------------- host

local function host_alive_mask()
  local m = 0
  for pid, pl in pairs(host.players) do
    if pl.alive then m = bit_set(m, pid) end
  end
  return m
end

local function host_joined_mask()
  local m = 0
  for pid in pairs(host.players) do m = bit_set(m, pid) end
  return m
end

local function host_task_pct()
  local done, total = 0, 0
  for _, pl in pairs(host.players) do
    done = done + pl.tasks
    total = total + TASKS_PER_PLAYER
  end
  if total == 0 then return 0 end
  return math.floor(done * 100 / total)
end

local function host_send_state()
  local cd = 0
  if gv.phase == PH_TALK or gv.phase == PH_VOTE then
    cd = clamp(math.floor((host.phase_until - now()) / 1000), 0, 255)
  end
  local j, a = host_joined_mask(), host_alive_mask()
  send(frame("S", gv.phase,
    math.floor(j / 256), j % 256 >= 0 and j % 256 or 0,
    math.floor(a / 256), a % 256,
    host_task_pct(), cd, gv.mseq, gv.ejected, gv.was_imp, gv.winner))
  host.last_state_ms = now()
end

local function host_check_win()
  if gv.winner ~= 0 then return end
  local imps, crew = 0, 0
  for _, pl in pairs(host.players) do
    if pl.alive then
      if pl.role == ROLE_IMP then imps = imps + 1 else crew = crew + 1 end
    end
  end
  if imps == 0 then gv.winner = 1
  elseif host_task_pct() >= 100 then gv.winner = 1
  elseif imps >= crew then gv.winner = 2 end
  if gv.winner ~= 0 then
    gv.phase = PH_END
    _DBG.winner = gv.winner
    -- burst the result: everyone should learn the ending fast
    host_send_state()
    host_send_state()
    host_send_state()
    clear_screen()
    lbl(gv.winner == 1 and "CREW WINS" or "IMPOSTORS WIN",
      "center", 0, -20, "large", gv.winner == 1 and COL_CREW or COL_IMP)
    lbl("START: new lobby", "center", 0, 60, "small", COL_DIM)
  end
end

local function host_start_meeting(reason)
  gv.mseq = gv.mseq + 1
  gv.phase = PH_TALK
  gv.ejected, gv.was_imp = 0, 0
  host.votes = {}
  host.phase_until = now() + TALK_S * 1000
  send(frame("M", gv.mseq, 0, reason))
  host_send_state()
end

local function host_tally()
  local counts, voters = {}, 0
  for _, target in pairs(host.votes) do
    counts[target] = (counts[target] or 0) + 1
    voters = voters + 1
  end
  local best, best_n, tie = 0, 0, false
  for target, n in pairs(counts) do
    if target ~= 0 then
      if n > best_n then best, best_n, tie = target, n, false
      elseif n == best_n then tie = true end
    end
  end
  if best ~= 0 and not tie then
    local pl = host.players[best]
    if pl then
      pl.alive = false
      gv.ejected = best
      gv.was_imp = pl.role == ROLE_IMP and 1 or 0
    end
  end
  gv.phase = PH_PLAY
  host_send_state()
  host_check_win()
end

local function host_begin_game()
  if host.count < MIN_PLAYERS then return end
  local seed = badge.sys.random(65536)
  host.seed = seed
  host.n_imp = host.count >= 8 and 2 or 1
  -- pick impostors
  local pids = {}
  for pid in pairs(host.players) do pids[#pids + 1] = pid end
  for i = 1, host.n_imp do
    local k = badge.sys.random(#pids) + 1
    local pid = table.remove(pids, k)
    host.players[pid].role = ROLE_IMP
  end
  for pid, pl in pairs(host.players) do
    if pl.role ~= ROLE_IMP then pl.role = ROLE_CREW end
    pl.alive = true
    -- role frame, masked with the player's join nonce
    local xrole = (pl.role + pl.nonce) % 256
    send(frame("O", pl.mac, xrole))
  end
  send(frame("G", math.floor(seed / 256), seed % 256, host.n_imp))
  gv.phase = PH_PLAY
  gv.winner = 0
  host_send_state()
  clear_screen()
  lbl("GAME RUNNING", "center", 0, -40, "large")
  ui.status = lbl("", "center", 0, 0)
  ui.names = lbl("", "center", 0, 40, "small", COL_DIM)
  leds_all(0, 80, 30)
end

local function host_handle(f)
  if f.gid ~= gv.gid then return end
  if f.t == "J" and gv.phase == PH_LOBBY then
    -- known mac rejoins with the same pid
    for pid, pl in pairs(host.players) do
      if pl.mac == f.mac then
        send(frame("K", f.mac, pid))
        return
      end
    end
    if host.count >= MAX_PLAYERS then return end
    local pid = host.count + 1
    host.players[pid] = { mac = f.mac, nonce = f.nonce, name = f.name,
      role = 0, alive = false, tasks = 0, last_seen = now() }
    host.count = host.count + 1
    send(frame("K", f.mac, pid))
  elseif f.t == "B" then
    local pl = host.players[f.pid]
    if pl and pl.mac == f.mac then
      pl.tasks = f.tasks
      pl.last_seen = now()
      if gv.phase == PH_PLAY and host_task_pct() >= 100 then host_check_win() end
    end
  elseif f.t == "X" and gv.phase == PH_PLAY then
    local killer, victim = host.players[f.killer], host.players[f.victim]
    if killer and victim and killer.role == ROLE_IMP
      and killer.alive and victim.alive
      and now() - (killer.last_kill or -999999) > KILL_CD_S * 1000 then
      killer.last_kill = now()
      victim.alive = false
      send(frame("D", f.victim))
      host_send_state()
      host_check_win()
    end
  elseif f.t == "P" and gv.phase == PH_PLAY then
    host_start_meeting(1)
  elseif f.t == "M" and gv.phase == PH_PLAY and f.caller ~= 0 then
    -- player-called emergency (caller relays through us for authority)
    host_start_meeting(0)
  elseif f.t == "V" and gv.phase == PH_VOTE and f.mseq == gv.mseq then
    local pl = host.players[f.voter]
    if pl and pl.alive and host.votes[f.voter] == nil then
      host.votes[f.voter] = f.target
    end
  end
end

local function host_tick()
  local t = now()
  if gv.phase == PH_LOBBY then
    if t - host.last_state_ms > 1000 then
      send(frame("L", host.count))
      -- repeat every join ack too, so a lost one costs a second, not the game
      for pid, pl in pairs(host.players) do
        send(frame("K", pl.mac, pid))
      end
      host.last_state_ms = t
    end
    if ui.count then
      ui.count:set_text("players: " .. host.count)
      local names = {}
      for _, pl in pairs(host.players) do names[#names + 1] = pl.name end
      table.sort(names)
      ui.names:set_text(table.concat(names, "  "))
    end
  else
    if t - host.last_state_ms > 2000 then host_send_state() end
    -- repeat role + seed frames so a lost packet can't strand a player
    if gv.phase ~= PH_END and t - (host.last_role_ms or 0) > 3000 then
      host.last_role_ms = t
      send(frame("G", math.floor(host.seed / 256), host.seed % 256, host.n_imp))
      for _, pl in pairs(host.players) do
        send(frame("O", pl.mac, (pl.role + pl.nonce) % 256))
      end
    end
    if gv.phase == PH_TALK and t > host.phase_until then
      gv.phase = PH_VOTE
      host.phase_until = t + VOTE_S * 1000
      host_send_state()
    elseif gv.phase == PH_VOTE then
      local all_in = true
      for pid, pl in pairs(host.players) do
        if pl.alive and host.votes[pid] == nil then all_in = false end
      end
      if all_in or t > host.phase_until then host_tally() end
    elseif gv.phase == PH_PLAY and ui.status then
      ui.status:set_text("ship " .. host_task_pct() .. "%   alive " ..
        popcount(host_alive_mask()))
    end
  end
  -- roster rebroadcast, one name per second
  if t - host.last_roster_ms > 1000 and host.count > 0 then
    host.last_roster_ms = t
    local pid = host.roster_next
    for _ = 1, MAX_PLAYERS do
      pid = pid % MAX_PLAYERS + 1
      if host.players[pid] then break end
    end
    host.roster_next = pid
    if host.players[pid] then
      send(frame("R", pid, pad_name(host.players[pid].name)))
    end
  end
  _DBG.phase = gv.phase
end

-- ---------------------------------------------------------------- player

local function ema(old, v)
  if old == nil then return v end
  -- react fast to someone approaching, slow to fading, so the kill
  -- prompt appears quickly but does not flicker
  if v > old then return math.floor(old * 0.3 + v * 0.7) end
  return math.floor(old * 0.7 + v * 0.3)
end

local function player_join(f)
  if f then gv.gid = f.gid end
  -- nonce is picked once and reused: the host remembers the first one it saw
  send(frame("J", me.nonce, pad_name(badge.me.name() or "GOOSE")))
  last_join_ms = now()
end

local function nearest_target()
  -- strongest smoothed signal among living crew (for the impostor)
  local best_pid, best = 0, -999
  for pid, pr in pairs(peers) do
    if pid ~= me.pid and bit_get(gv.alive, pid)
      and now() - pr.last_ms < PEER_TIMEOUT_MS and pr.rssi > best then
      best_pid, best = pid, pr.rssi
    end
  end
  return best_pid, best
end

local function nearest_corpse()
  local best_pid, best = 0, -999
  for pid, c in pairs(corpses) do
    if now() - c.last_ms < 6000 and c.rssi > best then
      best_pid, best = pid, c.rssi
    end
  end
  return best_pid, best
end

local function enter_meeting(f)
  corpses = {}
  if not me.dead then show_meeting(f and f.reason or 0) end
end

local function player_handle(f)
  if f.t == "L" and screen == "lobby" and me.pid == 0 then
    player_join(f)
    if ui.status then ui.status:set_text("ship found, joining...") end
    if ui.count then ui.count:set_text("players: " .. f.count) end
  elseif f.t == "K" and f.tmac == my_mac and f.gid == gv.gid then
    me.pid = f.pid
    _DBG.pid = f.pid
    if ui.status then ui.status:set_text("joined as player " .. f.pid) end
  elseif f.gid ~= gv.gid then
    return
  elseif f.t == "O" and f.tmac == my_mac then
    me.role = (f.xrole - me.nonce) % 256
    _DBG.role = me.role
  elseif f.t == "G" then
    if not me.seeded and me.pid ~= 0 then -- host repeats G; only init once
      me.seeded = true
      me.tasks = my_stations(f.seed, me.pid)
      me.tasks_done = 0
      me.dead = false
      if me.role == 0 then me.role = ROLE_CREW end -- missed role frame so far
      show_role()
    end
  elseif f.t == "S" then
    local was_phase, was_winner = gv.phase, gv.winner
    gv.phase, gv.joined, gv.alive = f.phase, f.joined, f.alive
    gv.task_pct, gv.cd, gv.mseq = f.task_pct, f.cd, f.mseq
    gv.ejected, gv.was_imp, gv.winner = f.ejected, f.was_imp, f.winner
    last_host_ms = now()
    _DBG.phase = gv.phase
    _DBG.winner = gv.winner
    if me.pid ~= 0 and not bit_get(gv.alive, me.pid)
      and bit_get(gv.joined, me.pid) and gv.phase ~= PH_LOBBY
      and not me.dead and me.role ~= 0 then
      me.dead = true
      show_dead()
    end
    if gv.phase == PH_LOBBY and was_phase ~= PH_LOBBY then
      me.seeded, me.role, me.tasks, me.tasks_done, me.dead = false, 0, {}, 0, false
      show_lobby_player()
    end
    if gv.winner ~= 0 and was_winner == 0 then
      show_end()
    elseif gv.phase == PH_TALK and was_phase ~= PH_TALK and not me.dead then
      enter_meeting(nil)
    elseif gv.phase == PH_VOTE and was_phase ~= PH_VOTE and not me.dead then
      show_vote()
    elseif gv.phase == PH_PLAY and was_phase ~= PH_PLAY and gv.winner == 0
      and me.role ~= 0 then
      if not me.dead then show_hud()
      else show_dead() end
    end
  elseif f.t == "M" then
    if f.mseq > gossip.mseq then
      gossip.mseq, gossip.sent = f.mseq, 0
      enter_meeting(f)
    end
  elseif f.t == "B" then
    local pr = peers[f.pid] or {}
    pr.rssi = ema(pr.rssi, f.rssi)
    pr.last_ms = now()
    peers[f.pid] = pr
  elseif f.t == "C" then
    if bit_get(gv.alive, f.victim) == false then
      local c = corpses[f.victim] or {}
      c.rssi = ema(c.rssi, f.rssi)
      c.last_ms = now()
      corpses[f.victim] = c
    end
  elseif f.t == "D" and f.victim == me.pid then
    me.dead = true
    show_dead()
  elseif f.t == "R" then
    roster[f.pid] = f.name
  end
end

local function player_tick()
  local t = now()
  -- still waiting for a join ack: keep asking
  if screen == "lobby" and me.pid == 0 and gv.gid ~= 0
    and t - last_join_ms > 1500 then
    player_join(nil)
  end
  -- presence beacon while in a running game
  if me.pid ~= 0 and gv.phase ~= PH_LOBBY and t - last_beacon_ms > 1000 then
    last_beacon_ms = t
    local flags = me.dead and 0 or 1
    send(frame("B", me.pid, flags, me.tasks_done))
  end
  -- dead and unreported: shout where the body is
  if me.dead and gv.phase == PH_PLAY and t - last_corpse_ms > 1000 then
    last_corpse_ms = t
    send(frame("C", me.pid))
  end
  -- retries for lossy one-shot actions
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
  -- meeting gossip relay so calls travel past direct radio range
  if gossip.sent < 2 and gossip.mseq == gv.mseq and gv.mseq > 0
    and (gv.phase == PH_TALK or gv.phase == PH_VOTE) then
    if badge.sys.random(20) == 0 then
      gossip.sent = gossip.sent + 1
      send(frame("M", gv.mseq, 0, 0))
    end
  end

  if screen == "hud" then
    ui.taskpct:set_text("ship " .. gv.task_pct .. "%")
    ui.tasks:set_text(tasks_left_text())
    if me.role == ROLE_IMP then
      local pid, rssi = nearest_target()
      local cd_left = KILL_CD_S - math.floor((t - me.last_kill_ms) / 1000)
      if cd_left > 0 then
        ui.action:set_text("kill ready in " .. cd_left .. "s")
        leds_off()
      elseif pid ~= 0 and rssi >= KILL_RSSI then
        ui.action:set_text("A: KILL " .. (roster[pid] or ("player " .. pid)))
        leds_all(160, 0, 0)
      else
        -- proximity meter: closer target lights more LEDs
        ui.action:set_text(pid == 0 and "no one nearby"
          or "hunting: " .. (roster[pid] or pid) .. " " .. rssi .. "dBm")
        local n = clamp(math.floor((rssi + 80) / 5), 0, 6)
        badge.led.clear()
        for i = 1, n do badge.led.set(i, 100, 10, 0) end
        badge.led.show()
      end
    else
      local cpid, crssi = nearest_corpse()
      if cpid ~= 0 and crssi >= BODY_RSSI then
        ui.action:set_text("B: REPORT BODY (" .. (roster[cpid] or cpid) .. ")")
        leds_all(140, 60, 0)
      else
        ui.action:set_text("")
        leds_off()
      end
    end
  elseif screen == "meeting" and ui.cd then
    ui.cd:set_text(gv.cd .. "s")
  elseif screen == "vote" and ui.cd then
    ui.cd:set_text(gv.cd .. "s")
    local names = { "SKIP" }
    local ids = { 0 }
    for pid = 1, MAX_PLAYERS do
      if bit_get(gv.alive, pid) and pid ~= me.pid then
        ids[#ids + 1] = pid
        names[#names + 1] = roster[pid] or ("player " .. pid)
      end
    end
    vote_sel = vote_sel % #ids
    ui.target:set_text(vote_cast and "voted" or names[vote_sel + 1])
    ui.vote_ids = ids
  elseif screen == "task" then
    if game.kind == 2 and ui.bar then
      game.pos = game.pos + game.dir * 3
      if game.pos >= 100 then game.pos, game.dir = 100, -1 end
      if game.pos <= 0 then game.pos, game.dir = 0, 1 end
      ui.bar:set_value(game.pos)
    end
  end
end

local function finish_task()
  complete_station(game.station)
  send(frame("B", me.pid, me.dead and 0 or 1, me.tasks_done))
  if me.dead then show_dead() else show_hud() end
end

-- ---------------------------------------------------------------- input

local function player_button(b, kind)
  local BT = badge.input.BUTTON
  if kind ~= badge.input.KIND.PRESSED then
    return
  end
  if screen == "menu" then
    if b == BT.A then
      mode = "player"
      if not badge.radio.enable() then
        clear_screen(); lbl("radio failed, reboot badge", "center", 0, 0)
        return
      end
      my_mac = badge.radio.mac()
      me.nonce = badge.sys.random(256)
      show_lobby_player()
    elseif b == BT.START then
      mode = "host"
      if not badge.radio.enable() then
        clear_screen(); lbl("radio failed, reboot badge", "center", 0, 0)
        return
      end
      my_mac = badge.radio.mac()
      gv.gid = badge.sys.random(255) + 1
      show_lobby_host()
    end
  elseif mode == "host" then
    if b == BT.START then
      if gv.phase == PH_LOBBY then host_begin_game()
      elseif gv.phase == PH_END then
        -- fresh lobby, same gid
        for _, pl in pairs(host.players) do
          pl.role, pl.alive, pl.tasks = 0, false, 0
        end
        gv.phase, gv.winner, gv.mseq = PH_LOBBY, 0, 0
        gv.ejected, gv.was_imp = 0, 0
        show_lobby_host()
      end
    elseif b == BT.A and gv.phase == PH_PLAY then
      host_start_meeting(0) -- host can force a meeting (moderator power)
    end
  elseif screen == "role" then
    if b == BT.A then show_hud() end
  elseif screen == "hud" then
    if b == BT.A and me.role == ROLE_IMP and not me.dead then
      local pid, rssi = nearest_target()
      local cd_ok = now() - me.last_kill_ms > KILL_CD_S * 1000
      if pid ~= 0 and rssi >= KILL_RSSI and cd_ok then
        me.last_kill_ms = now()
        pending_kill = { pid = pid, tries = 0, next_ms = 0 }
      end
    elseif b == BT.B and not me.dead then
      local cpid, crssi = nearest_corpse()
      if cpid ~= 0 and crssi >= BODY_RSSI then
        pending_report = { pid = cpid, tries = 0, next_ms = 0 }
      end
    elseif b == BT.START then
      if DEBUG then
        -- simulate an NFC tap on my next unfinished station
        for i = 1, #me.tasks do
          if me.tasks[i] > 0 then show_task(me.tasks[i]) return end
        end
      end
    elseif b == BT.AUX1 and not me.used_emergency and not me.dead then
      me.used_emergency = true
      send(frame("M", gv.mseq + 1, me.pid, 0)) -- host re-issues with authority
    end
  elseif screen == "task" then
    if game.kind == 0 and b == BT.B then
      game.count = game.count + 1
      ui.action:set_text("mash B! " .. game.count .. "/12")
      if game.count >= 12 then finish_task() end
    elseif game.kind == 1 then
      local dirs = { [badge.input.BUTTON.UP] = 0, [badge.input.BUTTON.DOWN] = 1,
        [badge.input.BUTTON.LEFT] = 2, [badge.input.BUTTON.RIGHT] = 3 }
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
    elseif game.kind == 2 and b == BT.A then
      if game.pos >= 40 and game.pos <= 60 then finish_task()
      else ui.action:set_text("missed (" .. game.pos .. "), again") end
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

-- ---------------------------------------------------------------- lifecycle

function on_enter(root)
  root_scr = root
  local bg = badge.ui.box(root, 320, 240)
  bg:align("center", 0, 0)
  bg:style({ bg_color = COL_BG, border_width = 0 })
  -- bg is never deleted; real screens draw on root above it
  _DBG.me, _DBG.gv, _DBG.game, _DBG.host = me, gv, game, host
  _DBG.peers, _DBG.corpses = peers, corpses
  show_menu()
  badge.radio.on_recv(function(mac, rssi, payload)
    if #inbox < 24 then inbox[#inbox + 1] = { mac, rssi, payload } end
  end)
end

function on_tick()
  -- handle a bounded batch of radio frames per tick
  for i = 1, 8 do
    local m = table.remove(inbox, 1)
    if not m then break end
    local f = parse(m[1], m[2], m[3])
    if f and mode == "host" then host_handle(f)
    elseif f and mode == "player" then player_handle(f) end
  end
  if mode == "host" then host_tick()
  elseif mode == "player" then player_tick() end
end

function on_button(b, kind)
  player_button(b, kind)
end

function on_exit()
  badge.led.clear()
  badge.led.show()
  badge.radio.disable()
end
