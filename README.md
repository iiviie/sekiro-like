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

- **Lobby.** You arrive on a floating shrine island above the castle: a cobbled spawn plaza, a grand stair up to the
  torii terrace (where the Royale pad is, overlooking the castle), the dojo with the Deflect Trainer on the left wing,
  the hall of champions with the leaderboards on the right, two waterfalls, rope bridges to two islets, and more
  islets over a sea of cloud. It's sculpted terrain built by [LobbyBuilder.luau](src/server/LobbyBuilder.luau) at
  server start, so it doesn't exist in edit mode. There's no rules screen: new players start **queued**, so the first
  fight (against Novice bots, with the in-fight **Coach**) comes within ~10 s of leaving the title card; press **PLAY**
  (or step on the glowing red pad) to join or leave the queue. While anyone who is past the title card is queued an 8 s
  countdown runs; nobody is put in a match from the title card. **Invite friends** sits left of PLAY and glows when
  you're alone in the server. Lobby PvP is off by default (turning it on takes 3 s); with it off nobody can touch you except
  the **Deflect Trainer**, which swings at whoever steps into its sand ring and never deals damage; after each swing a
  readout says how many milliseconds before impact you pressed and what it earned. Fall off the island and you're put
  back. Two boards show **Total Wins** and **Ranked Rating** (OrderedDataStores once published; this server's players
  until then), and every player carries a title with their wins and rank.
- **Menus** (bottom bar, painted icons): **How to fight** (the rules in plain words), **Arsenal** (weapons to equip or
  unlock with coins, and **Blades**: cosmetic skins), **Trials** (three daily goals), **Store** (how coins are earned; gem
  packs once developer products exist), **Profile** (wins, losses, W/L, kills, deathblows, most used weapons, ranked
  season tier with its crest), **Rewards** (7-day daily streak, gems on day 7), **Settings** (camera shake, hitstop,
  controls hint). Top left: your **Mastery** level and XP bar.
- **Match:** queued players plus bots filling up to six fighters start on a circle around the courtyard. Bots match the
  least experienced human: **Ronin** (Novice) for a player's first 3 matches, **Samurai** (Adept), **Kensei** (Master,
  with rare blades) for proven players; only one bot fights a given human at a time. About one match in three has an
  **Omen**: Blood Moon (every deathblow kills, the sky turns red), Iron Will (posture breaks 40% faster) or Rushing Mist
  (the ring closes twice as fast). After 20 s a ring of red mist starts closing and hurts anyone outside it. Every player
  has one **Resurrection** (回生) per match: the first lethal blow cuts you down to your knees, untouchable, and you rise
  2.2 s later at half vitality. The second death is final; you spectate. When two remain, the 一騎討 **Final duel**
  is announced. The last one standing wins. The match ends as soon as no human is left alive, so nobody waits for bots.
