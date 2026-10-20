--!strict
-- Every combat number lives here so feel can be tuned without touching logic.
-- Times are seconds on the shared server clock (workspace:GetServerTimeNow()).

-- Light1-3 are the slash combo; the client picks the matching clip from the kind name.
export type AttackKind = "Light1" | "Light2" | "Light3" | "Perilous" | "Sweep"

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
}

local attacks: { [AttackKind]: AttackSpec } = {
	Light1 = {
		windup = 0.42,
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
		windup = 0.40,
		recovery = 0.25,
		cooldown = 0,
		damage = 9,
		postureDamage = 18,
		range = 7,
		width = 6,
		lunge = 18,
		unblockable = false,
	},
	Light3 = {
		windup = 0.55,
		recovery = 0.45,
		cooldown = 0,
		damage = 14,
		postureDamage = 28,
		range = 7.5,
		width = 5,
		lunge = 26,
		unblockable = false,
	},
	Perilous = {
		windup = 0.95,
		recovery = 0.55,
		cooldown = 3,
		damage = 28,
		postureDamage = 35,
		range = 9,
		width = 4,
		lunge = 40,
		unblockable = false, -- Sekiro lets you deflect a thrust, but not guard it
		perilous = true,
		noGuard = true,
		thrust = true,
	},
	Sweep = {
		windup = 0.95,
		recovery = 0.6,
		cooldown = 3,
		damage = 24,
		postureDamage = 30,
		range = 8.5,
		width = 10,
		lunge = 12,
		unblockable = true,
		perilous = true,
		low = true,
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

	Combo = {
		Sequence = { "Light1", "Light2", "Light3" } :: { AttackKind },
		Window = 0.5, -- after recovery ends, the next slash continues the combo for this long
		Buffer = 0.3, -- an attack pressed this close to the end of recovery fires as soon as it can
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
			Light3 = 16,
			Perilous = 22,
			Sweep = 22,
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
		Intermission = 15,
		MaxDuration = 180, -- a match ends here even if several fighters remain
		Results = 7,
		MinFighters = 6, -- bots fill the match up to this many
		PracticeBots = 2, -- sparring partners during intermission
		SpawnRadius = 48, -- fighters start evenly spaced on this circle
		RespawnDelay = 3, -- outside a match
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
		PerfectWindow = 0.07, -- the last ~4 frames before impact
		SpamPenaltyPerPress = 0.045,
		SpamMemory = 0.5,
		LateTolerance = 0.03, -- clock-sync slack for presses stamped just after impact
		AttackerPosture = 18,
		PerfectAttackerPosture = 30,
		PerilousPostureMultiplier = 1.4, -- deflecting a perilous thrust hurts its owner more
		DefenderPosture = 6, -- deflecting still costs a little posture; a perfect one doesn't
		ChainWindow = 1.2, -- deflects in quick succession each deal more posture damage...
		ChainBonus = 0.25,
		ChainMax = 2, -- ...up to double
		GuardPostureMultiplier = 1,
		FacingDot = 0.15, -- defender must roughly face the attacker to deflect or guard
		-- A deflected attacker stays open long enough for one counter-slash (windup 0.40-0.42 s
		-- plus resolve) to land, as in Sekiro; a perfect deflect leaves a bigger window.
		AttackerRecoil = 0.5,
		PerfectAttackerRecoil = 0.75,
	},

	Feint = {
		Cutoff = 0.12, -- a windup can't be cancelled this close to impact
		PostureCost = 6,
	},

	Dodge = {
		IFrames = 0.3,
		Cooldown = 0.9,
		Speed = 50,
		DashDuration = 0.16,
	},

	Net = {
		CompensationCap = 0.25, -- how far in the past a client stamp may claim to be
		ResolveGrace = 0.12, -- wait this long past impact for late defender packets
		MaxActionsPerSecond = 20,
	},

	HitStagger = 0.3,
	HitPostureMultiplier = 0.5, -- unguarded hits still build some posture
	DeathblowDamage = 1000,

	WalkSpeed = 16,
	AttackWalkSpeed = 6,
	BlockWalkSpeed = 9,
	BrokenWalkSpeed = 4,
	SoftLockRange = 16,

	LockOn = {
		Range = 45, -- max distance to acquire a target
		BreakRange = 60, -- lock drops beyond this
		TurnRate = 16, -- how quickly the character turns to face its target
		CameraDistance = 11,
		CameraHeight = 3.2,
		CameraShoulder = 2,
		CameraSmoothing = 10,
	},

	Visual = {
		PerilousColor = Color3.fromRGB(255, 40, 40),
		Hitstop = 0.07,
		PerfectHitstop = 0.11,
		DeathblowHitstop = 0.16,
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
		AttackInterval = { 0.6, 1.6 },
		ComboContinueChance = 0.6, -- chance to chain each next slash
		PerilousChance = 0.15,
		PunishChance = 0.9, -- chance to counter-attack right after a perfect deflect
		-- Defense rolls, cumulative: perfect, then normal deflect, then hold guard, else eat the hit.
		PerfectChance = 0.15,
		DeflectChance = 0.45,
		GuardChance = 0.25,
		DodgePerilousChance = 0.5,
		MikiriChance = 0.4, -- of the dodges against a thrust, how many dash in for a Mikiri
		HealBelow = 0.4, -- sip the gourd when vitality drops under this fraction
		FeintChance = 0.2, -- when a defence roll lands mid-windup, how often to feint instead of committing
		-- Reading spam: each swing from the same attacker within StreakMemory makes the bot
		-- likelier to deflect the next one.
		StreakMemory = 1.6,
		ReadAfter = 2, -- from the second swing in a streak, the bot stops attacking and waits to deflect
		StreakDeflectBonus = 0.22,
		StreakPerfectBonus = 0.15,
		MaxDeflectChance = 0.92,
		MaxPerfectChance = 0.6,
		-- Openings: attack a target stuck in recovery, recoil or a sip.
		OpeningChance = 0.75,
		OpeningCooldown = 0.6,
	},
}

return Config
