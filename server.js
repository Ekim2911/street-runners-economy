const express = require('express');
const cors = require('cors');
const { DatabaseSync } = require('node:sqlite'); // built-in; needs Node >= 22.5
const fs = require('fs');
const path = require('path');

const PORT = process.env.PORT || 3000;
const API_KEY = process.env.ECONOMY_API_KEY || '';
const STARTING_BALANCE = 5000;
// The Lua lives next to server.js by default. On a host with an ephemeral
// filesystem (e.g. Railway) point DB_PATH at a mounted volume so the SQLite
// file survives redeploys/restarts.
const SCRIPT_TEMPLATE_PATH = process.env.SCRIPT_PATH || path.join(__dirname, 'street_runners_missions.lua');
const DB_PATH = process.env.DB_PATH || path.join(__dirname, 'economy.db');
const STEAM_ID_PLACEHOLDER = '__STEAM_ID__';
const STEAM_ID_PATTERN = /^\d{15,20}$/;
const PUBLIC_PATHS = new Set(['/health', '/script.lua']);

fs.mkdirSync(path.dirname(DB_PATH), { recursive: true });
const db = new DatabaseSync(DB_PATH);
db.exec('PRAGMA journal_mode = WAL;');

db.exec(`
  CREATE TABLE IF NOT EXISTS players (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL DEFAULT 'Runner',
    title TEXT NOT NULL DEFAULT '',
    balance INTEGER NOT NULL DEFAULT ${STARTING_BALANCE},
    updated_at INTEGER NOT NULL
  );

  CREATE TABLE IF NOT EXISTS drift_runs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    zone_id TEXT NOT NULL,
    zone_name TEXT NOT NULL,
    player_id TEXT NOT NULL,
    player_name TEXT NOT NULL,
    score REAL NOT NULL,
    combo_max REAL NOT NULL DEFAULT 1,
    created_at INTEGER NOT NULL
  );

  CREATE INDEX IF NOT EXISTS idx_drift_runs_zone_player
    ON drift_runs (zone_id, player_id, score DESC);

  CREATE TABLE IF NOT EXISTS hotlap_runs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    route_id TEXT NOT NULL,
    route_name TEXT NOT NULL,
    player_id TEXT NOT NULL,
    player_name TEXT NOT NULL,
    car TEXT NOT NULL DEFAULT '',
    time_ms INTEGER NOT NULL,
    created_at INTEGER NOT NULL
  );

  CREATE INDEX IF NOT EXISTS idx_hotlap_runs_route_car_player
    ON hotlap_runs (route_id, car, player_id, time_ms ASC);

  CREATE TABLE IF NOT EXISTS missions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    kind TEXT NOT NULL,        -- 'route' | 'zone'
    name TEXT NOT NULL,
    data TEXT NOT NULL,        -- JSON of the full mission definition
    created_at INTEGER NOT NULL,
    UNIQUE (kind, name)
  );
`);

// Upgrade path for databases created before the `title` column existed.
try {
  db.exec("ALTER TABLE players ADD COLUMN title TEXT NOT NULL DEFAULT ''");
} catch (e) {
  // already has the column
}
// Upgrade path for hotlap_runs created before per-car tracking.
try {
  db.exec("ALTER TABLE hotlap_runs ADD COLUMN car TEXT NOT NULL DEFAULT ''");
} catch (e) {
  // already has the column
}

const getPlayer = db.prepare('SELECT id, name, title, balance FROM players WHERE id = ?');
const insertPlayer = db.prepare(
  'INSERT INTO players (id, name, title, balance, updated_at) VALUES (?, ?, ?, ?, ?)'
);
const updatePlayer = db.prepare(
  'UPDATE players SET balance = ?, name = ?, title = ?, updated_at = ? WHERE id = ?'
);
const topCash = db.prepare('SELECT name, title, balance FROM players ORDER BY balance DESC LIMIT ?');
const deletePlayer = db.prepare('DELETE FROM players WHERE id = ?');
const insertDriftRun = db.prepare(`
  INSERT INTO drift_runs (zone_id, zone_name, player_id, player_name, score, combo_max, created_at)
  VALUES (?, ?, ?, ?, ?, ?, ?)
`);
// Best single run per player for a zone, ranked descending.
const zoneLeaderboard = db.prepare(`
  SELECT player_name AS playerName, MAX(score) AS score, MAX(combo_max) AS comboMax
  FROM drift_runs
  WHERE zone_id = ?
  GROUP BY player_id
  ORDER BY score DESC
  LIMIT ?
`);

