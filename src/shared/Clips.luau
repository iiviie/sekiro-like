--!strict
-- Timelines for the procedural animator, built from the poses in Poses.luau.
-- A segment's duration may be "windup": the animator stretches it so the strike lands on
-- the server's hitAt, however late the Windup event arrived. Segments marked `trail`
-- light up the sword trail.

export type Ease = "linear" | "in" | "out" | "inOut"

export type Segment = {
	pose: string,
	duration: number | "windup",
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
	Light1 = {
		segments = {
			{ pose = "Slash1Windup", duration = "windup", ease = "out" },
			{ pose = "Slash1Strike", duration = 0.09, ease = "in", trail = true },
			{ pose = "Slash1Follow", duration = 0.12, ease = "out", trail = true },
		},
		hold = 0.06,
		fadeOut = 0.25,
	},
	Light2 = {
		segments = {
			{ pose = "Slash2Windup", duration = "windup", ease = "out" },
			{ pose = "Slash2Strike", duration = 0.09, ease = "in", trail = true },
			{ pose = "Slash2Follow", duration = 0.12, ease = "out", trail = true },
		},
		hold = 0.06,
		fadeOut = 0.25,
	},
	Light3 = {
		segments = {
			{ pose = "Slash3Windup", duration = "windup", ease = "out" },
			{ pose = "Slash3Strike", duration = 0.1, ease = "in", trail = true },
			{ pose = "Slash3Follow", duration = 0.16, ease = "out", trail = true },
		},
		hold = 0.12,
		fadeOut = 0.3,
	},
	Perilous = {
		segments = {
			{ pose = "ThrustWindup", duration = "windup", ease = "out" },
			{ pose = "ThrustStrike", duration = 0.1, ease = "in", trail = true },
		},
		hold = 0.25,
		fadeOut = 0.3,
	},
	Sweep = {
		segments = {
			{ pose = "SweepWindup", duration = "windup", ease = "out" },
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
