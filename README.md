# Street Runners Economy Server

Node.js + SQLite backend for `street_runners_missions.lua`. Tracks player cash
balances, titles, and per-zone drift leaderboards so progress survives
reconnects and is shared across players. It also serves the mission script
itself, personalized with each player's real Steam64 id.

## Setup

Requires **Node.js 22.5 or newer** — the server uses Node's built-in
`node:sqlite` module, so there's no native build step and `npm install` only
pulls pure-JS packages (Express + CORS). No compiler / Python / build tools
needed.

```
cd economy-server
npm install
npm start
```

Server listens on port 3000 by default (`PORT` env var to change). Data is
stored in `economy.db` (SQLite, WAL mode) next to `server.js`.

Then point the script at it — set in `street_runners_missions.lua`:

```lua
CONFIG.economyUrl = 'http://<your ip>:3000'
```

Re-host the script and restart the server. Leave `economyUrl` blank and the
script runs in local-only mode (cash stored per-client, no leaderboards, no
title sync — the shop still works, it just doesn't share state).

## SteamID identity (recommended)

By default the script mints a random per-install id, which resets if local
storage is cleared and isn't tied to a real Steam account. To bind economy
balances to an actual Steam64 id instead, host the script *through this
server* rather than as a static file, and let AssettoServer inject the id:

```ini
[SCRIPT_1]
SCRIPT = "http://<your ip>:3000/script.lua?steamid={SteamID}"
```

AssettoServer resolves `{SteamID}` per connecting client (it knows this from
the actual Steam auth handshake) before that client's CSP fetches the URL, so
`/script.lua` serves each player a copy of the script with their real Steam64
id baked in as a literal. The script picks it up automatically — no config
change needed on the Lua side.

`/script.lua` reads `street_runners_missions.lua` (in this folder, or the
`SCRIPT_PATH` env var if set) on every request, so editing that file and
re-hosting the routes doesn't require restarting the server.

## Deploy to Railway

Railway runs the app continuously (no idle-sleep) and gives you an HTTPS
domain, which is a clean fit. Two Railway-specific gotchas are already handled
in `server.js`: it binds `0.0.0.0`, reads Railway's dynamic `PORT`, and takes
`DB_PATH` so the SQLite file can live on a persistent volume.

1. Push this `economy-server/` folder to a GitHub repo (see below).
2. On Railway: **New Project → Deploy from GitHub repo**, pick the repo. If the
   repo root isn't `economy-server`, set **Root Directory** to `economy-server`
   in the service settings. Nixpacks auto-detects Node (from `engines`) and
   runs `npm start`.
3. **Add a Volume** (service → Variables/Settings → Volumes), mount path e.g.
   `/data`. Then add a variable **`DB_PATH=/data/economy.db`** so the economy
   persists across redeploys. Without this the DB resets on every deploy.
4. (Optional) add **`ECONOMY_API_KEY=<something>`** to require the shared
   secret, and set the matching `CONFIG.apiKey` in the Lua.
5. Railway gives you a public URL like `https://<app>.up.railway.app`. Use it:
   - In `street_runners_missions.lua`: `CONFIG.economyUrl = 'https://<app>.up.railway.app'`
   - In the AC server's `cfg/csp_extra_options.ini`:
     ```ini
     [SCRIPT_1]
     SCRIPT = "https://<app>.up.railway.app/script.lua?steamid={SteamID}"
     ```
   (No port needed — Railway proxies 443 to the app. Don't set `PORT` yourself;
   Railway injects it.)

First push to GitHub:

```
cd economy-server
git init
git add .
git commit -m "Street Runners economy server"
git branch -M main
git remote add origin https://github.com/<you>/<repo>.git
git push -u origin main
```

`node_modules/` and `economy.db*` are gitignored, so only source is pushed.

## Running with pm2 (keep it alive across reboots — for a VPS, not Railway)

```
npm install -g pm2
pm2 start server.js --name street-runners-economy
pm2 save
pm2 startup
```

## Endpoints

| Method | Path                          | Body / Query                                   | Notes |
|--------|-------------------------------|-------------------------------------------------|-------|
| GET    | `/health`                     | —                                               | liveness check, never requires the API key |
| GET    | `/script.lua`                 | `?steamid=` (from AssettoServer's `{SteamID}`)  | serves the mission script with the id baked in; never requires the API key |
| GET    | `/players/:id`                | `?name=&title=` (optional, set on first create) | creates the player at $5,000 if new |
| POST   | `/players/:id/earn`           | `{ amount, name, title }`                       | adds `amount` (negative = spend, used by the shop) to balance; updates name/title if given |
| GET    | `/leaderboard/cash`           | `?limit=10`                                     | top players by balance, includes `title` |
| POST   | `/drift/runs`                 | `{ zoneId, zoneName, playerId, playerName, score, comboMax }` | records one drift run |
| GET    | `/drift/leaderboard/:zoneId`  | `?limit=10`                                     | **best single run per player** for that zone, ordered by score desc |

The drift leaderboard is deliberately "best run per player", not every run —
so one lucky combo doesn't bury a player's own entry with duplicates.

There's no separate "spend" endpoint — the shop (titles + payout boosts) just
calls `earn` with a negative amount, same as any other balance adjustment.

## Security notes (read before going public)

This is trust-based: the client (the Lua script) reports its own earnings,
spends, and scores, so a modified client could report whatever it wants.
Fine for a friends server, not cheat-proof. Two hardening steps are wired up:

1. **Shared secret** — set `ECONOMY_API_KEY` in the server's environment and
   the matching `CONFIG.apiKey` in the Lua script. Every request except
   `/health` and `/script.lua` then requires an `x-economy-key` header
   matching it (those two stay open because the game client fetches them
   directly and can't attach custom headers).
2. **SteamID keying** — see the section above. This raises the bar
   meaningfully (the id comes from AssettoServer's real Steam auth, not
   something the player can set in their own client config) but isn't
   cryptographically airtight — a sufficiently motivated player intercepting
   their own network traffic could still spoof requests to the API directly.

The real fix, if this ever needs to be fully cheat-proof, is validating
runs/earnings server-side (e.g. a small AssettoServer C# plugin that knows
actual car state) instead of trusting client-reported numbers.
