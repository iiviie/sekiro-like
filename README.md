# sekiro-like

A Roblox deflect-duel royale: Sekiro-style posture combat in short free-for-all rounds.
This is the **week 1–3 combat prototype**: one sword, deflects, posture, deathblows and bots, in a greybox arena.
The round loop (shrinking ring, rounds, spectating) comes after the combat feels fair at 200 ms ping.

## Setup

Tools (installed with Homebrew): `rojo` 7.7, `selene`, `stylua`. The Rojo Studio plugin is installed with `rojo plugin install`.

1. Build the place file once and open it in Roblox Studio:
   ```bash
   rojo build -o sekiro-like.rbxl
   ```
   ```bash
   open sekiro-like.rbxl
   ```
2. Start live sync, then in Studio open **Plugins → Rojo → Connect**:
   ```bash
   rojo serve
   ```
   Edits to `src/` now sync into Studio as you save.
3. In **Game Settings → Avatar**, set the avatar type to **R15**. The sword grips the R15 `RightHand`, and R15-only also
   qualifies for the higher US 18+ DevEx rate.

## Testing

- **Solo:** press Play. Three bots ("Ronin") spawn and fight you and each other.
- **Two players:** Test tab → Clients and Servers → 2 players.
- **Lag:** in Studio Settings → Network, set *Incoming Replication Lag* to 0.1–0.2 s. The week-1 gate is that deflects
  still feel fair at about 200 ms.

Lint and format before committing:

```bash
selene src && stylua --check src
```

## Controls

| Action | Keyboard / mouse | Gamepad | Touch |
|---|---|---|---|
| Slash | Left click | R1 | Slash |
| Deflect (tap just before impact) / guard (hold) | F | L1 | Block |
| Perilous thrust (unblockable) | E | Y | Thrust |
| Dodge (i-frames) | Q | B | Dodge |

Pressing block during your own windup **feints** it: you cancel the attack for a small posture cost.

## Combat rules

All numbers live in [src/shared/Config.luau](src/shared/Config.luau).

- **Attack phases.** Every attack has a windup (light 0.35 s, perilous 0.7 s), an impact time `hitAt` fixed on the server
  clock, and recovery. Clients land their swing visual on `hitAt`, so everyone sees impact at the same moment.
- **Deflect.** If you press block within 0.25 s before impact, you deflect: the attacker takes posture damage and you take a
  little. Within 0.1 s it is a **perfect** deflect, with heavy attacker posture damage and no cost to you. If you hold block
  outside the window, you **guard**, which costs your own posture. Mashing doesn't work, because presses less than 0.35 s
  apart don't re-arm the deflect.
- **Perilous attacks** (red 危) ignore deflect and guard. Dodge them.
- **Posture.** At 100 you are **broken** for 1.6 s, and any hit in that time is a **deathblow** (忍殺, instant kill).
  Posture recovers after 1.2 s without posture damage, and faster while guarding.
- **Netcode.** Clients send only intents, stamped with `workspace:GetServerTimeNow()`. The server clamps each stamp to at most
  0.25 s in the past and resolves each hit 0.15 s after impact, so a deflect pressed on time on the defender's screen
  counts while its packet is still in flight. The server owns posture, health and every outcome, and rate-limits each
  player to 20 actions per second.

## Code map

```
src/
  shared/   (ReplicatedStorage.Shared)
    Config.luau         all tuning numbers
    Types.luau          combat states, actions, the "Combatant" tag
    SwordPoses.luau     greybox sword poses (stand-ins for animations)
  server/   (ServerScriptService.Server)
    init.server.luau    boots arena, combat, bots
    CombatService.luau  state machine, hit resolution, posture, remote handling
    BotService.luau     bot opponents that use the same entry point as players
    SwordRig.luau       welds the sword to a character
    ArenaBuilder.luau   greybox floor, pillars, spawn, lighting
  client/   (StarterPlayerScripts.Client)
    init.client.luau    boots input, HUD, visuals
    CombatInput.luau    bindings, soft lock-on, dodge dash
    CombatVisuals.luau  sword poses, telegraphs, sparks, text, camera shake
    CombatHUD.luau      posture and health bars
```

## Known shortcuts (by design for now)

- **No animations yet.** The sword pose is tweened on its weld. Real deflect, posture-break and deathblow animations come
  after the fun gate, since they are the most expensive art.
- **Hits are detected on the server** with a box in front of the attacker. Moving targets are judged from the server's
  slightly delayed view. If that feels unfair, switch to detecting on the attacker's client and validating on the server.
- **The attacker's windup isn't predicted locally**, so your own swing starts one round trip after you click.
- **Classic replication, not Server Authority mode.** The combat rules are isolated in `CombatService`, so moving them
  into `BindToSimulation` later is a contained change.

## Next

1. Playtest at 0–200 ms lag and tune `Config.Deflect` and `Config.Posture` until duels last 10–20 s.
2. Add a heavy attack and a second perilous attack (sweep), plus a whiff penalty for failed deflects.
3. Build the round loop: 12–16 player server, shrinking ring, 3–5 minute rounds, bots filling empty slots, instant requeue.
