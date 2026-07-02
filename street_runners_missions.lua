--[[
Street Runners Missions — CSP online script
Checkpoint runs + drift zones + synced economy + per-zone leaderboards + shop.

Written against the CSP online-script surface (script.update/draw3D/drawUI,
ac.* / render.* / ui.* / web.*). CSP's Lua API shifts between builds — if a
call throws on load, the in-game Lua log names the line/function to fix.
]]

-- Replaced server-side (see economy-server's /script.lua route) when the
-- server's csp_extra_options.ini SCRIPT line uses the {SteamID} placeholder,
-- e.g. SCRIPT = "http://host:3000/script.lua?steamid={SteamID}". If the
-- script is instead loaded as a static file, this stays literal and the
-- script falls back to a locally-generated id (see identity section below).
local INJECTED_STEAM_ID = '__STEAM_ID__'

local CONFIG = {
  showEditor = true,          -- flip to false once ROUTES/DRIFT_ZONES are baked in and re-host
  startingCash = 5000,
  checkpointRadius = 8,       -- meters
  economyUrl = 'https://street-runners-economy-production.up.railway.app',  -- blank = local-only mode
  apiKey = '',                -- must match ECONOMY_API_KEY on the server, if set
  playerName = 'Runner',      -- shown on leaderboards until the player renames via the editor
  drift = {
    minAngle = 15,            -- degrees of slip before scoring starts
    spinAngle = 100,          -- degrees of slip that counts as a spin (wipes combo)
    comboGrowPerSec = 0.35,
    comboMax = 6,
    straightenGrace = 1.2,    -- seconds allowed below minAngle before combo resets
    scoreScale = 1.0,
  },
}

-- Paste captured routes/zones here (via the editor's Copy buttons) and set showEditor = false.
local ROUTES = {
  -- { name = "Downtown Sprint", target = 45, baseReward = 500, bonusPerSecond = 25,
  --   points = { vec3(0, 0, 0), vec3(120, 0, 40) } },
}

local DRIFT_ZONES = {
  -- { name = "Warehouse Corridor", width = 8, payoutPer = 2,
  --   points = { vec3(0, 0, 0), vec3(80, 0, 20), vec3(140, 0, 90) } },
}

-- Spend sink: cosmetic titles (permanent) and payout boosts (consumable).
local SHOP_ITEMS = {
  titles = {
    { id = 'rookie', name = 'Rookie Runner', price = 0 },
    { id = 'ghost', name = '街道幽霊 Street Ghost', price = 15000 },
    { id = 'legend', name = 'Street Legend', price = 50000 },
    { id = 'king', name = '走り屋の王 Drift King', price = 100000 },
  },
  boosts = {
    { id = 'boost_2x_10m', name = '2x Payout — 10 min', price = 5000, durationSec = 600, multiplier = 2 },
    { id = 'boost_3x_5m', name = '3x Payout — 5 min', price = 8000, durationSec = 300, multiplier = 3 },
  },
}

---------------------------------------------------------------------------
-- Persistent storage & identity
---------------------------------------------------------------------------

-- v3: added title/boost fields and real-SteamID keying — bumped the storage
-- key so old v2 saves (random local GUID identity) don't collide with it.
local storage = ac.storage({
  cash = CONFIG.startingCash,
  playerId = '',
  playerName = CONFIG.playerName,
  ownedTitlesCsv = 'rookie',
  equippedTitle = 'rookie',
  boostId = '',
  boostExpiry = 0,
  boostMultiplier = 1,
}, 'street_runners_v3')

local function isValidSteamId(s)
  return type(s) == 'string' and s:match('^%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d+$') ~= nil
end

if isValidSteamId(INJECTED_STEAM_ID) then
  storage.playerId = INJECTED_STEAM_ID -- real Steam64 id, stable across reinstalls
elseif storage.playerId == '' then
  -- Static hosting fallback: no server-injected id available, so mint a
  -- per-install random one. Trust-based either way; this just isn't tied
  -- to a real Steam identity.
  math.randomseed(os.time() + (ac.getCar(0) and ac.getCar(0).index or 0))
  storage.playerId = string.format('%08x-%04x-%04x', os.time(), math.random(0, 0xFFFF), math.random(0, 0xFFFF))
end

---------------------------------------------------------------------------
-- Small math helpers
---------------------------------------------------------------------------

local function dist2D(a, b)
  local dx, dz = a.x - b.x, a.z - b.z
  return math.sqrt(dx * dx + dz * dz)
end

-- Distance from point p to segment a-b, ground plane only.
local function pointSegmentDist(p, a, b)
  local abx, abz = b.x - a.x, b.z - a.z
  local apx, apz = p.x - a.x, p.z - a.z
  local abLenSq = abx * abx + abz * abz
  local t = abLenSq > 0 and math.max(0, math.min(1, (apx * abx + apz * abz) / abLenSq)) or 0
  local cx, cz = a.x + abx * t, a.z + abz * t
  local dx, dz = p.x - cx, p.z - cz
  return math.sqrt(dx * dx + dz * dz)
end

local function nearestCorridorDist(p, points)
  if #points < 2 then return math.huge end
  local best = math.huge
  for i = 1, #points - 1 do
    best = math.min(best, pointSegmentDist(p, points[i], points[i + 1]))
  end
  return best
end

-- Slip angle in degrees between car heading (look) and velocity direction.
local function slipAngleDeg(car)
  local vel = car.velocity
  local speed = math.sqrt(vel.x * vel.x + vel.z * vel.z)
  if speed < 0.5 then return 0 end
  local look = car.look
  local dot = (look.x * vel.x + look.z * vel.z) / speed
  dot = math.max(-1, math.min(1, dot))
  return math.deg(math.acos(dot))
end

---------------------------------------------------------------------------
-- Titles & boosts (the spend sink)
---------------------------------------------------------------------------

local function ownedTitlesList()
  local list = {}
  for id in string.gmatch(storage.ownedTitlesCsv or 'rookie', '[^,]+') do
    table.insert(list, id)
  end
  return list
end

local function ownsTitle(id)
  for _, t in ipairs(ownedTitlesList()) do
    if t == id then return true end
  end
  return false
end

local function addOwnedTitle(id)
  if ownsTitle(id) then return end
  storage.ownedTitlesCsv = (storage.ownedTitlesCsv ~= '' and (storage.ownedTitlesCsv .. ',' .. id)) or id
end

local function titleDisplayName(id)
  for _, t in ipairs(SHOP_ITEMS.titles) do
    if t.id == id then return t.name end
  end
  return id
end

local function activeBoostMultiplier()
  if storage.boostExpiry and storage.boostExpiry > os.time() then
    return storage.boostMultiplier or 1
  end
  return 1
end

local function activeBoostRemaining()
  return math.max(0, (storage.boostExpiry or 0) - os.time())
end

---------------------------------------------------------------------------
-- Economy sync (wrapped in pcall — falls back to local-only silently)
---------------------------------------------------------------------------

local economy = { leaderboardCash = {}, driftLeaderboards = {} }

local function economyEnabled()
  return CONFIG.economyUrl ~= nil and CONFIG.economyUrl ~= ''
end

-- Headers for a request. Always send a table (CSP's web.get/post take
-- headers as the 2nd arg); include JSON content-type for posts and the
-- optional shared secret.
local function economyHeaders(json)
  local h = {}
  if json then h['Content-Type'] = 'application/json' end
  if CONFIG.apiKey and CONFIG.apiKey ~= '' then h['x-economy-key'] = CONFIG.apiKey end
  return h
end

-- Minimal JSON encoder for our flat request bodies (string/number/boolean
-- values only), so we don't depend on a JSON.stringify existing in the CSP
-- build and can send a proper application/json string body.
local function jsonEncode(t)
  local parts = {}
  for k, v in pairs(t) do
    local tv, val = type(v)
    if tv == 'number' or tv == 'boolean' then
      val = tostring(v)
    else
      val = '"' .. tostring(v):gsub('\\', '\\\\'):gsub('"', '\\"') .. '"'
    end
    parts[#parts + 1] = '"' .. tostring(k) .. '":' .. val
  end
  return '{' .. table.concat(parts, ',') .. '}'
end

-- Pure-Lua percent-encoding so we don't depend on ac.encodeURIComponent
-- existing (it's called from the update loop for zone names, which may be
-- non-ASCII). Byte-wise, which is correct for UTF-8.
local function urlEncode(s)
  return (tostring(s):gsub('[^%w%-_%.~]', function(c)
    return string.format('%%%02X', string.byte(c))
  end))
end

-- Catches JSON being absent/renamed as well as a parse failure — indexing a
-- nil JSON would otherwise throw outside pcall's reach.
local function safeJsonParse(s)
  local ok, res = pcall(function() return JSON.parse(s) end)
  if ok then return res end
  return nil
end

-- CSP web API: web.get(url, headers, callback) and
-- web.post(url, headers, dataString, callback). Body is a JSON string.
local function economyGet(path, callback)
  if not economyEnabled() or web == nil then return end
  pcall(web.get, CONFIG.economyUrl .. path, economyHeaders(false), callback)
end

local function economyPost(path, body, callback)
  if not economyEnabled() or web == nil then return end
  pcall(web.post, CONFIG.economyUrl .. path, economyHeaders(true), jsonEncode(body), callback)
end

local function economyEarn(amount, source)
  local applied = amount
  if applied > 0 then applied = math.floor(applied * activeBoostMultiplier()) end
  storage.cash = storage.cash + applied
  economyPost('/players/' .. storage.playerId .. '/earn',
    { amount = applied, source = source, name = storage.playerName, title = storage.equippedTitle },
    function(err, response) end)
end

local function economyRefreshCashLeaderboard()
  economyGet('/leaderboard/cash?limit=10', function(err, response)
    if err or not response then return end
    local data = safeJsonParse(response.body)
    if data then economy.leaderboardCash = data end
  end)
end

local function economyReportDriftRun(zone, score, comboMax)
  economyPost('/drift/runs',
    {
      zoneId = zone.name,
      zoneName = zone.name,
      playerId = storage.playerId,
      playerName = storage.playerName,
      score = score,
      comboMax = comboMax,
    },
    function(err, response) end)
end

local function economyRefreshDriftLeaderboard(zoneName)
  economyGet('/drift/leaderboard/' .. urlEncode(zoneName) .. '?limit=10', function(err, response)
    if err or not response then return end
    local data = safeJsonParse(response.body)
    if data then economy.driftLeaderboards[zoneName] = data end
  end)
end

---------------------------------------------------------------------------
-- Shop actions
---------------------------------------------------------------------------

local shopMessage, shopMessageTimer = '', 0

local function shopSetMessage(text)
  shopMessage, shopMessageTimer = text, 3
end

local function shopBuyTitle(item)
  if ownsTitle(item.id) then shopSetMessage('Already owned.'); return end
  if storage.cash < item.price then shopSetMessage('Not enough cash.'); return end
  economyEarn(-item.price, 'shop:title:' .. item.id)
  addOwnedTitle(item.id)
  shopSetMessage('Purchased ' .. item.name .. '.')
end

local function shopEquipTitle(id)
  if ownsTitle(id) then storage.equippedTitle = id end
end

local function shopBuyBoost(item)
  if storage.cash < item.price then shopSetMessage('Not enough cash.'); return end
  economyEarn(-item.price, 'shop:boost:' .. item.id)
  storage.boostId = item.id
  storage.boostExpiry = os.time() + item.durationSec
  storage.boostMultiplier = item.multiplier
  shopSetMessage('Boost active: ' .. item.name .. '.')
end

---------------------------------------------------------------------------
-- Checkpoint run state
---------------------------------------------------------------------------

-- Monotonic seconds accumulated from dt each frame. os.clock() measures CPU
-- time (not wall-clock) in standard Lua, so it's the wrong basis for a race
-- timer; this is guaranteed to track real elapsed time.
local sessionTime = 0

local run = { active = false, route = nil, index = 0, startTime = 0 }

local function startRoute(route)
  run.active = true
  run.route = route
  run.index = 1
  run.startTime = sessionTime
end

local function finishRoute()
  local elapsed = sessionTime - run.startTime
  local bonus = math.max(0, (run.route.target - elapsed) * run.route.bonusPerSecond)
  local payout = run.route.baseReward + math.floor(bonus)
  economyEarn(payout, 'checkpoint:' .. run.route.name)
  run.active = false
  run.route = nil
end

---------------------------------------------------------------------------
-- Drift zone state
---------------------------------------------------------------------------

local drift = {
  active = false, zone = nil, score = 0, combo = 1, angle = 0,
  state = 'idle', -- idle | drifting | spin
  belowMinTimer = 0, comboMax = 1,
}

local function driftBank()
  if drift.score > 0 then
    local payout = math.floor(drift.score * drift.zone.payoutPer)
    economyEarn(payout, 'drift:' .. drift.zone.name)
    economyReportDriftRun(drift.zone, drift.score, drift.comboMax)
    economyRefreshDriftLeaderboard(drift.zone.name)
  end
  drift.active, drift.zone, drift.score, drift.combo, drift.comboMax = false, nil, 0, 1, 1
  drift.state = 'idle'
end

local function updateDriftZones(car, dt)
  local inAnyZone = false
  for _, zone in ipairs(DRIFT_ZONES) do
    if nearestCorridorDist(car.position, zone.points) <= zone.width / 2 then
      inAnyZone = true
      if not drift.active or drift.zone ~= zone then
        if drift.active and drift.zone ~= zone then driftBank() end
        drift.active, drift.zone, drift.score, drift.combo, drift.comboMax = true, zone, 0, 1, 1
        economyRefreshDriftLeaderboard(zone.name)
      end
      break
    end
  end

  if drift.active and not inAnyZone then
    driftBank()
    return
  end
  if not drift.active then return end

  local angle = slipAngleDeg(car)
  local speed = car.speedKmh
  drift.angle = angle

  if angle >= CONFIG.drift.spinAngle then
    drift.state = 'spin'
    drift.combo = 1
    drift.belowMinTimer = 0
  elseif angle >= CONFIG.drift.minAngle then
    drift.state = 'drifting'
    drift.belowMinTimer = 0
    drift.combo = math.min(CONFIG.drift.comboMax, drift.combo + CONFIG.drift.comboGrowPerSec * dt)
    drift.comboMax = math.max(drift.comboMax, drift.combo)
    local points = (angle * speed * drift.combo * CONFIG.drift.scoreScale) * dt * 0.05
    drift.score = drift.score + points
  else
    drift.belowMinTimer = drift.belowMinTimer + dt
    if drift.belowMinTimer > CONFIG.drift.straightenGrace then
      drift.state = 'idle'
      drift.combo = 1
    end
  end
end

---------------------------------------------------------------------------
-- Checkpoint update
---------------------------------------------------------------------------

local function updateCheckpoints(car)
  if not run.active then return end
  local target = run.route.points[run.index]
  if dist2D(car.position, target) <= CONFIG.checkpointRadius then
    if run.index >= #run.route.points then
      finishRoute()
    else
      run.index = run.index + 1
    end
  end
end

---------------------------------------------------------------------------
-- Editor (route + zone capture, shared buffer)
---------------------------------------------------------------------------

local editor = {
  mode = 'route',        -- 'route' | 'zone'
  points = {},
  name = 'New Route',
  target = 45, baseReward = 500, bonusPerSecond = 25,   -- route fields
  width = 8, payoutPer = 2,                              -- zone fields
}

local function editorCapture(car)
  table.insert(editor.points, vec3(car.position.x, car.position.y, car.position.z))
end

local function editorClear()
  editor.points = {}
end

local function serializePoints(points)
  local parts = {}
  for _, p in ipairs(points) do
    table.insert(parts, string.format('vec3(%.2f, %.2f, %.2f)', p.x, p.y, p.z))
  end
  return table.concat(parts, ', ')
end

local function editorCopyRoute()
  if #editor.points < 2 then return end
  local snippet = string.format(
    '{ name = "%s", target = %d, baseReward = %d, bonusPerSecond = %d, points = { %s } },',
    editor.name, editor.target, editor.baseReward, editor.bonusPerSecond, serializePoints(editor.points))
  ac.setClipboardText(snippet)
  ac.log('[street_runners] route snippet:\n' .. snippet)
end

local function editorCopyZone()
  if #editor.points < 2 then return end
  local snippet = string.format(
    '{ name = "%s", width = %d, payoutPer = %d, points = { %s } },',
    editor.name, editor.width, editor.payoutPer, serializePoints(editor.points))
  ac.setClipboardText(snippet)
  ac.log('[street_runners] zone snippet:\n' .. snippet)
end

---------------------------------------------------------------------------
-- Keyboard controls
---------------------------------------------------------------------------
-- The online-script UI overlay renders but doesn't receive mouse clicks on
-- many CSP builds, so the editor is driven by hotkeys read here instead.
-- Ctrl + number to avoid clashing with driving binds. If the key-read API
-- isn't present on a build, reads just no-op and the panel's CTRL indicator
-- stays "up" — which tells us to switch input methods.
local VK = { CTRL = 0x11, N1 = 0x31, N2 = 0x32, N3 = 0x33, N4 = 0x34, N5 = 0x35, N6 = 0x36,
  LEFT = 0x25, UP = 0x26, RIGHT = 0x27, DOWN = 0x28, PGUP = 0x21, PGDN = 0x22 }
local keyState = {}
local ctrlDown = false
local editorMessage, editorMessageTimer = '', 0

-- Per-panel screen offset from its default position (drag-to-move + Ctrl+arrows
-- both write here; panel() reads it). Shared across the update and draw halves.
local winOffset = {}
local function winOff(id)
  if not winOffset[id] then winOffset[id] = { x = 0, y = 0 } end
  return winOffset[id]
end

-- HUD scale factor (Ctrl+PageUp/Down). Applied via ui.setWindowFontScale in
-- panel(); scaleWorks records whether that native call exists on this build.
local uiScale = 1.0
local scaleWorks = false

-- App window open state — declared here because the hotkey handler toggles it.
local appOpen = false

local function editorSetMessage(t) editorMessage, editorMessageTimer = t, 3 end

local function rawKeyDown(vk)
  local d = false
  if not pcall(function() d = ac.isKeyDown(vk) and true or false end) then
    pcall(function() d = ui.keyboardButtonDown(vk) and true or false end)
  end
  return d
end

local function keyEdge(vk)
  local down = rawKeyDown(vk)
  local was = keyState[vk] or false
  keyState[vk] = down
  return down and not was
end

local function updateEditorHotkeys(car, dt)
  ctrlDown = rawKeyDown(VK.CTRL)
  -- Compute edges every frame so held-state stays current regardless of Ctrl.
  local e1, e2, e3, e4, e5, e6 =
    keyEdge(VK.N1), keyEdge(VK.N2), keyEdge(VK.N3), keyEdge(VK.N4), keyEdge(VK.N5), keyEdge(VK.N6)

  -- Ctrl+arrows nudge the main HUD; Ctrl+PageUp/Down scale the whole HUD.
  if ctrlDown then
    local o = winOff('STREET RUNNERS')
    local step = 260 * (dt or 0.016)
    if rawKeyDown(VK.LEFT)  then o.x = o.x - step end
    if rawKeyDown(VK.RIGHT) then o.x = o.x + step end
    if rawKeyDown(VK.UP)    then o.y = o.y - step end
    if rawKeyDown(VK.DOWN)  then o.y = o.y + step end
    local sstep = 0.8 * (dt or 0.016)
    if rawKeyDown(VK.PGUP) then uiScale = math.min(2.2, uiScale + sstep) end
    if rawKeyDown(VK.PGDN) then uiScale = math.max(0.6, uiScale - sstep) end
  end

  if ctrlDown and e6 then
    appOpen = not appOpen
    if appOpen then
      economyRefreshCashLeaderboard()
      if drift.active then economyRefreshDriftLeaderboard(drift.zone.name) end
    end
  end

  if not CONFIG.showEditor or not ctrlDown then return end
  if e1 then editorCapture(car); editorSetMessage('Captured point ' .. #editor.points) end
  if e4 then editor.mode = (editor.mode == 'route') and 'zone' or 'route'; editorSetMessage('Mode: ' .. editor.mode) end
  if e5 then editorClear(); editorSetMessage('Cleared points') end
  if e2 then
    if #editor.points < 2 then
      editorSetMessage('Need 2+ points')
    elseif editor.mode == 'route' then
      startRoute({ name = editor.name, target = editor.target, baseReward = editor.baseReward,
        bonusPerSecond = editor.bonusPerSecond, points = editor.points })
      editorSetMessage('Test drive started')
    else
      table.insert(DRIFT_ZONES, { name = editor.name, width = editor.width, payoutPer = editor.payoutPer, points = editor.points })
      editorSetMessage('Test zone added')
    end
  end
  if e3 then
    if editor.mode == 'route' then editorCopyRoute() else editorCopyZone() end
    editorSetMessage('Copied to clipboard + log')
  end
end

---------------------------------------------------------------------------
-- script.update
---------------------------------------------------------------------------

local idleRefreshTimer = 0

-- Auto-fill the display name from the in-game driver (Steam) name while it's
-- still the default, so the leaderboard shows real names instead of "Runner".
-- Once set to a real name it stops re-fetching. Falls back silently if the
-- API isn't present on a build.
local function ensureDisplayName()
  if storage.playerName ~= '' and storage.playerName ~= CONFIG.playerName then return end
  local name
  if not pcall(function() name = ac.getDriverName(0) end) then return end
  if type(name) == 'string' and name ~= '' then storage.playerName = name end
end

function script.update(dt)
  sessionTime = sessionTime + dt

  local car = ac.getCar(0)
  if not car then return end

  ensureDisplayName()
  updateCheckpoints(car)
  updateDriftZones(car, dt)
  updateEditorHotkeys(car, dt)

  if shopMessageTimer > 0 then shopMessageTimer = shopMessageTimer - dt end
  if editorMessageTimer > 0 then editorMessageTimer = editorMessageTimer - dt end

  if not run.active and not drift.active then
    idleRefreshTimer = idleRefreshTimer + dt
    if idleRefreshTimer > 15 then
      idleRefreshTimer = 0
      economyRefreshCashLeaderboard()
    end
  end
end

---------------------------------------------------------------------------
-- script.draw3D — checkpoint gates & drift corridors
---------------------------------------------------------------------------

function script.draw3D()
  pcall(function()
    render.setDepthMode(render.DepthMode.ReadOnlyLessEqual)

    for _, route in ipairs(ROUTES) do
      for _, p in ipairs(route.points) do
        render.debugSphere(p, 1.2, rgbm(0.1, 1, 0.4, 0.6))
      end
    end
    if run.active then
      render.debugSphere(run.route.points[run.index], 1.6, rgbm(1, 1, 0, 0.9))
    end

    for _, zone in ipairs(DRIFT_ZONES) do
      for i = 1, #zone.points - 1 do
        render.debugLine(zone.points[i], zone.points[i + 1], rgbm(1, 0.2, 0.6, 0.7))
      end
    end

    for _, p in ipairs(editor.points) do
      render.debugSphere(p, 1, rgbm(0.2, 0.7, 1, 0.8))
    end
  end)
end

---------------------------------------------------------------------------
-- script.drawUI — HUD + editor + leaderboards + shop
---------------------------------------------------------------------------

-- Street Runners neon palette
local NEON    = rgbm(0.30, 1.00, 0.55, 1)   -- primary green
local CYAN    = rgbm(0.35, 0.90, 1.00, 1)
local MAGENTA = rgbm(1.00, 0.25, 0.62, 1)
local GOLD    = rgbm(1.00, 0.82, 0.28, 1)
local SILVER  = rgbm(0.82, 0.86, 0.92, 1)
local BRONZE  = rgbm(0.90, 0.58, 0.32, 1)
local WHITE   = rgbm(0.96, 0.99, 0.96, 1)
local DIM     = rgbm(0.52, 0.60, 0.58, 1)
local REDC    = rgbm(1.00, 0.30, 0.30, 1)
local GREEN   = NEON
local PANEL_BG = rgbm(0.02, 0.035, 0.03, 0.92)

local function formatDuration(sec)
  return string.format('%d:%02d', math.floor(sec / 60), math.floor(sec % 60))
end

-- Thousands-separated integer, e.g. 12345 -> "12,345".
local function comma(n)
  n = math.floor(tonumber(n) or 0)
  local sign = n < 0 and '-' or ''
  local out = tostring(math.abs(n)):reverse():gsub('(%d%d%d)', '%1,'):reverse()
  if out:sub(1, 1) == ',' then out = out:sub(2) end
  return sign .. out
end

local function money(n)
  local c = comma(n)
  if c:sub(1, 1) == '-' then return '-$' .. c:sub(2) end
  return '$' .. c
end

-- Bar meter out of solid/light blocks.
local function meter(frac, segs)
  frac = math.max(0, math.min(1, frac))
  local f = math.floor(frac * segs + 0.5)
  return string.rep('█', f) .. string.rep('░', segs - f)
end

-- Header accent colour shimmering between magenta and cyan.
local function accentPulse()
  local p = 0.5 + 0.5 * math.sin(sessionTime * 4)
  return rgbm(0.4 + 0.6 * (1 - p), 0.3 + 0.6 * p, 0.7 + 0.3 * p, 1)
end

local function rankColor(i)
  if i == 1 then return GOLD elseif i == 2 then return SILVER elseif i == 3 then return BRONZE end
  return DIM
end

local function carSpeed()
  local s = 0
  pcall(function() s = ac.getCar(0).speedKmh end)
  return s
end

-- toolWindow gives a solid-background interactive window but is fixed in place
-- (no native drag). So we position it ourselves from a per-panel offset and
-- move that offset when the window is hovered and the left mouse button is
-- dragged — plus Ctrl+arrows for the main HUD. Falls back to the transparent
-- overlay if a build restricts tool windows, so panels never vanish.
local function mouseDragDelta()
  local d
  if not pcall(function()
    if ui.windowHovered() and ui.mouseDown(ui.MouseButton.Left) then d = ui.mouseDelta() end
  end) then return nil end
  return d
end

-- Scale the current window's text; records support so we only grow the window
-- box when the font actually scales (otherwise a bigger box with same-size
-- text looks broken).
local function applyFontScale(s)
  if pcall(function() ui.setWindowFontScale(s) end) then scaleWorks = true end
end

local function panel(id, defaultPos, size, fn)
  local o = winOff(id)
  local pos = vec2(defaultPos.x + o.x, defaultPos.y + o.y)
  local sz = scaleWorks and vec2(size.x * uiScale, size.y * uiScale) or size
  local body = function()
    applyFontScale(uiScale)
    fn()
    local d = mouseDragDelta()
    if d then o.x = o.x + d.x; o.y = o.y + d.y end
  end
  if not pcall(function() ui.toolWindow(id, pos, sz, false, true, body) end) then
    pcall(function()
      ui.beginTransparentWindow('t_' .. id, pos, sz, true)
      ui.pushStyleColor(ui.StyleColor.WindowBg, PANEL_BG)
      body()
      ui.popStyleColor()
      ui.endTransparentWindow()
    end)
  end
end

-- Compact always-on driving HUD (cash + live run/drift state).
local function drawMainHUD()
  panel('STREET RUNNERS', vec2(24, ui.windowSize().y - 210), vec2(300, 0), function()
  ui.textColored('街道走者', NEON); ui.sameLine()
  ui.textColored('«' .. titleDisplayName(storage.equippedTitle):upper() .. '»', GOLD)
  ui.textColored('BALANCE  ', DIM); ui.sameLine(); ui.textColored(money(storage.cash), WHITE)

  if activeBoostMultiplier() > 1 then
    ui.textColored(string.format('» %dx BOOST  %s', storage.boostMultiplier, formatDuration(activeBoostRemaining())), MAGENTA)
  end

  if run.active then
    ui.separator()
    ui.textColored(string.format('CHECKPOINT  %d / %d', run.index, #run.route.points), CYAN)
    ui.textColored(string.format('TIME  %.1fs', sessionTime - run.startTime), WHITE)
  end

  if drift.active then
    ui.separator()
    local stateCol = drift.state == 'spin' and REDC or (drift.state == 'drifting' and NEON or DIM)
    ui.textColored('» ' .. drift.zone.name:upper(), MAGENTA)
    ui.textColored('SCORE  ' .. comma(drift.score), WHITE)
    local frac = drift.combo / CONFIG.drift.comboMax
    local comboCol = frac > 0.66 and MAGENTA or (frac > 0.33 and GOLD or NEON)
    ui.textColored(meter(frac, 10), comboCol); ui.sameLine()
    ui.textColored(string.format('x%.1f', drift.combo), comboCol)
    ui.textColored(string.format('%s   %d°   %d km/h', drift.state:upper(), math.floor(drift.angle), math.floor(carSpeed())), stateCol)
  end

  ui.separator()
  ui.textColored('Ctrl+6 open app  ·  drag to move', DIM)
  end)
end

---------------------------------------------------------------------------
-- App tabs
---------------------------------------------------------------------------

local function missionsTab()
  ui.textColored('» ROUTES', CYAN)
  if #ROUTES == 0 then
    ui.textColored('   No routes yet — capture some in the Editor tab.', DIM)
  else
    for i, r in ipairs(ROUTES) do
      if ui.button('Start##r' .. i) then startRoute(r); appOpen = false end
      ui.sameLine(); ui.textColored(r.name, WHITE)
      ui.sameLine(); ui.textColored(money(r.baseReward) .. ' + time bonus', GOLD)
    end
  end
  ui.separator()
  ui.textColored('» DRIFT ZONES', MAGENTA)
  if #DRIFT_ZONES == 0 then
    ui.textColored('   No zones yet — capture some in the Editor tab.', DIM)
  else
    for _, z in ipairs(DRIFT_ZONES) do
      ui.textColored('   ' .. z.name, WHITE); ui.sameLine()
      ui.textColored('$' .. z.payoutPer .. '/pt · drive in to start', DIM)
    end
  end
end

local function shopTab()
  ui.textColored('» TITLES', CYAN)
  for _, item in ipairs(SHOP_ITEMS.titles) do
    local owned = ownsTitle(item.id)
    if storage.equippedTitle == item.id then
      ui.textColored('EQUIPPED', NEON)
    elseif owned then
      if ui.button('Equip##' .. item.id) then shopEquipTitle(item.id) end
    else
      if ui.button('Buy ' .. money(item.price) .. '##' .. item.id) then shopBuyTitle(item) end
    end
    ui.sameLine(); ui.textColored(item.name, owned and WHITE or DIM)
  end
  ui.separator()
  ui.textColored('» BOOSTS', CYAN)
  for _, item in ipairs(SHOP_ITEMS.boosts) do
    if ui.button('Buy ' .. money(item.price) .. '##' .. item.id) then shopBuyBoost(item) end
    ui.sameLine(); ui.textColored(item.name, WHITE)
  end
  if activeBoostMultiplier() > 1 then
    ui.separator()
    ui.textColored(string.format('Active: %dx for %s', storage.boostMultiplier, formatDuration(activeBoostRemaining())), MAGENTA)
  end
  if shopMessageTimer > 0 then ui.textColored('» ' .. shopMessage, NEON) end
end

local function leaderboardTab()
  if drift.active then
    ui.textColored('» ZONE BEST · ' .. drift.zone.name:upper(), MAGENTA)
    ui.separator()
    local rows = economy.driftLeaderboards[drift.zone.name] or {}
    if #rows == 0 then
      ui.textColored(economyEnabled() and 'No runs yet.' or 'Economy offline.', DIM)
    else
      for i, row in ipairs(rows) do
        ui.textColored(tostring(i) .. '.', rankColor(i)); ui.sameLine()
        ui.textColored(row.playerName or '???', WHITE); ui.sameLine()
        ui.textColored(comma(row.score or 0), NEON)
      end
    end
  else
    ui.textColored('» TOP RUNNERS', NEON)
    ui.separator()
    if #economy.leaderboardCash == 0 then
      ui.textColored(economyEnabled() and 'Loading...' or 'Economy offline.', DIM)
    else
      for i, row in ipairs(economy.leaderboardCash) do
        ui.textColored(tostring(i) .. '.', rankColor(i)); ui.sameLine()
        ui.textColored(row.name or '???', WHITE)
        if row.title and row.title ~= '' and row.title ~= 'rookie' then
          ui.sameLine(); ui.textColored('«' .. titleDisplayName(row.title) .. '»', GOLD)
        end
        ui.sameLine(); ui.textColored(money(row.balance or 0), NEON)
      end
    end
  end
end

local function editorTab()
  if ui.button((editor.mode == 'route' and '[ ROUTE ]' or 'ROUTE') .. '##emr') then editor.mode = 'route' end
  ui.sameLine()
  if ui.button((editor.mode == 'zone' and '[ ZONE ]' or 'ZONE') .. '##emz') then editor.mode = 'zone' end
  ui.sameLine(); ui.textColored('points: ' .. #editor.points, DIM)
  ui.separator()

  if ui.button('Capture point##ec') then editorCapture(ac.getCar(0)); editorSetMessage('Captured ' .. #editor.points) end
  ui.sameLine()
  if ui.button('Clear##ecl') then editorClear() end
  if editor.mode == 'route' then
    if ui.button('Test drive##et') then
      if #editor.points >= 2 then
        startRoute({ name = editor.name, target = editor.target, baseReward = editor.baseReward,
          bonusPerSecond = editor.bonusPerSecond, points = editor.points })
        appOpen = false
      else editorSetMessage('Need 2+ points') end
    end
    ui.sameLine()
    if ui.button('Copy route##ecp') then editorCopyRoute(); editorSetMessage('Copied to clipboard + log') end
  else
    if ui.button('Test zone##etz') then
      if #editor.points >= 2 then
        table.insert(DRIFT_ZONES, { name = editor.name, width = editor.width, payoutPer = editor.payoutPer, points = editor.points })
      else editorSetMessage('Need 2+ points') end
    end
    ui.sameLine()
    if ui.button('Copy zone##ecpz') then editorCopyZone(); editorSetMessage('Copied to clipboard + log') end
  end
  ui.separator()
  ui.textColored('While driving:  Ctrl+1 capture · Ctrl+2 test · Ctrl+3 copy · Ctrl+4 mode', DIM)
  if editorMessageTimer > 0 then ui.textColored('» ' .. editorMessage, GOLD) end
end

local function drawApp()
  if not appOpen then return end
  panel('STREET RUNNERS APP', vec2(360, 70), vec2(600, 440), function()
    ui.textColored('街道走者 STREET RUNNERS', NEON)
    ui.sameLine(); ui.textColored('   ' .. money(storage.cash), GOLD)
    ui.sameLine(); ui.textColored('   «' .. titleDisplayName(storage.equippedTitle):upper() .. '»', CYAN)
    ui.separator()

    local ok = pcall(function()
      ui.tabBar('sr_tabs', function()
        ui.tabItem('MISSIONS', missionsTab)
        ui.tabItem('SHOP', shopTab)
        ui.tabItem('LEADERBOARD', leaderboardTab)
        if CONFIG.showEditor then ui.tabItem('EDITOR', editorTab) end
      end)
    end)
    if not ok then
      -- No tab bar on this build: stack the sections instead.
      missionsTab(); ui.separator(); shopTab(); ui.separator(); leaderboardTab()
      if CONFIG.showEditor then ui.separator(); editorTab() end
    end
  end)
end

function script.drawUI()
  pcall(drawMainHUD)
  pcall(drawApp)
end
