--!strict
-- Every combat number lives here so feel can be tuned without touching logic.
-- Times are seconds on the shared server clock (workspace:GetServerTimeNow()).

-- Light1-3 are the slash combo; the third hit branches (see Combo). Riposte, DodgeSlash and
-- MikiriSlash open the counter-strings (after a deflect, a dodge, a Mikiri). The client picks
-- the matching clip from the kind name (Clips.luau aliases the counter moves).
export type AttackKind =
	"Light1"
	| "Light2"
	| "Light3"
	| "Overhead"
	| "Riposte"
	| "Riposte2"
	| "DodgeSlash"
	| "MikiriSlash"
	| "Perilous"
	| "Sweep"

-- Hit reactions by weight (Kannagi's DamageReaction / GuardReaction / HajikiReaction).
export type Reaction = "Small" | "Middle" | "Large" | "Gedan"
export type GuardReaction = "Small" | "Middle" | "Large"
export type DeflectSide = "Right" | "Left" | "Back"
-- Seconds after impact from which recovery can be cancelled into each input. A missing
-- entry means "only once recovery ends".
export type CancelPoints = { Attack: number?, Block: number?, Dodge: number?, Jump: number?, Heal: number? }

-- A move as written in Config.Attacks: every field below `unblockable` is optional and falls
-- back to Config.MoveDefaults. Weapons.spec resolves a MoveDef into a full AttackSpec. The
-- per-move timing fields (tracking, cancels, recoil, reactions, stomp window) are the hooks
-- the Kannagi anim-notify decode fills in; until then they hold sensible defaults.
export type MoveDef = {
	windup: number, -- telegraph before impact; keep >= 0.3 so 200 ms ping players can still read it
	recovery: number, -- lockout after impact, on top of Net.ResolveGrace
	cooldown: number, -- min time between starts of this attack
	damage: number,
	postureDamage: number,
	range: number, -- studs in front of the attacker
	width: number,
	lunge: number, -- forward speed (studs/s) the strike starts with, eased out over lungeTime
	unblockable: boolean, -- can't be deflected or guarded at all (sweeps): jump it
	perilous: boolean?, -- 危: hyper armour late in its windup, and a red warning
	noGuard: boolean?, -- holding guard does nothing; only a timed deflect works (thrusts)
	thrust: boolean?, -- can be Mikiri-countered by dashing into it
	low: boolean?, -- a sweep: only a jump avoids it (dodge i-frames don't)
	-- Hyper armour: hits during the last `armorFrom` seconds of the windup hurt but don't
	-- interrupt it. Early in the windup the swing can still be stopped by a hit.
	armorFrom: number?,
	cooldownGroup: string?, -- attacks in a group share one escalating cooldown (Config.Cooldowns)
	riposte: boolean?, -- only available just after a deflect that recoiled the attacker
	-- Windup when the previous slash in the string *landed* (Chivalry 2's rule: strings
	-- speed up on hit, never on block or deflect).
	chainWindup: number?,
	ender: boolean?, -- ends a string: a short rest before the next string can start
	follow: AttackKind?, -- the next slash of this move's counter-string (Riposte -> Riposte2)

	-- Facing (Kannagi: one turn into the attack, then capped tracking inside authored windows,
	-- which for player swings run to impact at 800 deg/s; bosses 300-500). Never in recovery.
	startTurn: number?, -- seconds of the opening turn toward the target as the attack starts...
	startTurnRate: number?, -- ...at up to this many degrees/s
	trackRate: number?, -- degrees/s the attacker may keep turning inside the tracking window
	trackFrom: number?, -- tracking window opens this long after the attack starts...
	trackUntil: number?, -- ...and closes this long before impact (0 = at impact)
	-- Deflects: does a deflect of this move knock the attacker into a recoil (ending the
	-- string and opening the defender's Riposte)? Openers don't: deflect rallies continue.
	recoilOnDeflect: boolean?,
	deflectPosture: number?, -- Kannagi's ReTDamageScale: posture the attacker takes per deflect, x postureDamage
	cancel: CancelPoints?,
	lungeAt: number?, -- seconds relative to impact the lunge starts (negative = before)
	lungeTime: number?, -- seconds the lunge eases out over
	reaction: Reaction?, -- the victim's flinch size (sets hit stun, see Config.HitStun)
	guardReaction: GuardReaction?, -- how hard a guard of it rocks the defender
	deflectSide: DeflectSide?, -- which way the defender's deflect throws the blade
	knockback: number?, -- studs the victim slides on a clean hit (scaled down on guard and deflect)
	stompFrom: number?, -- low moves: a second jump press on the sweeper counts from this long
	stompUntil: number?, -- after impact (negative = before) until this long after it
}

-- A move as resolved by Weapons.spec: defaults filled in and the weapon applied.
export type AttackSpec = {
	windup: number,
	recovery: number,
	cooldown: number,
	damage: number,
	postureDamage: number,
	range: number,
	width: number,
	lunge: number,
	unblockable: boolean,
	perilous: boolean?,
	noGuard: boolean?,
	thrust: boolean?,
	low: boolean?,
	armorFrom: number?,
	cooldownGroup: string?,
	riposte: boolean?,
	chainWindup: number?,
	ender: boolean?,
	follow: AttackKind?,
	startTurn: number,
	startTurnRate: number,
	trackRate: number,
	trackFrom: number,
	trackUntil: number,
	recoilOnDeflect: boolean,
	deflectPosture: number,
	cancel: CancelPoints,
	lungeAt: number,
	lungeTime: number,
	reaction: Reaction,
	guardReaction: GuardReaction,
	deflectSide: DeflectSide,
	knockback: number,
	stompFrom: number,
	stompUntil: number,
	-- Filled in by Weapons.spec: which move and weapon this resolved spec belongs to.
	kind: AttackKind?,
	weapon: string?,
}

-- What every move gets unless it says otherwise: Kannagi's player string (Ichijiku_Attack01/02,
-- research_notes/Kannagi Usagi RE/move_data.md section 2), measured from impact. Guard and dodge
-- open 0.14 s after it (Kannagi 0.136), jump and sip 0.19 s (0.185). Recovery ends (walking
-- comes back) about 0.59 s after impact in Kannagi; each move sets its own `recovery`. Player
-- hits have no knockback and a Small flinch. Deviation: Kannagi's player tracks its lock target
-- at 800 deg/s, tuned against slow bosses; in PvP the attacker is the defender's "boss", so we
-- use the boss tracking band (300-500 deg/s, median 0.06 s past impact; we stop at impact).
local moveDefaults = {
	startTurn = 0.1,
	startTurnRate = 900,
	trackRate = 500,
	trackFrom = 0,
	trackUntil = 0,
	recoilOnDeflect = false,
	deflectPosture = 1, -- Kannagi reTScale: 1.0 on every player hit, 1.2-3.0 on boss finishers
	cancel = { Block = 0.14, Dodge = 0.14, Jump = 0.19, Heal = 0.19 } :: CancelPoints,
	-- The lunge stands in for the clip's root motion (the Kannagi clips play in place): ~0.1 s
	-- of travel just around impact (Light1: 3.7 studs, 0.47-0.57 s into a clip whose impact is at
	-- 0.50). The client shortens it to stop 3 studs short of anyone in front.
	lungeAt = -0.03,
	lungeTime = 0.12,
	reaction = "Small" :: Reaction,
	guardReaction = "Small" :: GuardReaction,
	deflectSide = "Right" :: DeflectSide,
	knockback = 0,
	stompFrom = 0,
	stompUntil = 0,
}

-- Our moves and the Kannagi move each is filled from (times relative to impact):
--   Light1 / Light2     Ichijiku_Attack01 / Attack02 (the 2-hit loop): impact 0.43, cancels L1/B +0.136,
--                       R1/A/Y +0.185, Idle +0.586, lunge 4.29 studs, deflect anim Left / Right.
--   Light3, Overhead    no player equivalent (Kannagi's player has no ender): Light3 is Attack01 with
--                       ender extras; Overhead uses the boss Normal median (windup 0.64, recovery 0.61).
--   Riposte / Riposte2  Attack04 / Attack05 (the counter loop after a deflect): impact 0.325 / 0.312,
--                       cancels L1/B +0.19, R1 +0.24, Idle +0.62, lunge 4.13.
--   DodgeSlash          Attack03 from a dodge: impact 0.351, cancels +0.131 / +0.196, Idle +0.6, lunge 5.08.
--   MikiriSlash         Attack03@Mikiri (starts 0.25 s in): impact 0.304, cancels +0.131 / +0.195.
--   Perilous / Sweep    no player equivalent: boss Tsuki / Gedan medians (windup 0.83 / 0.89, 危 shown
--                       0.67-1.18 s before impact, recovery 0.61).
-- Lunges: `lunge` is a start speed easing out over lungeTime (distance ~= 0.55 x lunge x lungeTime),
-- matched to each clip's authored root travel (anim_integration.md): 56 over 0.12 s is ~3.7 studs.
--
-- Deliberate PvP deviations (each also noted on the move):
--   * Openers keep 0.46-0.5 s windups (Kannagi 0.43): a human defender needs ~0.25 s reaction plus up to
--     0.125 s of ping. Chained hits (after a landed one) use 0.42, Kannagi's own rhythm.
--   * Every Kannagi player hit recoils the boss when deflected (a 0.41 s ReHajiki). In PvP each fighter is
--     the other's "boss", so we follow the boss data instead (59 of 311 boss hits recoil, mostly enders):
--     openers are only knocked aside and the rally goes on; enders recoil.
--   * The Riposte stays at 0.18 s (Kannagi Attack04 0.325): it must land inside our 0.5 s attacker recoil
--     at 250 ms ping, where Kannagi's bosses recoil for 0.78 s.
--
-- Hit areas (`range` deep x `width` wide) follow the blade (Weapons: "reach follows the blade"), sized
-- for the 1.3x katana whose tip is 4.95 studs from the hand (was 3.85). Each box grew by what its clip's
-- tip sweep gained, measured in Edit mode over the strike segments: +1.1 deep on every move, and wider by
-- how much further the tip swings sideways (Light1/2 and the Riposte +1.5; Light3, DodgeSlash, MikiriSlash
-- and the sweep +2). The Overhead and the thrust are straight cuts and the Riposte2's arc barely widened,
-- so those keep their width. Weapons scales `range` by reach (the odachi's +1.4). Bots' AttackDistance /
-- StrafeDistance and the Coach's range moved with them.
local attacks: { [AttackKind]: MoveDef } = {
	Light1 = {
		windup = 0.5, -- PvP opener floor (Kannagi 0.43)
		recovery = 0.47, -- Idle 0.59 s after impact (Kannagi 0.586), on top of Net.ResolveGrace
		cooldown = 0,
		damage = 9,
		postureDamage = 18,
		range = 8.1,
		width = 7.5,
		lunge = 56, -- 3.7 studs at impact (clip root travel; Kannagi 4.3)
		unblockable = false,
		deflectSide = "Left", -- Kannagi Attack01 deflectReaction LeftSmall
		-- The next slash 0.2 s after impact (Kannagi 0.185; not before the blow resolves, which takes
		-- at most Net.GraceMax, so the chain speed-up knows whether it landed).
		cancel = { Attack = 0.2 },
	},
	Light2 = {
		windup = 0.46,
		chainWindup = 0.42, -- after a landed hit: Kannagi's 0.43 s swing, 0.62 s between impacts
		recovery = 0.47,
		cooldown = 0,
		damage = 9,
		postureDamage = 18,
		range = 8.1,
		width = 7.5,
		lunge = 56, -- 3.7 studs
		unblockable = false,
		deflectSide = "Right", -- Kannagi Attack02 deflectReaction RightSmall
		cancel = { Attack = 0.2 },
	},
	-- The third hit is a read. Click on rhythm for a fast Light3; pause first (Combo.DelayAfter)
	-- for the delayed Overhead, which catches early deflects and hits posture harder; press E/C
	-- for a perilous morph; or press block to feint. Enders recoil when deflected, cost the
	-- attacker more posture when deflected (Kannagi boss finishers: reTScale 1.2-3.0) and leave
	-- them open longer (no attack cancel, a later guard/dodge one, then Combo.EnderRest).
	Light3 = {
		windup = 0.46,
		chainWindup = 0.42,
		recovery = 0.49, -- boss median 0.61 s after the last hit
		cooldown = 0,
		damage = 11,
		postureDamage = 22,
		range = 8.6,
		width = 8,
		lunge = 62, -- 4.1 studs
		lungeAt = -0.04,
		unblockable = false,
		ender = true,
		recoilOnDeflect = true,
		deflectPosture = 1.2,
		reaction = "Middle",
		guardReaction = "Middle",
		deflectSide = "Back",
		knockback = 2,
		cancel = { Block = 0.2, Dodge = 0.2, Jump = 0.25, Heal = 0.25 },
	},
	Overhead = {
		windup = 0.62, -- the boss Normal median, 0.64
		chainWindup = 0.56,
		recovery = 0.55,
		cooldown = 0,
		damage = 14,
		postureDamage = 34,
		range = 8.6,
		width = 5,
		lunge = 56, -- 3.7 studs
		lungeAt = -0.05,
		unblockable = false,
		ender = true,
		recoilOnDeflect = true,
		deflectPosture = 1.5,
		reaction = "Large",
		guardReaction = "Large",
		deflectSide = "Back",
		knockback = 3,
		cancel = { Block = 0.24, Dodge = 0.24, Jump = 0.3, Heal = 0.3 },
	},

	-- Deflect an ender (any move with recoilOnDeflect), then slash within
	-- Deflect.RiposteWindow: a fast counter-cut that can't be interrupted, the first hit of a
	-- two-hit counter-string (Kannagi's Attack04 -> Attack05). It has to land inside the
	-- attacker's recoil even at 250 ms ping (recoil 0.5 s >= startup 0.18 s + ~0.125 s one-way
	-- + cushion), so it is faster than Kannagi's 0.325 s.
	Riposte = {
		windup = 0.18,
		recovery = 0.5, -- Idle 0.62 s after impact (Kannagi Attack04)
		cooldown = 0,
		damage = 11,
		postureDamage = 24,
		range = 8.6,
		width = 7.5,
		lunge = 55, -- 3.6 studs (Kannagi Attack04 4.13)
		lungeAt = -0.01,
		unblockable = false,
		armorFrom = 0.18,
		riposte = true,
		follow = "Riposte2",
		deflectSide = "Left", -- Kannagi Attack04 deflectReaction LeftSmall
		cancel = { Block = 0.19, Dodge = 0.19, Attack = 0.24, Jump = 0.24, Heal = 0.24 },
	},
	-- The counter-string's second cut (Kannagi Attack05, impact 0.312 s). A little slower here
	-- (0.42, or 0.36 after a landed Riposte) so a defender who pressed block during the
	-- Riposte's flinch can still deflect it. It ends the string.
	Riposte2 = {
		windup = 0.42,
		chainWindup = 0.36,
		recovery = 0.52, -- Idle 0.64 s after impact (Kannagi Attack05)
		cooldown = 0,
		damage = 10,
		postureDamage = 22,
		range = 8.6,
		width = 6,
		lunge = 55, -- 3.6 studs
		lungeAt = 0,
		unblockable = false,
		ender = true,
		recoilOnDeflect = true,
		deflectPosture = 1.2,
		deflectSide = "Right", -- Kannagi Attack05 deflectReaction RightSmall
		cancel = { Block = 0.2, Dodge = 0.2, Jump = 0.25, Heal = 0.25 },
	},
	-- Attack out of a dodge (Dodge.AttackWindow): Kannagi's Attack03 dodge-attack, a thrusting
	-- cut with the longest lunge. Chains on into Light2.
	DodgeSlash = {
		windup = 0.35, -- Kannagi 0.351
		recovery = 0.48, -- Idle 0.6 s after impact
		cooldown = 0,
		damage = 10,
		postureDamage = 20,
		range = 8.6,
		width = 7,
		lunge = 67, -- 4.4 studs (Kannagi 5.08)
		lungeAt = -0.01,
		unblockable = false,
		follow = "Light2",
		deflectSide = "Right", -- Kannagi Attack03 deflectReaction RightSmall
		cancel = { Block = 0.13, Dodge = 0.13, Attack = 0.2, Jump = 0.2, Heal = 0.2 },
	},
	-- Attack right after a Mikiri Counter (Mikiri.FollowWindow): Kannagi's Attack03 started
	-- 0.25 s in, the cut onto the pinned blade. It recoils when deflected (a big read paid off).
	MikiriSlash = {
		windup = 0.3, -- Kannagi 0.304
		recovery = 0.48,
		cooldown = 0,
		damage = 13,
		postureDamage = 26,
		range = 8.6,
		width = 8,
		lunge = 67, -- 4.4 studs
		lungeAt = -0.01,
		unblockable = false,
		armorFrom = 0.3,
		follow = "Light2",
		recoilOnDeflect = true,
		-- Small like Kannagi's Attack03: a Middle stun would let the Light2 that follows it combo.
		deflectSide = "Right",
		cancel = { Block = 0.13, Dodge = 0.13, Attack = 0.2, Jump = 0.2, Heal = 0.2 },
	},
	-- Perilous attacks: no player equivalent, so they follow the boss Tsuki / Gedan data. The 危
	-- warning shows for the whole windup, which sits inside the bosses' 0.67-1.18 s band.
	Perilous = {
		windup = 0.85, -- boss Tsuki median 0.83
		recovery = 0.55, -- boss median 0.61 s after the last hit
		cooldown = 0, -- see Cooldowns.Perilous, shared with the sweep
		damage = 18, -- ~2x a slash: strong when it lands, but a read costs far more
		postureDamage = 35,
		range = 10.1,
		width = 4,
		lunge = 85, -- 4.7 studs in the last 0.06 s before impact
		lungeAt = -0.06,
		lungeTime = 0.1,
		unblockable = false, -- Sekiro lets you deflect a thrust, but not guard it
		perilous = true,
		noGuard = true,
		thrust = true,
		armorFrom = 0.3,
		cooldownGroup = "Perilous",
		recoilOnDeflect = true,
		trackRate = 420, -- inside the boss band, to impact: the late turn is its tell
		reaction = "Large",
		deflectSide = "Back",
		knockback = 3,
		cancel = { Block = 0.25, Dodge = 0.25, Jump = 0.3, Heal = 0.3 },
	},
	Sweep = {
		windup = 0.9, -- boss Gedan median 0.89
		recovery = 0.6,
		cooldown = 0, -- see Cooldowns.Perilous, shared with the thrust
		damage = 16,
		postureDamage = 30,
		range = 9.6,
		width = 12,
		lunge = 76, -- 5 studs: the clip spins 9.7 studs forward, capped so a PvP sweep never carries past its victim
		unblockable = true,
		perilous = true,
		low = true,
		armorFrom = 0.3,
		cooldownGroup = "Perilous",
		trackRate = 360,
		reaction = "Gedan",
		knockback = 2.5,
		cancel = { Block = 0.25, Dodge = 0.25, Jump = 0.3, Heal = 0.3 },
		-- Jump it and press jump again over the sweeper to stomp (Config.Stomp). Kannagi's stomp
		-- windows open about at impact and last 0.8-1.1 s; ours ends with the sweep's recovery.
		stompFrom = -0.05,
		stompUntil = 0.72,
	},
}

local Config = {
	Attacks = attacks,
	MoveDefaults = moveDefaults,

	-- Working title; change freely.
	Title = {
		Name = "L A S T   B L A D E",
		Kanji = "最後の刃",
		Tagline = "Deflect.  Break their posture.  Be the last blade standing.",
	},

	-- Shared cooldowns. Each use inside `Memory` seconds of the last multiplies the next
	-- cooldown by `Escalation`, so alternating thrust and sweep can't be spammed.
	Cooldowns = {
		Perilous = { Base = 7, Escalation = 1.5, Memory = 8 },
	} :: { [string]: { Base: number, Escalation: number, Memory: number } },

	-- What a correctly read perilous attack costs its owner: a big posture chunk and a long
	-- recovery, so a perilous is a gamble, not a free unblockable.
	PerilousCounter = {
		DeflectPosture = 40, -- a deflected thrust, on top of the normal deflect posture
		DeflectRecoil = 0.8,
		JumpedRecovery = 0.7, -- a sweep that was jumped leaves its owner open this long
	},

	Combo = {
		Sequence = { "Light1", "Light2", "Light3" } :: { AttackKind },
		Window = 0.7, -- after recovery ends, the next slash continues the combo for this long
		-- Every input (attack, block, dodge, heal; jump on the client) pressed while you're busy
		-- is held this long and fires on the first frame it becomes legal (Kannagi's
		-- PreInputKey timeline). Last input wins; a stagger or posture break drops a queued
		-- attack, so a panic click can't commit you after the fight has moved on.
		Buffer = 0.45,
		DelayAfter = 0.25, -- the third slash pressed this long after Light2 ends is the Overhead
		EnderRest = 0.3, -- after an ender the next string waits this long: the defender's turn
		-- E or C during Light2's recovery or the third slash's windup morphs the ender into
		-- a perilous attack with this shorter windup. One morph or feint per string.
		MorphWindup = 0.65,
	},

	-- Stamina only limits dodge (and feint) spam now. Attacks are limited by commitment (no
	-- walking, per-move cancel points), perilous cooldowns and opponents who guard, then
	-- deflect, a mashed string (Kannagi and Sekiro have no stamina at all). Dodges keep a cost
	-- because i-frames are the one verb commitment doesn't limit: four in a row empty it.
	Stamina = {
		Max = 100,
		RegenPerSecond = 30,
		RegenDelay = 0.7, -- after spending any
		Costs = {
			Dodge = 25,
		} :: { [string]: number },
	},

	Gourd = {
		Charges = 3, -- per life
		Heal = 45,
		DrinkTime = 0.9, -- slowed and open the whole time; a hit wastes the sip
	},

	-- Dash forward into a thrust: a forward dodge counts as a Mikiri from its first frame, if
	-- it started within `Window` before the thrust's impact (i-frames or not).
	Mikiri = {
		Window = 0.47, -- Kannagi's forward dodge carries the Mikiri flag 0-0.47 s
		PostureScale = 2, -- the thrust's posture x deflectPosture x this, as Kannagi
		Freeze = 3.5, -- the attacker's posture recovery stops this long
		AttackerStagger = 0.9,
		Lunge = 4, -- studs the countering fighter slides onto the blade (stopping short of them)
		-- Slash this soon after for the MikiriSlash follow-up. Kannagi allows it from 0.785 s into a
		-- 1.21 s boss ReMikiri; ours has to land inside AttackerStagger (0.45 + its 0.3 s windup
		-- + resolve stays under 0.9 s).
		FollowWindow = 0.45,
	},

	Jump = {
		EvadeWindow = 0.65, -- a sweep landing this soon after jumping misses
		-- The server only takes a jump it can see: the body must be airborne within
		-- VerifyTime (plus half the player's ping) of the press. One per MinInterval.
		VerifyTime = 0.25,
		MinInterval = 0.4,
		BackdateSlack = 0.03, -- jump and dodge stamps may be back-dated by one-way ping + this
		-- A jump pressed during a swing or a stagger waits (Combo.Buffer) instead of firing.
	},

	-- A second jump press in the air over a sweeper (inside the sweep's stomp window, see
	-- AttackSpec.stompFrom/stompUntil) lands on their head: Kannagi's Fumitsuke.
	Stomp = {
		Range = 6, -- studs between the two roots, across the ground (the stomper must be above)
		PostureScale = 2, -- the sweep's posture x deflectPosture x this
		Freeze = 3.5, -- the sweeper's posture recovery stops this long
		Stagger = 0.45,
		Launch = 27, -- studs/s up for the stomper
	},

	-- Spawn protection: you can't be hit and bots ignore you for this long.
	SpawnProtection = 2,

	Arena = {
		WallHalfExtent = 78, -- castle walls form a square this far from the centre
		FightRadius = 66, -- open ground inside the walls
	},

	-- Resurrection (回生), Sekiro's signature: the first lethal blow of a match only cuts a
	-- player down. They kneel, untouchable, for `DownTime`, then rise with `Vitality` of
	-- their health. Dying in five seconds shouldn't end anyone's match.
	Resurrection = {
		Charges = 1, -- per match, players only (bots are fillers and stay down)
		DownTime = 2.2,
		Vitality = 0.5,
		Protection = 1.5, -- untouchable this long after rising
	},

	-- The first matches are where players quit. While `Played` is under `Matches`, a
	-- player's deflect windows are wider; it tapers off by the last of them.
	NewcomerAssist = {
		Matches = 10,
		WindowMultiplier = 1.2, -- 250 ms -> 300 ms
		PerfectMultiplier = 1.3,
	},

	Round = {
		Intermission = 8, -- countdown once someone is queued
		MaxDuration = 180, -- a match ends here even if several fighters remain
		Results = 6,
		MinFighters = 6, -- bots fill the match up to this many
		SpawnRadius = 36, -- fighters start evenly spaced on this circle, well inside the mist
		RespawnDelay = 3, -- outside a match
	},

	-- The free-roam lobby: a floating shrine island above the castle. Players spawn here,
	-- queue for the royale (PLAY or the glowing pad), and spar safely.
	Lobby = {
		-- Centre of the island's lower tier (terrain fill top; you walk 2 studs above it).
		-- The layout itself is in server/LobbyBuilder; it publishes spawn, pad and trainer
		-- positions as attributes on Workspace.Lobby.
		Origin = Vector3.new(0, 80, 300),
		Radius = 70,
		FallY = 40, -- below this height a lobby player is put back on the island
		QueuePadRadius = 7,
		AutoQueue = true, -- new players start queued: a first fight within ~30 s
		PvPToggleDelay = 3, -- turning lobby PvP on takes this long, so it can't be an ambush
	},

	-- 1v1 duels (一騎討). Posture combat reads best one on one, and a duel pad is a fight
	-- with no queue: two players stepping onto a facing pair of pads start a first-to-3 on
	-- a fenced terrace floating beside the island, and a lone player gets a bot after
	-- `BotWait`. The pads and terraces are laid out by server/LobbyBuilder; the duel loop
	-- is server/DuelService.
	Duel = {
		FirstTo = 3, -- rounds to win the duel
		BotWait = 8, -- a lone duellist is matched with a bot after this long on the pad
		PadRadius = 3.2,
		ArenaRadius = 17, -- the fence; fighters start StartDistance apart across the middle
		StartDistance = 14,
		RoundCountdown = 3, -- both fighters stand protected this long before each round
		RoundGap = 3.5, -- after a round is decided, so the fall and the point both read
		MaxRoundTime = 75, -- a stalled round goes to whoever has more vitality left
		Results = 5, -- on the terrace with the final score before both go back to the lobby
		FallDepth = 14, -- this far below the terrace a fighter is put back on their mark
	},

	-- Boss duels (Kannagi Usagi's nine bosses, see Shared/Bosses and server/BossService). Boss
	-- vitality and posture keep Kannagi's ratios to the player's own damage: Bosses.luau
	-- scales them by (our Light1/Light2 damage and posture) / (Kannagi's player 10 / 10), and a
	-- boss's posture recovery by the same posture ratio. Boss hits deal Kannagi's numbers
	-- (31-35 vitality per 1.0-scale hit against our 100) times DamageScale.
	Bosses = {
		DamageScale = 1,
		-- Kannagi's PlayerAttackSignSet_ANS: a boss "sees" your swing from this long before its
		-- impact until just after, within SignRadius studs (the 300 cm sign sphere plus the
		-- boss's capsule), and an idle boss raises guard on it. Widened past Kannagi's ~10.7 so it
		-- still covers the longest player reach after the 1.3x blades (an odachi thrust, ~13.4).
		SignLead = 0.12,
		SignTail = 0.03,
		SignRadius = 14,
		-- When a boss parries you, you recoil (Kannagi's ReHajiki: guard and dodge come back
		-- 0.41 s in) and take ParryPosture x your move's deflectPosture (the boss's
		-- AttackBaseTDamage, so Nanashi's parry costs you 25 of 100).
		PlayerRecoil = 0.41,
		-- Hit area of a boss swing: reach by weapon class (Kannagi's collider boxes plus an arm),
		-- plus however far the move's root motion carries it while the collider is on.
		Reach = { Katana = 7, Naginata = 9, Odachi = 8, Dual = 7 } :: { [string]: number },
		Width = 6,
		-- Lives: Kannagi's player has ZP 2 (one revival) against a boss.
		PlayerResurrections = 1,
		-- The fight: countdown on the marks, a result pause, and a time limit.
		Countdown = 3,
		Results = 6,
		MaxFightTime = 900,
		ArenaRadius = 26,
		StartDistance = 20,
		FallDepth = 16,
		-- Each extra player in the fight speeds the boss's posture recovery by this much.
		ExtraPlayerRegen = 0.25,
		Rewards = {
			Fought = { XP = 25, Coins = 10 },
			Clear = { XP = 80, Coins = 30 }, -- per clear, scaled by the boss's stars (min 1)
			FirstClear = { XP = 150, Coins = 120 }, -- once per boss, on top
			Phase = { XP = 20 }, -- per life taken, so a loss in phase 2 still pays
		},
	},

	-- Soft currency earned by playing, premium currency bought or dripped free.
	Economy = {
		StartCoins = 250,
		StartGems = 0,
		-- Match rewards (coins and XP) live in Shared/Progression.Rewards.
		-- Daily login streak: day N of a streak pays Daily[N] coins (gems on day 7).
		Daily = { 50, 60, 70, 80, 100, 120, 150 },
		DailyGems = 5,
	},

	Rating = {
		Start = 400,
		Division = 200, -- each tier has three divisions of this many points
		K = 24, -- rating change per decisive pairwise result
	},

	-- Omens: about one match in three gets a twist, announced at the start. Variety for
	-- free from the same arena. Applied by CombatService (Posture, Deathblow) and
	-- RoundService (Zone); the client tints the sky for Blood Moon.
	Omens = {
		Chance = 0.35,
		List = {
			{ id = "BloodMoon", name = "Blood Moon", kanji = "紅月", text = "Every deathblow kills" },
			{ id = "IronWill", name = "Iron Will", kanji = "鉄心", text = "Posture breaks faster" },
			{ id = "RushingMist", name = "Rushing Mist", kanji = "霧", text = "The mist closes twice as fast" },
		},
		IronWillPosture = 1.4,
	},

	Zone = {
		StartRadius = 74,
		EndRadius = 10,
		ShrinkDelay = 20, -- seconds after the match starts before the ring moves
		ShrinkTime = 110,
		CenterJitter = 18, -- the final circle lands somewhere near the middle
		DamagePerSecond = 7,
		TickInterval = 0.5,
	},

	-- Kannagi's posture economy. Deflecting is free for the defender; guarding is what breaks
	-- you; clean hits build some posture but can't break a fighter. Recovery is a flat rate
	-- (no vitality scaling, no guard bonus) that restarts after a delay set by the last
	-- posture event, so a guarded hit stalls it far longer than a deflect.
	Posture = {
		Max = 100,
		RegenPerSecond = 9,
		Delay = {
			Deflect = 0.5, -- the defender, after their own deflect
			Guard = 2.5,
			Hit = 2.5,
			Deflected = 1.2, -- the attacker, after being deflected (or Mikiri'd, stomped)
			Other = 1.2, -- feints and anything else
		} :: { [string]: number },
		BrokenDuration = 1.6, -- the deathblow window
		-- A break that runs out unpunished leaves posture this full (x Max), so any posture
		-- damage that can break before it drains re-breaks (Kannagi's bosses). Recovery
		-- restarts after AfterBreakDelay.
		AfterBreak = 0.99,
		AfterBreakDelay = 0.1,
		SurvivedDeathblowStun = 0.9, -- knocked down this long by a deathblow that didn't kill
		-- Share of a blow's posture damage a defender takes, by how they met it. Fighters
		-- (players and bots) use Kannagi's player column; Boss is its boss column, for the
		-- boss duels to come (a combatant's `postureProfile`).
		-- A profile may also set its own recovery rate and a single delay for every event
		-- (Kannagi bosses: 8.2/s after 0.75 s).
		Profiles = {
			Fighter = { Deflect = 0, Guard = 1, Hit = 0.5, HitBreaks = false },
			Boss = { Deflect = 0.6, Guard = 1, Hit = 0.8, HitBreaks = true, Regen = 8.2, RegenDelay = 0.75 },
		} :: {
			[string]: {
				Deflect: number,
				Guard: number,
				Hit: number,
				HitBreaks: boolean,
				Regen: number?,
				RegenDelay: number?,
			},
		},
	},

	-- Kannagi's model: a block press arms a deflect for `Window` seconds (judged on the
	-- defender's own clock stamp, with Net's ping grace on top). There is no shrinking for
	-- mashing. Instead, re-pressing within RepressLockout of lowering your guard, with nothing
	-- having struck you since, opens the window RepressDelay late (the guard is still coming
	-- down); and any press within ChainPress of your last deflect or guarded hit opens it at
	-- once, so deflecting a whole string in rhythm always feels crisp.
	Deflect = {
		Window = 0.25,
		PerfectWindow = 0.09, -- the last ~5 frames before impact: extra posture and a gold flash
		LateTolerance = 0.03, -- clock-sync slack for presses stamped just after impact
		RepressLockout = 0.25,
		RepressDelay = 0.15,
		ChainPress = 0.6,
		PerfectPosture = 1.6, -- a perfect deflect deals this much more posture to the attacker
		ChainWindow = 1.5, -- deflects in quick succession each deal more posture damage...
		ChainBonus = 0.2,
		ChainMax = 1.6, -- ...up to +60%
		FacingDot = 0.15, -- defender must roughly face the attacker to deflect or guard
		-- Deflecting a move with recoilOnDeflect staggers its attacker long enough for the
		-- Riposte to land, as in Sekiro; a perfect deflect leaves a bigger window. Other moves
		-- are only knocked aside (a pose, no stagger) and the string goes on.
		AttackerRecoil = 0.5,
		PerfectAttackerRecoil = 0.75,
		RiposteWindow = 0.5, -- slash this soon after a recoil deflect for a Riposte
		-- Right after a deflect, swings from anyone *else* are auto-guarded, so a third party
		-- can't trade into your riposte.
		ThirdPartyGuard = 0.35,
		-- A deflect that breaks the attacker pulls the defender up to them (at most this many
		-- studs), so the deathblow is one press away.
		BreakPull = 6,
	},

	Feint = {
		Cutoff = 0.12, -- a windup can't be cancelled this close to impact
		PostureCost = 6,
		StaminaCost = 8,
	},

	Dodge = {
		-- Kannagi's dodges (move_data.md section 2): i-frames 0.01-0.31 s forward / 0.01-0.35 s
		-- sideways and back, which never beat a sweep; the dodge-attack is allowed from 0.415 /
		-- 0.475 s, every other input from 0.551 / 0.637 s; 10.6 studs (8.6 back).
		IFrames = 0.33,
		Duration = 0.55, -- the dodge is an action: other inputs wait (buffered) until it ends...
		AttackCancel = 0.42, -- ...except an attack, which may cut in from here (the DodgeSlash)
		AttackWindow = 0.8, -- an attack this soon after a dodge starts is a DodgeSlash (Kannagi to 0.87)
		Cooldown = 0.6, -- dodge to dodge (Kannagi: the 0.551 s cancel)
		Speed = 50, -- bots' sidestep speed
		-- The player's dash bursts out and eases down to walking pace, ~10.7 studs in all
		-- (Kannagi 10.6), instead of a constant speed and a dead stop (which reads as a teleport).
		-- Faster than Kannagi's ~0.45 s of root motion: a PvP dash shouldn't drift into the next blow.
		DashStartSpeed = 72,
		DashEndSpeed = 14,
		DashDuration = 0.32,
		DashFovKick = 6, -- degrees, recovered over the dash
	},

	-- Client-side locomotion feel (see client/Movement). Speeds are studs/s.
	Movement = {
		StartFraction = 0.75, -- from standstill you start at this share of full speed...
		Acceleration = 22, -- ...and close the gap at this rate (~0.1 s to full)
		SpeedBlend = 12, -- how quickly speed follows a state change (guard, sip)
		StopBlend = 35, -- ...and how quickly a committed swing stops you (Kannagi: braking 2000 cm/s2)
	},

	Net = {
		CompensationCap = 0.25, -- how far in the past a client stamp may claim to be
		-- Nominal wait past impact for late defender packets; the timeline (recovery, cancels)
		-- is built on this. The actual wait scales with the defenders' ping:
		-- clamp(ping / 2 + GraceBase, GraceMin, GraceMax), so a 50 ms player isn't held to a
		-- 250 ms player's delay and a 250 ms player still gets a fair deflect.
		ResolveGrace = 0.12,
		GraceBase = 0.05,
		GraceMin = 0.06,
		GraceMax = 0.2,
		MaxActionsPerSecond = 20,
	},

	-- Hit stun by the attack's reaction size: until the victim can guard or dodge again. Kannagi's
	-- player flinches (Damage01-04) free guard and dodge at 0.25 / 1.12 / 1.40 / 1.50 s. Small is
	-- Kannagi's; the heavier ones are cut to about half because in PvP the attacker's next blow
	-- comes sooner than a boss's: each still ends before the same attacker's earliest next impact
	-- (Middle on Light3: next impact >= 1.4 s; Large/Gedan on enders and perilous: >= 1.17 s), so
	-- strings are never true combos. A block pressed during the stun is buffered and opens a
	-- deflect window the frame it ends (Kannagi's RenzokuHajiki rhythm). Resolve halves these.
	HitStun = { Small = 0.25, Middle = 0.6, Large = 0.8, Gedan = 0.8 } :: { [string]: number },
	-- Knockback slides the victim `knockback` studs over Duration (eased out, as Kannagi's
	-- 1 -> 0 curve), scaled by how the blow was met.
	Knockback = { Duration = 0.5, Hit = 1, Guard = 0.6, Deflect = 0.35 },
	-- Bodies keep apart like Kannagi's capsules (CharacterBase's CollisionCylinder, r = 35 cm:
	-- 1.25 studs at BossAI's 28 cm per stud), scaled by a body's BodyScale attribute (bosses).
	-- Fighters still don't collide physically (so a dodge passes through and nobody gets
	-- flung); Shared/Spacing keeps two fighters of the same arena at least their two radii
	-- apart instead: the server pushes bots and bosses, each client its own character.
	Spacing = {
		Radius = 1.25,
		Height = 3.5, -- roots further apart vertically than this (a jump over, a stomp) don't push
		StopMargin = 0.35, -- lunges, root motion and approaches stop this far outside contact
	},

	-- Free-for-all fairness. "Resolve" (For Honor's lesson: an "I'm outnumbered" tool, never
	-- an "I'm losing" tool) switches on only while two or more different fighters have struck
	-- you recently, and does nothing in a 1v1.
	Resolve = {
		Window = 3, -- strikes from distinct attackers within this many seconds count
		Attackers = 2,
		PostureRegenMultiplier = 2,
		StaggerMultiplier = 0.5, -- hit stun is shorter while outnumbered
	},
	-- Only the fighter who broke a posture may deathblow it for this long, so a third party
	-- can't steal the kill someone else earned. Others still land normal hits.
	BreakerOnlyDeathblow = 1.5,
	-- A deathblow takes a big chunk, and kills outright only an already wounded fighter
	-- (Sekiro bosses carry more than one "life"): a single posture break at full vitality
	-- isn't the end of your round.
	DeathblowDamage = 65,

	WalkSpeed = 16,
	AttackWalkSpeed = 0, -- swings are committed: no walking in windup or recovery, only the lunge
	StaggerWalkSpeed = 2,
	DrinkWalkSpeed = 6,
	BlockWalkSpeed = 9,
	BrokenWalkSpeed = 4,
	SoftLockRange = 16,

	LockOn = {
		Range = 45, -- max distance to acquire a target
		BreakRange = 60, -- lock drops beyond this
		TurnSpeed = 720, -- degrees/s the body turns toward its target while free (Kannagi: 800)
		-- The locked camera follows Kannagi's spring arm (Player_BP CameraBoom: 260 cm arm, pivot
		-- 35 cm above the capsule centre, lag speed 7 with at most 120 cm of lag, control rotation
		-- interpolated at 5) at BossAI's 28 cm per stud. Kannagi's FOV 88 is UE's horizontal angle;
		-- Roblox's FieldOfView is vertical, and 88 deg horizontal at 16:9 is ~57 deg vertical, so the
		-- locked lens is 60 (the free camera keeps Roblox's 70).
		CameraDistance = 9.3,
		PivotHeight = 1.25, -- above the root
		CameraHeight = 2.4, -- the eye above the pivot
		CameraShoulder = 2,
		FieldOfView = 60,
		FreeFieldOfView = 70,
		PositionLag = 7, -- Kannagi CameraLagSpeed
		MaxLag = 4.3, -- studs (CameraLagMaxDistance 120 cm)
		RotationLag = 5, -- Kannagi's RInterpTo toward the target
		-- Framing the pair: our bodies stand at Kannagi's capsule contact, where a camera straight
		-- behind you hides the target's torso and blade behind your back. Inside CloseRange the
		-- eye swings further out to the shoulder, rises and pulls back, and the focus slides toward
		-- the target, all in proportion to how close they are (full at contact).
		CloseRange = 14,
		CloseShoulder = 3.2,
		CloseRaise = 2,
		ClosePullBack = 1.2,
		-- Touch players lock on automatically to the nearest enemy (TouchHUD).
		AutoRange = 28, -- acquire the nearest enemy within this
		AutoBreakRange = 40, -- an automatic lock lets go beyond this, freeing the camera
		AutoSwitchGap = 10, -- switch when another enemy is this much closer
	},

	-- Four clearly separate feedback tiers (hitstop seconds). Hitstop only freezes the two
	-- fighters involved, on their own clients; in a free-for-all a long freeze is a liability.
	Visual = {
		PerilousColor = Color3.fromRGB(255, 40, 40),
		-- Kannagi has no hitstop at all; ours is kept short now that reactions carry weight.
		-- It only freezes clips already playing (never a windup), so it can't desync a swing.
		GuardHitstop = 0.03,
		Hitstop = 0.06, -- deflect
		PerfectHitstop = 0.09,
		DeathblowHitstop = 0.12,
		-- Clean hits, escalating through the string.
		HitHitstop = {
			Light1 = 0.035,
			Light2 = 0.04,
			Light3 = 0.06,
			Overhead = 0.08,
			Riposte = 0.06,
			Riposte2 = 0.06,
			DodgeSlash = 0.05,
			MikiriSlash = 0.08,
			Perilous = 0.1,
			Sweep = 0.1,
		} :: { [string]: number },
	},

	Bots = {
		SpawnRadius = 35,
		RespawnDelay = 4,
		AggroRange = 90,
		PlayerBias = 0.85, -- players look a little closer, so bots lean toward them without mobbing
		ArenaRadius = 62, -- bots won't chase past this distance from the centre
		ThinkInterval = 0.1,
		TurnResponsiveness = 18,
		TurnSpeed = 720, -- degrees/s while free; inside a swing the move's tracking applies
		-- Spacing: circle at StrafeDistance while waiting, step in to AttackDistance to swing. Both
		-- keep their margins to the slash's hit area (8.1 deep): waiting just outside it, swinging
		-- well inside it.
		AttackDistance = 6,
		StrafeDistance = 9,
		SeparationRadius = 4, -- push away from other fighters closer than this
		RetreatPosture = 0.7, -- back off to recover when own posture passes this fraction
		AttackInterval = { 0.9, 2.0 },
		ComboContinueChance = 0.6, -- chance to chain each next slash
		PerilousChance = 0.15,
		PunishChance = 0.6, -- chance to counter-attack once a deflect has stopped the attacker
		-- Defence is Kannagi's escalation ladder, tracked per attacker (no dice for slashes):
		-- an idle bot that sees a swing coming raises guard; a bot that was hit holds guard
		-- for the next one; a bot that guarded deflects the next one; a deflect is followed by
		-- a counter once the attacker stops. Ladder.Memory without contact resets it. A tier
		-- follows each rung with probability Follow (else it drops a rung) and needs
		-- Reaction seconds to see a windup, so Ronin bots still eat honest strings.
		Ladder = {
			Memory = 1.5,
			-- A guard has to be up before the deflect window would open, or it's a deflect.
			GuardLead = 0.3,
			GuardHold = 0.35, -- keep a reflex guard up this long past impact
			DeflectLead = { 0.04, 0.2 }, -- press this long before impact for a deflect...
			PerfectLead = { 0.015, 0.075 }, -- ...or this long for a perfect one
			Backstep = 0.25, -- after being hit, back off with guard up this long (a short step)
		},
		DodgePerilousChance = 0.5, -- perilous answers are still a roll (x tier Defense)
		MikiriChance = 0.4, -- of the dodges against a thrust, how many dash in for a Mikiri
		HealBelow = 0.4, -- sip the gourd when vitality drops under this fraction
		FeintChance = 0.2, -- when a defence press lands mid-windup, how often to feint instead of committing
		-- Openings: attack a target stuck in recovery, recoil or a sip.
		OpeningChance = 0.75,
		OpeningCooldown = 0.6,
		-- Only this many bots may fight one human at a time; the rest pick other targets.
		MaxBotsPerPlayer = 1,

		-- Skill tiers scale the numbers above. A match's tier follows its least experienced
		-- human (see Bots.tierFor), so a newcomer's first fights are winnable: players who
		-- face much stronger opponents quit, and easy early wins keep them.
		Tiers = {
			Novice = {
				Title = "Ronin",
				Follow = 0.4, -- chance to climb each ladder rung
				Reaction = 0.4, -- seconds to react to a windup
				Perfect = 0.05, -- share of its deflects that are perfect
				Defense = 0.35, -- multiplies the perilous answers (jump, dodge, Mikiri)
				AttackInterval = 1.7, -- multiplies the pause between strings
				Perilous = 0.4,
				Opening = 0.45,
				Punish = 0.3,
				Stomp = 0,
				-- A full string's third hit (BotService.rollTrick): a delayed Overhead, a perilous
				-- morph or a feint at these odds, else on rhythm. Ronin bots stay on rhythm.
				Mix = { Overhead = 0, Morph = 0, Feint = 0 },
			},
			Adept = {
				Title = "Samurai",
				Follow = 0.72,
				Reaction = 0.27,
				Perfect = 0.2,
				Defense = 0.8,
				AttackInterval = 1.15,
				Perilous = 0.8,
				Opening = 0.8,
				Punish = 0.8,
				Stomp = 0.3,
				Mix = { Overhead = 0.22, Morph = 0.1, Feint = 0.06 },
			},
			Master = {
				Title = "Kensei",
				Follow = 0.93,
				Reaction = 0.18,
				Perfect = 0.4,
				Defense = 1.1,
				AttackInterval = 0.9,
				Perilous = 1.2,
				Opening = 1,
				Punish = 1.1,
				Stomp = 0.8,
				Mix = { Overhead = 0.32, Morph = 0.16, Feint = 0.12 },
			},
		} :: { [string]: { [string]: any } },
	},
}

return Config
