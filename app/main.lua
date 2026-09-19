-- Among Us: social deduction for the HTN 2026 badge.
-- The badge runs out of RAM compiling one big file, so the app is split:
-- this file holds shared state and the menu, then loads player.lua or
-- host.lua on demand. A badge only ever compiles the half it uses.

DEBUG = true -- shorter timers + Start simulates an NFC task tap

-- shared constants (globals on purpose: player.lua and host.lua use them)
MAGIC = "A1"
MAX_PLAYERS = 15
MIN_PLAYERS = 3
TASKS_PER_PLAYER = 3
NUM_STATIONS = 8
KILL_RSSI = -56 -- smoothed dBm needed to kill (tune at venue)
BODY_RSSI = -62 -- smoothed dBm needed to report a body
PEER_TIMEOUT_MS = 12000

TALK_S = DEBUG and 6 or 45
VOTE_S = DEBUG and 10 or 30
KILL_CD_S = DEBUG and 5 or 25

ROLE_CREW, ROLE_IMP = 1, 2
PH_LOBBY, PH_PLAY, PH_TALK, PH_VOTE, PH_END = 0, 1, 2, 3, 4

COL_BG = 0x101018
COL_CREW = 0x35c4f0
COL_IMP = 0xe23c3c
COL_DIM = 0x777788

-- shared game view (what STATE frames tell us)
gv = { gid = 0, phase = PH_LOBBY, joined = 0, alive = 0,
       task_pct = 0, cd = 0, mseq = 0, ejected = 0, was_imp = 0, winner = 0 }

mode = nil -- "host" | "player"
screen = "menu"
my_mac = "?"
ui = {}
widgets = {}
ACTIVE = nil -- the loaded module (player or host)

_DBG = { role = 0, phase = 0, winner = 0, pid = 0, gv = gv }

local inbox = {}

-- ------------------------------------------------------------- helpers

function now() return badge.sys.ms() end
function clamp(v, a, b) return math.max(a, math.min(b, v)) end

function bit_get(mask, i)
  return math.floor(mask / 2 ^ (i - 1)) % 2 == 1
end

function bit_set(mask, i)
  if not bit_get(mask, i) then return mask + 2 ^ (i - 1) end
  return mask
end

-- ------------------------------------------------------------- protocol

