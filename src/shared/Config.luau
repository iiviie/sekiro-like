--!strict
-- Every combat number lives here so feel can be tuned without touching logic.
-- Times are seconds on the shared server clock (workspace:GetServerTimeNow()).

-- Light1-3 are the slash combo; the client picks the matching clip from the kind name.
export type AttackKind = "Light1" | "Light2" | "Light3" | "Perilous"

export type AttackSpec = {
	windup: number, -- telegraph before impact; keep >= 0.3 so 200 ms ping players can still read it
	recovery: number, -- lockout after impact, on top of Net.ResolveGrace
	cooldown: number, -- min time between starts of this attack
	damage: number,
	postureDamage: number,
	range: number, -- studs in front of the attacker
	width: number,
	lunge: number, -- forward speed (studs/s) added at the strike
	unblockable: boolean, -- perilous attacks ignore deflect and guard; dodge them instead
}

local attacks: { [AttackKind]: AttackSpec } = {
	Light1 = {
		windup = 0.32,
		recovery = 0.22,
		cooldown = 0,
		damage = 9,
		postureDamage = 18,
		range = 7,
		width = 6,
		lunge = 18,
		unblockable = false,
	},
	Light2 = {
		windup = 0.3,
		recovery = 0.22,
		cooldown = 0,
		damage = 9,
		postureDamage = 18,
		range = 7,
		width = 6,
		lunge = 18,
		unblockable = false,
	},
	Light3 = {
		windup = 0.42,
		recovery = 0.4,
		cooldown = 0,
		damage = 14,
		postureDamage = 28,
		range = 7.5,
		width = 5,
		lunge = 26,
		unblockable = false,
	},
	Perilous = {
		windup = 0.7,
		recovery = 0.55,
		cooldown = 3,
		damage = 28,
		postureDamage = 35,
		range = 9,
		width = 4,
		lunge = 40,
		unblockable = true,
	},
}

local Config = {
	Attacks = attacks,

	Combo = {
		Sequence = { "Light1", "Light2", "Light3" } :: { AttackKind },
		Window = 0.5, -- after recovery ends, the next slash continues the combo for this long
		Buffer = 0.3, -- an attack pressed this close to the end of recovery fires as soon as it can
		RecoveryCancel = 0.06, -- after impact resolves, block can cancel the rest of recovery
	},

	-- Spawn protection: you can't be hit and bots ignore you for this long.
	SpawnProtection = 2,

	Posture = {
		Max = 100,
		RegenPerSecond = 14,
		RegenDelay = 1.2, -- seconds without posture damage before regen starts
		GuardRegenMultiplier = 1.5, -- holding guard recovers posture faster, like Sekiro
		BrokenDuration = 1.6, -- the deathblow window
		ResetAfterBreak = 0.35, -- fraction of Max left when a break expires unpunished
	},

	Deflect = {
		Window = 0.25, -- press block within this long before impact to deflect
		PerfectWindow = 0.1,
		LateTolerance = 0.03, -- clock-sync slack for presses stamped just after impact
		SpamLockout = 0.35, -- presses closer together than this don't re-arm the deflect
		AttackerPosture = 18,
		PerfectAttackerPosture = 32,
		DefenderPosture = 6,
		GuardPostureMultiplier = 1,
		FacingDot = 0.15, -- defender must roughly face the attacker to deflect or guard
		AttackerRecoil = 0.22, -- a deflected attacker is staggered this long...
		PerfectAttackerRecoil = 0.42, -- ...and longer after a perfect deflect, opening a punish
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
		ResolveGrace = 0.15, -- wait this long past impact for late defender packets
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
		Count = 3,
		SpawnRadius = 35,
		RespawnDelay = 4,
		AggroRange = 90,
		PlayerBias = 0.6, -- players look this much closer, so bots prefer them over each other
		ArenaRadius = 105, -- bots won't chase past this distance from the centre
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
		PunishChance = 0.7, -- chance to counter-attack right after a perfect deflect
		-- Defense rolls, cumulative: perfect, then normal deflect, then hold guard, else eat the hit.
		PerfectChance = 0.15,
		DeflectChance = 0.45,
		GuardChance = 0.25,
		DodgePerilousChance = 0.5,
	},
}

return Config
