-- Lockstep for Omarchy / Hyprland.
--
-- Every monitor shows the same workspace *group* at all times. Press SUPER+3
-- and every monitor switches to "workspace 3". Under the hood each monitor
-- keeps its own Hyprland workspaces: monitor index i (0-based, sorted left to
-- right, then top to bottom) shows workspace  g + stride * i  for group g.
-- With the defaults that is 1-10 on the first monitor, 11-20 on the second,
-- 21-30 on the third, and so on.
--
-- Load this from ~/.config/hypr/bindings.lua:
--
--   dofile(os.getenv("HOME") .. "/.config/omarchy/plugins/joachim.lockstep/hypr/lockstep.lua")
--
-- Options can be set before the dofile line:
--
--   lockstep = { groups = 10, bind_keys = true, gather_on_undock = true }
--
-- Runtime inspection:
--
--   hyprctl repl 'return lockstep.status()'
--   hyprctl repl 'lockstep.set_enabled(false)'   -- pause: monitors go their own way again

local M = _G.lockstep or {}
_G.lockstep = M

M.groups = M.groups or 10 -- groups per monitor; only 1-10 get number keys
M.stride = M.stride or 10 -- id spacing between monitors; must be >= groups
if M.bind_keys == nil then M.bind_keys = true end
M.stride = math.max(M.stride, M.groups)

local syncing = false

-- Pause state survives reloads through a state file the bar widget watches.
local state_dir = (os.getenv("XDG_STATE_HOME") or (os.getenv("HOME") .. "/.local/state")) .. "/omarchy/lockstep"
M.state_file = state_dir .. "/enabled"

local function read_state()
  local f = io.open(M.state_file, "r")
  if not f then return nil end
  local text = f:read("*a") or ""
  f:close()
  return text:match("^%s*0") == nil
end

local function write_state(enabled)
  os.execute("mkdir -p '" .. state_dir .. "'")
  local f = io.open(M.state_file, "w")
  if not f then return end
  f:write(enabled and "1\n" or "0\n")
  f:close()
end

if M.enabled == nil then
  local saved = read_state()
  if saved == nil then M.enabled = true else M.enabled = saved end
end

function M.set_enabled(enabled)
  enabled = enabled and true or false
  M.enabled = enabled
  write_state(enabled)
  if enabled then M.sync() end
  return enabled
end

function M.toggle()
  return M.set_enabled(not M.enabled)
end

local function log(message)
  print("lockstep: " .. tostring(message))
end

local function same_window(a, b)
  if a == nil or b == nil then return a == b end
  return a.address == b.address
end

-- ---------------------------------------------------------------------------
-- Arithmetic

function M.group_of(id)
  return ((id - 1) % M.stride) + 1
end

function M.index_of(id)
  return math.floor((id - 1) / M.stride)
end

function M.workspace_id(group, index)
  return group + M.stride * index
end

local function is_regular(ws)
  return ws ~= nil and ws.id > 0 and not ws.special and M.group_of(ws.id) <= M.groups
end

-- ---------------------------------------------------------------------------
-- Monitors, ordered left to right, then top to bottom

function M.monitors()
  local mons = {}
  for _, mon in ipairs(hl.get_monitors()) do
    if not mon.is_mirror then table.insert(mons, mon) end
  end
  table.sort(mons, function(a, b)
    if a.x ~= b.x then return a.x < b.x end
    return a.y < b.y
  end)
  return mons
end

function M.index_of_monitor(mon)
  if not mon then return 0 end
  for i, m in ipairs(M.monitors()) do
    if m.name == mon.name then return i - 1 end
  end
  return 0
end

function M.current_group()
  local mon = hl.get_active_monitor()
  local ws = mon and mon.active_workspace
  if not is_regular(ws) then return M.last_group or 1 end
  return M.group_of(ws.id)
end

-- ---------------------------------------------------------------------------
-- Workspace rules: pin every id to its monitor and keep it alive

M.rules = M.rules or {}

