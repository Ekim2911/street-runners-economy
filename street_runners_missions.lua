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

local function economyHeaders()
  if CONFIG.apiKey and CONFIG.apiKey ~= '' then
    return { ['x-economy-key'] = CONFIG.apiKey }
  end
  return nil
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

-- CSP's web.* header support varies by build, so try the (url, headers,
-- ...) overload first and fall back to the plain form if that pcall fails.
-- (If apiKey is set but the header overload is unsupported, the fallback
-- sends no key and the server 401s — the callback just leaves us in local
-- mode, which is the safe degradation.)
local function economyGet(path, callback)
  if not economyEnabled() or web == nil then return end
  local headers = economyHeaders()
  local url = CONFIG.economyUrl .. path
  local ok = headers and pcall(web.get, url, headers, callback)
  if not ok then pcall(web.get, url, callback) end
end

local function economyPost(path, body, callback)
  if not economyEnabled() or web == nil then return end
  local headers = economyHeaders()
  local url = CONFIG.economyUrl .. path
  local ok = headers and pcall(web.post, url, headers, body, callback)
  if not ok then pcall(web.post, url, body, callback) end
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
local VK = { CTRL = 0x11, N1 = 0x31, N2 = 0x32, N3 = 0x33, N4 = 0x34, N5 = 0x35, N6 = 0x36 }
local keyState = {}
local ctrlDown = false
local editorMessage, editorMessageTimer = '', 0

-- Panel visibility — declared here (not in drawUI) because the hotkey handler
-- below toggles the leaderboard.
local showLeaderboard = false
local showShop = false

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

local function updateEditorHotkeys(car)
  ctrlDown = rawKeyDown(VK.CTRL)
  -- Compute edges every frame so held-state stays current regardless of Ctrl.
  local e1, e2, e3, e4, e5, e6 =
    keyEdge(VK.N1), keyEdge(VK.N2), keyEdge(VK.N3), keyEdge(VK.N4), keyEdge(VK.N5), keyEdge(VK.N6)

  if ctrlDown and e6 then
    showLeaderboard = not showLeaderboard
    if showLeaderboard then
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

function script.update(dt)
  sessionTime = sessionTime + dt

  local car = ac.getCar(0)
  if not car then return end

  updateCheckpoints(car)
  updateDriftZones(car, dt)
  updateEditorHotkeys(car)

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

local GREEN = rgbm(0.15, 0.9, 0.45, 1)
local PANEL_BG = rgbm(0.03, 0.05, 0.04, 0.85)

local function formatDuration(sec)
  return string.format('%d:%02d', math.floor(sec / 60), math.floor(sec % 60))
end

