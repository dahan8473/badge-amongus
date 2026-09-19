-- Host side: the "ship". Runs the lobby, deals roles, validates kills,
-- runs meetings and votes, and rebroadcasts the full game state every 2s.
-- Loaded by main.lua when the user picks "host". Shares globals from main.

local M = {}

local host = { players = {}, count = 0, phase_until = 0, votes = {},
               last_state_ms = 0, n_imp = 1, seed = 0, last_role_ms = 0 }

local function alive_mask()
  local m = 0
  for pid, pl in pairs(host.players) do
    if pl.alive then m = bit_set(m, pid) end
  end
  return m
end

local function alive_count()
  local n = 0
  for _, pl in pairs(host.players) do if pl.alive then n = n + 1 end end
  return n
end

local function joined_mask()
  local m = 0
  for pid in pairs(host.players) do m = bit_set(m, pid) end
  return m
end

local function task_pct()
  local done, total = 0, 0
  for _, pl in pairs(host.players) do
    done = done + pl.tasks
    total = total + TASKS_PER_PLAYER
  end
  if total == 0 then return 0 end
  return math.floor(done * 100 / total)
end

local function send_state()
  local cd = 0
  if gv.phase == PH_TALK or gv.phase == PH_VOTE then
    cd = clamp(math.floor((host.phase_until - now()) / 1000), 0, 255)
  end
  local j, a = joined_mask(), alive_mask()
  send(frame("S", gv.phase, math.floor(j / 256), j % 256,
    math.floor(a / 256), a % 256,
    task_pct(), cd, gv.mseq, gv.ejected, gv.was_imp, gv.winner))
  host.last_state_ms = now()
end

local function check_win()
  if gv.winner ~= 0 then return end
  local imps, crew = 0, 0
  for _, pl in pairs(host.players) do
    if pl.alive then
      if pl.role == ROLE_IMP then imps = imps + 1 else crew = crew + 1 end
    end
  end
  if imps == 0 then gv.winner = 1
  elseif task_pct() >= 100 then gv.winner = 1
  elseif imps >= crew then gv.winner = 2 end
  if gv.winner ~= 0 then
    gv.phase = PH_END
    _DBG.winner = gv.winner
    -- burst the result: everyone should learn the ending fast
    send_state()
    send_state()
    send_state()
    clear_screen()
    lbl(gv.winner == 1 and "CREW WINS" or "IMPOSTORS WIN",
      "center", 0, -20, "large", gv.winner == 1 and COL_CREW or COL_IMP)
    lbl("START: new lobby", "center", 0, 60, "small", COL_DIM)
  end
end

local function start_meeting(reason)
  gv.mseq = gv.mseq + 1
  gv.phase = PH_TALK
  gv.ejected, gv.was_imp = 0, 0
  host.votes = {}
  host.phase_until = now() + TALK_S * 1000
  send(frame("M", gv.mseq, 0, reason))
  send_state()
end

local function tally()
  local counts = {}
  for _, target in pairs(host.votes) do
    counts[target] = (counts[target] or 0) + 1
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
  send_state()
  check_win()
end

local function show_lobby()
  screen = "lobby"
  clear_screen()
  lbl("SHIP (HOST)", "center", 0, -80, "large")
  ui.count = lbl("players: 0", "center", 0, -20)
  lbl("START begins the game (min " .. MIN_PLAYERS .. ")",
    "center", 0, 75, "small", COL_DIM)
end