function M.apply_rules()
  for _, rule in ipairs(M.rules) do
    pcall(function() rule:set_enabled(false) end)
  end
  M.rules = {}

  for i, mon in ipairs(M.monitors()) do
    for g = 1, M.groups do
      local id = M.workspace_id(g, i - 1)
      table.insert(M.rules, hl.workspace_rule({
        workspace = tostring(id),
        monitor = mon.name,
        persistent = true,
        default = (g == 1),
      }))
    end
  end
end

-- First enable: a workspace that already lives on monitor i but carries an id
-- meant for another monitor is renumbered in place, so nothing visibly moves.
-- Only ids that are free get taken; anything else is left for place().
function M.adopt()
  local index = {}
  for i, mon in ipairs(M.monitors()) do index[mon.name] = i - 1 end

  for _, ws in ipairs(hl.get_workspaces()) do
    if is_regular(ws) and ws.monitor then
      local i = index[ws.monitor.name]
      if i and M.index_of(ws.id) ~= i then
        local target = M.workspace_id(M.group_of(ws.id), i)
        if not hl.get_workspace(target) then
          hl.dispatch(hl.dsp.workspace.change_id({ workspace = tostring(ws.id), id = target }))
        end
      end
    end
  end
end

-- Put every workspace on the monitor its id belongs to. Ids whose monitor is
-- not connected right now (index beyond the monitor count) are left where
-- Hyprland parked them; they come back when the monitor does.
function M.place()
  local mons = M.monitors()
  for _, ws in ipairs(hl.get_workspaces()) do
    if is_regular(ws) and ws.monitor then
      local mon = mons[M.index_of(ws.id) + 1]
      if mon and ws.monitor.name ~= mon.name then
        hl.dispatch(hl.dsp.workspace.move({ workspace = tostring(ws.id), monitor = mon.name }))
      end
    end
  end
end

-- ---------------------------------------------------------------------------
-- Sync: bring every monitor to one group

function M.sync(group)
  if syncing or not M.enabled then return end
  syncing = true

  local ok, err = pcall(function()
    group = group or M.current_group()
    local focused = hl.get_active_monitor()
    local prev_window = hl.get_active_window()

    for i, mon in ipairs(M.monitors()) do
      if not focused or mon.name ~= focused.name then
        local id = M.workspace_id(group, i - 1)
        local active = mon.active_workspace
        if hl.get_workspace(id) and (not active or active.id ~= id) then
          mon:set_workspace({ workspace = tostring(id) })
        end
      end
    end

    if focused then
      local id = M.workspace_id(group, M.index_of_monitor(focused))
      local active = focused.active_workspace
      if not active or active.id ~= id then
        hl.dispatch(hl.dsp.focus({ workspace = tostring(id) }))
      elseif prev_window and not same_window(prev_window, hl.get_active_window()) then
        -- set_workspace on another monitor handed keyboard focus to a window
        -- there; give it back.
        hl.dispatch(hl.dsp.focus({ window = prev_window }))
      end
    end

    if M.last_group ~= group then
      M.previous_group = M.last_group
      M.last_group = group
    end
  end)

  syncing = false
  if not ok then log("sync failed: " .. tostring(err)) end
end

function M.focus(group)
  group = math.max(1, math.min(M.groups, math.floor(group)))
  if not M.enabled then
    -- Paused: behave like stock Hyprland, one monitor at a time.
    local id = M.workspace_id(group, M.index_of_monitor(hl.get_active_monitor()))
    hl.dispatch(hl.dsp.focus({ workspace = tostring(id) }))
    return
  end
  M.sync(group)
end

-- Groups that have at least one window on any monitor, plus the current one.
function M.occupied_groups()
  local seen = {}
  for _, ws in ipairs(hl.get_workspaces()) do
    if is_regular(ws) and ws.windows > 0 then seen[M.group_of(ws.id)] = true end
  end
  seen[M.current_group()] = true
  local groups = {}
  for g = 1, M.groups do
    if seen[g] then table.insert(groups, g) end
  end
  return groups
end