local function drawMainHUD()
  ui.beginTransparentWindow('sr_hud', vec2(20, ui.windowSize().y - 260), vec2(300, 230), true)
  ui.pushStyleColor(ui.StyleColor.WindowBg, PANEL_BG)
  ui.textColored('街道走者  STREET RUNNERS', GREEN)
  ui.text('[' .. titleDisplayName(storage.equippedTitle) .. ']')
  ui.separator()
  ui.text(string.format('Cash: $%d', storage.cash))

  if activeBoostMultiplier() > 1 then
    ui.textColored(string.format('BOOST x%d — %s left', storage.boostMultiplier, formatDuration(activeBoostRemaining())), GREEN)
  end

  if run.active then
    ui.textColored(string.format('Checkpoint %d/%d', run.index, #run.route.points), GREEN)
    ui.text(string.format('Time: %.1fs', sessionTime - run.startTime))
  end

  if drift.active then
    local stateColor = drift.state == 'spin' and rgbm(1, 0.2, 0.2, 1)
      or drift.state == 'drifting' and GREEN or rgbm(0.8, 0.8, 0.8, 1)
    ui.textColored(drift.zone.name, GREEN)
    ui.text(string.format('Score: %.0f   Combo: x%.1f', drift.score, drift.combo))
    ui.textColored(string.format('%s   %.0f°   %.0f km/h', drift.state:upper(), drift.angle, ac.getCar(0).speedKmh), stateColor)
  end

  ui.separator()
  ui.text('Ctrl+6  ' .. (showLeaderboard and 'hide' or 'show') .. ' leaderboard')

  ui.popStyleColor()
  ui.endTransparentWindow()
end

local function drawLeaderboardWindow()
  if not showLeaderboard then return end
  ui.beginTransparentWindow('sr_leaderboard', vec2(20, ui.windowSize().y - 480), vec2(300, 200), true)
  ui.pushStyleColor(ui.StyleColor.WindowBg, PANEL_BG)

  if drift.active then
    ui.textColored('ZONE BEST — ' .. drift.zone.name, GREEN)
    local rows = economy.driftLeaderboards[drift.zone.name] or {}
    if #rows == 0 then
      ui.text(economyEnabled() and 'No runs yet.' or 'Economy offline.')
    else
      for i, row in ipairs(rows) do
        ui.text(string.format('%d. %s — %.0f', i, row.playerName or '???', row.score or 0))
      end
    end
  else
    ui.textColored('TOP RUNNERS (cash)', GREEN)
    if #economy.leaderboardCash == 0 then
      ui.text(economyEnabled() and 'Loading...' or 'Economy offline.')
    else
      for i, row in ipairs(economy.leaderboardCash) do
        local label = row.title and row.title ~= '' and row.title ~= 'rookie'
          and ('[' .. titleDisplayName(row.title) .. '] ') or ''
        ui.text(string.format('%d. %s%s — $%d', i, label, row.name or '???', row.balance or 0))
      end
    end
  end

  ui.popStyleColor()
  ui.endTransparentWindow()
end

local function drawShopWindow()
  if not showShop then return end
  ui.beginTransparentWindow('sr_shop', vec2(700, 40), vec2(340, 400), true)
  ui.pushStyleColor(ui.StyleColor.WindowBg, PANEL_BG)
  ui.textColored('SHOP', GREEN)
  ui.textColored(string.format('Cash: $%d', storage.cash), GREEN)
  ui.separator()

  ui.text('Titles')
  for _, item in ipairs(SHOP_ITEMS.titles) do
    ui.text(string.format('%s ($%d)', item.name, item.price))
    ui.sameLine()
    if ownsTitle(item.id) then
      if storage.equippedTitle == item.id then
        ui.textColored('Equipped', GREEN)
      elseif ui.button('Equip##' .. item.id) then
        shopEquipTitle(item.id)
      end
    elseif ui.button('Buy##' .. item.id) then
      shopBuyTitle(item)
    end
  end

  ui.separator()
  ui.text('Boosts')
  for _, item in ipairs(SHOP_ITEMS.boosts) do
    ui.text(string.format('%s ($%d)', item.name, item.price))
    ui.sameLine()
    if ui.button('Buy##' .. item.id) then shopBuyBoost(item) end
  end

  if shopMessageTimer > 0 then
    ui.separator()
    ui.textColored(shopMessage, GREEN)
  end

  ui.popStyleColor()
  ui.endTransparentWindow()
end

local function drawEditorWindow()
  if not CONFIG.showEditor then return end
  ui.beginTransparentWindow('sr_editor', vec2(340, 40), vec2(360, 320), true)
  ui.pushStyleColor(ui.StyleColor.WindowBg, PANEL_BG)
  ui.textColored('ROUTE EDITOR  (keyboard)', GREEN)
  ui.separator()

  ui.text('Mode: ' .. editor.mode:upper())
  ui.text('Captured points: ' .. #editor.points)
  if editor.mode == 'route' then
    ui.text(string.format('Reward $%d  +$%d/s under %ds', editor.baseReward, editor.bonusPerSecond, editor.target))
  else
    ui.text(string.format('Corridor %dm  $%d per score pt', editor.width, editor.payoutPer))
  end
  ui.separator()

  ui.text('Ctrl+1   capture point here')
  ui.text('Ctrl+2   ' .. (editor.mode == 'route' and 'test drive route' or 'test drift zone'))
  ui.text('Ctrl+3   copy ' .. editor.mode .. ' to clipboard')
  ui.text('Ctrl+4   toggle route / zone')
  ui.text('Ctrl+5   clear points')
  ui.text('Ctrl+6   show / hide leaderboard')
  ui.separator()

  ui.textColored('CTRL: ' .. (ctrlDown and 'DOWN' or 'up'), ctrlDown and GREEN or rgbm(0.55, 0.55, 0.55, 1))
  if editorMessageTimer > 0 then ui.textColored(editorMessage, GREEN) end

  ui.popStyleColor()
  ui.endTransparentWindow()
end

function script.drawUI()
  pcall(drawMainHUD)
  pcall(drawLeaderboardWindow)
  pcall(drawShopWindow)
  pcall(drawEditorWindow)
end
