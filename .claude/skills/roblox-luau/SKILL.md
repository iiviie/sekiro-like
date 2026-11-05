---
name: roblox-luau
description: Roblox engineering standards for this repo (LAST BLADE). Load before writing or editing any .luau file in src/ — server services, client modules, shared config, remotes, DataStores, UI, VFX. Covers strict Luau typing, server authority and remote validation, the service/start() pattern, replication via attributes, performance, memory leaks, DataStore safety, and lint/format rules.
---

# Roblox / Luau standards for LAST BLADE

## Project layout (Rojo, see `default.project.json`)

| Folder | Lands in | Runs on |
|---|---|---|
| `src/server/` | `ServerScriptService.Server` | server only; `init.server.luau` requires every service and calls `.start()` in order |
| `src/client/` | `StarterPlayerScripts.Client` | each client; `init.client.luau` is the entry |
| `src/shared/` | `ReplicatedStorage.Shared` | both; pure data + helpers, no side effects at require time |
| Remotes | `ReplicatedStorage.Remotes` (declared in `default.project.json`) | `CombatAction`, `CombatEvent`, `RoundEvent`, `LobbyAction` |

- A new remote goes into `default.project.json`, then **restart `rojo serve`** (project structure doesn't hot-reload). Prefer adding an action string to an existing remote over a new remote.
- New server service: a ModuleScript returning a table with `start()`, required and started in `init.server.luau` in dependency order (before `DevHooks.start()`; `WorldReady` is set last).
- Tunable numbers go in `src/shared/Config.luau` (combat), `EconomyConfig.luau` (economy), `Season.luau`, `Catalog.luau` (items). Never hard-code a balance number inside a service.
- Files named `Baked*`, `KannagiMoves/*`, `BossLeads.luau` are **generated** — don't hand-edit; regenerate from their tools (see README).

## Code style

- Every file starts with `--!strict`. Type function params and module tables; use `unknown` for anything from the network and narrow it with `typeof`.
- Tabs, 120 columns, double quotes, always parentheses on calls (`stylua.toml`). Lint std is `roblox` (`selene.toml`).
- `local X = game:GetService("X")` at the top; never `game.X`.
- Use the `task` library: `task.wait`, `task.spawn`, `task.delay`, `task.defer`. Never `wait`, `spawn`, `delay` (deprecated, throttled).
- Comments explain *why* in plain words (the codebase's tone), not what the line does.

## Server authority (non-negotiable)

The server owns every outcome: hits, damage, posture, currency, inventory, match results. Clients send **intents** only.

Every `OnServerEvent` handler must:
1. Treat all arguments as `unknown`; check `typeof(...)` and ranges before use. Reject NaN/inf numbers (`x ~= x`, `math.abs(x) == math.huge`).
2. Look up actions in a handler table (`handlers[action :: string]`) rather than `if/elseif` on strings — see `LobbyService.luau`.
3. Rate-limit per player (token bucket like `PassService` `buckets[player]`), and clear per-player tables on `Players.PlayerRemoving`.
4. Re-check state on the server (is the player alive? in this match? owns the item? can afford it?) — never trust a client flag.
5. Clamp client timestamps (combat uses `workspace:GetServerTimeNow()` stamps clamped to 0.25 s in the past).

Never put secrets, prices that matter, or authority logic in `src/shared/` or `src/client/` — clients can read and modify anything replicated to them.

## Replication

- Prefer **attributes** (`SetAttribute`/`GetAttributeChangedSignal`) for state the client displays (round phase, currency, timers). Clients derive per-frame values from the synced clock rather than receiving per-frame updates.
- Fire remotes for one-off events (a hit landed, a toast), not for continuous state.
- Don't send whole tables every change; send the delta or a version number.

## Performance

- No per-frame work in HUD code; react to signals and animate with `TweenService`. If something must run per frame, use `RunService.Heartbeat`/`RenderStepped` once, gated so it only runs while needed (e.g. only during a match).
- Decorative parts: `CanCollide/CanQuery/CanTouch = false`, `CastShadow = false` for small parts. Anchor static geometry.
- Pool frequently created instances (beams, particles, UI rows) instead of `Instance.new` + `Destroy` each time.
- Cache `FindFirstChild` results; avoid `GetDescendants()` in hot paths.
- Highlight cap is ~31 rendered at once — count before adding more.
- Spatial queries: `workspace:GetPartBoundsInBox` / `Raycast` with an `OverlapParams`/`RaycastParams` built once and reused.

## Memory leaks

- Store every `RBXScriptConnection` you create for a player/character/match and `:Disconnect()` it when that scope ends.
- Key per-player tables by `Player` and nil them in `PlayerRemoving`; clear per-character data on `Humanoid.Died`/`AncestryChanged`.
- Loops started with `task.spawn` must have an exit condition (player left, match ended).

## DataStores (StatsService owns them)

- All profile reads/writes go through `StatsService` (session-locked schema-3 profile in `PlayerData_v2`). Don't open new DataStores ad hoc.
- Wrap every DataStore call in `pcall` with retries/backoff; respect the request budget (`DataStoreService:GetRequestBudgetForRequestType`).
- Use `UpdateAsync`, not `SetAsync`, for anything that could race.
- Developer product purchases: grant only after the save commits; record `PurchaseId` for idempotency (see `Monetization.luau`). Return `Enum.ProductPurchaseDecision.NotProcessedYet` on failure.
- Bump the schema and write a migration rather than changing a field's meaning.

## Client

- UI: build in code with the shared `UI.luau` helpers and `Palette.luau` colours; use scale sizing/`UIScale` and check at 844×390 (phone landscape) — touch targets ≥ 45 px.
- Input: go through `CombatInput` / `InputNames` so keyboard, gamepad and touch all work. Check `gameProcessedEvent`.
- Predict locally for feel (start the animation on press), but render the server's verdict when it arrives.

## Lint and format

`selene` and `stylua` may not be installed on Windows. If they are on PATH, run after edits:
```powershell
stylua src
selene src
```
If they aren't, match the existing style by hand and say lint wasn't run.

## After editing

Rojo live sync pushes the change into Studio. Tell the user what to test in Play (and which test hooks or workspace attributes help — see the `roblox-playtest` skill). You can't press Play yourself.
