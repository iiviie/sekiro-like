--!strict
-- Every combat number lives here so feel can be tuned without touching logic.
-- Times are seconds on the shared server clock (workspace:GetServerTimeNow()).

-- Light1-3 are the slash combo; the third hit branches (see Combo). The client picks the
-- matching clip from the kind name.
export type AttackKind = "Light1" | "Light2" | "Light3" | "Overhead" | "Riposte" | "Perilous" | "Sweep"

export type AttackSpec = {
	windup: number, -- telegraph before impact; keep >= 0.3 so 200 ms ping players can still read it
	recovery: number, -- lockout after impact, on top of Net.ResolveGrace
	cooldown: number, -- min time between starts of this attack
	damage: number,
	postureDamage: number,
	range: number, -- studs in front of the attacker
	width: number,
	lunge: number, -- forward speed (studs/s) added at the strike
	unblockable: boolean, -- can't be deflected or guarded at all (sweeps): jump or dodge
	perilous: boolean?, -- 危: hyper armour through its windup, and a red warning
	noGuard: boolean?, -- holding guard does nothing; only a timed deflect works (thrusts)
	thrust: boolean?, -- can be Mikiri-countered by dashing into it
	low: boolean?, -- a sweep: jump over it
	-- Hyper armour: hits during the last `armorFrom` seconds of the windup hurt but don't
	-- interrupt it. Early in the windup the swing can still be stopped by a hit.
	armorFrom: number?,
	cooldownGroup: string?, -- attacks in a group share one escalating cooldown (Config.Cooldowns)
	riposte: boolean?, -- only available just after a successful deflect
	-- Windup when the previous slash in the string *landed* (Chivalry 2's rule: strings
	-- speed up on hit, never on block or deflect).
	chainWindup: number?,
	ender: boolean?, -- ends a string: a short rest before the next string can start
	-- Filled in by Weapons.spec: which move and weapon this resolved spec belongs to.
	kind: AttackKind?,
	weapon: string?,
}

local attacks: { [AttackKind]: AttackSpec } = {
	-- Opening swings must be reactable: human reaction (~0.25 s) plus up to ~0.125 s of
	-- one-way ping, plus a moment to press. Below ~0.45 s players feel hit "before the sword".
	Light1 = {
		windup = 0.5,
		recovery = 0.25,
		cooldown = 0,
		damage = 9,
		postureDamage = 18,
		range = 7,
		width = 6,
		lunge = 18,
		unblockable = false,
	},
	Light2 = {
		windup = 0.46,
		chainWindup = 0.38, -- a rhythm read after a landed hit, still deflectable on the beat
		recovery = 0.25,
		cooldown = 0,
		damage = 9,
		postureDamage = 18,
		range = 7,
		width = 6,
		lunge = 18,
		unblockable = false,
	},
	-- The third hit is a read. Click on rhythm for a fast Light3; pause first (Combo.DelayAfter)
	-- for the delayed Overhead, which catches early deflects and hits posture harder; press E/C
	-- for a perilous morph; or press block to feint.
	Light3 = {
		windup = 0.46,
		chainWindup = 0.4,
		recovery = 0.35,
		cooldown = 0,
		damage = 11,
		postureDamage = 22,
		range = 7.5,
		width = 6,
		lunge = 22,
		unblockable = false,
		ender = true,
	},
	Overhead = {
		windup = 0.62,
		chainWindup = 0.56,
		recovery = 0.45,
		cooldown = 0,
		damage = 14,
		postureDamage = 34,
		range = 7.5,
		width = 5,
		lunge = 26,
		unblockable = false,
		ender = true,
	},

	-- Deflect, then slash within Deflect.RiposteWindow: a fast counter-cut that can't be
	-- interrupted. It is the parry's payoff, so it has to land inside the attacker's recoil
	-- even at 250 ms ping (recoil 0.5 s >= startup 0.18 s + ~0.125 s one-way + cushion).
	Riposte = {
		windup = 0.18,
		recovery = 0.3,
		cooldown = 0,
		damage = 11,
		postureDamage = 24,
		range = 7.5,
		width = 6,
		lunge = 22,
		unblockable = false,
		armorFrom = 0.18,
		riposte = true,
	},
	Perilous = {
		windup = 0.95,
		recovery = 0.55,
		cooldown = 0, -- see Cooldowns.Perilous, shared with the sweep
		damage = 18, -- ~2x a slash: strong when it lands, but a read costs far more
		postureDamage = 35,
		range = 9,
		width = 4,
		lunge = 40,
		unblockable = false, -- Sekiro lets you deflect a thrust, but not guard it
		perilous = true,
		noGuard = true,
		thrust = true,
		armorFrom = 0.3,
		cooldownGroup = "Perilous",
	},
	Sweep = {
		windup = 0.95,
		recovery = 0.6,
		cooldown = 0, -- see Cooldowns.Perilous, shared with the thrust
		damage = 16,
		postureDamage = 30,
		range = 8.5,
		width = 10,
		lunge = 12,
		unblockable = true,
		perilous = true,
		low = true,
		armorFrom = 0.3,
		cooldownGroup = "Perilous",
	},
}