const insertHotlapRun = db.prepare(`
  INSERT INTO hotlap_runs (route_id, route_name, player_id, player_name, car, time_ms, created_at)
  VALUES (?, ?, ?, ?, ?, ?, ?)
`);
// Best (fastest) lap per player for a route, ranked ascending (all cars).
const hotlapLeaderboard = db.prepare(`
  SELECT player_name AS playerName, car, MIN(time_ms) AS timeMs
  FROM hotlap_runs
  WHERE route_id = ?
  GROUP BY player_id
  ORDER BY timeMs ASC
  LIMIT ?
`);
// Best lap per player for a route WITH a specific car, ranked ascending.
const hotlapLeaderboardByCar = db.prepare(`
  SELECT player_name AS playerName, car, MIN(time_ms) AS timeMs
  FROM hotlap_runs
  WHERE route_id = ? AND car = ?
  GROUP BY player_id
  ORDER BY timeMs ASC
  LIMIT ?
`);
// Overall best lap for each car on a route (with who holds it), fastest cars first.
const hotlapCars = db.prepare(`
  SELECT car, player_name AS playerName, MIN(time_ms) AS timeMs, COUNT(DISTINCT player_id) AS drivers
  FROM hotlap_runs
  WHERE route_id = ? AND car <> ''
  GROUP BY car
  ORDER BY timeMs ASC
  LIMIT ?
`);

const listMissions = db.prepare('SELECT id, kind, name, data FROM missions ORDER BY kind, name');
// Upsert by (kind, name): a re-saved route replaces the old one.
const upsertMission = db.prepare(`
  INSERT INTO missions (kind, name, data, created_at) VALUES (?, ?, ?, ?)
  ON CONFLICT(kind, name) DO UPDATE SET data = excluded.data
`);
const deleteMission = db.prepare('DELETE FROM missions WHERE id = ?');

// Seed canonical, generated routes (e.g. the H1 Hotlap) on startup. Upserted so
// a redeploy with a regenerated seed updates the course; edit the JSON + redeploy
// to tune it.
function seedMissions() {
  for (const file of ['seed_h1_hotlap.json']) {
    try {
      const p = path.join(__dirname, file);
      if (!fs.existsSync(p)) continue;
      const seed = JSON.parse(fs.readFileSync(p, 'utf8'));
      if (seed && seed.name && seed.data && Array.isArray(seed.data.points)) {
        upsertMission.run(seed.kind || 'route', String(seed.name), JSON.stringify(seed.data), Date.now());
        console.log(`Seeded ${seed.kind || 'route'}: ${seed.name} (${seed.data.points.length} points)`);
      }
    } catch (e) {
      console.error(`seed ${file} failed:`, e.message);
    }
  }
}
seedMissions();

// Clamp a client-supplied limit to a sane range. Guards against a negative
// value, which SQLite would treat as "no limit" and dump the whole table.
function parseLimit(raw) {
  const n = Math.floor(Number(raw));
  if (!Number.isFinite(n) || n < 1) return 10;
  return Math.min(50, n);
}

function ensurePlayer(id, name, title) {
  let player = getPlayer.get(id);
  if (!player) {
    insertPlayer.run(id, name || 'Runner', title || '', STARTING_BALANCE, Date.now());
    player = getPlayer.get(id);
  }
  return player;
}

const app = express();
app.use(cors());
// Accept JSON and form-encoded bodies, and tolerate a wrong/missing
// Content-Type by also parsing text/* as JSON — CSP's web.post body encoding
// varies, so we normalize on the server side.
app.use(express.json({ type: ['application/json', 'text/*'] }));
app.use(express.urlencoded({ extended: true }));

if (API_KEY) {
  app.use((req, res, next) => {
    // /script.lua is fetched directly by the game client (via AssettoServer's
    // csp_extra_options.ini SCRIPT= line), which can't attach custom headers,
    // so it — like /health — can't be gated behind the shared secret.
    if (PUBLIC_PATHS.has(req.path)) return next();
    if (req.get('x-economy-key') !== API_KEY) {
      return res.status(401).json({ error: 'unauthorized' });
    }
    next();
  });
}

app.get('/health', (req, res) => res.json({ ok: true }));

// Serves the mission script with the requesting player's real Steam64 id
// baked in, when AssettoServer's SCRIPT line uses the {SteamID} placeholder:
//   SCRIPT = "http://<host>:3000/script.lua?steamid={SteamID}"
// AssettoServer substitutes {SteamID} per connecting client before the
// client's CSP fetches this URL, so the id in the query string reflects the
// actual authenticated Steam connection, not something the player can pick
// by editing their own client config.
app.get('/script.lua', (req, res) => {
  let template;
  try {
    template = fs.readFileSync(SCRIPT_TEMPLATE_PATH, 'utf8');
  } catch (e) {
    return res.status(500).send('-- street_runners_missions.lua not found next to the economy server');
  }
  const raw = String(req.query.steamid || '').trim();
  const steamId = STEAM_ID_PATTERN.test(raw) ? raw : '';
  const script = template.split(STEAM_ID_PLACEHOLDER).join(steamId);
  res.set('Content-Type', 'text/plain; charset=utf-8');
  res.set('Cache-Control', 'no-store');
  res.send(script);
});

app.get('/players/:id', (req, res) => {
  const player = ensurePlayer(req.params.id, req.query.name, req.query.title);
  res.json(player);
});

