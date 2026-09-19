-- Desktop mock of the HTN badge Lua API.
-- Lets us run several copies of app/main.lua on a laptop and simulate
-- radio, positions, signal strength, and packet loss. No hardware needed.

local M = {}

-- ------------------------------------------------------------- widgets

local Widget = {}
Widget.__index = Widget

local function new_widget(kind, text)
  return setmetatable({ kind = kind, text = text or "", deleted = false }, Widget)
end

function Widget:align() return self end
function Widget:set_text(t) self.text = t end
function Widget:set_font_size() end
function Widget:style() end
function Widget:set_size() end
function Widget:set_pos() end
function Widget:set_value(v) self.value = v end
function Widget:set_range() end
function Widget:set_color() end
function Widget:set_border() end
function Widget:hidden() end
function Widget:clickable() end
function Widget:bring_to_front() end
function Widget:delete() self.deleted = true end

-- ------------------------------------------------------------- world

local World = {}
World.__index = World

function M.new_world(seed, loss)
  math.randomseed(seed or 1)
  return setmetatable({
    time = 0,
    instances = {},
    loss = loss or 0.15,
    log_lines = {},
  }, World)
end

function World:broadcast(sender, payload)
  for _, inst in ipairs(self.instances) do
    if inst ~= sender and inst.recv then
      local dx, dy = inst.x - sender.x, inst.y - sender.y
      local dist = math.sqrt(dx * dx + dy * dy)
      local rssi = math.floor(-40 - 6 * dist + math.random(-3, 3))
      if rssi >= -90 and math.random() >= self.loss then
        inst.recv(sender.mac, rssi, payload)
      end
    end
  end
end

function World:spawn(name, x, y)
  local world = self
  local n = #self.instances + 1
  local inst = {
    name = name, x = x, y = y,
    mac = string.format("AA:BB:CC:DD:EE:%02X", n),
    recv = nil, leds = {},
  }

  local badge = {
    ui = {
      screen_width = 320, screen_height = 240,
      label = function(_, text) return new_widget("label", text) end,
      box = function() return new_widget("box") end,
      bar = function(_, _, _, v) local w = new_widget("bar") w.value = v return w end,
      button = function() return new_widget("button") end,
      arc = function() return new_widget("arc") end,
      image = function() return new_widget("image") end,
      line = function() return new_widget("line") end,
    },
    led = {
      set = function(i, r, g, b) inst.leds[i] = { r, g, b } end,
      set_all = function(r, g, b)
        for i = 1, 6 do inst.leds[i] = { r, g, b } end
      end,
      clear = function() inst.leds = {} end,
      show = function() end,
      count = function() return 6 end,
    },
    input = {
      BUTTON = { A = 1, B = 2, HOME = 3, DOWN = 4, LEFT = 5, RIGHT = 6,
                 UP = 7, AUX1 = 8, START = 9 },
      KIND = { PRESSED = 1, RELEASED = 2 },
      is_down = function() return false end,
      held = function() return 0 end,
    },
    sensor = {
      accel = function() return 0, 0, 1000 end,
      shake = function() return false end,
      tap = function() return false end,
      orientation = function() return "flat_up" end,
    },
    sys = {
      ms = function() return world.time end,
      uptime = function() return math.floor(world.time / 1000) end,
      log = function(s)
        world.log_lines[#world.log_lines + 1] = "[" .. name .. "] " .. tostring(s)
      end,
      random = function(range)
        if range then return math.random(0, range - 1) end
        return math.random(0, 2 ^ 31 - 1)
      end,
      heap = function() return 0 end,
      gc_step = function() end,
      version = function() return "mock" end,
      wake_lock = function() end,
      stats = function() return {} end,
    },
    me = {
      name = function() return name end,
      role = function() return 0 end,
      role_name = function() return "Hacker" end,
      color = function() return 255, 255, 255 end,
      badge_id = function() return "mock-" .. n end,
      provisioned = function() return true end,
    },
    contacts = {
      count = function() return 0 end,
      get = function() return nil end,
    },
    app = {
      slug = function() return "amongus" end,
      name = function() return "Among Us" end,
      exit = function() end,
    },
    fs = {
      read = function() return nil, "mock" end,
      write = function() return true end,
      append = function() return true end,
      exists = function() return false end,
      remove = function() return false end,
      list = function() return {} end,
      mkdir = function() return true end,
    },
    nfc = {
      enable = function() return true end,
      disable = function() end,
      card = function() return inst.nfc_card end,
      read_text = function() return inst.nfc_text end,
      clear = function() inst.nfc_card = nil end,
    },
    radio = {
      enable = function() return true end,
      disable = function() end,
      send = function(p)
        if #p > 44 then error(name .. " sent " .. #p .. " byte frame (max 44)") end
        world:broadcast(inst, p)
        return true
      end,
      on_recv = function(fn) inst.recv = fn end,
      mac = function() return inst.mac end,
      dropped = function() return 0 end,
    },
  }

  -- store: simple table-backed version
  local store_data = {}
  badge.store = {
    set = function(k, v) store_data[k] = v end,
    get = function(k, d) return store_data[k] or d end,
    set_int = function(k, v) store_data[k] = v end,
    get_int = function(k, d) return store_data[k] or d end,
    set_str = function(k, v) store_data[k] = v end,
    get_str = function(k, d) return store_data[k] or d end,
  }

  -- each instance runs the app in its own environment
  local env = setmetatable({ badge = badge }, { __index = _G })
  env._ENV_NAME = name
  local f = assert(io.open(M.app_path, "r"))
  local src = f:read("*a")
  f:close()
  local chunk = assert(load(src, "@main.lua[" .. name .. "]", "t", env))
  chunk()

  inst.env = env
  self.instances[#self.instances + 1] = inst
  return inst
end

function World:enter_all()
  for _, inst in ipairs(self.instances) do
    inst.env.on_enter(new_widget("root"))
  end
end

function World:press(inst, button_name)
  local b = inst.env.badge.input.BUTTON[button_name]
  inst.env.on_button(b, 1)
  inst.env.on_button(b, 2)
end

function World:move(inst, x, y)
  inst.x, inst.y = x, y
end

function World:run(ms)
  local steps = math.floor(ms / 20)
  for _ = 1, steps do
    self.time = self.time + 20
    for _, inst in ipairs(self.instances) do
      inst.env.on_tick()
    end
  end
end

return M
