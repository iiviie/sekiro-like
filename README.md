# LAST BLADE (working title)

A Roblox posture-and-deflect sword royale. Free-for-all rounds in a castle courtyard: deflect to break posture, punish
broken opponents with a deathblow, and be the last blade standing while a ring of red mist closes in.

## Setup

Tools (installed with Homebrew): `rojo` 7.7, `selene`, `stylua`. The Rojo Studio plugin is installed with
`rojo plugin install`.

1. Open `sekiro-like.rbxl` in Roblox Studio. It holds the hand-placed props (torii, lanterns, trees, pagoda, distant
   mountains) in `Workspace.Props`. Don't overwrite it with `rojo build` while it's open; build to another path instead.
2. Start live sync, then in Studio open **Plugins → Rojo → Connect**:
   ```bash
   rojo serve
   ```
   Restart `rojo serve` after changing `default.project.json`; it doesn't hot-reload project structure.
3. In **Game Settings → Avatar**, set the avatar type to **R15**.

## Playing

Press Play. A letterboxed title card (a slow dolly toward the shrine) shows first; click or press any key to enter.

- **Lobby.** You arrive on a floating shrine island above the castle. New players start **queued**, so the first fight
  comes within ~15 s; press **PLAY** (or step on the glowing red pad) to join or leave the queue. While anyone is queued
  a 12 s countdown runs. Lobby PvP is off by default (turning it on takes 3 s); with it off nobody can touch you except
  the **Deflect Trainer**, which swings at whoever steps into its sand ring and never deals damage. Fall off the island
  and you're put back.
- **Menus** (bottom bar): **Weapons** (equip, or unlock with coins), **Store** (how coins are earned; gem packs once
  developer products exist), **Profile** (wins, losses, W/L, kills, deathblows, most used weapons, ranked season tier
  and rating), **Rewards** (7-day daily streak, gems on day 7), **Settings** (camera shake, hitstop, controls hint).
- **Match:** queued players plus bots filling up to six fighters start on a circle around the courtyard. After 20 s a
  ring of red mist starts closing and hurts anyone outside it. No respawns; fallen players spectate for a few seconds,
  then return to the lobby. The last one standing wins.
- **Results:** a victory banner, coins (play 10, kill 15, deathblow +5, win 60), ranked rating (pairwise Elo against the
  other humans you placed above or below; bots don't count), then everyone back to the lobby.

Everything persists with DataStores in `PlayerData_v2` (old `PlayerStats_v1` Wins/Kills migrate on first visit), and
is session-only in an unpublished place.

| Action | Keyboard / mouse | Gamepad | Touch |
|---|---|---|---|
| Slash (rhythm for a 3-hit string; pause before the 3rd for an overhead) | Left click | R1 | Slash |
| Deflect (tap just before impact) / guard (hold) | F | L1 | Block |
| Dodge (i-frames; dash *into* a thrust for a Mikiri Counter) | Q | B | Dodge |
| Perilous thrust (unblockable) | E | Y | Thrust |
| Perilous sweep (unblockable; jump over it) | C | X | Sweep |
| Healing gourd (3 sips per life) | G | D-pad up | Heal |
| Lock on / off | R or middle mouse | R3 | Lock |

Pressing block during your own windup **feints** it. Slashing right after a deflect is a **Riposte**.

## Combat rules

All numbers live in [src/shared/Config.luau](src/shared/Config.luau). The rules follow Sekiro's.

- **Timing.** Every attack has a windup, an impact time `hitAt` fixed on the server clock, and recovery. Your own swing
  starts animating the moment you click; the server confirms it and decides every outcome.
- **Hit area.** A box in front of where the attacker stood and faced at the moment of the strike (turning afterwards
  can't re-aim it): slashes 6 wide × 7 deep, finisher 5 × 7.5, thrust 4 × 9, sweep 10 × 8.5, all 6 tall.
- **Strings.** Slashes chain Light1 → Light2 → third hit, and speed up only while they keep landing (0.42 → 0.32 →
  0.34 s windups on hit; normal on block; a deflect ends the string). The third hit is a read: click on rhythm for a fast
  Light3, pause 0.25 s for the delayed **Overhead** (more posture, catches early deflects), press E/C during Light2's
  recovery or the third windup to **morph** into a perilous attack with a 0.65 s windup, or press block to **feint**.
  One morph or feint per string, and you can't feint out of a feint. After an ender there's a 0.3 s rest: the defender's
  turn. Hit stun (0.25 s) ends before the next chained hit, so strings are never true combos.
- **Buffering.** Attacks pressed up to 0.3 s early fire as soon as you're free; the last input wins, and a block or dodge
  clears the queue.
- **Deflect.** A block press arms a deflect for 0.2 s before impact; the last 0.09 s is a **perfect** deflect. Each press
  soon after the last shrinks that window (down to 0.067 s), and the penalty clears after 0.5 s or on a successful
  deflect, so pressing early is safe (it guards) and mashing isn't. Deflecting knocks the attacker into a recoil (0.5 s,
  0.75 s after a perfect) and builds their posture; deflects in quick succession build it 20% harder each time (up to
  +60%) and ring higher.
- **Riposte.** Slash within 0.5 s of a deflect for a fast (0.18 s), uninterruptible counter-cut that chains into Light2.
  It is sized to land inside the recoil even at 250 ms ping. For 0.35 s after a deflect, swings from anyone else are
  auto-guarded, so a third party can't trade into it.
- **Guard.** Holding block stops vitality damage but takes the attack's posture damage, and does nothing against thrusts.
- **Perilous attacks** (a red brush 危, a red outline and a chime) only have hyper armour in the last 0.3 s of their
  windup, so a read one can be interrupted early. Thrust and sweep share one cooldown (7 s, ×1.5 for each reuse within
  8 s) and cost ~2.5× a slash in stamina. The **thrust** can't be guarded: deflect it (its owner takes +40 posture and a
  0.8 s recoil), or dash into it for a **Mikiri Counter**. The **sweep** can't be blocked at all: jump it (its owner is
  stuck in recovery for 0.7 s), and land on the sweeper's head for posture damage if you're close.