- **Duels (一騎討).** Two pairs of gold **duel pads** sit on the lower tier (east and west of the spawn plaza). Stand on
  one: when someone takes the facing pad a first-to-3 duel starts at once; alone, a bot matched to your experience
  (the royale's tier rule) steps in after 8 s. The pair's duellists go to its fenced terrace floating just off the rim,
  in view of the lobby. Each round both start on their marks, full and protected through a 3 s countdown; there is no
  resurrection, the first to fall loses the round, and a round still going after 75 s goes to whoever has more
  vitality. The Coach still prompts new players. Afterwards both return to the lobby: deflects, kills, deathblows and
  Trials count as in the royale, a duel pays "Duel fought" plus XP per round taken, a win pays 60 XP and 25 coins,
  and it counts toward Played (bot tier, Coach, newcomer assist) and the separate duel wins and losses. A duel between
  two humans is a ranked result: one full-weight Elo game on the ranked rating (`Config.Rating.K`); duels against bots
  never move it. Leaving mid-duel forfeits. While you're on a pad or in a duel you're held out of the royale queue.
  Numbers in `Config.Duel`; the loop is [DuelService.luau](src/server/DuelService.luau), the pads and terraces are in
  LobbyBuilder, the score banner is [DuelHUD.luau](src/client/DuelHUD.luau).
- **Boss trials (試練).** Cross the rope bridge to the back islet and step on the violet shrine pad under the small
  torii: a picker lists Kannagi Usagi's nine bosses (the tutorial trainer first, then by difficulty: Nameless Warrior,
  Cat General, Guard of Mist, Little Demon, Night Fox, Crimson Shadow, Puppet Maiden, Niten Usagi), with ✓ on the ones
  you've cleared. Pick one and you're on the boss terrace floating behind the island, against it, after a 3 s
  countdown. Each boss replays its own decoded Kannagi AI: its pattern deck, step scripts (strafes, approaches to a
  range, timed multi-hit strings, 危 perilous thrusts and sweeps), its guard ladder against you (an idle boss guards
  your swing; a guarded hit arms its parry; a parry sends you recoiling and opens its counter deck) and its cooldowns.
  Deflecting a boss hit only knocks it back when that hit is authored to recoil, so most strings must be deflected in
  rhythm. Bosses have two lives: vitality 0 or a full posture bar breaks them for a long deathblow window, the first
  deathblow starts phase 2 (more vitality and posture, phase-2 patterns, an opener), the second ends it. You get one
  resurrection and your gourd; a boss's blow on your broken guard is a hit, not a deathblow. The tutorial trainer
  (Shikigami) runs Kannagi's staged lessons, one per deathblow: attack, deflect, double deflect, jump the sweep,
  Mikiri the thrust, then two real lives. A fight pays "Boss fought", XP per life taken, a clear (× stars) and a
  first-clear bonus once per boss (`Config.Bosses.Rewards`, clears saved in `BossClears`), with the report card
  ("Trial cleared", counting the deathblows that took the boss's lives). The camera locks on to the boss as the fight
  starts. There's one boss terrace, so one trial runs at a time: picking while it's taken puts you in line (the picker
  says who's fighting and your place; LEAVE LINE gives it up) and your trial starts by itself when the arena frees up.
  Every pick gets an answer: the fight starts, or the picker (or a toast) says why not. The picker stays usable a few
  steps off the pad and closes once you walk away or the royale takes you.
  Numbers in `Config.Bosses`; the AI is [BossAI.luau](src/server/BossAI.luau), the fight loop and shrine are
  [BossService.luau](src/server/BossService.luau), bosses' looks, weapons and stat scaling are
  [Bosses.luau](src/shared/Bosses.luau) (over the generated `Shared/KannagiMoves` data), and the picker and boss bar
  are [BossHUD.luau](src/client/BossHUD.luau) with animation in [BossVisuals.luau](src/client/BossVisuals.luau).
- **Rewards as they happen.** Every deflect, kill, deathblow and placement pays XP (and kills pay coins) with a toast on
  the right; levels pay coins; a finished Trial pays at once; your own kills splash 斬 with a streak count.
- **Results:** a victory banner, then a **report card** (your place, cut downs, deathblows, deflects, perfect deflects,
  coins and XP earned, the Mastery bar), ranked rating (pairwise Elo against the other humans you placed above or below;
  bots don't count), and the next royale ~14 s later if you're still queued.

Everything persists with DataStores in `PlayerData_v2` (old `PlayerStats_v1` Wins/Kills migrate on first visit), and
is session-only in an unpublished place.

| Action | Keyboard / mouse | Gamepad | Touch |
|---|---|---|---|
| Slash (rhythm for a 3-hit string; pause before the 3rd for an overhead) | Left click | R1 | Slash (beside Deflect) |
| Deflect (tap just before impact) / guard (hold) | F | L1 | Deflect (big button under the right thumb; hold to guard) |
| Dodge (i-frames; dash *into* a thrust for a Mikiri Counter) | Q | B | Dodge (arc) |
| Perilous thrust (unblockable) | E | Y | Thrust (arc) |
| Perilous sweep (unblockable; jump over it) | C | X | Sweep (arc) |
| Healing gourd (3 sips per life) | G | D-pad up | Heal (arc) |
| Jump | Space | A | Jump |
| Lock on / off (automatic at the start of a boss fight and each duel round) | R or middle mouse | R3 | Automatic (nearest enemy); Lock toggles it off for free look |

Pressing block during your own windup **feints** it. Slashing right after a deflect that recoils the attacker is a
**Riposte**. Press jump again in the air over a sweeper to **stomp** them.

**Phones** get their own thumb cluster ([src/client/TouchHUD.luau](src/client/TouchHUD.luau)) in place of Roblox's grey
buttons: a large painted Deflect under the right thumb, Slash beside it, an arc of Dodge / Thrust / Sweep / Heal above
them, and Jump and Lock on the outside (Roblox's own jump button hides while it's up). It keeps to the right half of the
screen so the left-thumb move stick is never covered, every button is at least 45 px, and it scales with the screen
(laid out for 844×390 landscape; Jump and Lock move to the top on a portrait screen). On touch the camera locks on to the
nearest enemy you can fight by itself (`Config.LockOn.AutoRange`). In a match or a duel the cluster is always up; in the
lobby it appears only next to the trainer or a sparring partner.

**The Coach.** For a player's first 3 matches (or until 12 lifetime deflects), every swing aimed at you flashes a small
**F / DEFLECT** key prompt in time with the glint (in the lower third, just above your posture bar or the boss's bars,
never over the fighters), a deflect is followed by **CLICK / RIPOSTE**, a broken opponent by
**DEATHBLOW**, and perilous attacks name their answer. Touch players see button names instead of keys. For the same
first 10 matches the deflect window is up to 1.4× wider (perfect 1.3×), tapering to normal (`Config.NewcomerAssist`).

## Combat rules

All numbers live in [src/shared/Config.luau](src/shared/Config.luau). The rules follow Sekiro's, tuned against the
reverse-engineered Kannagi Usagi (`research_notes/Kannagi Usagi RE/`: `combat_spec.md`, `gap_analysis.md`,
`impl-progress.md`). Every move's timing hooks (tracking, cancel points, recoil on deflect, reaction size, knockback,
stomp window) are per-move fields in `Config.Attacks` with defaults in `Config.MoveDefaults`.

- **Timing.** Every attack has a windup, an impact time `hitAt` fixed on the server clock, and recovery. Your own swing
  starts animating the moment you click; the server confirms it and decides every outcome.
- **Commitment.** A swing roots you: no walking in its windup or recovery (only its lunge moves you), no jumping, and
  your facing turns into the attack at its start, then only at the move's capped tracking rate (500°/s for slashes,
  420 / 360 for thrust / sweep; slower blades scale down) until impact, and never in recovery. Recovery can be cut
  short only from each move's own cancel points, taken from Kannagi's decoded player moves: block and dodge 0.14 s
  after impact, jump and sip 0.19 s, the next slash of a string 0.2 s (so landed Light1 → Light2 impacts are 0.62 s
  apart, Kannagi's rhythm); enders and perilous moves later. The mapping and every deviation are commented above
  `Config.Attacks`.
- **Hit area.** A box in front of where the attacker stood and faced at the moment of the strike (turning afterwards
  can't re-aim it): Light1/Light2 7.5 wide × 8.1 deep, Light3 8 × 8.6, Overhead 5 × 8.6, Riposte 7.5 × 8.6, Riposte2
  6 × 8.6, DodgeSlash 7 × 8.6, MikiriSlash 8 × 8.6, thrust 4 × 10.1, sweep 12 × 9.6, all 6 tall. They follow the blade:
  sized to where each clip sweeps the 1.3× katana's tip; a weapon's reach scales the depth (odachi 1.25×). Targets are
  judged where they stood at the moment of impact (the server keeps a short position history), not where they are when
  the blow resolves.
- **Strings.** Slashes chain Light1 → Light2 → third hit, and speed up only while they keep landing (0.42 s windups on
  hit, Kannagi's swing; normal on block or deflect). The third hit is a read: click on rhythm for a fast Light3, pause 0.25 s
  for the delayed **Overhead** (more posture, catches early deflects), press E/C during Light2's recovery or the third
  windup to **morph** into a perilous attack with a 0.65 s windup, or press block to **feint**. One morph or feint per
  string, and you can't feint out of a feint. After an ender there's a 0.3 s rest: the defender's turn. Hit stun ends
  before the next chained hit, so strings are never true combos.
- **Buffering.** Every input (slash, block, dodge, jump, heal) pressed while you're busy is kept for 0.45 s and fires on
  the first frame it becomes legal; the last input wins, and a stagger drops a queued slash. Holding block through
  anything (a swing, a flinch, a sip, a dodge) raises guard again the moment it ends, with a fresh deflect window.
- **Deflect.** A block press opens a 0.25 s deflect window; the last 0.09 s before impact is a **perfect** deflect (more
  posture, a gold flash). There's no penalty for pressing early (it guards). Mashing is handled Kannagi's way:
  re-pressing within 0.25 s of lowering your guard, with nothing having struck you since, opens the window 0.15 s late;
  any press within 0.6 s of your own deflect or guarded hit opens it at once, so deflecting a string in rhythm is crisp.
  Deflecting is free for the defender. **Deflect rallies:** deflecting an opener (Light1, Light2, the Riposte) only
  knocks the blade aside, and the attacker's string goes on; deflecting an ender (Light3, Overhead, Riposte2) or a
  thrust recoils the attacker (0.5 s, 0.75 s after a perfect) and opens the Riposte. Every deflect costs the attacker
  posture (the move's posture × its `deflectPosture`); deflects in quick succession build it 20% harder each time (up
  to +60%) and ring higher. A deflect that breaks the attacker pulls you up to them for the deathblow.
- **Counter-strings.** After a recoil deflect, slash within 0.5 s for the **Riposte** (0.18 s, uninterruptible, sized to
  land inside the recoil even at 250 ms ping), which chains into a second fast cut (Riposte2, 0.42 s, 0.36 after a
  landed Riposte). Slash within 0.8 s of a dodge's start for a **DodgeSlash** (0.35 s; it can cut in from 0.42 s into
  the dodge), and within 0.45 s of a Mikiri for the **MikiriSlash** (0.3 s); both chain into Light2. For 0.35 s after a deflect, swings from anyone else are auto-guarded, so a
  third party can't trade into it.
- **Guard.** Holding block stops vitality damage but takes the attack's full posture damage with a 2.5 s recovery delay,
  so guarding is what breaks you. It does nothing against thrusts.
- **Hit reactions.** Each move sets its victim's flinch (small / middle / large / low: 0.25 / 0.6 / 0.8 / 0.8 s of
  stun, Kannagi's 0.25 / 1.12 / 1.40 / 1.50 cut so a stun always ends before the attacker's next blow can land), guard
  rock (small / middle / large) and deflect side (right / left / back), a knockback slide (eased out over 0.5 s,
  smaller on a guard or deflect; slashes have none, as in Kannagi), and the victim snaps to face the blow.
- **Perilous attacks** (a red brush 危, a red outline and a chime) only have hyper armour in the last 0.3 s of their
  windup, so a read one can be interrupted early. Thrust and sweep share one cooldown (7 s, ×1.5 for each reuse within
  8 s). Their windups follow Kannagi's boss medians (thrust 0.85 s, sweep 0.9 s). The **thrust** can't be guarded: deflect it (its owner takes +40 posture and a 0.8 s recoil), or dash forward
  into it for a **Mikiri Counter**: a forward dodge started up to 0.47 s before impact counts from its first frame,
  i-frames or not, costs the thruster twice the posture and freezes their posture recovery for 3.5 s. The **sweep** can
  only be jumped (dodge i-frames don't help); its owner is stuck in recovery for 0.7 s, and pressing jump again above
  them **stomps** their head (double posture, recovery frozen 3.5 s, a bounce up).
- **Free-for-all rules.** When two or more different fighters have struck you within 3 s you gain **Resolve**: posture
  recovers twice as fast and hit stun is halved. It never applies in a 1v1. For 1.5 s after a posture break, only the
  fighter who broke it can deathblow; anyone else's hit just chips vitality.
- **Telegraphs.** Every swing coming at you flashes a white glint at the blade tip 0.3 s before impact: press block as it
  flashes. Your own hits pop up DEFLECTED / GUARDED / damage over the target.
- **Posture.** Builds from guarded hits (×1.0), clean hits (×0.5, which can fill it to 99 but never break it) and being
  deflected. It recovers at a flat 9/s once its delay has passed: 0.5 s after your deflect, 2.5 s after a guarded or
  clean hit, 1.2 s after being deflected; there's no vitality scaling and no guard bonus. At 100 you're **broken** for
  1.6 s with a red deathblow marker; a hit then is a **deathblow** (忍殺): 65 damage, so it kills a wounded fighter and
  knocks an unhurt one down hard (posture wiped). A break that runs out unpunished leaves posture at 99, so the next
  guard or deflect re-breaks. `Config.Posture.Profiles.Boss` holds Kannagi's boss column for the boss duels to come.
- **Stamina.** Only dodges (25 of 100) and feints cost stamina; attacks are limited by commitment, cooldowns and
  opponents who guard, then deflect. The bar shows only while it isn't full.
- **Healing gourd.** A 0.9 s sip that slows you; a hit mid-sip wastes it. There is no passive regeneration.
- **Bots** defend with Kannagi's ladder, per attacker: an idle bot that sees a swing coming raises guard; once hit it
  holds guard for the next one and steps back; once it has guarded it deflects; after a deflect that stops you it
  counters. Their tier sets how often they climb each rung and how fast they react (Ronin 40% / 0.4 s, Samurai 72% /
  0.27 s, Kensei 93% / 0.18 s), so a Ronin still eats an honest string. Perilous answers (jump, Mikiri, sidestep,
  stomp) are still rolls. They exploit recovery and sips, always go for the deathblow on a broken posture, and turn at
  a capped rate inside their own swing's tracking window, so side-stepping a committed bot swing works.
- **Netcode.** Clients send intents stamped with `workspace:GetServerTimeNow()`. The server clamps stamps to 0.25 s in the
  past (dodges and jumps to half the player's ping plus 30 ms, so a late dodge can't buy i-frames) and resolves shortly
  after impact (half the slowest nearby defender's ping plus 50 ms, between 0.06 and 0.2 s), so a deflect pressed on
  time on your screen counts; your screen shows the deflect the instant the blow lands (the server publishes every
  deflect window it opens as `DeflectAt` / `DeflectWindow` attributes, and your client mirrors only presses the server
  will take now). A jump only counts once the server sees the body leave the ground (one per 0.4 s). Pushes are
  force-capped.
- **Spacing.** Bodies keep Kannagi's capsule distance ([Spacing.luau](src/shared/Spacing.luau)): every fighter has a
  1.25-stud radius (CharacterBase's 35 cm capsule; bosses scale it by their `BodyScale`), and two fighters of the same
  arena (royale, duel terrace, boss arena) are never closer than their two radii. Fighters still don't collide
  physically, so nobody gets flung or stands on a head: the server moves bots and bosses out of anyone they overlap,
  and your own client moves you (you stop at a body and slide around it). Lunges, knockback slides, boss root motion and boss
  approach steps shorten to stop just outside contact instead of passing through (checked every frame, and a lunge at
  someone who is winding up takes half the gap, so two lunges meet at contact); a bot's lunge shortens rather than
  being skipped. Dodging, downed and dead bodies don't take up room (dash past or through someone), nor do bodies far apart
  vertically (a jump over a sweep, a stomp). The lobby has no spacing (crowds on the pads), but a lunge still stops
  short of a lobby opponent. Hitstop freezes only clips already playing, never a windup, so
  it can't push a swing past its impact.

### Testing

Set the workspace attribute `HoldIntermission` to `true` from the Studio command bar to keep the lobby countdown from
finishing, and `ForceOmen` to `"BloodMoon"`, `"IronWill"` or `"RushingMist"` to get that omen every match. Set `ForceTouchHUD`
to `true` on the client to try the phone controls with a mouse. To test a duel alone,
stand on a duel pad and wait 8 s for the bot; setting a duellist's `Humanoid.Health` to 0 from the server command bar
decides a round. In Studio,
`ServerStorage.CombatTest` (a BindableFunction from DevHooks) spawns dummy fighters, performs actions with exact
timing, reads their state (including blocking, the buffered input, when the deflect window opened and the posture
recovery delay), moves them (`pivot`), deals damage (`damage("player", 500)` tests a resurrection), sets resurrections
and grants currency, for automated combat tests. `ServerStorage.BossTest` drives boss fights: `start("Enemy01")` puts
the first player in a fight without the pad, `state()` snapshots it (AI mode, lives, action, flags, vitality, posture),
`log(n)` lists the boss's last moves and reactions (`R:<name>`), `tally()` counts the outcomes of blows involving the
boss, `posture(v)` / `health(v)` set the boss's bars, `god(true)` keeps the player's vitality from dropping (blows still land; it lasts through the countdown, attacking and later fights until `god(false)`), `stop()` ends the fight.

### Boss port notes

- **Scale.** Boss vitality, posture and posture recovery are Kannagi's times (our Light1/Light2 damage / Kannagi's
  player hit of 10) and (our posture / 10), so each takes the same number of our cuts as in Kannagi (Nameless Warrior:
  108 vitality, 540 posture, 14.8/s after 0.75 s). Boss hits deal Kannagi's numbers on our 100 vitality (31-35 per
  1.0-scale hit, `Config.Bosses.DamageScale`). A deflected boss hit costs the boss reTScale × 18 posture, before our
  perfect and chain multipliers.
- **Hits** are scheduled from the decoded notify times (`CombatService.scriptedAttack`), each its own kind
  `Enemy01|Attack09|2` resolved by `Bosses.spec` (type Normal / Tsuki = thrust / Gedan = sweep, damage and posture
  scales, reactions, recoil, knockback, stomp window, reach + root motion). Their Windup broadcasts carry `boss = true`.
- **Flags** (Guard, Hajiki = parry, HajikiDisable, SuperArmor) follow every move's deck `set` and notifies and are read
  as they stood at each blow's impact (`Combatant.bossGuard`).
- **Animation.** Each boss move plays the animation worker's retargeted clip for its Kannagi asset (`BakedBoss`,
  loaded per boss); a missing clip falls back to Light1/2/3, Perilous or Sweep per hit. The ~3 MB of boss clip modules
  are moved to `ServerStorage.BossClips` at server start and copied back per boss when a fight needs them.
- **Size and spacing.** Bosses stand 1.3-1.42× our height (Kannagi's ~1.35×; `look.height` in Bosses.luau, also the
  boss's `BodyScale`, which grows its capsule and scales its pose offsets). Root motion and reach are Kannagi's world
  distances, so they need no rescaling. Root motion and approach steps stop at capsule contact (Shared/Spacing).
- **Blade timing.** Each clip's `impactLead` ends its windup early by how long its blade takes to reach a fighter at
  contact, so the cut connects 0-15 ms after the server's hit: player moves in `Clips.luau`, bosses in
  [BossLeads.luau](src/shared/BossLeads.luau) (measured in Edit mode by
  `~/re/kannagi-usagi/scripts/anim/boss_leads.luau`; re-run it after re-baking).
- **Frozen holds.** Kannagi's PauseBlendIn (a move's `hold` in KannagiMoves) is a true hold: the clip blends into its
  first frame and sits there for the hold, then plays the rest of the windup into the server's hit time
  (`Animator.play(model, clip, windup, freeze)`), instead of the whole windup playing slowed.
- **Known deviations.** One player per fight and one arena (Kannagi's bosses are 1v1 too; `ExtraPlayerRegen` is
  ready for parties). Vertical root motion (Kugutsu's flying leaps) is played flat.

## Movement

[Movement.luau](src/client/Movement.luau) sets your WalkSpeed on your own client every frame, so slowing for a swing or
guard is instant instead of a round trip late: you push off from 75% of full speed and reach it in ~0.1 s, and state
changes blend; a swing stops you almost at once. Turning is Roblox's own rotation unless you have a target (locked on, or
a soft target while attacking or guarding), when the body turns toward it at a constant 720°/s; inside a swing it
follows the move's tracking (see Combat rules). Dashes burst at 72 studs/s and ease out over 0.32 s (~10.7 studs, Kannagi 10.6; i-frames 0.33 s, attack from 0.42 s, anything else from 0.55 s) with a
small FOV kick; attack lunges ease out too. Research: `research_notes/Sword combat design and lobby/movement_feel.md`.

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

- **Swings.** Modelled on Dueling Grounds, frame-counted from a 60 fps recording: a fast snap (about a third of the
  windup) into a cocked pose, a held coil that is the readable telegraph, a ~70 ms strike with a soft white smear, then
  a ~0.22 s held follow-through at full extension. The whole body drives each cut: torso and hips twist, the front foot
  steps in and the stance drops (Light1 diagonal cut, Light2 rising backhand, Light3 overhead into a deep lunge).
  In Studio, `PlayerScripts.AnimTest:Invoke("sample", model, clip, windup, t)` freezes any clip at time `t` for review.
- **Animation from Blender.** Sword stances and the seven attack clips (Light1-3, Overhead, Riposte, thrust, sweep)
  are keyed in Blender on a matching R15 rig ([art/anim/katana.blend](art/anim/katana.blend)) with the left hand
  IK-locked to the hilt and IK feet. Each clip is keyposes on a timeline (cock, coil, a last pull back for
  anticipation, an arc breakdown, the strike, an overshoot, the settle), Bezier-interpolated by Blender and sampled at
  30 fps into [BakedPoses.luau](src/shared/BakedPoses.luau) and [BakedClips.luau](src/shared/BakedClips.luau)
  (generated; don't edit). Frames before impact stretch to the server's windup. To change one: edit the `poses` or
  `clips` text block in Blender, run the `run` block, and review in Studio with
  `AnimTest:Invoke("sample", model, clip, windup, t)` or `AnimTest:Invoke("pose", model, name)`.
- **At runtime** the left arm is solved live (two-bone IK) onto the hilt whenever a two-handed clip or stance is
  showing, so the grip holds between frames too. While you move, attack clips leave the hips and legs to the walk
  cycle, so you keep stepping under a swing.
- **Animation.** Every R15 fighter stands in a low swordsman stance: hips dropped, right foot leading, hips turned
  38° with the chest turned back to the opponent ([Gait.luau](src/shared/Gait.luau) places the feet and hips, Animator
  solves the legs with IK, scaled to each rig's leg length). Walking, running, strafing and backpedalling are procedural
  footwork driven by the real ground velocity relative to facing, so planted feet don't slide; Roblox's own animations
  only show in the air, when seated or climbing. Out of combat the stance stands taller and the blade is carried
  forward and down; locked on, or within 4 s of an exchange, fighters raise a two-handed chudan guard. Combat motion
  is procedural: [Poses.luau](src/shared/Poses.luau)
  describes each pose as directions (where the arm, forearm and blade point), solves them into joint rotations, and
  [Animator.luau](src/client/Animator.luau) layers them over the locomotion with eased keyframes from [Clips.luau](src/shared/Clips.luau).
- **Swords.** Stylised and slightly oversized, like Dueling Grounds': the katana is 5.7 studs (the odachi 7.6), with
  a code-built dark iron tsuba with a gold rim, a gold pommel cap and a bright neon line along the edge welded over the
  mesh ([SwordRig.luau](src/server/SwordRig.luau)), and a thin ink outline (a Highlight) so it reads at camera
  distance. The hit areas in `Config` are sized to this blade, so a cut that visibly reaches someone lands. Each
  strike draws a wide gradient crescent that follows the blade's real sweep, steel-white for slashes (or the skin's
  colour) and red for perilous attacks. **Blade skins**
  ([Progression.luau](src/shared/Progression.luau)) tint the mesh through `SpecialMesh.VertexColor` and recolour the
  outline and trail; the rarer ones add a glow or drifting petals. Some unlock through play (Mastery 3, 5 wins, 25
  deathblows, 150 perfect deflects) and are then bought with coins. Roblox caps how many
  Highlights render at once (about 31), so keep fighters plus perilous telegraphs under that.
- **Lock-on camera** ([LockOn.luau](src/client/LockOn.luau), `Config.LockOn`). Kannagi's spring arm: 9.3 studs back
  from a pivot 1.25 above your root, the eye trailing at lag speed 7 (at most 4.3 studs behind) and turning toward the
  target at 5, a 60° lens (Kannagi's 88° is UE's horizontal angle; Roblox's FieldOfView is vertical, and 88° horizontal
  is ~57° vertical at 16:9; the free camera stays at 70). Inside 14 studs it frames the pair: the eye swings further to
  the shoulder, rises (more for a tall boss) and pulls back, and the focus slides toward the target's chest. Walls,
  rocks and posts between you and the eye pull the camera in (invisible fence walls don't). When your own body still
  hides the target's head or chest, it fades to see-through on your screen (your blade doesn't). Camera shake works
  while locked, and still follows the Settings toggle.
- **HUD.** Sekiro / Dark Souls style: a crimson vitality bar with a damage trail, a posture bar that grows from the centre
  and hides when empty, gourd count, enemy bars only for your target and recent opponents, a red deathblow marker, kanji
  splashes, a phase banner, a kill feed and spectating. The closing mist is a wall of camera-facing beams (a cylinder
  part culls its inside faces, so it vanished once you were inside it); columns fade as the camera nears them so one
  never fills the screen, and standing in the mist tints your screen red. Fighters standing between the camera and you
  fade out on your screen ([Occlusion.luau](src/client/Occlusion.luau)). A boss gets no floating bars, only its
  bar at the bottom of the screen, which shows the red deathblow marker on its posture bar while it's broken (its body
  carries the marker too). The dead let go of their swords: the blade drops and lies beside the body.
  Rewards, level-ups, Trials and the end-of-match report card are in [Toasts.luau](src/client/Toasts.luau).
- **Icons and store art.** Every menu, currency, rank, reward and touch-button icon is painted by ChatGPT image
  generation (through the Codex CLI) from one style bible, [art/icons/STYLE.md](art/icons/STYLE.md): sumi-e ink outline
  plus flat cel shading in the crimson / bone / gold / jade palette. `art/icons/gen.sh <name> "<subject>"` makes one,
  `cutout.py` removes the white background (and enclosed holes) into a 512 px PNG, and uploaded ids live in
  `Assets.Icons`, `Assets.RankCrests` and `Assets.Touch`. The splash backdrop is a painted brush stroke. Store icon and
  thumbnails (from real gameplay screenshots as references) are in `art/store/export/`.
- **Map.** [MapBuilder.luau](src/server/MapBuilder.luau) generates the terrain, castle walls, shrine hall, a pale-sand
  duelling circle (so dark-clad fighters read clearly), moss along the walls, crimson nobori banners, braziers and
  drifting maple leaves. World and HUD colours come from [Palette.luau](src/shared/Palette.luau).
- **Environment** ([EnvironmentProfile.luau](src/server/EnvironmentProfile.luau), at startup): terrain material colours
  for midday (calm sand fighting floors so characters pop, fresh grass, near-neutral cliff rock), warm sandstone for the
  placed lanterns and boulders, and the round vermilion lacquered post with a black cap used on every fence, the dojo
  and the shrine.
- **Materials.** `MaterialService` overrides re-skin every Plaster, Wood and ClayRoofTiles surface at once with
  generated materials (aged lime plaster, cedar, kawara tiles), the closest thing Roblox has to one shared shader. They
  live in the place file, not in git. Lacquered red pillars use SmoothPlastic so the timber override skips them.
- **Lighting.** Bright, soft daylight in the spirit of Dueling Grounds, applied by the server at startup from
  [LightingProfile.luau](src/shared/LightingProfile.luau): an early-afternoon sun, neutral-warm ambient high enough that
  faces and clothes read in shadow, soft shadows, a light far haze that leaves fighters clear, a gentle grade and bloom,
  and Roblox's stock day sky. `LightingStyle = Realistic` with `PrioritizeLightingQuality` stay in
  `default.project.json` (scripts can't set them), which also mirrors the profile's values so edit mode and thumbnails
  match; change both together. Props in `Workspace.Props` came from the Creator Store and were
  stripped of every script.
- **Fighters.** Bots and bosses are dressed by [Outfit.luau](src/server/Outfit.luau) in textured classic Shirt/Pants:
  a gi with crossed lapels and an obi over pleated hakama, six mid-tone colourways for bots and one set per boss
  (ids in [Clothing.luau](src/shared/Clothing.luau)). The templates are built by `art/clothing/build.py` from
  Codex-generated fabric swatches; to retune colours edit its `COLOURWAYS`, rebuild, re-upload and paste
  `build.py --luau` into Clothing.luau. Bots also wear a woven kasa (made with Studio's mesh generator).
- **Combat VFX** ([CombatVisuals.luau](src/client/CombatVisuals.luau)). Slash smears are pooled flat Beams swept
  between the sword's `TrailStart`/`TrailEnd` attachments every frame (interpolated, so even a 70 ms cut draws a smooth
  arc). Thrusts (the perilous thrust, boss thrusts) barely sweep, so they also draw a straight, tapered streak from the
  guard to past the tip, red for perilous, that closes up toward the point as it fades. Deflects spray long sparks
  from where the blades meet (more, and a bigger bloom, for a perfect deflect); hits
  add a cut streak, a white star flash and shards to the dark, gravity-pulled blood; deathblows add an X cut, pools on
  the floor and a brief desaturated freeze. **Settings → Reduced effects** thins particles, drops flash lights and
  shortens smears. In Studio, `workspace:SetAttribute("VfxSlowMo", 0.1)` slows only these effects for screenshots. The camera kicks along the blow and settles
  rather than jittering at random.
- **Sound.** Licensed ProSoundEffects and APM library audio. Every asset id is in [Assets.luau](src/shared/Assets.luau).

## Balance telemetry

[Telemetry.luau](src/server/Telemetry.luau) counts every move started and how it resolved (hit, guarded, deflected,
perfect, Mikiri, jumped, dodged, whiffed, deathblow), the move behind each kill and how many attackers each victim had,
humans and bots separately; only royale fighters count (duels and boss trials that run during a match are left out). After each match the server prints running totals to the output and raises alarms once the
sample is large enough: perilous above 20% of human attacks, perilous countered under 40% of the time, or one move
landing over 35% of kills. Tune numbers in `Config` and `Weapons`, then watch the alarms.

## Performance

- The scene is about 450 parts, 6 lights and one terrain mesh. Decorative props don't collide, query or touch, and small
  parts don't cast shadows. Distant mountains are single meshes with shadows and collision off.
- Nothing in the HUD runs per frame. Bars update from attribute and health signals and animate with tweens. The ring is
  the only per-frame update, and only during a match.
- Round state replicates as a few attributes per phase; clients compute the ring and timers from the synced clock.

## Code map

```
src/
  shared/   Config, Weapons, Ranks, Types, Assets, Palette, Poses, Clips, BakedPoses, BakedClips, Round, Progression,
            Bosses, Spacing, KannagiMoves (generated), BakedBoss (generated)
  server/   init, CombatService, BotService, RoundService, StatsService, ProgressService, LobbyService, LobbyBuilder,
            LeaderboardService, Telemetry, MapBuilder, Outfit, Locomotion, SwordRig, DevHooks, DuelService,
            BossService, BossAI
  client/   init, Animator, CombatVisuals, CombatInput, LockOn, CombatHUD, RoundHUD, LobbyHUD, Panels, UI,
            TrainerReadout, TitleScreen, Ambience, Coach, Toasts, Occlusion, DuelHUD, BossHUD, BossVisuals
```

## Before publishing

- Save the place in Studio, then run `rojo syncback` so `Workspace.Props` and the `MaterialService` variants are tracked
  in git.
- Game Settings: R15 only; Security → enable Studio access to API services to test DataStores.
- Store page: icon and thumbnails (real gameplay captures work best), description, genre "Fighting".
- Rename anything that borrows FromSoftware terms ("Shinobi Execution", "Mikiri") if you want to avoid trouble.
