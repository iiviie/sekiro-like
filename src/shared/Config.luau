--!strict
-- Every combat number lives here so feel can be tuned without touching logic.
-- Times are seconds on the shared server clock (workspace:GetServerTimeNow()).

export type AttackKind = "Light" | "Perilous"

export type AttackSpec = {
	windup: number, -- telegraph before impact; keep >= 0.3 so 200 ms ping players can still read it
	recovery: number, -- lockout after impact, on top of Net.ResolveGrace
	cooldown: number, -- min time between starts of this attack
	damage: number,
	postureDamage: number,
	range: number, -- studs in front of the attacker
	width: number,
	unblockable: boolean, -- perilous attacks ignore deflect and guard; dodge them instead
}

local attacks: { [AttackKind]: AttackSpec } = {
	Light = {
		windup = 0.35,
		recovery = 0.25,
		cooldown = 0.45,
		damage = 10,
		postureDamage = 20,
		range = 7,
		width = 6,
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
		unblockable = true,
	},
}

local Config = {
	Attacks = attacks,

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

	Visual = {
		StrikeTime = 0.08,
		StrikeHold = 0.12,
		SwordColor = Color3.fromRGB(200, 205, 212),
		WindupColor = Color3.fromRGB(255, 170, 60),
		PerilousColor = Color3.fromRGB(255, 40, 40),
	},

	Bots = {
		Count = 3,
		SpawnRadius = 35,
		RespawnDelay = 4,
		AggroRange = 90,
		PlayerBias = 0.6, -- players look this much closer, so bots prefer them over each other
		EngageDistance = 5.5,
		ThinkInterval = 0.1,
		AttackInterval = { 0.7, 1.8 },
		PerilousChance = 0.15,
		-- Defense rolls, cumulative: perfect, then normal deflect, then hold guard, else eat the hit.
		PerfectChance = 0.15,
		DeflectChance = 0.45,
		GuardChance = 0.25,
		DodgePerilousChance = 0.5,
	},
}

return Config