local function begin_game()
  if host.count < MIN_PLAYERS then return end
  host.seed = badge.sys.random(65536)
  host.n_imp = host.count >= 8 and 2 or 1
  local pids = {}
  for pid in pairs(host.players) do pids[#pids + 1] = pid end
  for _ = 1, host.n_imp do
    local k = badge.sys.random(#pids) + 1
    local pid = table.remove(pids, k)
    host.players[pid].role = ROLE_IMP
  end
  for _, pl in pairs(host.players) do
    if pl.role ~= ROLE_IMP then pl.role = ROLE_CREW end
    pl.alive = true
    -- role frame, masked with the player's join nonce
    send(frame("O", pl.mac, (pl.role + pl.nonce) % 256))
  end
  send(frame("G", math.floor(host.seed / 256), host.seed % 256, host.n_imp))
  gv.phase = PH_PLAY
  gv.winner = 0
  send_state()
  clear_screen()
  lbl("GAME RUNNING", "center", 0, -40, "large")
  ui.status = lbl("", "center", 0, 0)
  lbl("A: force meeting", "center", 0, 60, "small", COL_DIM)
  leds_all(0, 80, 30)
end

function M.handle(f)
  if f.gid ~= gv.gid then return end
  if f.t == "J" and gv.phase == PH_LOBBY then
    for pid, pl in pairs(host.players) do
      if pl.mac == f.mac then -- known badge rejoins with the same pid
        send(frame("K", f.mac, pid))
        return
      end
    end
    if host.count >= MAX_PLAYERS then return end
    local pid = host.count + 1
    host.players[pid] = { mac = f.mac, nonce = f.nonce,
      role = 0, alive = false, tasks = 0, last_seen = now() }
    host.count = host.count + 1
    send(frame("K", f.mac, pid))
  elseif f.t == "B" then
    local pl = host.players[f.pid]
    if pl and pl.mac == f.mac then
      pl.tasks = f.tasks
      pl.last_seen = now()
      if gv.phase == PH_PLAY and task_pct() >= 100 then check_win() end
    end
  elseif f.t == "X" and gv.phase == PH_PLAY then
    local killer, victim = host.players[f.killer], host.players[f.victim]
    if killer and victim and killer.role == ROLE_IMP
      and killer.alive and victim.alive
      and now() - (killer.last_kill or -999999) > KILL_CD_S * 1000 then
      killer.last_kill = now()
      victim.alive = false
      send(frame("D", f.victim))
      send_state()
      check_win()
    end
  elseif f.t == "P" and gv.phase == PH_PLAY then
    start_meeting(1)
  elseif f.t == "M" and gv.phase == PH_PLAY and f.caller ~= 0 then
    -- a player pressed their emergency button; we re-issue with authority
    start_meeting(0)
  elseif f.t == "V" and gv.phase == PH_VOTE and f.mseq == gv.mseq then
    local pl = host.players[f.voter]
    if pl and pl.alive and host.votes[f.voter] == nil then
      host.votes[f.voter] = f.target
    end
  end
end

function M.tick()
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
    if ui.count then ui.count:set_text("players: " .. host.count) end
  else
    if t - host.last_state_ms > 2000 then send_state() end
    -- repeat role + seed frames so a lost packet can't strand a player
    if gv.phase ~= PH_END and t - host.last_role_ms > 3000 then
      host.last_role_ms = t
      send(frame("G", math.floor(host.seed / 256), host.seed % 256, host.n_imp))
      for _, pl in pairs(host.players) do
        send(frame("O", pl.mac, (pl.role + pl.nonce) % 256))
      end
    end
    if gv.phase == PH_TALK and t > host.phase_until then
      gv.phase = PH_VOTE
      host.phase_until = t + VOTE_S * 1000
      send_state()
    elseif gv.phase == PH_VOTE then
      local all_in = true
      for pid, pl in pairs(host.players) do
        if pl.alive and host.votes[pid] == nil then all_in = false end
      end
      if all_in or t > host.phase_until then tally() end
    elseif gv.phase == PH_PLAY and ui.status then
      ui.status:set_text("ship " .. task_pct() .. "%   alive " .. alive_count())
    end
  end
  _DBG.phase = gv.phase
end

function M.button(b)
  local BT = badge.input.BUTTON
  if b == BT.START then
    if gv.phase == PH_LOBBY then begin_game()
    elseif gv.phase == PH_END then
      for _, pl in pairs(host.players) do
        pl.role, pl.alive, pl.tasks = 0, false, 0
      end
      gv.phase, gv.winner, gv.mseq = PH_LOBBY, 0, 0
      gv.ejected, gv.was_imp = 0, 0
      show_lobby()
    end
  elseif b == BT.A and gv.phase == PH_PLAY then
    start_meeting(0) -- moderator power
  end
end

function M.start()
  gv.gid = badge.sys.random(255) + 1
  _DBG.host = host
  show_lobby()
end

return M
