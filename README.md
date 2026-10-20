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

Press Play. A title card shows first; click or press any key to enter.

- **Intermission (15 s):** spar with two practice bots. You respawn instantly.
- **Match:** everyone, plus bots filling up to six fighters, starts on a circle around the courtyard. After 20 s a ring of
  red mist starts closing and hurts anyone outside it. No respawns; fallen players spectate (click to switch). The last
  one standing wins.
- **Results:** a victory banner, then the next intermission.

Wins and Kills show in the player list and are saved with DataStores (session-only in an unpublished place).

| Action | Keyboard / mouse | Gamepad | Touch |
|---|---|---|---|
| Slash (press in rhythm for a 3-hit combo) | Left click | R1 | Slash |
| Deflect (tap just before impact) / guard (hold) | F | L1 | Block |
| Dodge (i-frames; dash *into* a thrust for a Mikiri Counter) | Q | B | Dodge |
| Perilous thrust (unblockable) | E | Y | Thrust |
| Perilous sweep (unblockable; jump over it) | C | X | Sweep |
| Healing gourd (3 sips per life) | G | D-pad up | Heal |
| Lock on / off | R or middle mouse | R3 | Lock |

Pressing block during your own windup **feints** it.

## Combat rules

All numbers live in [src/shared/Config.luau](src/shared/Config.luau). The rules follow Sekiro's.

- **Timing.** Every attack has a windup, an impact time `hitAt` fixed on the server clock, and recovery. Your own swing
  starts animating the moment you click; the server confirms it and decides every outcome.
- **Hit area.** A box in front of where the attacker stood and faced at the moment of the strike (turning afterwards
  can't re-aim it): slashes 6 wide × 7 deep, finisher 5 × 7.5, thrust 4 × 9, sweep 10 × 8.5, all 6 tall.
- **Combo and buffering.** Slashes chain Light1 → Light2 → Light3 (a delayed overhead). Inputs up to 0.3 s early are
  buffered, and block or dodge can cancel recovery shortly after impact.
- **Deflect.** A block press arms a deflect for 0.2 s before impact; the last 0.07 s is a **perfect** deflect. Each press
  soon after the last shrinks that window (down to 0.067 s), and the penalty clears after 0.5 s or on a successful
  deflect, so pressing early is safe (it guards) and mashing isn't. Deflecting knocks the attacker into a recoil long
  enough for one counter-slash (0.5 s, 0.75 s after a perfect) and builds their posture; deflects in quick succession
  build it harder each time.
- **Guard.** Holding block stops vitality damage but takes the attack's posture damage, and does nothing against thrusts.
- **Perilous attacks** (a red brush 危, a red outline and a chime) have hyper armour through their windup. The **thrust**
  can't be guarded: deflect it, or dash into it for a **Mikiri Counter**. The **sweep** can't be blocked at all: jump it,
  and land on the sweeper's head for posture damage if you're close.
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

Set the workspace attribute `HoldIntermission` to `true` from the Studio command bar to stay in intermission for
practice or automated combat tests.

## Presentation

- **Animation.** Locomotion uses Roblox's Ninja Animation Package. Combat motion is procedural: [Poses.luau](src/shared/Poses.luau)
  describes each pose as directions (where the arm, forearm and blade point), solves them into joint rotations, and
  [Animator.luau](src/client/Animator.luau) layers them over the locomotion with eased keyframes from [Clips.luau](src/shared/Clips.luau).
- **HUD.** Sekiro / Dark Souls style: a crimson vitality bar with a damage trail, a posture bar that grows from the centre
  and hides when empty, gourd count, enemy bars only for your target and recent opponents, a red deathblow marker, kanji
  splashes, a phase banner, a kill feed and spectating.
- **Map.** [MapBuilder.luau](src/server/MapBuilder.luau) generates the terrain, castle walls, shrine hall, a pale-sand
  duelling circle (so dark-clad fighters read clearly), moss along the walls, crimson nobori banners, braziers and
  drifting maple leaves. World and HUD colours come from [Palette.luau](src/shared/Palette.luau).
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
  shared/   Config, Types, Assets, Palette, Poses, Clips, Round
  server/   init, CombatService, BotService, RoundService, StatsService, MapBuilder, Outfit, Locomotion, SwordRig
  client/   init, Animator, CombatVisuals, CombatInput, LockOn, CombatHUD, RoundHUD, TitleScreen, Ambience
```

## Before publishing

- Save the place in Studio, then run `rojo syncback` so `Workspace.Props` is tracked in git.
- Game Settings: R15 only; Security → enable Studio access to API services to test DataStores.
- Store page: icon and thumbnails (real gameplay captures work best), description, genre "Fighting".
- Rename anything that borrows FromSoftware terms ("Shinobi Execution", "Mikiri") if you want to avoid trouble.
