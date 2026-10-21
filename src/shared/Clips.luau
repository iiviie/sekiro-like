--!strict
-- Timelines for the procedural animator, built from the poses in Poses.luau.
-- A segment's duration may be "windup": the animator stretches it so the strike lands on
-- the server's hitAt, however late the Windup event arrived. Several windup segments
-- split the time by `share`, which is how perilous attacks coil, hold, then snap. Segments marked `trail`
-- light up the sword trail.

export type Ease = "linear" | "in" | "out" | "inOut"

export type Segment = {
	pose: string,
	duration: number | "windup",
	share: number?, -- for "windup" segments: this segment's fraction of the windup time
	ease: Ease?,
	trail: boolean?,
}

export type Clip = {
	segments: { Segment },
	hold: number?, -- seconds to hold the last pose
	fadeOut: number?, -- seconds to blend back to the base stance
	twoHanded: boolean?, -- the left hand stays IK-locked to the hilt throughout
	baked: boolean?, -- sampled from Blender: the windup segments end where the hit collider turns on
	-- Baked clips only: how far past the end of the windup segments the blade is mid-cut. The
	-- server's hit is instant at hitAt, but Kannagi's collider is live for a whole active window,
	-- so the clip is shifted to put the middle of that window on hitAt.
	impactLead: number?,
	-- Seconds the clip holds its first frame while blending in (Kannagi's PauseBlendIn), before
	-- the rest of the windup plays; Animator.play's `freeze` argument overrides it.
	freeze: number?,
}

-- How far into the strike segment the blade actually connects.
local IMPACT_FRACTION = 0.6

local Clips: { [string]: Clip } = {
	-- Cock fast (~a third of the windup), hold the coil (the readable telegraph), strike in
	-- ~70 ms, then hold the extended follow-through ~0.22 s before settling back.
	Light1 = {
		segments = {
			{ pose = "Slash1Windup", duration = "windup", share = 0.32, ease = "out" },
			{ pose = "Slash1Coil", duration = "windup", share = 0.68, ease = "inOut" },
			{ pose = "Slash1Strike", duration = 0.07, ease = "in", trail = true },
			{ pose = "Slash1Follow", duration = 0.09, ease = "out", trail = true },
		},
		hold = 0.22,
		fadeOut = 0.3,
	},
	Light2 = {
		segments = {
			{ pose = "Slash2Windup", duration = "windup", share = 0.32, ease = "out" },
			{ pose = "Slash2Coil", duration = "windup", share = 0.68, ease = "inOut" },
			{ pose = "Slash2Strike", duration = 0.07, ease = "in", trail = true },
			{ pose = "Slash2Follow", duration = 0.09, ease = "out", trail = true },
		},
		hold = 0.22,
		fadeOut = 0.3,
	},
	-- The on-rhythm third slash: snaps overhead and drives down into a deep lunge.
	Light3 = {
		segments = {
			{ pose = "Slash3Windup", duration = "windup", share = 0.35, ease = "out" },
			{ pose = "Slash3Hold", duration = "windup", share = 0.65, ease = "inOut" },
			{ pose = "Slash3Strike", duration = 0.08, ease = "in", trail = true },
			{ pose = "Slash3Follow", duration = 0.12, ease = "out", trail = true },
		},
		hold = 0.26,
		fadeOut = 0.34,
	},
	-- Held back a beat: the delayed overhead, a longer coil at the top.
	Overhead = {
		segments = {
			{ pose = "Slash3Windup", duration = "windup", share = 0.25, ease = "out" },
			{ pose = "Slash3Hold", duration = "windup", share = 0.75, ease = "inOut" },
			{ pose = "Slash3Strike", duration = 0.08, ease = "in", trail = true },
			{ pose = "Slash3Follow", duration = 0.12, ease = "out", trail = true },
		},
		hold = 0.3,
		fadeOut = 0.34,
	},
	-- The counter-cut out of a deflect: Light2's arc, snapped out fast.
	Riposte = {
		segments = {
			{ pose = "Slash2Coil", duration = "windup", ease = "out" },
			{ pose = "Slash2Strike", duration = 0.06, ease = "in", trail = true },
			{ pose = "Slash2Follow", duration = 0.08, ease = "out", trail = true },
		},
		hold = 0.2,
		fadeOut = 0.28,
	},
	Perilous = {
		segments = {
			{ pose = "ThrustWindup", duration = "windup", share = 0.5, ease = "out" },
			{ pose = "ThrustHold", duration = "windup", share = 0.5, ease = "inOut" },
			{ pose = "ThrustStrike", duration = 0.1, ease = "in", trail = true },
		},
		hold = 0.25,
		fadeOut = 0.3,
	},
	Sweep = {
		segments = {
			{ pose = "SweepWindup", duration = "windup", share = 0.5, ease = "out" },
			{ pose = "SweepHold", duration = "windup", share = 0.5, ease = "inOut" },
			{ pose = "SweepStrike", duration = 0.1, ease = "in", trail = true },
		},
		hold = 0.25,
		fadeOut = 0.3,
	},
	Drink = {
		segments = { { pose = "Drink", duration = 0.15, ease = "out" } },
		hold = 0.7,
		fadeOut = 0.25,
	},
	Mikiri = {
		segments = { { pose = "MikiriStomp", duration = 0.08, ease = "out" } },
		hold = 0.45,
		fadeOut = 0.3,
	},
	Recoil = {
		segments = { { pose = "Recoil", duration = 0.08, ease = "out" } },
		hold = 0.22,
		fadeOut = 0.3,
	},
	HitReact = {
		segments = { { pose = "HitReact", duration = 0.06, ease = "out" } },
		hold = 0.12,
		fadeOut = 0.25,
	},
	-- Flinches by the attack's reaction size (Config.HitStun 0.2 / 0.3 / 0.45 / 0.4 s): they
	-- snap in at once (Kannagi blends reactions in over 0-0.02 s) and hold for the stun.
	HitSmall = {
		segments = { { pose = "HitReact", duration = 0.03, ease = "out" } },
		hold = 0.12,
		fadeOut = 0.2,
	},
	HitMiddle = {
		segments = { { pose = "HitMiddle", duration = 0.03, ease = "out" } },
		hold = 0.2,
		fadeOut = 0.25,
	},
	HitLarge = {
		segments = { { pose = "HitLarge", duration = 0.03, ease = "out" } },
		hold = 0.32,
		fadeOut = 0.3,
	},
	HitGedan = {
		segments = { { pose = "HitGedan", duration = 0.04, ease = "out" } },
		hold = 0.28,
		fadeOut = 0.3,
	},
	GuardImpact = {
		segments = { { pose = "GuardImpact", duration = 0.05, ease = "out" } },
		hold = 0.05,
		fadeOut = 0.15,
	},
	-- Guard hits by size (GuardReaction); the large one lingers (Kannagi plays it at 0.7x).
	GuardSmall = {
		segments = { { pose = "GuardImpact", duration = 0.03, ease = "out" } },
		hold = 0.05,
		fadeOut = 0.15,
	},
	GuardMiddle = {
		segments = { { pose = "GuardImpact", duration = 0.03, ease = "out" } },
		hold = 0.1,
		fadeOut = 0.2,
	},
	GuardLarge = {
		segments = { { pose = "GuardImpactLarge", duration = 0.03, ease = "out" } },
		hold = 0.18,
		fadeOut = 0.3,
	},
	-- The defender's deflect, thrown to the side the blade came from (AttackSpec.deflectSide).
	DeflectRight = {
		segments = { { pose = "DeflectRight", duration = 0.02, ease = "out" } },
		hold = 0.08,
		fadeOut = 0.25,
	},
	DeflectLeft = {
		segments = { { pose = "DeflectLeft", duration = 0.02, ease = "out" } },
		hold = 0.08,
		fadeOut = 0.25,
	},
	DeflectBack = {
		segments = { { pose = "DeflectBack", duration = 0.02, ease = "out" } },
		hold = 0.12,
		fadeOut = 0.35,
	},
	-- A deflected opener: the blade is knocked aside for a beat and the string goes on.
	Knocked = {
		segments = { { pose = "Knocked", duration = 0.04, ease = "out" } },
		hold = 0.06,
		fadeOut = 0.12,
	},
	Deathblow = {
		segments = {
			{ pose = "DeathblowWindup", duration = 0.16, ease = "out" },
			{ pose = "DeathblowStrike", duration = 0.1, ease = "in", trail = true },
		},
		hold = 0.5,
		fadeOut = 0.4,
	},
	Dash = {
		segments = { { pose = "Dash", duration = 0.06, ease = "out" } },
		hold = 0.14,
		fadeOut = 0.2,
	},
	Executed = {
		segments = { { pose = "Executed", duration = 0.45, ease = "out" } },
		hold = 30,
		fadeOut = 0.1,
	},
}

-- Sword clips keyed in Blender and sampled at 30 fps (art/anim/katana.blend) replace the
-- hand-written ones of the same name.
for name, clip in require(script.Parent.BakedClips) do
	clip.baked = true
	Clips[name] = clip
end

-- The counter-string moves reuse the sword clips until they get their own: the second
-- counter cut swings Light1's arc (the Riposte swings Light2's), the dodge attack is the
-- thrust, and the Mikiri follow-up is the overhead cut down onto the pinned blade.
-- How far past the end of the windup segments the blade meets a standing target (tip 3+ studs
-- ahead at body height), so that moment lands on hitAt. Measured in Studio's Edit datamodel (QA,
-- the same sampler as ~/re/kannagi-usagi/scripts/anim/boss_leads.luau): with no lead the cuts
-- arrived 30-45 ms after the hit (Light3 and Sweep 10-15, Overhead and the thrust on time or
-- early); these put every one 0-15 ms after it. (The earlier "half the active window" values,
-- 0.03-0.08, were compensating for Animator's old 20 ms floor per windup segment, which stretched
-- dense bakes past the hit.)
local IMPACT_LEAD: { [string]: number } = {
	Light1 = 0.025,
	Light2 = 0.02,
	Light3 = 0,
	Overhead = 0,
	Riposte = 0.025,
	Riposte2 = 0.03,
	DodgeSlash = 0.035,
	MikiriSlash = 0.035,
	Perilous = 0,
	Sweep = 0,
}
for name, lead in IMPACT_LEAD do
	local clip = Clips[name]
	if clip and clip.baked and clip.impactLead == nil then
		clip.impactLead = lead
	end
end

local ALIASES = { Riposte2 = "Light1", DodgeSlash = "Perilous", MikiriSlash = "Overhead" }
for name, source in ALIASES do
	if not Clips[name] then
		Clips[name] = Clips[source]
	end
end

-- Stances held with both hands on the hilt (the left hand is IK-locked to it).
local TwoHandedStances = { Ready = true, Guard = true, GuardImpact = true }

return {
	Clips = Clips,
	ImpactFraction = IMPACT_FRACTION,
	TwoHandedStances = TwoHandedStances,
}