local Config = {
	Attacks = attacks,

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
		-- Attack-to-attack buffer. Last input wins, and a block, dodge, deflect or stagger
		-- clears it, so a panic click can't commit you after the fight has moved on.
		Buffer = 0.3,
		DelayAfter = 0.25, -- the third slash pressed this long after Light2 ends is the Overhead
		EnderRest = 0.3, -- after an ender the next string waits this long: the defender's turn
		-- E or C during Light2's recovery or the third slash's windup morphs the ender into
		-- a perilous attack with this shorter windup. One morph or feint per string.
		MorphWindup = 0.65,
		RecoveryCancel = 0.06, -- after impact resolves, block can cancel the rest of recovery
	},

	Stamina = {
		Max = 100,
		RegenPerSecond = 30,
		RegenDelay = 0.7, -- after spending any
		GuardRegenMultiplier = 0.5, -- slower while holding guard
		-- Deflecting is free, as in Sekiro: stamina limits aggression and evasion only.
		Costs = {
			Light1 = 12,
			Light2 = 12,
			Light3 = 14,
			Overhead = 16,
			Perilous = 32, -- ~2.5x a slash
			Sweep = 32,
			Dodge = 18,
		} :: { [string]: number },
	},

	Gourd = {
		Charges = 3, -- per life
		Heal = 45,
		DrinkTime = 0.9, -- slowed and open the whole time; a hit wastes the sip
	},

	Mikiri = {
		AttackerPosture = 45,
		AttackerStagger = 0.9,
	},

	Jump = {
		EvadeWindow = 0.65, -- a sweep landing this soon after jumping misses
		KickPosture = 25, -- clearing a sweep at close range lands on their head, as in Sekiro
		KickRange = 7,
	},

	-- Spawn protection: you can't be hit and bots ignore you for this long.
	SpawnProtection = 2,

	Arena = {
		WallHalfExtent = 78, -- castle walls form a square this far from the centre
		FightRadius = 66, -- open ground inside the walls
	},

	Round = {
		Intermission = 12, -- countdown once someone is queued
		MaxDuration = 180, -- a match ends here even if several fighters remain
		Results = 7,
		MinFighters = 6, -- bots fill the match up to this many
		SpawnRadius = 48, -- fighters start evenly spaced on this circle
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

	-- Soft currency earned by playing, premium currency bought or dripped free.
	Economy = {
		StartCoins = 250,
		StartGems = 0,
		Rewards = { Kill = 15, Deathblow = 5, Win = 60, Played = 10 },
		-- Daily login streak: day N of a streak pays Daily[N] coins (gems on day 7).
		Daily = { 50, 60, 70, 80, 100, 120, 150 },
		DailyGems = 5,
	},

	Rating = {
		Start = 400,
		Division = 200, -- each tier has three divisions of this many points
		K = 24, -- rating change per decisive pairwise result
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

	Posture = {
		Max = 100,
		RegenPerSecond = 14,
		RegenDelay = 1.2, -- seconds without posture damage before regen starts
		GuardRegenMultiplier = 1.5, -- holding guard recovers posture faster, like Sekiro
		BrokenDuration = 1.6, -- the deathblow window
		ResetAfterBreak = 0.35, -- fraction of Max left when a break expires unpunished
		SurvivedDeathblowStun = 0.9, -- knocked down this long by a deathblow that didn't kill
		-- As in Sekiro, posture recovers more slowly the more vitality you've lost: at zero
		-- vitality it recovers at this fraction of the normal rate.
		VitalityRegenFloor = 0.25,
	},

	-- Sekiro's model: a press arms a deflect for `Window` seconds before impact (12 frames);
	-- each press soon after the last shrinks that window (down to MinWindow, 4 frames), and
	-- the penalty clears after SpamMemory or on a successful deflect. Pressing early still
	-- guards, so early is safe and mashing is not.
	Deflect = {
		Window = 0.2,
		MinWindow = 0.067,
		PerfectWindow = 0.09, -- the last ~5 frames before impact, judged on the defender's clock
		SpamPenaltyPerPress = 0.045,
		SpamMemory = 0.5,
		LateTolerance = 0.03, -- clock-sync slack for presses stamped just after impact
		AttackerPosture = 18,
		PerfectAttackerPosture = 30,
		DefenderPosture = 6, -- deflecting still costs a little posture; a perfect one doesn't
		ChainWindow = 1.5, -- deflects in quick succession each deal more posture damage...
		ChainBonus = 0.2,
		ChainMax = 1.6, -- ...up to +60%
		GuardPostureMultiplier = 0.7, -- holding guard is safe for a while, not forever
		FacingDot = 0.15, -- defender must roughly face the attacker to deflect or guard
		-- A deflected attacker stays open long enough for one counter-slash (windup 0.40-0.42 s
		-- plus resolve) to land, as in Sekiro; a perfect deflect leaves a bigger window.
		AttackerRecoil = 0.5,
		PerfectAttackerRecoil = 0.75,
		RiposteWindow = 0.5, -- slash this soon after a deflect for a Riposte
		-- Right after a deflect, swings from anyone *else* are auto-guarded, so a third party
		-- can't trade into your riposte.
		ThirdPartyGuard = 0.35,
	},

	Feint = {
		Cutoff = 0.12, -- a windup can't be cancelled this close to impact
		PostureCost = 6,
		StaminaCost = 8,
	},

	Dodge = {
		IFrames = 0.3,
		Cooldown = 0.9,
		Speed = 50, -- bots' sidestep speed
		-- The player's dash bursts out and eases down to walking pace, ~9.5 studs in all,
		-- instead of a constant speed and a dead stop (which reads as a teleport).
		DashStartSpeed = 78,
		DashEndSpeed = 16,
		DashDuration = 0.26,
		DashFovKick = 6, -- degrees, recovered over the dash
	},

	-- Client-side locomotion feel (see client/Movement). Speeds are studs/s.
	Movement = {
		StartFraction = 0.45, -- from standstill you start at this share of full speed...
		Acceleration = 14, -- ...and close the gap at this rate (~0.15 s to full)
		SpeedBlend = 12, -- how quickly speed follows a state change (attack, guard)
		TurnRate = 620, -- degrees/s while moving freely
		CombatTurnRate = 360, -- while swinging, guarding or broken
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

	HitStagger = 0.25, -- ends before the next chained hit lands, so strings are never true combos

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
	HitPostureMultiplier = 0.5, -- unguarded hits still build some posture
	-- A deathblow takes a big chunk, and kills outright only an already wounded fighter
	-- (Sekiro bosses carry more than one "life"): a single posture break at full vitality
	-- isn't the end of your round.
	DeathblowDamage = 65,

	WalkSpeed = 16,
	AttackWalkSpeed = 6,
	BlockWalkSpeed = 9,
	BrokenWalkSpeed = 4,
	SoftLockRange = 16,

	LockOn = {
		Range = 45, -- max distance to acquire a target
		BreakRange = 60, -- lock drops beyond this
		TurnRate = 16, -- how quickly the character turns to face its target
		CameraDistance = 9.5, -- close enough that both blades read clearly
		CameraHeight = 3.2,
		CameraShoulder = 2,
		CameraSmoothing = 10,
	},

	-- Four clearly separate feedback tiers (hitstop seconds). Hitstop only freezes the two
	-- fighters involved, on their own clients; in a free-for-all a long freeze is a liability.
	Visual = {
		PerilousColor = Color3.fromRGB(255, 40, 40),
		GuardHitstop = 0.035,
		Hitstop = 0.07, -- deflect
		PerfectHitstop = 0.105,
		DeathblowHitstop = 0.12,
		-- Clean hits, escalating through the string.
		HitHitstop = {
			Light1 = 0.045,
			Light2 = 0.055,
			Light3 = 0.08,
			Overhead = 0.11,
			Riposte = 0.08,
			Perilous = 0.13,
			Sweep = 0.13,
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
		-- Spacing: circle at StrafeDistance while waiting, step in to AttackDistance to swing.
		AttackDistance = 5,
		StrafeDistance = 8,
		SeparationRadius = 4, -- push away from other fighters closer than this
		RetreatPosture = 0.7, -- back off to recover when own posture passes this fraction
		AttackInterval = { 0.9, 2.0 },
		ComboContinueChance = 0.6, -- chance to chain each next slash
		PerilousChance = 0.15,
		PunishChance = 0.6, -- chance to counter-attack right after a perfect deflect
		-- Defense rolls, cumulative: perfect, then normal deflect, then hold guard, else eat the hit.
		-- Together these defend ~60% of swings (it was 85%): good players still need to mix
		-- up timing, but a new player's honest slashes land.
		PerfectChance = 0.08,
		DeflectChance = 0.3,
		GuardChance = 0.22,
		DodgePerilousChance = 0.5,
		MikiriChance = 0.4, -- of the dodges against a thrust, how many dash in for a Mikiri
		HealBelow = 0.4, -- sip the gourd when vitality drops under this fraction
		FeintChance = 0.2, -- when a defence roll lands mid-windup, how often to feint instead of committing
		-- Reading spam: each swing from the same attacker within StreakMemory makes the bot
		-- likelier to deflect the next one.
		StreakMemory = 1.6,
		ReadAfter = 2, -- from the second swing in a streak, the bot stops attacking and waits to deflect
		StreakDeflectBonus = 0.15,
		StreakPerfectBonus = 0.08,
		MaxDeflectChance = 0.75,
		MaxPerfectChance = 0.35,
		-- Openings: attack a target stuck in recovery, recoil or a sip.
		OpeningChance = 0.75,
		OpeningCooldown = 0.6,
	},
}

return Config