- **Posture.** Builds from deflected swings, guarded hits and taking hits. It recovers after 1.2 s without posture
  damage, faster while guarding, and **slower the lower your vitality**. At 100 you're **broken** for 1.6 s with a red
  deathblow marker; any hit then is a **deathblow** (忍殺).
- **Stamina.** Slashes, perilous attacks and dodges cost stamina; deflecting is free.
- **Healing gourd.** A 0.9 s sip that slows you; a hit mid-sip wastes it. There is no passive regeneration.
- **Bots** read rhythm: from the second swing of a mashed string they stop attacking, hold their ground, deflect, and
  counter. They exploit recovery and sips, and always go for the deathblow on a broken posture.
- **Netcode.** Clients send intents stamped with `workspace:GetServerTimeNow()`. The server clamps stamps to 0.25 s in the
  past and resolves 0.12 s after impact, so a deflect pressed on time on your screen counts; your screen shows the
  deflect the instant the blow lands. Fighters don't collide with each other, and pushes are force-capped.

### Testing

Set the workspace attribute `HoldIntermission` to `true` from the Studio command bar to keep the lobby countdown from
finishing. In Studio, `ServerStorage.CombatTest` (a BindableFunction from DevHooks) spawns dummy fighters, performs
actions with exact timing, reads their state and grants currency, for automated combat tests.

## Weapons

Every move is read through [Weapons.luau](src/shared/Weapons.luau): a weapon is the base moveset in `Config.Attacks`
bent by a few multipliers (windup, recovery, damage, posture damage, reach, stamina) plus per-move overrides, and a
look (mesh, scale, grip). A load-time validator rejects unknown moves and fields.

| Weapon | Archetype | Strengths | Weaknesses / counter |
|---|---|---|---|
| Katana | All-rounder | Baseline speed and reach | None special |
| Odachi | Bruiser | 1.7× posture damage, 1.25× reach, armoured overhead | 1.4× windup, 1.3× recovery, 1.35× stamina; deflect it and punish, or interrupt early |

