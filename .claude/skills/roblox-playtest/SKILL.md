---
name: roblox-playtest
description: How to verify a change in this Roblox game. Use after any gameplay, UI, economy or boss change, or when the user asks how to test something — gives the exact Studio steps, command-bar snippets and built-in test hooks (CombatTest, BossTest, PassTest, ShopTest, workspace attributes) so the user can confirm it works.
---

# Playtesting LAST BLADE

Claude can't press Play or read Studio's Output directly. So after a change:
1. Make sure `rojo serve` is running and Studio is connected (see `rojo-workflow`).
2. Give the user a **short, numbered test plan**: what to do in Play, and what they should see.
3. Give **copy-paste command bar snippets** (View → Command Bar) where a hook makes the test faster. Server snippets need the Server view selected during Play (the "Current: Server/Client" toggle on the Test tab).
4. Ask them to paste any red Output errors back.

## Fast setup attributes (command bar, server)

```lua
workspace:SetAttribute("HoldIntermission", true)      -- lobby countdown never finishes
workspace:SetAttribute("ForceOmen", "BloodMoon")      -- or "IronWill", "RushingMist"
workspace:SetAttribute("VfxSlowMo", 0.1)              -- slow combat VFX for inspection
workspace:SetAttribute("GaitMode", "procedural")      -- or "hybrid"
```
Client: `workspace:SetAttribute("ForceTouchHUD", true)` shows the phone controls with a mouse.
Studio's **Test → Device emulator** checks phone layouts (844×390 landscape is the target).

## Test hooks (ServerStorage, Studio only, from `src/server/DevHooks.luau`)

```lua
local SS = game:GetService("ServerStorage")
-- Combat: dummies, exact-timed actions, state, damage
SS.CombatTest:Invoke("damage", "player", 500)          -- tests the Resurrection
SS.CombatTest:Invoke("grant", "Coins", 5000)           -- marks session as test, never saved
SS.CombatTest:Invoke("economy", "buy", "<itemId>")
-- Bosses
SS.BossTest:Invoke("start", "Enemy01")
SS.BossTest:Invoke("god", true)
print(SS.BossTest:Invoke("state"))
SS.BossTest:Invoke("stop")
-- Season pass / shop
SS.PassTest:Invoke("xp", 5000)
SS.ShopTest:Invoke("simulate", "<pool>", 10000, 1)
```
Read `src/server/DevHooks.luau` for the exact argument names before suggesting a call; the README's "Test hooks" and "Testing" sections list them all.

Client previews: `PlayerScripts.CosmeticTest:Invoke(fn, ...)`, `PlayerScripts.AnimTest:Invoke("sample", model, clip, windup, t)`, and `require(...).preview()` on `DuelHUD` / `Podium`.

## Multiplayer checks

Anything touching remotes, replication, matchmaking or duels: **Test → Clients and Servers → Start** with 2 players. Check both clients see the same thing and that a player leaving mid-action doesn't error.

## Before calling a change done

- No new red errors or warnings in Output on Play.
- Works on keyboard, gamepad and touch if it involves input.
- Balance changes: after a few royales the server prints `Telemetry` totals and alarms — ask the user to check them.
- DataStores: Studio uses an in-memory store unless `ServerStorage.UseRealDataStore` exists. Don't enable it unless asked.