function frame(t, ...)
  local parts = { MAGIC, t, string.char(gv.gid % 256) }
  local args = { ... }
  for i = 1, #args do
    local a = args[i]
    if type(a) == "number" then a = string.char(a % 256) end
    parts[#parts + 1] = a
  end
  return table.concat(parts)
end

function send(payload)
  badge.radio.send(payload)
end

-- field layouts per frame type: { name, byte } or { name, from, to }
local LAYOUT = {
  L = { { "count", 5 } },
  J = { { "nonce", 5 } },
  K = { { "tmac", 5, 21 }, { "pid", 22 } },
  O = { { "tmac", 5, 21 }, { "xrole", 22 } },
  G = { { "seed", 5, -6 }, { "n_imp", 7 } },
  S = { { "phase", 5 }, { "joined", 6, -7 }, { "alive", 8, -9 },
        { "task_pct", 10 }, { "cd", 11 }, { "mseq", 12 },
        { "ejected", 13 }, { "was_imp", 14 }, { "winner", 15 } },
  B = { { "pid", 5 }, { "flags", 6 }, { "tasks", 7 } },
  X = { { "killer", 5 }, { "victim", 6 } },
  D = { { "victim", 5 } },
  C = { { "victim", 5 } },
  P = { { "reporter", 5 }, { "victim", 6 } },
  M = { { "mseq", 5 }, { "caller", 6 }, { "reason", 7 } },
  V = { { "mseq", 5 }, { "voter", 6 }, { "target", 7 } },
}

-- parse one frame into a table, nil when malformed
function parse(mac, rssi, p)
  if #p < 4 or string.sub(p, 1, 2) ~= MAGIC then return nil end
  local fields = LAYOUT[string.sub(p, 3, 3)]
  if not fields then return nil end
  local f = { t = string.sub(p, 3, 3), gid = string.byte(p, 4),
              mac = mac, rssi = rssi }
  for i = 1, #fields do
    local d = fields[i]
    if d[3] == nil then -- one byte
      if #p < d[2] then return nil end
      f[d[1]] = string.byte(p, d[2])
    elseif d[3] < 0 then -- two bytes, big endian
      if #p < -d[3] then return nil end
      f[d[1]] = string.byte(p, d[2]) * 256 + string.byte(p, -d[3])
    else -- fixed range (mac string)
      if #p < d[3] then return nil end
      f[d[1]] = string.sub(p, d[2], d[3])
    end
  end
  return f
end

-- ------------------------------------------------------------- UI

root_scr = nil

function clear_screen()
  for i = 1, #widgets do widgets[i]:delete() end
  widgets = {}
end

function lbl(text, ax, dx, dy, size, color)
  local w = badge.ui.label(root_scr, text)
  w:align(ax or "center", dx or 0, dy or 0)
  if size then w:set_font_size(size) end
  if color then w:style({ text_color = color }) end
  widgets[#widgets + 1] = w
  return w
end

function leds_off() badge.led.clear() badge.led.show() end

function leds_all(r, g, b)
  badge.led.clear()
  badge.led.set_all(r, g, b)
  badge.led.show()
end

function show_menu()
  screen = "menu"
  clear_screen()
  lbl("AMONG US", "center", 0, -60, "large")
  lbl("A: join a game", "center", 0, -10)
  lbl("START: host a game (ship)", "center", 0, 20)
  lbl("HOME: quit", "center", 0, 70, "small", COL_DIM)
  leds_off()
end

-- ------------------------------------------------------------- lifecycle

local pending_mode = nil

local function show_confirm(which)
  pending_mode = which
  screen = "confirm"
  clear_screen()
  lbl("START BLUETOOTH?", "center", 0, -60, "large")
  lbl("On old badge firmware this can", "center", 0, -15, "small")
  lbl("reboot the badge. The help desk", "center", 0, 5, "small")
  lbl("has the firmware update.", "center", 0, 25, "small")
  lbl("A: go   B: back", "center", 0, 70, "small", COL_DIM)
end

local function start_mode(which)
  local m = require(which) -- compiles just that half, on demand
  collectgarbage("collect")
  if not badge.radio.enable() then
    clear_screen()
    lbl("Bluetooth could not start.", "center", 0, -20)
    lbl("Reboot the badge and retry.", "center", 0, 10)
    return
  end
  my_mac = badge.radio.mac()
  badge.radio.on_recv(function(mac, rssi, payload)
    if #inbox < 24 then inbox[#inbox + 1] = { mac, rssi, payload } end
  end)
  mode = which
  ACTIVE = m
  ACTIVE.start()
end

function on_enter(root)
  root_scr = root
  local bg = badge.ui.box(root, 320, 240)
  bg:align("center", 0, 0)
  bg:style({ bg_color = COL_BG, border_width = 0 })
  show_menu()
end

function on_tick()
  for i = 1, 8 do
    local m = table.remove(inbox, 1)
    if not m then break end
    local f = parse(m[1], m[2], m[3])
    if f and ACTIVE then ACTIVE.handle(f) end
  end
  if ACTIVE then ACTIVE.tick() end
end

function on_button(b, kind)
  if kind ~= badge.input.KIND.PRESSED then return end
  local BT = badge.input.BUTTON
  if ACTIVE then
    ACTIVE.button(b)
  elseif screen == "menu" then
    if b == BT.A then show_confirm("player")
    elseif b == BT.START then show_confirm("host") end
  elseif screen == "confirm" then
    if b == BT.A then start_mode(pending_mode)
    elseif b == BT.B then show_menu() end
  end
end

function on_exit()
  badge.led.clear()
  badge.led.show()
  badge.radio.disable()
end
