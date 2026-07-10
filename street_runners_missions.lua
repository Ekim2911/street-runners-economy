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
  -- Cops: to go on duty a player must be LEVEL >= copLevel AND driving a car
  -- whose id contains one of copCars (lower-case substring match). Add your
  -- server's cop car folder names here.
  copLevel = 20,
  copCars = { 'police', 'sheriff', 'patrol', 'crown_victoria', 'interceptor', 'charger_police',
              'acpursuit', 'undercover', 'sayrx_dodge_charger_undercover' },
  -- The cop radar ignores AI traffic: cars that hide labels, or whose driver name
  -- starts with one of these (your server's AI NamePrefix is "Traffic Guy").
  trafficPrefixes = { 'traffic' },
  levelXpK = 250,             -- level = floor(1 + sqrt(lifetimeEarned / levelXpK))
  devSteamIds = { '76561199438773448' },   -- these players are always max level (dev/admin)
  -- Storyline audio streamed from the server's /audio folder (no install). Any
  -- file that isn't uploaded is simply skipped.
  audioVolume = 1.0,
  audio = {
    deliveryStart  = 'delivery_start.mp3',
    deliveryPickup = 'delivery_pickup.mp3',
    deliveryWanted = 'delivery_wanted.mp3',
    deliveryDone   = 'delivery_done.mp3',
    deliveryBusted = 'delivery_busted.mp3',
  },
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

-- Smuggling runs: drive to the pickup, then to the drop without the heat maxing
-- out. points[1] = pickup, points[#] = dropoff.
local DELIVERIES = {
  -- { name = "Dockside Drop", reward = 3000, points = { vec3(0,0,0), vec3(200,0,90) } },
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
  lifetimeEarned = 0,      -- total cash ever earned; drives player level
}, 'street_runners_v3')

-- Backfill lifetime earnings for players who existed before levels: assume at
-- least their current balance was earned, so they aren't reset to level 1.
if (storage.lifetimeEarned or 0) < (storage.cash or 0) then storage.lifetimeEarned = storage.cash or 0 end

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

local economy = { leaderboardCash = {}, driftLeaderboards = {}, hotlapLeaderboards = {},
  hotlapCars = {}, hotlapCarBoards = {}, leaderboardArrests = {} }

local function economyEnabled()
  return CONFIG.economyUrl ~= nil and CONFIG.economyUrl ~= ''
end

-- Storyline audio: stream a short clip from the server's /audio folder via
-- ui.MediaPlayer (nothing for players to install). References are kept so
-- playback isn't garbage-collected mid-clip. Entirely best-effort/pcall'd.
local audioClips = {}
local function playAudio(file)
  if not file or file == '' or not economyEnabled() then return end
  pcall(function()
    local mp = ui.MediaPlayer(CONFIG.economyUrl .. '/audio/' .. file)
    pcall(function() mp:setVolume(CONFIG.audioVolume or 1.0) end)
    pcall(function() mp:play() end)
    audioClips[#audioClips + 1] = mp
    while #audioClips > 6 do table.remove(audioClips, 1) end
  end)
end

-- Current car's model id (folder name), used to key per-car lap leaderboards.
-- Cached once the API returns it. `prettyCar` makes a readable label.
local _carId
local function currentCarId()
  if _carId then return _carId end
  local id
  pcall(function() id = ac.getCarID(0) end)
  if type(id) == 'string' and id ~= '' then _carId = id end
  return _carId or ''
end
local function prettyCar(id)
  if type(id) ~= 'string' or id == '' then return '???' end
  return (id:gsub('_', ' '))
end

-- Dev/admin players (by Steam id) are always maxed — keeps cop/dev access without
-- grinding, gated to specific ids so it isn't open to everyone.
local function isDev()
  local pid = tostring(storage.playerId or '')
  for _, id in ipairs(CONFIG.devSteamIds or {}) do if pid == id then return true end end
  return false
end

-- Player level from lifetime earnings. Level 1 at 0, ~level 20 near 90k earned
-- with the default levelXpK. `levelProgress` returns 0..1 toward the next level.
local function playerLevel()
  if isDev() then return 99 end
  local e = math.max(0, storage.lifetimeEarned or 0)
  return math.floor(1 + math.sqrt(e / CONFIG.levelXpK))
end
local function xpForLevel(l) return CONFIG.levelXpK * (l - 1) * (l - 1) end
local function levelProgress()
  local l = playerLevel()
  local cur, nxt = xpForLevel(l), xpForLevel(l + 1)
  local e = math.max(0, storage.lifetimeEarned or 0)
  if nxt <= cur then return 1 end
  return math.max(0, math.min(1, (e - cur) / (nxt - cur)))
end

-- Cop duty: driving a cop car AND high enough level.
local function isCopCar(id)
  if type(id) ~= 'string' or id == '' then return false end
  local low = id:lower()
  for _, pat in ipairs(CONFIG.copCars) do
    if low:find(pat, 1, true) then return true end
  end
  return false
end
local function copEligible()
  return playerLevel() >= CONFIG.copLevel and isCopCar(currentCarId())
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

-- Post a pre-built JSON string (for nested payloads jsonEncode can't handle).
local function economyPostRaw(path, jsonStr, callback)
  if not economyEnabled() or web == nil then return end
  pcall(web.post, CONFIG.economyUrl .. path, economyHeaders(true), jsonStr, callback)
end

local function jsStr(s)
  return '"' .. tostring(s):gsub('\\', '\\\\'):gsub('"', '\\"') .. '"'
end

local function jsPoints(points)
  local parts = {}
  for _, p in ipairs(points) do
    parts[#parts + 1] = string.format('{"x":%.2f,"y":%.2f,"z":%.2f}', p.x, p.y, p.z)
  end
  return '[' .. table.concat(parts, ',') .. ']'
end

local function routePostBody(r)
  return string.format('{"kind":"route","name":%s,"data":{"name":%s,"target":%d,"baseReward":%d,"bonusPerSecond":%d,"points":%s}}',
    jsStr(r.name), jsStr(r.name), math.floor(r.target), math.floor(r.baseReward), math.floor(r.bonusPerSecond), jsPoints(r.points))
end

local function zonePostBody(z)
  return string.format('{"kind":"zone","name":%s,"data":{"name":%s,"width":%d,"payoutPer":%d,"points":%s}}',
    jsStr(z.name), jsStr(z.name), math.floor(z.width), math.floor(z.payoutPer), jsPoints(z.points))
end

local function deliveryPostBody(d)
  return string.format('{"kind":"delivery","name":%s,"data":{"name":%s,"reward":%d,"points":%s}}',
    jsStr(d.name), jsStr(d.name), math.floor(d.reward or 3000), jsPoints(d.points))
end

local function economyEarn(amount, source)
  local applied = amount
  if applied > 0 then applied = math.floor(applied * activeBoostMultiplier()) end
  storage.cash = storage.cash + applied
  if applied > 0 then storage.lifetimeEarned = (storage.lifetimeEarned or 0) + applied end
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

-- Cop arrests: report a bust (bumps the arrest counter) and pull the board.
local function economyReportArrest()
  economyPost('/players/' .. storage.playerId .. '/arrest',
    { name = storage.playerName, title = storage.equippedTitle },
    function(err, response) end)
end
local function economyRefreshArrestsLeaderboard()
  economyGet('/leaderboard/arrests?limit=10', function(err, response)
    if err or not response then return end
    local data = safeJsonParse(response.body)
    if data then economy.leaderboardArrests = data end
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

local function economyReportHotlap(route, timeMs)
  economyPost('/hotlap/runs',
    {
      routeId = route.name,
      routeName = route.name,
      playerId = storage.playerId,
      playerName = storage.playerName,
      car = currentCarId(),
      timeMs = timeMs,
    },
    function(err, response) end)
end

local function economyRefreshHotlapLeaderboard(routeName)
  economyGet('/hotlap/leaderboard/' .. urlEncode(routeName) .. '?limit=10', function(err, response)
    if err or not response then return end
    local data = safeJsonParse(response.body)
    if data then economy.hotlapLeaderboards[routeName] = data end
  end)
end

-- Per-car lap data for the LAPS tab: the best lap for each car on a route, and
-- (lazily) the ranked board for one selected car.
local function economyRefreshHotlapCars(routeName)
  economyGet('/hotlap/cars/' .. urlEncode(routeName) .. '?limit=30', function(err, response)
    if err or not response then return end
    local data = safeJsonParse(response.body)
    if data then economy.hotlapCars[routeName] = data end
  end)
end

local function economyRefreshHotlapCarBoard(routeName, car)
  if not car or car == '' then return end
  economyGet('/hotlap/leaderboard/' .. urlEncode(routeName) .. '?limit=10&car=' .. urlEncode(car),
    function(err, response)
      if err or not response then return end
      local data = safeJsonParse(response.body)
      if data then economy.hotlapCarBoards[routeName .. '|' .. car] = data end
    end)
end

-- Replace a list's contents in place (keeps the table reference the gameplay
-- loops hold).
local function rebuildList(tbl, items)
  for i = #tbl, 1, -1 do tbl[i] = nil end
  for _, it in ipairs(items) do tbl[#tbl + 1] = it end
end

-- Pull server-managed routes/zones and rebuild ROUTES / DRIFT_ZONES. Callers
-- that could disrupt an active run (the idle refresh) already gate on
-- not run.active/drift.active.
local function economyLoadMissions()
  economyGet('/routes', function(err, response)
    if err or not response then return end
    local data = safeJsonParse(response.body)
    if not data then return end
    local routes, zones, deliveries = {}, {}, {}
    for _, m in ipairs(data) do
      local d = m.data
      if type(d) == 'table' and type(d.points) == 'table' and #d.points >= 2 then
        local pts, dirs, hws = {}, {}, {}
        for _, p in ipairs(d.points) do
          pts[#pts + 1] = vec3(p.x or 0, p.y or 0, p.z or 0)
          -- optional baked road tangent + asphalt half-widths (from gen_h1_hotlap)
          if p.dx and p.dz then dirs[#pts] = { tonumber(p.dx), tonumber(p.dz) } end
          if p.hwl and p.hwr then hws[#pts] = { tonumber(p.hwl), tonumber(p.hwr) } end
        end
        local protectedM = d.protected == true          -- seeded/locked: no delete button
        if m.kind == 'route' then
          routes[#routes + 1] = { _id = m.id, name = d.name or m.name, target = d.target or 45,
            baseReward = d.baseReward or 500, bonusPerSecond = d.bonusPerSecond or 25, points = pts,
            dirs = next(dirs) and dirs or nil, hws = next(hws) and hws or nil,
            hotlap = d.hotlap == true, checkpointRadius = tonumber(d.checkpointRadius), protected = protectedM }
        elseif m.kind == 'zone' then
          zones[#zones + 1] = { _id = m.id, name = d.name or m.name, width = d.width or 8,
            payoutPer = d.payoutPer or 2, points = pts, protected = protectedM }
        elseif m.kind == 'delivery' then
          deliveries[#deliveries + 1] = { _id = m.id, name = d.name or m.name,
            reward = tonumber(d.reward) or 3000, points = pts, protected = protectedM }
        end
      end
    end
    rebuildList(DELIVERIES, deliveries)
    rebuildList(ROUTES, routes)
    rebuildList(DRIFT_ZONES, zones)
  end)
end

local function economySaveRoute(r)
  economyPostRaw('/routes', routePostBody(r), function(err, response) economyLoadMissions() end)
end

local function economySaveZone(z)
  economyPostRaw('/routes', zonePostBody(z), function(err, response) economyLoadMissions() end)
end

local function economySaveDelivery(d)
  economyPostRaw('/routes', deliveryPostBody(d), function(err, response) economyLoadMissions() end)
end

local function economyDeleteMission(id)
  if not id then return end
  economyPostRaw('/routes/' .. id .. '/delete', '{}', function(err, response) economyLoadMissions() end)
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

-- Set by finishRoute for a hotlap so the HUD/leaderboard can flash the result.
local lastHotlap = { name = nil, timeMs = 0, at = -100 }

local function finishRoute()
  local route = run.route
  local elapsed = sessionTime - run.startTime
  local bonus = math.max(0, (route.target - elapsed) * route.bonusPerSecond)
  local payout = route.baseReward + math.floor(bonus)
  economyEarn(payout, 'checkpoint:' .. route.name)
  if route.hotlap then
    local timeMs = math.floor(elapsed * 1000)
    economyReportHotlap(route, timeMs)
    economyRefreshHotlapLeaderboard(route.name)
    economyRefreshHotlapCars(route.name)                     -- LAPS tab: per-car records
    economyRefreshHotlapCarBoard(route.name, currentCarId())
    lastHotlap = { name = route.name, timeMs = timeMs, at = sessionTime }
  end
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
  if dist2D(car.position, target) <= (run.route.checkpointRadius or CONFIG.checkpointRadius) then
    if run.index >= #run.route.points then
      finishRoute()
    else
      -- Hotlap: the clock starts when you actually cross the start line
      -- (checkpoint 1), not when you pressed Start, so driving up to the line
      -- doesn't count against the lap.
      if run.route.hotlap and run.index == 1 then run.startTime = sessionTime end
      run.index = run.index + 1
    end
  end
end

-- Auto-start a hotlap the instant you physically cross its start line — no need
-- to press Start. Detected as a proper plane crossing (behind → in front of the
-- line, within the road width) rather than a fat proximity radius, so the timer
-- begins exactly at the visible line. Skipped while a run is already going (so a
-- lap-closing crossing finishes instead of re-triggering).
local hotlapPrevSide = {}   -- per route: last signed distance in front of the start line
local function updateHotlapAutostart(car)
  if drift.active then return end
  for _, route in ipairs(ROUTES) do
    if route.hotlap and #route.points >= 2 then
      local p1, p2 = route.points[1], route.points[2]
      local fdx, fdz
      if route.dirs and route.dirs[1] then
        fdx, fdz = route.dirs[1][1], route.dirs[1][2]        -- baked tangent = drawn line normal
      else
        local ddx, ddz = p2.x - p1.x, p2.z - p1.z
        local len = math.sqrt(ddx * ddx + ddz * ddz)
        if len < 0.001 then len = 1 end
        fdx, fdz = ddx / len, ddz / len                      -- forward along the track
      end
      local ox, oz = car.position.x - p1.x, car.position.z - p1.z
      local fwd = ox * fdx + oz * fdz                        -- signed distance in front of line
      local lat = math.abs(ox * (-fdz) + oz * fdx)           -- distance from the line's center
      local r = route.checkpointRadius or CONFIG.checkpointRadius
      local key = route._id or route.name
      local prev = hotlapPrevSide[key]
      if not run.active and prev ~= nil and prev < 0 and fwd >= 0 and lat <= r then
        startRoute(route)                                     -- crossed forward over the line
      end
      hotlapPrevSide[key] = fwd
    end
  end
end

---------------------------------------------------------------------------
-- Delivery / smuggling runs: pickup -> drop without the heat maxing out.
-- "Cop attention" = a heat meter that climbs when you drive recklessly near
-- traffic (fast + close to other cars). Max it out and the cops are on you
-- (WANTED) — you must cool down to shake them or you get busted and lose the
-- cargo. Deliver clean for the biggest payout.
---------------------------------------------------------------------------

local DLV = {
  radius     = 12,     -- reach radius for pickup / drop (m)
  heatSpeed  = 70,     -- km/h above which being near traffic generates heat
  nearDist   = 22,     -- m to an AI car that counts as "near"
  heatRise   = 55,     -- heat/s at point-blank + high speed
  heatDecay  = 22,     -- heat/s bled off when driving clean
  cool       = 35,     -- drop below this while WANTED to shake the cops
  wantedTime = 10,     -- seconds of sustained heat before you're busted
  stealthPer = 40,     -- bonus cash per point of (100-heat) kept on delivery
}

local delivery = { active = false, mission = nil, stage = 'pickup',
  heat = 0, wanted = false, bustTimer = 0, startTime = 0, msg = '', msgUntil = -1 }

local function deliveryMsg(t) delivery.msg, delivery.msgUntil = t, sessionTime + 4 end

local function startDelivery(m)
  run.active = false; run.route = nil                 -- one job at a time
  delivery.active, delivery.mission = true, m
  delivery.stage, delivery.heat = 'pickup', 0
  delivery.wanted, delivery.bustTimer = false, 0
  delivery.startTime = sessionTime
  deliveryMsg('Go to the PICKUP')
  playAudio(CONFIG.audio.deliveryStart)
end

local function deliveryComplete()
  local m = delivery.mission
  local bonus = math.floor(math.max(0, 100 - delivery.heat) * DLV.stealthPer)
  local payout = (m.reward or 3000) + bonus
  economyEarn(payout, 'delivery:' .. m.name)
  deliveryMsg(string.format('DELIVERED  +%s  (stealth +%s)', money(payout), money(bonus)))
  delivery.active, delivery.mission, delivery.wanted = false, nil, false
  playAudio(CONFIG.audio.deliveryDone)
end

local function deliveryFail(reason)
  deliveryMsg(reason or 'BUSTED — cargo lost')
  delivery.active, delivery.mission, delivery.wanted = false, nil, false
  playAudio(CONFIG.audio.deliveryBusted)
end

---------------------------------------------------------------------------
-- Cops (built into the online script — no separate app to install). On-duty =
-- driving a cop car AND level >= copLevel. Wanted smugglers broadcast themselves
-- peer-to-peer via an OnlineEvent; a cop busts one by keeping them cornered
-- until they've been STOPPED for a few seconds (no ramming — wait for the
-- mistake). Bust pays the cop a bounty and fails the runner's delivery.
---------------------------------------------------------------------------

local COP = {
  bounty       = 5000,   -- cash a cop earns per bust
  bustRange    = 30,     -- m: suspect must be within this to be bustable
  radarRange   = 400,    -- m: show nearby players on the cop radar within this
  stopSpeed    = 6,      -- km/h below which the suspect counts as stopped
  stopTime     = 5,      -- seconds stopped-in-range before the bust lands
  pingInterval = 1.0,    -- how often a wanted runner broadcasts itself
  staleAfter   = 4.0,    -- drop a wanted runner not heard from in this long
}

local cop = { onDuty = false, engaged = false, lockIndex = -1, suspectDist = 1e9,
  nearestIndex = -1, nearestDist = 1e9, stopSince = -1, bustHeld = 0, msg = '', msgUntil = -1 }

local function copSetMsg(t) cop.msg, cop.msgUntil = t, sessionTime + 4 end
local function copEndPursuit() cop.engaged, cop.lockIndex, cop.stopSince, cop.bustHeld, cop.alertAt = false, -1, -1, 0, nil end
local copWanted = {}        -- carIndex -> { name, at, index } of wanted runners we've heard
local wantedPingAt = -100
-- Set on the SUSPECT's client when a cop pings a pursuit / busts them.
local chasedBy, chasedUntil = '', -1
local bustedBy, bustedUntil = '', -1

local function mySessionId()
  local id = -1
  pcall(function() local me = ac.getCar(0); if me then id = me.sessionID end end)
  return id
end

-- Peer-to-peer cop<->runner channel. kind 1 = "I'm a wanted runner" ping;
-- kind 2 = "you're under arrest" (target = suspect sessionID); kind 3 = "you're
-- being pursued" alert (target = suspect sessionID). Wrapped so the script still
-- loads if OnlineEvent isn't available on the build.
local copEvent
pcall(function()
  copEvent = ac.OnlineEvent({
    kind   = ac.StructItem.int16(),
    target = ac.StructItem.int16(),
    name   = ac.StructItem.string(40),
  }, function(sender, data)
    if data.kind == 1 then
      copWanted[sender.index] = { name = data.name, at = sessionTime, index = sender.index }
    elseif data.kind == 2 then
      if data.target == mySessionId() then
        local by = (data.name ~= '' and data.name or 'Police')
        bustedBy, bustedUntil, chasedUntil = by, sessionTime + 7, -1
        if delivery.active then deliveryFail('BUSTED by ' .. by .. ' — cargo lost') end
      end
    elseif data.kind == 3 then
      if data.target == mySessionId() then
        chasedBy, chasedUntil = (data.name ~= '' and data.name or 'Police'), sessionTime + 5
      end
    end
  end)
end)

-- Send the "you're being chased" alert to a suspect's car (by index).
local function copAlertSuspect(index)
  pcall(function()
    local o = ac.getCar(index)
    if o and copEvent then copEvent{ kind = 3, target = o.sessionID, name = storage.playerName } end
  end)
end

local function copBroadcastWanted()
  if copEvent and sessionTime - wantedPingAt > COP.pingInterval then
    wantedPingAt = sessionTime
    pcall(function() copEvent{ kind = 1, target = 0, name = storage.playerName } end)
  end
end

-- Is car index `i` a real human player (not AI traffic)? Traffic hides its
-- labels and/or uses the "Traffic ..." name prefix on this server.
local function isPlayerCar(o, i)
  if not o or not o.isConnected or not o.position then return false end
  if o.isHidingLabels then return false end
  local nm = ac.getDriverName(i)
  if not nm or nm == '' then return false end
  local low = nm:lower()
  for _, p in ipairs(CONFIG.trafficPrefixes or {}) do
    if low:sub(1, #p) == p:lower() then return false end
  end
  return true
end

-- Engage a suspect (from the cop app's Initiate Pursuit button).
local function copInitiatePursuit(index)
  if index and index >= 0 then
    cop.engaged, cop.lockIndex, cop.stopSince, cop.bustHeld = true, index, -1, 0
    cop.alertAt = sessionTime
    copSetMsg('PURSUIT INITIATED')
    copAlertSuspect(index)                              -- tell them they're being chased
  end
end

-- Cop update: track the nearest wanted runner (for the Initiate button), and —
-- only while a pursuit is engaged — bust the locked suspect once they've been
-- stopped inside bustRange for stopTime seconds.
local function updateCop(car, dt)
  cop.onDuty = copEligible()
  if not cop.onDuty then copEndPursuit(); return end

  -- prune stale wanted
  for idx, w in pairs(copWanted) do
    if sessionTime - w.at > COP.staleAfter then copWanted[idx] = nil end
  end
  -- radar: every nearby connected car (players), wanted ones flagged, nearest first
  local nearby = {}
  pcall(function()
    local n = 64
    local sim = ac.getSim and ac.getSim(); if sim and sim.carsCount then n = sim.carsCount end
    for i = 1, n - 1 do
      local o = ac.getCar(i)
      if isPlayerCar(o, i) then                          -- real players only, no AI traffic
        local dx, dz = o.position.x - car.position.x, o.position.z - car.position.z
        local d = math.sqrt(dx * dx + dz * dz)
        if d <= COP.radarRange then
          nearby[#nearby + 1] = { index = i, dist = d, wanted = (copWanted[i] ~= nil), name = ac.getDriverName(i) or '???' }
        end
      end
    end
    table.sort(nearby, function(a, b)
      if a.wanted ~= b.wanted then return a.wanted end
      return a.dist < b.dist
    end)
  end)
  cop.nearby = nearby

  -- bust logic only runs against the ENGAGED, locked suspect (any car — wanted or not)
  if not cop.engaged or cop.lockIndex < 0 then cop.stopSince, cop.bustHeld = -1, 0; return end
  local o = ac.getCar(cop.lockIndex)
  if not o or not o.position or (o.isConnected == false) then
    copEndPursuit(); copSetMsg('Suspect lost'); return
  end
  local dx, dz = o.position.x - car.position.x, o.position.z - car.position.z
  cop.suspectDist = math.sqrt(dx * dx + dz * dz)
  -- keep reminding the suspect they're being chased (banner refreshes each ping)
  if sessionTime - (cop.alertAt or 0) > 2 then cop.alertAt = sessionTime; copAlertSuspect(cop.lockIndex) end
  if cop.suspectDist <= COP.bustRange and (o.speedKmh or 0) < COP.stopSpeed then
    if cop.stopSince < 0 then cop.stopSince = sessionTime end
    cop.bustHeld = sessionTime - cop.stopSince
    if cop.bustHeld >= COP.stopTime then
      local wentry = copWanted[cop.lockIndex]
      local nm = (wentry and wentry.name) or ac.getDriverName(cop.lockIndex) or 'suspect'
      pcall(function() copEvent{ kind = 2, target = o.sessionID, name = storage.playerName } end)
      economyReportArrest()                             -- counts toward the arrests leaderboard
      if wentry then                                    -- bounty only for actually-wanted runners
        economyEarn(COP.bounty, 'bust:' .. nm)
        copSetMsg(string.format('BUSTED %s  +%s', nm, money(COP.bounty)))
        copWanted[cop.lockIndex] = nil
      else
        copSetMsg('Arrested ' .. nm)
      end
      cop.msgUntil = sessionTime + 5
      copEndPursuit()
    end
  else
    cop.stopSince, cop.bustHeld = -1, 0
  end
end

-- distance (XZ) to the nearest OTHER car (traffic/players); big number if alone
local function nearestOtherCarDist(me)
  local best = 1e9
  pcall(function()
    local n = 64
    local sim = ac.getSim and ac.getSim()
    if sim and sim.carsCount then n = sim.carsCount end
    for i = 1, n - 1 do
      local o = ac.getCar(i)
      if o and o.position then
        local dx, dz = o.position.x - me.position.x, o.position.z - me.position.z
        local d = math.sqrt(dx * dx + dz * dz)
        if d < best then best = d end
      end
    end
  end)
  return best
end

local function updateDelivery(car, dt)
  if not delivery.active then return end
  local m = delivery.mission
  local spd = car.speedKmh or 0

  -- heat: reckless near traffic pushes it up; clean driving bleeds it off
  local nd = nearestOtherCarDist(car)
  if nd < DLV.nearDist and spd > DLV.heatSpeed then
    local closeF = (DLV.nearDist - nd) / DLV.nearDist          -- 0..1, closer = more
    local fastF  = (spd - DLV.heatSpeed) / DLV.heatSpeed        -- grows with speed
    delivery.heat = delivery.heat + DLV.heatRise * closeF * fastF * dt
  else
    delivery.heat = delivery.heat - DLV.heatDecay * dt
  end
  if delivery.heat < 0 then delivery.heat = 0 end
  if delivery.heat > 100 then delivery.heat = 100 end

  -- WANTED: max heat alerts the cops to your position; cool down or get busted
  if not delivery.wanted and delivery.heat >= 100 then
    delivery.wanted, delivery.bustTimer = true, 0
    deliveryMsg('COPS ON YOU — LOSE THEM!')
    playAudio(CONFIG.audio.deliveryWanted)
  end
  if delivery.wanted then
    copBroadcastWanted()                                 -- put yourself on cops' radar
    if delivery.heat <= DLV.cool then
      delivery.wanted = false
      deliveryMsg("Lost 'em — make the drop")
    else
      delivery.bustTimer = delivery.bustTimer + dt
      -- fallback bust if no cop catches you (keeps the mode working solo)
      if delivery.bustTimer >= DLV.wantedTime then deliveryFail('BUSTED — cargo lost'); return end
    end
  end

  -- pickup -> dropoff progression
  local pickup, drop = m.points[1], m.points[#m.points]
  if delivery.stage == 'pickup' then
    if dist2D(car.position, pickup) <= DLV.radius then
      delivery.stage = 'dropoff'
      deliveryMsg('Cargo loaded — DELIVER it, stay cool')
      playAudio(CONFIG.audio.deliveryPickup)
    end
  else
    if not delivery.wanted and dist2D(car.position, drop) <= DLV.radius then
      deliveryComplete()
    end
  end
end

---------------------------------------------------------------------------
-- Editor (route + zone capture, shared buffer)
---------------------------------------------------------------------------

local editor = {
  mode = 'route',        -- 'route' | 'zone' | 'delivery'
  points = {},
  name = 'New Route',
  target = 45, baseReward = 500, bonusPerSecond = 25,   -- route fields
  width = 8, payoutPer = 2,                              -- zone fields
  reward = 3000,                                         -- delivery field
  captureReq = false,    -- set by the button/hotkey; fulfilled in draw3D where track rays work
  freeCam = true,        -- true = drop where the camera aims (fly free cam); false = at the car
}

-- Request a point drop. The actual placement (a track raycast from the camera)
-- runs in script.draw3D, where render.createRay works; see editorFulfilCapture.
local function editorCapture()
  editor.captureReq = true
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
  N8 = 0x38, N9 = 0x39, LEFT = 0x25, UP = 0x26, RIGHT = 0x27, DOWN = 0x28 }
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
    if rawKeyDown(VK.N8) then uiScale = math.min(2.5, uiScale + sstep) end
    if rawKeyDown(VK.N9) then uiScale = math.max(0.6, uiScale - sstep) end
  end

  if ctrlDown and e6 then
    appOpen = not appOpen
    if appOpen then
      economyRefreshCashLeaderboard()
      economyLoadMissions()
      if drift.active then economyRefreshDriftLeaderboard(drift.zone.name) end
    end
  end

  if not CONFIG.showEditor or not ctrlDown then return end
  if e1 then editorCapture() end
  if e4 then editor.mode = editor.mode == 'route' and 'zone' or (editor.mode == 'zone' and 'delivery' or 'route'); editorSetMessage('Mode: ' .. editor.mode) end
  if e5 then editorClear(); editorSetMessage('Cleared points') end
  if e2 then
    if #editor.points < 2 then
      editorSetMessage('Need 2+ points')
    elseif editor.mode == 'route' then
      startRoute({ name = editor.name, target = editor.target, baseReward = editor.baseReward,
        bonusPerSecond = editor.bonusPerSecond, points = editor.points })
      editorSetMessage('Test drive started')
    elseif editor.mode == 'delivery' then
      startDelivery({ name = editor.name, reward = editor.reward, points = editor.points })
      editorSetMessage('Test delivery started')
    else
      table.insert(DRIFT_ZONES, { name = editor.name, width = editor.width, payoutPer = editor.payoutPer, points = editor.points })
      editorSetMessage('Test zone added')
    end
  end
  if e3 then
    if editor.mode == 'route' then editorCopyRoute() elseif editor.mode == 'zone' then editorCopyZone() end
    editorSetMessage('Copied to clipboard + log')
  end
end

---------------------------------------------------------------------------
-- script.update
---------------------------------------------------------------------------

local idleRefreshTimer = 0
local missionsLoaded = false

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
  if not missionsLoaded and economyEnabled() then missionsLoaded = true; economyLoadMissions() end
  updateHotlapAutostart(car)
  updateCheckpoints(car)
  updateDriftZones(car, dt)
  updateDelivery(car, dt)
  updateCop(car, dt)
  updateEditorHotkeys(car, dt)

  if shopMessageTimer > 0 then shopMessageTimer = shopMessageTimer - dt end
  if editorMessageTimer > 0 then editorMessageTimer = editorMessageTimer - dt end

  if not run.active and not drift.active then
    idleRefreshTimer = idleRefreshTimer + dt
    if idleRefreshTimer > 15 then
      idleRefreshTimer = 0
      economyRefreshCashLeaderboard()
      economyLoadMissions()
    end
  end
end

---------------------------------------------------------------------------
-- script.draw3D — checkpoint gates & drift corridors
---------------------------------------------------------------------------

-- Ground-plane unit vectors: perpendicular to a->b, and along a->b.
local function perpXZ(a, b)
  local dx, dz = b.x - a.x, b.z - a.z
  local len = math.sqrt(dx * dx + dz * dz)
  if len < 0.001 then return 1, 0 end
  return -dz / len, dx / len
end
local function dirXZ(a, b)
  local dx, dz = b.x - a.x, b.z - a.z
  local len = math.sqrt(dx * dx + dz * dz)
  if len < 0.001 then return 1, 0 end
  return dx / len, dz / len
end

local GREEN3     = rgbm(0.4, 1.0, 0.55, 1.0)
local RED3       = rgbm(1.0, 0.16, 0.16, 1.0)
local CYAN3      = rgbm(0.3, 0.85, 1.0, 1.0)
local YEL3       = rgbm(1.0, 0.95, 0.25, 1.0)

-- ONE consistent marker color code, used for every route AND drift zone so a
-- start looks like a start on every road, a finish like a finish, etc. Raw
-- r,g,b triples (groundLaser builds the rgbm layers itself).
local M_START    = { 0.35, 1.00, 0.45 }   -- green  = start line
local M_CHECK    = { 0.30, 0.85, 1.00 }   -- cyan   = intermediate checkpoint
local M_FINISH   = { 1.00, 0.10, 0.08 }   -- red    = finish line (saturated so additive glow stays red, not pink)
local M_ACTIVE   = { 1.00, 0.92, 0.25 }   -- yellow = your current target

local LASER_RADIUS = 0.07   -- core tube radius in metres; glow extends past it
local TUBE_SEGS    = 8      -- facets around the tube (higher = rounder, costlier)

-- Road-edge probing: instead of a fixed radius (which either misses the edges of
-- wide roads or overshoots past them), find the actual road edge each side via
-- track raycasts — a sideways ray for walls/barriers and a downward step-walk for
-- curbs/drops. Left and right are measured independently. Best-effort: if the ray
-- API is unavailable or finds nothing it degrades to the fixed fallback width.
local EDGE_STEP = 0.35   -- probe resolution (m)
local EDGE_MAX  = 16     -- never extend past this half-width (m)
local EDGE_MIN  = 2.0    -- never shorter than this half-width (m)
local EDGE_LIP  = 0.12   -- sudden ground jump BETWEEN adjacent steps that means an edge (m)
local EDGE_DROP = 0.6    -- absolute height change from road center that always counts as edge (m)
local EDGE_WALLH = 1.5   -- height (m) to fire the sideways wall probe from (above cars)
local EDGE_MARGIN = 0.3  -- pull the line back this far from a detected wall
local edgeCache = {}     -- keyed by rounded x_z so each spot is probed only once

-- Cast a ray against the track; return hit distance or nil (miss/unavailable).
-- render.createRay(...):track() is the confirmed CSP API (only valid in draw3D).
local function castTrack(ox, oy, oz, dirx, diry, dirz, len)
  local d
  local ok = pcall(function()
    d = render.createRay(vec3(ox, oy, oz), vec3(dirx, diry, dirz), len):track()
  end)
  if not ok or type(d) ~= 'number' or d < 0 then return nil end
  return d
end

-- Ground height directly below (x,z), or nil if nothing is there. Casting from
-- well above the point makes this independent of how accurate p.y is.
local function groundY(x, z, guessY)
  local d = castTrack(x, guessY + 3.0, z, 0, -1, 0, 12.0)
  if not d then return nil end
  return (guessY + 3.0) - d
end

-- How far the road reaches from p along unit lateral (sx,sz), but never past
-- `maxHalf` (the route's own width). The probe only PULLS IN from that width when
-- it detects an earlier edge — a wall/barrier (sideways ray), a sudden lip
-- between adjacent steps (asphalt->grass, even a small one), or a big drop /
-- missing surface. Painted road edges have no geometry to detect, so on those it
-- just uses the route width. Tune width per route via its checkpointRadius.
local function probeReach(p, sx, sz, baseY, maxHalf)
  local cap = math.min(maxHalf, EDGE_MAX)
  local reach, ok = cap, pcall(function()
    -- 1) wall/barrier: a single sideways ray, fired above car height
    local wall = castTrack(p.x, baseY + EDGE_WALLH, p.z, sx, 0, sz, cap + 2)
    local wallEdge = wall and (wall - EDGE_MARGIN) or cap

    -- 2) surface walk: stop on a sudden lip, a large drop, or no surface
    local last, prevY, d = EDGE_MIN, baseY, EDGE_STEP
    while d <= cap and d < wallEdge do
      local hy = groundY(p.x + sx * d, p.z + sz * d, baseY)
      if not hy then break end                          -- nothing below → past the edge
      if math.abs(hy - prevY) > EDGE_LIP then break end  -- sharp lip between steps → edge
      if math.abs(hy - baseY) > EDGE_DROP then break end -- far above/below the road → edge
      last, prevY, d = d, hy, d + EDGE_STEP
    end
    reach = math.min(last, wallEdge)
  end)
  if not ok then reach = cap end
  if reach < EDGE_MIN then reach = EDGE_MIN end
  if reach > cap then reach = cap end
  return reach
end

-- {l, r} half-widths to each road edge at p, cached per location.
local function roadEdges(p, ax, az, fallback)
  local k = string.format('%.1f_%.1f', p.x, p.z)
  local e = edgeCache[k]
  if not e then
    local base = groundY(p.x, p.z, p.y) or p.y          -- true road height at the center
    e = { l = probeReach(p, ax, az, base, fallback), r = probeReach(p, -ax, -az, base, fallback) }
    edgeCache[k] = e
  end
  return e
end

-- A glowing laser beam laid across the road, edge to edge. Drawn with ADDITIVE
-- blending so overlapping translucent shells sum into a hot bright core with a
-- coloured glow falloff — the way real light behaves — instead of a solid,
-- shaded, opaque tube. Thin cylinder shells give it round volume; a bright
-- near-white centre line runs down the axis. Raw r,g,b (reading rgbm fields is
-- unreliable in CSP). Used for every checkpoint / start / finish marker.
local function groundLaser(p, dx, dz, ax, az, halfL, halfR, r, g, b)
  local R    = LASER_RADIUS
  local cy   = p.y + R + 0.06                       -- float just above the tarmac
  local wx, wz = dx, dz                             -- travel dir = cross-section horizontal
  local pulse = 0.9 + 0.1 * math.sin(sessionTime * 3)
  -- brighter core in the SAME hue (scaled, not whitened) — reads as saturated neon
  local br, bg, bb = math.min(1, r * 1.3), math.min(1, g * 1.3), math.min(1, b * 1.3)
  local A = vec3(p.x + ax * halfL, cy, p.z + az * halfL)
  local B = vec3(p.x - ax * halfR, cy, p.z - az * halfR)

  -- switch to additive light accumulation; restore afterwards
  local blended = false
  pcall(function() render.setBlendMode(render.BlendMode.BlendAdd); blended = true end)

  -- a thin cylindrical shell of uniform emissive colour at radius `rad`
  local function shell(rad, cr, cg, cb, a)
    local col = rgbm(cr, cg, cb, a)
    for k = 0, TUBE_SEGS - 1 do
      local t0 = (k / TUBE_SEGS) * math.pi * 2
      local t1 = ((k + 1) / TUBE_SEGS) * math.pi * 2
      local c0, s0 = math.cos(t0), math.sin(t0)
      local c1, s1 = math.cos(t1), math.sin(t1)
      pcall(function()
        local p1 = vec3(A.x + wx * rad * c0, A.y + rad * s0, A.z + wz * rad * c0)
        local p2 = vec3(A.x + wx * rad * c1, A.y + rad * s1, A.z + wz * rad * c1)
        local p3 = vec3(B.x + wx * rad * c1, B.y + rad * s1, B.z + wz * rad * c1)
        local p4 = vec3(B.x + wx * rad * c0, B.y + rad * s0, B.z + wz * rad * c0)
        render.quad(p1, p2, p3, p4, col)
        render.quad(p4, p3, p2, p1, col)              -- double-sided (adds → brighter core)
      end)
    end
  end

  -- soft coloured light spilling onto the tarmac under the beam
  local function bleed(depth, a)
    pcall(function()
      local yy = p.y + 0.03
      render.quad(
        vec3(A.x - wx * depth, yy, A.z - wz * depth), vec3(A.x + wx * depth, yy, A.z + wz * depth),
        vec3(B.x + wx * depth, yy, B.z + wz * depth), vec3(B.x - wx * depth, yy, B.z - wz * depth),
        rgbm(r, g, b, a))
    end)
  end
  bleed(0.7, 0.04)

  -- tight neon tube: soft halo → saturated body → bright in-hue core (no white)
  shell(R * 2.4 * pulse, r,  g,  b,  0.05)          -- soft outer halo
  shell(R * 1.5,         r,  g,  b,  0.14)          -- saturated colour body
  shell(R,               br, bg, bb, 0.45)          -- bright core skin, same hue

  -- crisp bright centre line running the length, in the same hue (stays neon)
  render.debugLine(A, B, rgbm(br, bg, bb, 1.0))

  if blended then pcall(function() render.setBlendMode(render.BlendMode.AlphaBlend) end) end
end

-- Zone gate: a laser light-curtain across the road. Built from raw r,g,b so we
-- can synthesize many alphas without reading rgbm fields (unreliable in CSP).
-- Layers: a vertical gradient that fades to nothing at the top (reads as light,
-- not a wall), bright edge posts, a vertical laser-beam fence, a scan line that
-- sweeps up it, and a crisp ground core.
local function drawGate(p, dx, dz, ax, az, halfW, r, g, b)
  local Lx, Lz = p.x + ax * halfW, p.z + az * halfW
  local Rx, Rz = p.x - ax * halfW, p.z - az * halfW
  local by, t = p.y, sessionTime
  local topH  = 2.8
  local pulse = 0.5 + 0.5 * math.sin(t * 2.5)
  local br, bg, bb = math.min(1, r + 0.35), math.min(1, g + 0.35), math.min(1, b + 0.35)

  -- full-width vertical band between heights h0..h1 (double-sided)
  local function band(h0, h1, col)
    pcall(function()
      local a   = vec3(Lx, by + h0, Lz)
      local q   = vec3(Rx, by + h0, Rz)
      local c   = vec3(Rx, by + h1, Rz)
      local d   = vec3(Lx, by + h1, Lz)
      render.quad(a, q, c, d, col)
      render.quad(d, c, q, a, col)
    end)
  end

  -- 1) gradient curtain: bright at the base, fading to transparent at the top
  local N = 6
  for i = 0, N - 1 do
    local f0   = i / N
    local fade = (1 - f0) ^ 1.8
    band(0.03 + f0 * topH, 0.03 + ((i + 1) / N) * topH, rgbm(r, g, b, 0.34 * fade))
  end

  -- 2) scan line: a bright thin beam sweeping up and down the curtain
  local scan = ((math.sin(t * 1.3) + 1) * 0.5) * (topH - 0.2)
  band(0.03 + scan, 0.15 + scan, rgbm(br, bg, bb, 0.65))

  -- 3) bright vertical edge posts (thin quads framing the gate)
  local function post(px, pz)
    pcall(function()
      local ox, oz = dx * 0.12, dz * 0.12
      render.quad(vec3(px - ox, by + 0.02, pz - oz), vec3(px + ox, by + 0.02, pz + oz),
        vec3(px + ox, by + topH, pz + oz), vec3(px - ox, by + topH, pz - oz), rgbm(br, bg, bb, 0.9))
    end)
  end
  post(Lx, Lz); post(Rx, Rz)

  -- 4) vertical laser-beam fence across the width (breathes with the pulse)
  local beams = 6
  for i = 0, beams do
    local f  = i / beams
    local bx = Lx + (Rx - Lx) * f
    local bz = Lz + (Rz - Lz) * f
    pcall(function()
      render.debugLine(vec3(bx, by + 0.02, bz),
        vec3(bx, by + topH * (0.72 + 0.22 * pulse), bz), rgbm(r, g, b, 0.5))
    end)
  end

  -- 5) crisp ground core: soft halo strip + bright bar + guaranteed line
  local function strip(depth, yoff, col)
    pcall(function()
      local yy = by + yoff
      render.quad(vec3(Lx - dx * depth, yy, Lz - dz * depth), vec3(Lx + dx * depth, yy, Lz + dz * depth),
        vec3(Rx + dx * depth, yy, Rz + dz * depth), vec3(Rx - dx * depth, yy, Rz - dz * depth), col)
    end)
  end
  strip(0.5,  0.02, rgbm(r, g, b, 0.22))       -- breathing ground halo
  strip(0.14, 0.05, rgbm(br, bg, bb, 1.0))     -- crisp solid core
  render.debugLine(vec3(Lx, by + 0.05, Lz), vec3(Rx, by + 0.05, Rz), rgbm(br, bg, bb, 1.0))
end

-- Fulfil a pending editor capture (requested by the button/hotkey). In free-cam
-- mode, raycast from the camera to the track and drop the point where you're
-- aiming (fly around, look at a spot, Capture); if you're aiming at the sky it
-- drops straight below the camera. Otherwise (CAR mode / no camera) it drops at
-- the car. Runs here in draw3D because render.createRay is only valid at render.
local function editorFulfilCapture()
  if not editor.captureReq then return end
  editor.captureReq = false
  local pt
  if editor.freeCam then
    local cp
    pcall(function() cp = ac.getCameraPosition() end)
    if cp then
      local cf
      pcall(function() cf = ac.getCameraForward() end)
      if not cf then pcall(function() cf = ac.getCameraDirection() end) end
      if cf then
        pcall(function()
          local d = render.createRay(vec3(cp.x, cp.y, cp.z), vec3(cf.x, cf.y, cf.z), 5000):track()
          if d and d > 0 then pt = vec3(cp.x + cf.x * d, cp.y + cf.y * d, cp.z + cf.z * d) end
        end)
      end
      if not pt then   -- aiming at the sky → drop straight below the camera
        pcall(function()
          local d = render.createRay(vec3(cp.x, cp.y, cp.z), vec3(0, -1, 0), 5000):track()
          if d and d > 0 then pt = vec3(cp.x, cp.y - d, cp.z) end
        end)
      end
    end
  end
  if not pt then                                     -- CAR mode, or camera/ray unavailable
    local car = ac.getCar(0)
    if car then pt = vec3(car.position.x, car.position.y, car.position.z) end
  end
  if pt then
    table.insert(editor.points, pt)
    editorSetMessage('Captured ' .. #editor.points)
  else
    editorSetMessage('Aim at the road and try again')
  end
end

-- A tall glowing pillar + ground ring marking a delivery pickup/drop, visible
-- from a distance. Additive so it reads as light.
local function beacon(pos, r, g, b)
  local blended = false
  pcall(function() render.setBlendMode(render.BlendMode.BlendAdd); blended = true end)
  local baseY, h = pos.y + 0.1, 18
  local pulse = 0.8 + 0.2 * math.sin(sessionTime * 3)
  local br, bg, bb = math.min(1, r + 0.4), math.min(1, g + 0.4), math.min(1, b + 0.4)
  local function vshell(rad, a, cr, cg, cb)
    for k = 0, 7 do
      local t0, t1 = k / 8 * math.pi * 2, (k + 1) / 8 * math.pi * 2
      local c0, s0, c1, s1 = math.cos(t0), math.sin(t0), math.cos(t1), math.sin(t1)
      pcall(function()
        local a0 = vec3(pos.x + rad * c0, baseY, pos.z + rad * s0)
        local a1 = vec3(pos.x + rad * c1, baseY, pos.z + rad * s1)
        local b1 = vec3(pos.x + rad * c1, baseY + h, pos.z + rad * s1)
        local b0 = vec3(pos.x + rad * c0, baseY + h, pos.z + rad * s0)
        local col = rgbm(cr, cg, cb, a)
        render.quad(a0, a1, b1, b0, col); render.quad(b0, b1, a1, a0, col)
      end)
    end
  end
  vshell(1.4 * pulse, 0.05, r, g, b)
  vshell(0.8, 0.12, r, g, b)
  vshell(0.4, 0.40, br, bg, bb)
  -- pulsing ground ring at the trigger radius
  local rr = DLV.radius - 0.6
  for k = 0, 23 do
    local t0, t1 = k / 24 * math.pi * 2, (k + 1) / 24 * math.pi * 2
    pcall(function()
      render.quad(
        vec3(pos.x + rr * math.cos(t0), baseY, pos.z + rr * math.sin(t0)),
        vec3(pos.x + rr * math.cos(t1), baseY, pos.z + rr * math.sin(t1)),
        vec3(pos.x + (rr + 0.7) * math.cos(t1), baseY, pos.z + (rr + 0.7) * math.sin(t1)),
        vec3(pos.x + (rr + 0.7) * math.cos(t0), baseY, pos.z + (rr + 0.7) * math.sin(t0)),
        rgbm(br, bg, bb, 0.28))
    end)
  end
  if blended then pcall(function() render.setBlendMode(render.BlendMode.AlphaBlend) end) end
end

function script.draw3D()
  pcall(function()
    render.setDepthMode(render.DepthMode.ReadOnlyLessEqual)

    -- Active delivery: beacon the current objective (green pickup / gold drop,
    -- flashing red while the cops are on you).
    if delivery.active and delivery.mission then
      local m = delivery.mission
      if delivery.stage == 'pickup' then
        beacon(m.points[1], 0.30, 1.00, 0.45)
      elseif delivery.wanted then
        beacon(m.points[#m.points], 1.00, 0.12, 0.10)
      else
        beacon(m.points[#m.points], 1.00, 0.75, 0.20)
      end
    end

    -- On-duty cops see a red beacon over every wanted runner they've picked up.
    if cop.onDuty then
      for _, w in pairs(copWanted) do
        local o = ac.getCar(w.index)
        if o and o.position and sessionTime - w.at < COP.staleAfter then
          beacon(vec3(o.position.x, o.position.y, o.position.z), 1.00, 0.10, 0.10)
        end
      end
    end

    -- Checkpoint routes: green start → cyan checkpoints → red finish, with the
    -- current target in yellow. Every road uses this exact code + the flat laser.
    for _, route in ipairs(ROUTES) do
      local pts = route.points
      if #pts >= 2 then
        -- On a hotlap the start line IS the finish line, so it stays green START
        -- until you've cleared the last checkpoint (index == #pts), then it turns
        -- into the FINISH line for the closing crossing.
        local finishing = route.hotlap and run.active and run.route == route and run.index == #pts
        for i, p in ipairs(pts) do
          -- a hotlap's closing point sits on top of the start line — skip drawing
          -- it so there's just ONE line there (the start line shows the finish).
          if not (route.hotlap and i == #pts) then
            -- orientation: baked road tangent if present (straight across the road),
            -- else fall back to the chord toward the neighbouring checkpoint
            local dx, dz, ax, az
            if route.dirs and route.dirs[i] then
              dx, dz = route.dirs[i][1], route.dirs[i][2]
              ax, az = -dz, dx
            else
              local a, b = (i < #pts) and p or pts[i - 1], (i < #pts) and pts[i + 1] or p
              dx, dz = dirXZ(a, b); ax, az = perpXZ(a, b)
            end
            local m = M_CHECK
            if i == 1 then m = finishing and M_FINISH or M_START end
            if i == #pts and not route.hotlap then m = M_FINISH end
            if run.active and run.route == route and run.index == i then m = M_ACTIVE end
            -- width: baked asphalt half-widths if present, else probe the road
            local hl, hr
            if route.hws and route.hws[i] then
              hl, hr = route.hws[i][1], route.hws[i][2]
            else
              local e = roadEdges(p, ax, az, route.checkpointRadius or CONFIG.checkpointRadius)
              hl, hr = e.l, e.r
            end
            groundLaser(p, dx, dz, ax, az, hl, hr, m[1], m[2], m[3])
          end
        end
        -- (no floating START/FINISH text — render.debugText draws through walls at
        -- any distance, so it was visible across the whole map. The colored line
        -- carries the meaning: green=start, red=finish once past the last checkpoint.)
      end
    end

    -- Drift zones: same flat laser + color code — green START line, red FINISH
    -- line — so they read consistently with route checkpoints.
    for _, zone in ipairs(DRIFT_ZONES) do
      local pts = zone.points
      if #pts >= 2 then
        local halfW = (zone.width or 8) / 2
        local sdx, sdz = dirXZ(pts[1], pts[2])
        local sax, saz = perpXZ(pts[1], pts[2])
        local se = roadEdges(pts[1], sax, saz, halfW)
        groundLaser(pts[1], sdx, sdz, sax, saz, se.l, se.r, M_START[1], M_START[2], M_START[3])
        local fdx, fdz = dirXZ(pts[#pts - 1], pts[#pts])
        local fax, faz = perpXZ(pts[#pts - 1], pts[#pts])
        local fe = roadEdges(pts[#pts], fax, faz, halfW)
        groundLaser(pts[#pts], fdx, fdz, fax, faz, fe.l, fe.r, M_FINISH[1], M_FINISH[2], M_FINISH[3])
      end
    end

    -- Editor: place any pending point (raycast needs to run here), then draw the
    -- captured nodes as blue spheres connected in order.
    editorFulfilCapture()
    for i, p in ipairs(editor.points) do
      render.debugSphere(p, 1, rgbm(0.2, 0.7, 1, 0.85))
      if i > 1 then render.debugLine(editor.points[i - 1], p, rgbm(0.2, 0.7, 1, 0.5)) end
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

-- Milliseconds -> M:SS.mmm lap time.
local function fmtLapTime(ms)
  ms = math.max(0, math.floor(tonumber(ms) or 0))
  return string.format('%d:%02d.%03d', math.floor(ms / 60000), math.floor((ms % 60000) / 1000), ms % 1000)
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
  -- Always scale the window box so resize is visible even if the native
  -- font-scale call is missing; applyFontScale scales the text on top when
  -- the build supports it.
  local sz = vec2(size.x * uiScale, size.y * uiScale)
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

-- Colored buttons for that "app" look. Self-balancing: pops exactly as many
-- style colors as were pushed, so a missing StyleColor slot can't corrupt the
-- style stack.
local BTN_TX     = rgbm(0.04, 0.06, 0.05, 1)
local BTN_BUY    = rgbm(1.00, 0.72, 0.22, 1)
local BTN_GO     = rgbm(0.22, 0.90, 0.48, 1)
local BTN_INFO   = rgbm(0.35, 0.66, 0.96, 1)
local BTN_DANGER = rgbm(0.95, 0.35, 0.35, 1)
local BTN_MUTED  = rgbm(0.28, 0.32, 0.36, 1)

local function tintBtn(label, base)
  local hover = base
  pcall(function() hover = rgbm(math.min(1, base.r * 1.25), math.min(1, base.g * 1.25), math.min(1, base.b * 1.25), 1) end)
  local pushed = 0
  pcall(function() ui.pushStyleColor(ui.StyleColor.Button, base); pushed = pushed + 1 end)
  pcall(function() ui.pushStyleColor(ui.StyleColor.ButtonHovered, hover); pushed = pushed + 1 end)
  pcall(function() ui.pushStyleColor(ui.StyleColor.ButtonActive, base); pushed = pushed + 1 end)
  pcall(function() ui.pushStyleColor(ui.StyleColor.Text, BTN_TX); pushed = pushed + 1 end)
  local clicked = ui.button(label)
  for _ = 1, pushed do pcall(function() ui.popStyleColor() end) end
  return clicked
end

local function accentSep(col)
  local ok = pcall(function() ui.pushStyleColor(ui.StyleColor.Separator, col) end)
  ui.separator()
  if ok then pcall(function() ui.popStyleColor() end) end
end

-- Compact always-on driving HUD (cash + live run/drift state).
local function drawMainHUD()
  panel('STREET RUNNERS', vec2(24, ui.windowSize().y - 220), vec2(280, 188), function()
  ui.textColored('街道走者', NEON); ui.sameLine()
  ui.textColored('«' .. titleDisplayName(storage.equippedTitle):upper() .. '»', GOLD)
  ui.textColored('BALANCE  ', DIM); ui.sameLine(); ui.textColored(money(storage.cash), WHITE)
  ui.textColored(string.format('LVL %d', playerLevel()), CYAN); ui.sameLine()
  ui.textColored(meter(levelProgress(), 8), CYAN)
  if isCopCar(currentCarId()) then
    if playerLevel() >= CONFIG.copLevel then
      ui.textColored('COP CAR · ON DUTY', NEON)
    else
      ui.textColored(string.format('COP CAR · need LVL %d', CONFIG.copLevel), DIM)
    end
  end

  if activeBoostMultiplier() > 1 then
    ui.textColored(string.format('» %dx BOOST  %s', storage.boostMultiplier, formatDuration(activeBoostRemaining())), MAGENTA)
  end

  if run.active then
    ui.separator()
    if run.route.hotlap then
      ui.textColored(string.format('HOTLAP  %s', run.route.name), CYAN)
      ui.textColored(string.format('CP %d / %d   %s', run.index, #run.route.points,
        fmtLapTime((sessionTime - run.startTime) * 1000)), WHITE)
    else
      ui.textColored(string.format('CHECKPOINT  %d / %d', run.index, #run.route.points), CYAN)
      ui.textColored(string.format('TIME  %.1fs', sessionTime - run.startTime), WHITE)
    end
  elseif lastHotlap.name and sessionTime - lastHotlap.at < 6 then
    ui.separator()
    ui.textColored(string.format('LAP DONE  %s', fmtLapTime(lastHotlap.timeMs)), NEON)
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

  if delivery.active and delivery.mission then
    ui.separator()
    ui.textColored('» DELIVERY  ' .. tostring(delivery.mission.name):upper(), GOLD)
    ui.textColored(delivery.stage == 'pickup' and 'GO TO PICKUP' or (delivery.wanted and 'SHAKE THE COPS!' or 'DELIVER THE GOODS'),
      delivery.wanted and REDC or (delivery.stage == 'pickup' and NEON or GOLD))
    local hf = delivery.heat / 100
    local heatCol = delivery.heat >= 100 and REDC or (delivery.heat > 60 and GOLD or NEON)
    ui.textColored('HEAT ', DIM); ui.sameLine()
    ui.textColored(meter(hf, 12), heatCol); ui.sameLine()
    ui.textColored(string.format('%d%%', math.floor(delivery.heat)), heatCol)
    if delivery.wanted then
      ui.textColored(string.format('WANTED — lose them! %.0fs', math.max(0, DLV.wantedTime - delivery.bustTimer)), REDC)
    end
  end
  if delivery.msg ~= '' and sessionTime < delivery.msgUntil then
    ui.textColored(delivery.msg, WHITE)
  end

  ui.separator()
  ui.textColored('Ctrl+6 app · drag move', DIM)
  ui.textColored(string.format('Ctrl+8/9 resize (%.1fx)%s', uiScale, scaleWorks and '' or ' [box only]'), DIM)
  end)
end

---------------------------------------------------------------------------
-- App tabs
---------------------------------------------------------------------------

-- Best-effort teleport to a mission's first point, facing the second. Online
-- scripts can't always move the car (server anti-cheat), so this is wrapped
-- and reports whether the call was even accepted.
local TP_BACK = 3.0        -- metres to sit behind the start line: setCarPosition places the car
                          -- ORIGIN, so ~half a car length + a couple feet puts the NOSE behind the line
local TP_LANE_SIGN = 1     -- which side is the "far right" lane; flip to -1 if it lands on the left
local teleportMsg, teleportMsgUntil = '', -1
local function teleportTo(pts, radius, dir)
  if not pts or #pts < 1 then return end
  local p = pts[1]
  local dx, dz, ax, az
  if dir then                                    -- baked road tangent = truest heading
    dx, dz = dir[1], dir[2]; ax, az = -dz, dx
  else
    dx, dz = dirXZ(pts[1], pts[2] or pts[1])
    ax, az = perpXZ(pts[1], pts[2] or pts[1])
  end
  local px, py, pz = p.x, p.y + 0.4, p.z
  if radius then
    -- drop into the far-right lane, a bit behind the line
    local lane = math.max(0, radius - 2)
    px = px + ax * lane * TP_LANE_SIGN - dx * TP_BACK
    pz = pz + az * lane * TP_LANE_SIGN - dz * TP_BACK
  end
  -- face along the route (toward the next point). setCarPosition's direction
  -- convention points the opposite way, so negate.
  local ok = pcall(function() physics.setCarPosition(0, vec3(px, py, pz), vec3(-dx, 0, -dz)) end)
  teleportMsg = ok and 'Teleporting to start...' or 'Teleport not supported on this server'
  teleportMsgUntil = sessionTime + 3
end

local function missionsTab()
  if run.active and run.route then
    ui.textColored(string.format('● ACTIVE  %s   CP %d/%d   %.1fs', run.route.name, run.index, #run.route.points, sessionTime - run.startTime), YEL3)
    ui.sameLine(); if tintBtn('Cancel##cxr', BTN_DANGER) then run.active = false; run.route = nil end
    accentSep(YEL3)
  elseif drift.active and drift.zone then
    ui.textColored(string.format('● DRIFTING  %s   score %s', drift.zone.name, comma(drift.score)), MAGENTA)
    accentSep(MAGENTA)
  elseif delivery.active and delivery.mission then
    ui.textColored(string.format('● DELIVERY  %s   %s  heat %d%%', delivery.mission.name,
      delivery.stage == 'pickup' and 'to pickup' or 'to drop', math.floor(delivery.heat)), GOLD)
    ui.sameLine(); if tintBtn('Cancel##cxd', BTN_DANGER) then delivery.active = false; delivery.mission = nil end
    accentSep(GOLD)
  end

  ui.textColored('» ROUTES', CYAN)
  if #ROUTES == 0 then
    ui.textColored('   No routes yet — capture some in the Editor tab.', DIM)
  else
    for i, r in ipairs(ROUTES) do
      local active = run.active and run.route == r
      ui.textColored((active and '● ' or '') .. r.name, active and YEL3 or WHITE); ui.sameLine(230)
      ui.textColored(money(r.baseReward) .. ' +bonus', GOLD); ui.sameLine(345)
      -- hotlaps auto-start on crossing the line and end at the finish — no Start button
      if r.hotlap then
        ui.textColored('cross line to start', DIM); ui.sameLine()
      else
        if tintBtn('Start##r' .. i, BTN_GO) then startRoute(r); appOpen = false end
        ui.sameLine()
      end
      if tintBtn('TP##tpr' .. i, BTN_INFO) then teleportTo(r.points, r.checkpointRadius or CONFIG.checkpointRadius, r.dirs and r.dirs[1]) end
      if r._id and not (r.protected or r.hotlap) then ui.sameLine(); if tintBtn('x##dr' .. r._id, BTN_DANGER) then economyDeleteMission(r._id) end end
    end
  end
  ui.separator()
  ui.textColored('» DRIFT ZONES', MAGENTA)
  if #DRIFT_ZONES == 0 then
    ui.textColored('   No zones yet — capture some in the Editor tab.', DIM)
  else
    for i, z in ipairs(DRIFT_ZONES) do
      local active = drift.active and drift.zone == z
      ui.textColored((active and '● ' or '') .. z.name, active and MAGENTA or WHITE); ui.sameLine(230)
      ui.textColored('$' .. z.payoutPer .. '/pt', GOLD); ui.sameLine(345)
      if tintBtn('TP##tpz' .. i, BTN_INFO) then teleportTo(z.points) end
      if z._id and not z.protected then ui.sameLine(); if tintBtn('x##dz' .. z._id, BTN_DANGER) then economyDeleteMission(z._id) end end
    end
  end
  ui.separator()
  ui.textColored('» DELIVERIES', GOLD)
  if #DELIVERIES == 0 then
    ui.textColored('   No deliveries yet — capture some in the Editor tab.', DIM)
  else
    for i, d in ipairs(DELIVERIES) do
      local active = delivery.active and delivery.mission == d
      ui.textColored((active and '● ' or '') .. d.name, active and GOLD or WHITE); ui.sameLine(230)
      ui.textColored(money(d.reward) .. ' +stealth', GOLD); ui.sameLine(345)
      if tintBtn('Start##dl' .. i, BTN_GO) then startDelivery(d); appOpen = false end
      ui.sameLine(); if tintBtn('TP##tpd' .. i, BTN_INFO) then teleportTo(d.points) end
      if d._id and not d.protected then ui.sameLine(); if tintBtn('x##dd' .. d._id, BTN_DANGER) then economyDeleteMission(d._id) end end
    end
  end
  if sessionTime < teleportMsgUntil then ui.textColored(teleportMsg, CYAN) end
end

local function shopTab()
  ui.textColored('» TITLES', CYAN)
  for _, item in ipairs(SHOP_ITEMS.titles) do
    local owned = ownsTitle(item.id)
    ui.textColored(item.name, owned and WHITE or DIM); ui.sameLine(280)
    if storage.equippedTitle == item.id then
      ui.textColored('EQUIPPED', NEON)
    elseif owned then
      if tintBtn('Equip##' .. item.id, BTN_GO) then shopEquipTitle(item.id) end
    else
      if tintBtn('Buy ' .. money(item.price) .. '##' .. item.id, BTN_BUY) then shopBuyTitle(item) end
    end
  end
  accentSep(CYAN)
  ui.textColored('» BOOSTS', CYAN)
  for _, item in ipairs(SHOP_ITEMS.boosts) do
    ui.textColored(item.name, WHITE); ui.sameLine(280)
    if tintBtn('Buy ' .. money(item.price) .. '##' .. item.id, BTN_BUY) then shopBuyBoost(item) end
  end
  if activeBoostMultiplier() > 1 then
    ui.separator()
    ui.textColored(string.format('Active: %dx for %s', storage.boostMultiplier, formatDuration(activeBoostRemaining())), MAGENTA)
  end
  if shopMessageTimer > 0 then ui.textColored('» ' .. shopMessage, NEON) end
end

local lbLastRefresh = -100
local function leaderboardTab()
  if economyEnabled() and sessionTime - lbLastRefresh > 4 then
    lbLastRefresh = sessionTime
    economyRefreshCashLeaderboard()
    economyRefreshArrestsLeaderboard()
    if drift.active then economyRefreshDriftLeaderboard(drift.zone.name) end
    for _, r in ipairs(ROUTES) do
      if r.hotlap then economyRefreshHotlapLeaderboard(r.name) end
    end
  end
  if drift.active then
    ui.textColored('» ZONE BEST · ' .. drift.zone.name:upper(), MAGENTA)
    ui.separator()
    local rows = economy.driftLeaderboards[drift.zone.name] or {}
    if #rows == 0 then
      ui.textColored(economyEnabled() and 'No runs yet.' or 'Economy offline.', DIM)
    else
      for i, row in ipairs(rows) do
        ui.textColored(tostring(i) .. '.', rankColor(i)); ui.sameLine(40)
        ui.textColored(row.playerName or '???', WHITE); ui.sameLine(300)
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
        ui.textColored(tostring(i) .. '.', rankColor(i)); ui.sameLine(40)
        ui.textColored(row.name or '???', WHITE); ui.sameLine(220)
        if row.title and row.title ~= '' and row.title ~= 'rookie' then
          ui.textColored('«' .. titleDisplayName(row.title) .. '»', GOLD)
        end
        ui.sameLine(420); ui.textColored(money(row.balance or 0), NEON)
      end
    end
  end

  -- Hotlap boards (fastest lap per player), one section per hotlap route.
  for _, r in ipairs(ROUTES) do
    if r.hotlap then
      ui.separator()
      ui.textColored('» ' .. tostring(r.name):upper() .. ' · BEST LAP', CYAN)
      ui.separator()
      local rows = economy.hotlapLeaderboards[r.name] or {}
      if #rows == 0 then
        ui.textColored(economyEnabled() and 'No laps yet.' or 'Economy offline.', DIM)
      else
        for i, row in ipairs(rows) do
          ui.textColored(tostring(i) .. '.', rankColor(i)); ui.sameLine(40)
          ui.textColored(row.playerName or '???', WHITE); ui.sameLine(300)
          ui.textColored(fmtLapTime(row.timeMs or 0), NEON)
        end
      end
    end
  end

  -- Cop arrests board (most busts).
  ui.separator()
  ui.textColored('» MOST BUSTS  (police)', REDC)
  ui.separator()
  if #economy.leaderboardArrests == 0 then
    ui.textColored(economyEnabled() and 'No arrests yet.' or 'Economy offline.', DIM)
  else
    for i, row in ipairs(economy.leaderboardArrests) do
      ui.textColored(tostring(i) .. '.', rankColor(i)); ui.sameLine(40)
      ui.textColored(row.name or '???', WHITE); ui.sameLine(300)
      ui.textColored(tostring(row.arrests or 0) .. ' busts', REDC)
    end
  end
end

-- LAPS tab: per-car hotlap records. Shows the best lap for each car (click a car
-- to load its ranked board), plus the selected car's leaderboard. Defaults to
-- whatever car you're currently driving.
local lapsLastRefresh, lapsSelCar = -100, {}
local function lapsTab()
  local myCar = currentCarId()
  local hasHotlap = false
  for _, r in ipairs(ROUTES) do if r.hotlap then hasHotlap = true break end end
  if not hasHotlap then ui.textColored('No lap routes yet.', DIM); return end

  if economyEnabled() and sessionTime - lapsLastRefresh > 4 then
    lapsLastRefresh = sessionTime
    for _, r in ipairs(ROUTES) do
      if r.hotlap then
        economyRefreshHotlapCars(r.name)
        local sel = lapsSelCar[r.name]
        if (not sel or sel == '') then sel = myCar end
        if sel ~= '' then economyRefreshHotlapCarBoard(r.name, sel) end
      end
    end
  end

  for _, r in ipairs(ROUTES) do
    if r.hotlap then
      ui.textColored('» ' .. tostring(r.name):upper() .. ' · LAP RECORDS', CYAN)
      if myCar ~= '' then ui.textColored('Your car: ' .. prettyCar(myCar), DIM) end
      ui.separator()
      ui.textColored('BEST PER CAR  (click to see its board)', NEON)
      local cars = economy.hotlapCars[r.name] or {}
      if #cars == 0 then
        ui.textColored(economyEnabled() and 'No laps yet — set one!' or 'Economy offline.', DIM)
      else
        for i, row in ipairs(cars) do
          local mine = row.car == myCar
          ui.textColored(tostring(i) .. '.', rankColor(i)); ui.sameLine(34)
          if tintBtn(prettyCar(row.car) .. '##lc' .. i, mine and BTN_GO or BTN_INFO) then
            lapsSelCar[r.name] = row.car
            economyRefreshHotlapCarBoard(r.name, row.car)
          end
          ui.sameLine(320); ui.textColored(fmtLapTime(row.timeMs or 0), NEON)
          ui.sameLine(430); ui.textColored(row.playerName or '???', WHITE)
        end
      end

      ui.separator()
      local sel = lapsSelCar[r.name]
      if (not sel or sel == '') then sel = (myCar ~= '' and myCar) or (cars[1] and cars[1].car) or '' end
      if sel == '' then
        ui.textColored('Select a car above to see its leaderboard.', DIM)
      else
        ui.textColored('» ' .. prettyCar(sel):upper() .. ' · TOP LAPS', GOLD)
        local board = economy.hotlapCarBoards[r.name .. '|' .. sel] or {}
        if #board == 0 then
          ui.textColored(economyEnabled() and 'No laps in this car yet.' or 'Economy offline.', DIM)
        else
          for i, row in ipairs(board) do
            ui.textColored(tostring(i) .. '.', rankColor(i)); ui.sameLine(40)
            ui.textColored(row.playerName or '???', WHITE); ui.sameLine(300)
            ui.textColored(fmtLapTime(row.timeMs or 0), NEON)
          end
        end
      end
      ui.separator()
    end
  end
end

-- COP tab: on-duty status + the live wanted list. Cop = police car + level.
-- Body of the standalone POLICE window (only drawn when on duty). Shows wanted
-- runners with an Initiate Pursuit button, or the live pursuit + bust progress.
local function copAppBody()
  ui.textColored('MPD POLICE · ON DUTY', REDC)
  accentSep(REDC)
  if cop.engaged and cop.lockIndex >= 0 then
    local w = copWanted[cop.lockIndex]
    ui.textColored('PURSUING  ' .. ((w and w.name) or 'suspect'), GOLD)
    ui.textColored(string.format('%dm away', math.floor(cop.suspectDist or 0)), WHITE)
    if cop.stopSince >= 0 then
      ui.textColored('BUSTING ', REDC); ui.sameLine()
      ui.textColored(meter(math.min(1, cop.bustHeld / COP.stopTime), 12), REDC); ui.sameLine()
      ui.textColored(string.format('%.0fs', math.max(0, COP.stopTime - cop.bustHeld)), REDC)
    else
      ui.textColored('Corner them — wait for them to STOP', DIM)
    end
    if tintBtn('END PURSUIT##cend', BTN_DANGER) then copEndPursuit(); copSetMsg('Pursuit ended') end
  else
    ui.textColored('» RADAR  (wanted in red)', REDC)
    local list = cop.nearby or {}
    if #list == 0 then
      ui.textColored('   No cars nearby.', DIM)
    else
      for _, e in ipairs(list) do
        ui.textColored(e.name, e.wanted and REDC or WHITE); ui.sameLine(150)
        ui.textColored(math.floor(e.dist) .. 'm', GOLD); ui.sameLine(210)
        if e.wanted then ui.textColored('WANTED', REDC); ui.sameLine(275) end
        if tintBtn('Pursue##rp' .. e.index, e.wanted and BTN_DANGER or BTN_GO) then copInitiatePursuit(e.index) end
      end
    end
    if isDev() then
      ui.separator()
      if tintBtn('TEST PURSUIT (self)##ctest', BTN_MUTED) then copInitiatePursuit(0) end
      ui.sameLine(); ui.textColored('dev: stop 5s to bust yourself', DIM)
    end
  end
  if cop.msg ~= '' and sessionTime < cop.msgUntil then ui.textColored(cop.msg, NEON) end
  ui.separator()
  ui.textColored(string.format('bust: stop them %ds within %dm · bounty %s', COP.stopTime, COP.bustRange, money(COP.bounty)), DIM)
end

local function editorTab()
  if tintBtn((editor.mode == 'route' and '[ ROUTE ]' or 'ROUTE') .. '##emr', editor.mode == 'route' and BTN_GO or BTN_MUTED) then editor.mode = 'route' end
  ui.sameLine()
  if tintBtn((editor.mode == 'zone' and '[ ZONE ]' or 'ZONE') .. '##emz', editor.mode == 'zone' and BTN_GO or BTN_MUTED) then editor.mode = 'zone' end
  ui.sameLine()
  if tintBtn((editor.mode == 'delivery' and '[ DELIVERY ]' or 'DELIVERY') .. '##emd', editor.mode == 'delivery' and BTN_GO or BTN_MUTED) then editor.mode = 'delivery' end
  ui.sameLine(); ui.textColored('points: ' .. #editor.points, DIM)

  ui.textColored('name', DIM); ui.sameLine()
  pcall(function() editor.name = ui.inputText('##rn', editor.name) or editor.name end)
  ui.separator()

  if tintBtn('Capture point##ec', BTN_GO) then editorCapture() end
  ui.sameLine()
  if tintBtn('Clear##ecl', BTN_DANGER) then editorClear() end
  -- where a captured point lands: free-cam aim (fly around) vs the car itself
  if tintBtn((editor.freeCam and '[ FREE CAM ]' or 'FREE CAM') .. '##ecf', editor.freeCam and BTN_GO or BTN_MUTED) then editor.freeCam = true end
  ui.sameLine()
  if tintBtn((not editor.freeCam and '[ CAR ]' or 'CAR') .. '##ecc', not editor.freeCam and BTN_GO or BTN_MUTED) then editor.freeCam = false end
  ui.sameLine(); ui.textColored(editor.freeCam and 'aim camera at road, Capture' or 'drops at the car', DIM)
  if editor.mode == 'route' then
    if tintBtn('Test drive##et', BTN_INFO) then
      if #editor.points >= 2 then
        startRoute({ name = editor.name, target = editor.target, baseReward = editor.baseReward,
          bonusPerSecond = editor.bonusPerSecond, points = editor.points })
        appOpen = false
      else editorSetMessage('Need 2+ points') end
    end
    ui.sameLine()
    if tintBtn('Save route##esv', BTN_GO) then
      if #editor.points < 2 then editorSetMessage('Need 2+ points')
      elseif not economyEnabled() then editorSetMessage('Economy offline — cannot save')
      else
        local nm = editor.name
        if nm == '' or nm == 'New Route' then nm = 'Route ' .. tostring(os.time() % 100000) end
        economySaveRoute({ name = nm, target = editor.target, baseReward = editor.baseReward,
          bonusPerSecond = editor.bonusPerSecond, points = editor.points })
        editorSetMessage('Saved "' .. nm .. '" — now in Missions')
      end
    end
  elseif editor.mode == 'delivery' then
    ui.textColored('point 1 = pickup · last point = drop', DIM)
    if tintBtn('Save delivery##esvd', BTN_GO) then
      if #editor.points < 2 then editorSetMessage('Need 2 points (pickup + drop)')
      elseif not economyEnabled() then editorSetMessage('Economy offline — cannot save')
      else
        local nm = editor.name
        if nm == '' or nm == 'New Route' then nm = 'Delivery ' .. tostring(os.time() % 100000) end
        economySaveDelivery({ name = nm, reward = editor.reward, points = editor.points })
        editorSetMessage('Saved "' .. nm .. '" — now in Missions')
      end
    end
  else
    if tintBtn('Test zone##etz', BTN_INFO) then
      if #editor.points >= 2 then
        table.insert(DRIFT_ZONES, { name = editor.name, width = editor.width, payoutPer = editor.payoutPer, points = editor.points })
      else editorSetMessage('Need 2+ points') end
    end
    ui.sameLine()
    if tintBtn('Save zone##esvz', BTN_GO) then
      if #editor.points < 2 then editorSetMessage('Need 2+ points')
      elseif not economyEnabled() then editorSetMessage('Economy offline — cannot save')
      else
        local nm = editor.name
        if nm == '' or nm == 'New Route' then nm = 'Zone ' .. tostring(os.time() % 100000) end
        economySaveZone({ name = nm, width = editor.width, payoutPer = editor.payoutPer, points = editor.points })
        editorSetMessage('Saved "' .. nm .. '" — now in Missions')
      end
    end
  end
  ui.separator()
  ui.textColored('While driving:  Ctrl+1 capture · Ctrl+2 test · Ctrl+3 copy · Ctrl+4 mode', DIM)
  if editorMessageTimer > 0 then ui.textColored('» ' .. editorMessage, GOLD) end
end

local function drawApp()
  if not appOpen then return end
  panel('STREET RUNNERS APP', vec2(360, 70), vec2(560, 300), function()
    ui.textColored('街道走者 STREET RUNNERS', NEON)
    ui.sameLine(); ui.textColored('   ' .. money(storage.cash), GOLD)
    ui.sameLine(); ui.textColored('   «' .. titleDisplayName(storage.equippedTitle):upper() .. '»', CYAN)
    accentSep(NEON)

    local ok = pcall(function()
      ui.tabBar('sr_tabs', function()
        ui.tabItem('MISSIONS', missionsTab)
        ui.tabItem('SHOP', shopTab)
        ui.tabItem('LEADERBOARD', leaderboardTab)
        ui.tabItem('LAPS', lapsTab)
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

-- Standalone POLICE window — only appears when you're a cop (police car + level),
-- separate from the runner app. Auto-shows on duty; no need to open the main app.
local function drawCopApp()
  if not copEligible() then return end
  panel('MPD POLICE APP', vec2(24, 70), vec2(300, 240), copAppBody)
end

-- Big red banner across the top of the screen: shown to a player being chased
-- or just busted. Uses the sized dwrite text API (proven in the old police app).
local function drawBanner()
  local busted = sessionTime < bustedUntil
  local chased = sessionTime < chasedUntil
  if not (busted or chased) then return end
  if math.floor(sessionTime * 3) % 2 == 1 then return end   -- blink
  local text = busted
    and ('*** BUSTED ***   ARRESTED BY ' .. (bustedBy ~= '' and bustedBy or 'POLICE'):upper())
    or  ((chasedBy ~= '' and chasedBy or 'POLICE'):upper() .. '  IS CHASING YOU')
  pcall(function()
    local sw = ui.windowSize().x
    ui.beginTransparentWindow('sr_banner', vec2(0, 0), vec2(sw, 150), true)
    pcall(function() ui.pushDWriteFont('Orbitron;Weight=Bold') end)
    local fs = 36
    local ts = ui.measureDWriteText(text, fs)
    local ox = math.floor((sw - ts.x) / 2)
    local oy = 72
    ui.drawRectFilled(vec2(ox - 16, oy - 8), vec2(ox + ts.x + 16, oy + ts.y + 8), rgbm(0.5, 0, 0, 0.6))
    ui.dwriteDrawText(text, fs, vec2(ox, oy), rgbm(1, 0.92, 0.92, 1))
    pcall(function() ui.popDWriteFont() end)
    ui.endTransparentWindow()
  end)
end

function script.drawUI()
  pcall(drawMainHUD)
  pcall(drawApp)
  pcall(drawCopApp)
  pcall(drawBanner)
end