function M.focus_relative(step)
  local groups = M.occupied_groups()
  local current = M.current_group()
  local at = 1
  for i, g in ipairs(groups) do
    if g == current then at = i end
  end
  local next_at = ((at - 1 + step) % #groups) + 1
  M.focus(groups[next_at])
end

function M.focus_previous()
  if M.previous_group then M.focus(M.previous_group) end
end

-- Move the active window to group `group` on the monitor it is on.
function M.move_window(group, follow)
  local win = hl.get_active_window()
  if not win then return end
  local mon = win.monitor or hl.get_active_monitor()
  local id = M.workspace_id(group, M.index_of_monitor(mon))
  hl.dispatch(hl.dsp.window.move({ window = win, workspace = tostring(id), follow = false }))
  if follow then M.focus(group) end
end

-- ---------------------------------------------------------------------------
-- Undock / redock
--
-- When a monitor goes away its ids (e.g. 11-20) are orphaned: Hyprland parks
-- them on a remaining monitor, where they are hidden behind that monitor's own
-- ids. gather() moves their windows into the same group on the last monitor
-- and remembers where each came from; restore() sends them back once a
-- monitor exists at that index again and the window has not been moved since.
-- Origins are ids, not connector names, so a dock that renumbers DP-7/DP-8
-- does not matter. The map lives in a state file so reloads keep it.

if M.gather_on_undock == nil then M.gather_on_undock = true end
M.parked_file = state_dir .. "/parked"

local function read_parked()
  local parked = {}
  local f = io.open(M.parked_file, "r")
  if not f then return parked end
  for line in f:lines() do
    local address, origin, target = line:match("^(%S+)%s+(%d+)%s+(%d+)")
    if address then parked[address] = { origin = tonumber(origin), target = tonumber(target) } end
  end
  f:close()
  return parked
end

local function write_parked(parked)
  os.execute("mkdir -p '" .. state_dir .. "'")
  local f = io.open(M.parked_file, "w")
  if not f then return end
  for address, p in pairs(parked) do
    f:write(string.format("%s %d %d\n", address, p.origin, p.target))
  end
  f:close()
end

-- Send gathered windows home where their monitor is back.
function M.restore()
  local mons = M.monitors()
  local parked = read_parked()
  local changed = false
  for address, p in pairs(parked) do
    if M.index_of(p.origin) < #mons then
      local win = hl.get_window("address:" .. address)
      if win and win.workspace and win.workspace.id == p.target and hl.get_workspace(p.origin) then
        hl.dispatch(hl.dsp.window.move({ window = win, workspace = tostring(p.origin), follow = false }))
      end
      parked[address] = nil
      changed = true
    elseif not hl.get_window("address:" .. address) then
      parked[address] = nil -- closed while undocked
      changed = true
    end
  end
  if changed then write_parked(parked) end
end

-- Pull windows from workspaces whose monitor is gone (index beyond the
-- current monitor count) into the same group on the last monitor. Runs on
-- every monitor change unless lockstep.gather_on_undock = false; by hand:
--   hyprctl repl 'lockstep.gather()'
function M.gather(skip_sync)
  local mons = M.monitors()
  if #mons == 0 then return end
  local parked = read_parked()
  local changed = false
  for _, ws in ipairs(hl.get_workspaces()) do
    if is_regular(ws) and M.index_of(ws.id) >= #mons then
      local target = M.workspace_id(M.group_of(ws.id), #mons - 1)
      for _, win in ipairs(ws:get_windows()) do
        -- A window gathered twice (3 monitors -> 2 -> 1) keeps its first origin.
        local prev = parked[win.address]
        parked[win.address] = { origin = prev and prev.origin or ws.id, target = target }
        changed = true
        hl.dispatch(hl.dsp.window.move({ window = win, workspace = tostring(target), follow = false }))
      end
    end
  end
  if changed then write_parked(parked) end
  if not skip_sync then M.sync() end
end

-- Idempotent: undock can fire removed + layout_changed, and a flapping dock
-- fires them over and over; each run converges on the same state.
function M.relayout()
  local ok, err = pcall(function()
    log("relayout: " .. #M.monitors() .. " monitor(s)")
    M.apply_rules()
    M.restore()
    M.place()
    if M.gather_on_undock then M.gather(true) end
    M.sync()
  end)
  if not ok then log("relayout failed: " .. tostring(err)) end
end

-- For `hyprctl dispatch 'lockstep.dispatcher(3)'` (bar clicks).
function M.dispatcher(group)
  return function() M.focus(tonumber(group) or 1) end
end

function M.status()
  local lines = { (M.enabled and "active" or "paused") .. ", group " .. tostring(M.current_group()) .. " (groups=" .. M.groups .. ", stride=" .. M.stride .. ")" }
  for i, mon in ipairs(M.monitors()) do
    local ws = mon.active_workspace
    table.insert(lines, string.format("  [%d] %-8s workspace %s", i - 1, mon.name, tostring(ws and ws.id)))
  end
  return table.concat(lines, "\n")
end

-- ---------------------------------------------------------------------------
-- Events

M.subscriptions = M.subscriptions or {}
for _, sub in ipairs(M.subscriptions) do
  pcall(function() sub:remove() end)
end
M.subscriptions = {}

local function subscribe(event, fn)
  table.insert(M.subscriptions, hl.on(event, function(...)
    local ok, err = pcall(fn, ...)
    if not ok then log(event .. " handler failed: " .. tostring(err)) end
  end))
end

subscribe("workspace.active", function(ws)
  if syncing or not is_regular(ws) then return end
  M.sync(M.group_of(ws.id))
end)

subscribe("monitor.added", M.relayout)
subscribe("monitor.removed", M.relayout)
subscribe("monitor.layout_changed", M.relayout)

-- ---------------------------------------------------------------------------
-- Keys: replace Omarchy's per-monitor workspace bindings

if M.bind_keys then
  for g = 1, math.min(M.groups, 10) do
    local key = "code:" .. tostring(g + 9)
    hl.unbind("SUPER + " .. key)
    hl.unbind("SUPER + SHIFT + " .. key)
    hl.unbind("SUPER + SHIFT + ALT + " .. key)
    o.bind("SUPER + " .. key, "Switch to workspace " .. g, function() M.focus(g) end)
    o.bind("SUPER + SHIFT + " .. key, "Move window to workspace " .. g, function() M.move_window(g, true) end)
    o.bind("SUPER + SHIFT + ALT + " .. key, "Move window silently to workspace " .. g, function() M.move_window(g, false) end)
  end

  hl.unbind("SUPER + TAB")
  hl.unbind("SUPER + SHIFT + TAB")
  hl.unbind("SUPER + CTRL + TAB")
  hl.unbind("SUPER + mouse_down")
  hl.unbind("SUPER + mouse_up")
  o.bind("SUPER + TAB", "Next workspace", function() M.focus_relative(1) end)
  o.bind("SUPER + SHIFT + TAB", "Previous workspace", function() M.focus_relative(-1) end)
  o.bind("SUPER + CTRL + TAB", "Former workspace", function() M.focus_previous() end)
  o.bind("SUPER + mouse_down", "Scroll active workspace forward", function() M.focus_relative(1) end)
  o.bind("SUPER + mouse_up", "Scroll active workspace backward", function() M.focus_relative(-1) end)

  -- Omarchy's SUPER+SHIFT+arrows swap windows, which never leaves a monitor.
  -- Hyprland's move dispatcher swaps within the monitor and, at the edge,
  -- carries the window over to the next monitor's active workspace — which
  -- is the same group, so the window stays "in your workspace".
  local directions = { LEFT = "l", RIGHT = "r", UP = "u", DOWN = "d" }
  local labels = { LEFT = "left", RIGHT = "right", UP = "up", DOWN = "down" }
  for key, dir in pairs(directions) do
    hl.unbind("SUPER + SHIFT + " .. key)
    o.bind("SUPER + SHIFT + " .. key, "Move window " .. labels[key] .. " (across monitors)", hl.dsp.window.move({ direction = dir }))
  end
end

-- ---------------------------------------------------------------------------
-- Go

hl.on("hyprland.start", function() pcall(M.relayout) end)
pcall(function()
  write_state(M.enabled)
  M.adopt()
  M.relayout()
end)

return M