app.post('/players/:id/earn', (req, res) => {
  const { name, title } = req.body || {};
  // Coerce so a numeric string (form-encoded body) is accepted too.
  const amount = Number((req.body || {}).amount);
  if (!Number.isFinite(amount)) {
    return res.status(400).json({ error: 'amount must be a number' });
  }
  const player = ensurePlayer(req.params.id, name, title);
  const newBalance = player.balance + Math.round(amount);
  const newName = name || player.name;
  const newTitle = title !== undefined ? title : player.title;
  updatePlayer.run(newBalance, newName, newTitle, Date.now(), req.params.id);
  res.json({ id: req.params.id, name: newName, title: newTitle, balance: newBalance });
});

app.get('/leaderboard/cash', (req, res) => {
  res.json(topCash.all(parseLimit(req.query.limit)));
});

// Admin: remove a player (e.g. test data or a cheater). Open unless
// ECONOMY_API_KEY is set, in which case the shared-secret middleware gates it
// like the other write endpoints — recommended before going public.
app.delete('/players/:id', (req, res) => {
  const info = deletePlayer.run(req.params.id);
  res.json({ deleted: Number(info.changes) });
});

app.post('/drift/runs', (req, res) => {
  const { zoneId, zoneName, playerId, playerName } = req.body || {};
  const score = Number((req.body || {}).score);
  const comboMax = Number((req.body || {}).comboMax) || 1;
  if (!zoneId || !playerId || !Number.isFinite(score)) {
    return res.status(400).json({ error: 'zoneId, playerId, and numeric score are required' });
  }
  insertDriftRun.run(
    zoneId,
    zoneName || zoneId,
    playerId,
    playerName || 'Runner',
    score,
    comboMax,
    Date.now()
  );
  res.status(201).json({ ok: true });
});

app.get('/drift/leaderboard/:zoneId', (req, res) => {
  res.json(zoneLeaderboard.all(req.params.zoneId, parseLimit(req.query.limit)));
});

app.post('/hotlap/runs', (req, res) => {
  const { routeId, routeName, playerId, playerName, car } = req.body || {};
  const timeMs = Number((req.body || {}).timeMs);
  if (!routeId || !playerId || !Number.isFinite(timeMs) || timeMs <= 0) {
    return res.status(400).json({ error: 'routeId, playerId, and positive numeric timeMs are required' });
  }
  insertHotlapRun.run(
    routeId,
    routeName || routeId,
    playerId,
    playerName || 'Runner',
    String(car || ''),
    Math.round(timeMs),
    Date.now()
  );
  res.status(201).json({ ok: true });
});

// Ranked players. With ?car=<id> it's that car's board; otherwise all cars.
app.get('/hotlap/leaderboard/:routeId', (req, res) => {
  const limit = parseLimit(req.query.limit);
  const car = req.query.car;
  if (car != null && car !== '') {
    return res.json(hotlapLeaderboardByCar.all(req.params.routeId, String(car), limit));
  }
  res.json(hotlapLeaderboard.all(req.params.routeId, limit));
});

// Best lap for each car on a route (for the LAPS tab's per-car list).
app.get('/hotlap/cars/:routeId', (req, res) => {
  res.json(hotlapCars.all(req.params.routeId, parseLimit(req.query.limit)));
});

// --- Server-managed missions (routes + drift zones) ---
// Clients GET these on join and render them; the in-game editor POSTs new ones.

app.get('/routes', (req, res) => {
  const rows = listMissions.all().map((r) => {
    let data = null;
    try { data = JSON.parse(r.data); } catch (e) { data = null; }
    return { id: r.id, kind: r.kind, name: r.name, data };
  }).filter((r) => r.data);
  res.json(rows);
});

app.post('/routes', (req, res) => {
  const { kind, name, data } = req.body || {};
  if ((kind !== 'route' && kind !== 'zone') || !name || typeof data !== 'object' || data == null) {
    return res.status(400).json({ error: "kind ('route'|'zone'), name, and data object are required" });
  }
  if (!Array.isArray(data.points) || data.points.length < 2) {
    return res.status(400).json({ error: 'data.points must have at least 2 points' });
  }
  upsertMission.run(kind, String(name), JSON.stringify(data), Date.now());
  const saved = listMissions.all().find((r) => r.kind === kind && r.name === String(name));
  res.status(201).json({ id: saved ? saved.id : null, kind, name });
});

app.delete('/routes/:id', (req, res) => {
  const info = deleteMission.run(Number(req.params.id));
  res.json({ deleted: Number(info.changes) });
});

// POST alias for delete — the game client uses web.post (DELETE method isn't
// reliably available in CSP's web API).
app.post('/routes/:id/delete', (req, res) => {
  const info = deleteMission.run(Number(req.params.id));
  res.json({ deleted: Number(info.changes) });
});

app.listen(PORT, '0.0.0.0', () => {
  console.log(`Street Runners economy server listening on :${PORT}`);
});