Rules for new weapons: every weapon spends the same budget (sidegrades, never upgrades); defensive verbs (deflect,
guard, dodge, jump, Mikiri) and perilous timing are universal; reach follows the blade's length. Bots alternate the
roster. Players carry their `Weapon` player attribute (the lobby's Weapons menu sets it). Next on the research's ship
order: naginata (reach), then dual blades; kusarigama last.

## Presentation

- **Animation.** Locomotion uses Roblox's Ninja Animation Package. Combat motion is procedural: [Poses.luau](src/shared/Poses.luau)
  describes each pose as directions (where the arm, forearm and blade point), solves them into joint rotations, and
  [Animator.luau](src/client/Animator.luau) layers them over the locomotion with eased keyframes from [Clips.luau](src/shared/Clips.luau).
- **Swords.** The katana is 4.4 studs (the odachi 5.85) and much broader than the source mesh, with a thin ink outline (a Highlight) so it
  reads at camera distance. Trails taper, steel-white for slashes and red for perilous attacks. Roblox caps how many
  Highlights render at once (about 31), so keep fighters plus perilous telegraphs under that.
- **HUD.** Sekiro / Dark Souls style: a crimson vitality bar with a damage trail, a posture bar that grows from the centre
  and hides when empty, gourd count, enemy bars only for your target and recent opponents, a red deathblow marker, kanji
  splashes, a phase banner, a kill feed and spectating. The closing mist is a wall of camera-facing beams (a cylinder
  part culls its inside faces, so it vanished once you were inside it), and standing in it tints your screen red.
- **Map.** [MapBuilder.luau](src/server/MapBuilder.luau) generates the terrain, castle walls, shrine hall, a pale-sand
  duelling circle (so dark-clad fighters read clearly), moss along the walls, crimson nobori banners, braziers and
  drifting maple leaves. World and HUD colours come from [Palette.luau](src/shared/Palette.luau).
- **Materials.** `MaterialService` overrides re-skin every Plaster, Wood and ClayRoofTiles surface at once with
  generated materials (aged lime plaster, cedar, kawara tiles), the closest thing Roblox has to one shared shader. They
  live in the place file, not in git. Lacquered red pillars use SmoothPlastic so the timber override skips them.
- **Lighting.** Golden hour under a storm-lit sunset sky: `LightingStyle = Realistic` with `PrioritizeLightingQuality`,
  the sun placed where the skybox glows, warm key light against cool violet ambient, and a dense Atmosphere that pushes
  the mountains back. All of it is in `default.project.json` (the deprecated `Technology` property is gone). Props in `Workspace.Props` came from the Creator Store and were
  stripped of every script.
- **Fighters.** Bots are dressed by [Outfit.luau](src/server/Outfit.luau): a woven kasa (made with Studio's mesh
  generator), gi and hakama in one of four muted colourways, and a crimson sash.
- **Combat VFX.** Hits throw dark, gravity-pulled blood along the line of the blow instead of glowing sparks; deathblows
  add a heavier arc, pools on the floor and a brief desaturated freeze. The camera kicks along the blow and settles
  rather than jittering at random.
- **Sound.** Licensed ProSoundEffects and APM library audio. Every asset id is in [Assets.luau](src/shared/Assets.luau).

## Performance

- The scene is about 450 parts, 6 lights and one terrain mesh. Decorative props don't collide, query or touch, and small
  parts don't cast shadows. Distant mountains are single meshes with shadows and collision off.
- Nothing in the HUD runs per frame. Bars update from attribute and health signals and animate with tweens. The ring is
  the only per-frame update, and only during a match.
- Round state replicates as a few attributes per phase; clients compute the ring and timers from the synced clock.

## Code map

```
src/
  shared/   Config, Weapons, Ranks, Types, Assets, Palette, Poses, Clips, Round
  server/   init, CombatService, BotService, RoundService, StatsService, LobbyService, LobbyBuilder, MapBuilder,
            Outfit, Locomotion, SwordRig, DevHooks
  client/   init, Animator, CombatVisuals, CombatInput, LockOn, CombatHUD, RoundHUD, LobbyHUD, Panels, UI, TitleScreen,
            Ambience
```

## Before publishing

- Save the place in Studio, then run `rojo syncback` so `Workspace.Props` and the `MaterialService` variants are tracked
  in git.
- Game Settings: R15 only; Security → enable Studio access to API services to test DataStores.
- Store page: icon and thumbnails (real gameplay captures work best), description, genre "Fighting".
- Rename anything that borrows FromSoftware terms ("Shinobi Execution", "Mikiri") if you want to avoid trouble.
