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
	GuardImpact = {
		segments = { { pose = "GuardImpact", duration = 0.05, ease = "out" } },
		hold = 0.05,
		fadeOut = 0.15,
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

return {
	Clips = Clips,
	ImpactFraction = IMPACT_FRACTION,
}
