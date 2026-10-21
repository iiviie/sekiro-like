--!strict
-- Hand-authored body poses for the procedural animator (client/Animator), compiled to
-- joint Transforms at load.
--
-- Arms are written as directions in upper-torso space (X right, Y up, Z back, so
-- forward is -Z): where the upper arm points, where the forearm points, and for the
-- sword arm where the blade points and which way its cutting edge faces. The solver
-- below turns those into shoulder, elbow and wrist rotations. Torso, neck, root and
-- legs use plain angles { rx, ry, rz, px?, py?, pz? } in degrees and studs: +X pitches
-- a joint's child forward-up for limbs and back for the torso, +Y on the Waist turns
-- the right shoulder forward. Joints a pose leaves out keep the locomotion animation.

type Arm = { upper: Vector3, fore: Vector3, blade: Vector3?, edge: Vector3? }
type PoseSpec = {
	RightArm: Arm?,
	LeftArm: Arm?,
	[string]: any, -- joint name -> { rx, ry, rz, px?, py?, pz? }
}
export type Pose = { [string]: CFrame }

local DOWN = Vector3.new(0, -1, 0)

local function v(x: number, y: number, z: number): Vector3
	return Vector3.new(x, y, z).Unit
end

-- Smallest rotation taking direction `from` onto `to`.
local function between(from: Vector3, to: Vector3): CFrame
	from, to = from.Unit, to.Unit
	local dot = math.clamp(from:Dot(to), -1, 1)
	local axis = from:Cross(to)
	if axis.Magnitude < 1e-6 then
		if dot > 0 then
			return CFrame.identity
		end
		local helper = if math.abs(from.X) < 0.9 then Vector3.xAxis else Vector3.zAxis
		return CFrame.fromAxisAngle(from:Cross(helper).Unit, math.pi)
	end
	return CFrame.fromAxisAngle(axis.Unit, math.acos(dot))
end

-- Shoulder, elbow and wrist Transforms that put the arm (and blade) along the given directions.
-- The grip holds the blade along the hand's -Z with the edge toward the hand's -Y.
local function solveArm(arm: Arm): (CFrame, CFrame, CFrame)
	local shoulder = between(DOWN, arm.upper)
	local elbow = between(DOWN, shoulder:VectorToObjectSpace(arm.fore))
	local wrist = CFrame.identity
	local blade = arm.blade
	if blade then
		local back = -blade.Unit
		local edge = arm.edge or DOWN
		local up = -(edge - back * edge:Dot(back))
		if up.Magnitude < 1e-3 then
			up = Vector3.yAxis - back * back.Y
		end
		up = up.Unit
		local right = up:Cross(back).Unit
		local hand = CFrame.fromMatrix(Vector3.zero, right, back:Cross(right), back)
		wrist = (shoulder * elbow):Inverse() * hand
	end
	return shoulder, elbow, wrist
end

local function compile(spec: PoseSpec): Pose
	local pose: Pose = {}
	for key, value in spec do
		if key == "RightArm" or key == "LeftArm" then
			local side = if key == "RightArm" then "Right" else "Left"
			local shoulder, elbow, wrist = solveArm(value)
			pose[side .. "Shoulder"] = shoulder
			pose[side .. "Elbow"] = elbow
			if value.blade then
				pose[side .. "Wrist"] = wrist
			end
		else
			local rad = math.rad
			pose[key] = CFrame.new(value[4] or 0, value[5] or 0, value[6] or 0)
				* CFrame.Angles(rad(value[1]), rad(value[2]), rad(value[3]))
		end
	end
	return pose
end

local specs: { [string]: PoseSpec } = {
	-- Out of combat: the sword carried low at the right side, tip forward and down, so the
	-- walk reads upright and natural. Only the sword arm is posed; the left arm swings
	-- with the locomotion animation.
	Relaxed = {
		RightArm = { upper = v(0.12, -1, 0.05), fore = v(0.05, -0.75, -0.65), blade = v(0.12, -0.4, -1), edge = DOWN },
	},

	-- In combat: a low guard, blade forward toward the opponent, edge down; both hands near
	-- the hilt, torso square (not twisted) so the stance stays upright.
	Ready = {
		RightArm = { upper = v(0.2, -0.9, -0.35), fore = v(0.05, -0.35, -1), blade = v(-0.2, 0.3, -1), edge = DOWN },
		LeftArm = { upper = v(-0.15, -1, -0.2), fore = v(0.15, -0.6, -0.8) },
		Waist = { 0, 6, 0 },
	},

	-- Blade raised across the body, edge out, to catch strikes.
	Guard = {
		RightArm = {
			upper = v(0.35, -0.6, -0.7),
			fore = v(-0.4, 0.45, -0.8),
			blade = v(-0.85, 0.5, -0.1),
			edge = v(0, 0, -1),
		},
		LeftArm = { upper = v(-0.35, -0.5, -0.8), fore = v(0.45, 0.6, -0.6) },
		Waist = { 4, -10, 0 },
		Neck = { -4, 8, 0 },
	},
	GuardImpact = {
		RightArm = {
			upper = v(0.35, -0.7, -0.5),
			fore = v(-0.4, 0.5, -0.6),
			blade = v(-0.85, 0.55, 0.1),
			edge = v(0, 0, -1),
		},
		LeftArm = { upper = v(-0.35, -0.6, -0.6), fore = v(0.45, 0.6, -0.4) },
		Waist = { 12, -14, 0 },
		Neck = { 6, 8, 0 },
		Root = { 4, 0, 0, 0, -0.1, 0 },
	},

	-- Swings are built like Dueling Grounds' (frame-counted from a 60 fps recording): a fast
	-- snap into a cocked pose, a held coil that reads as the telegraph, an explosive strike,
	-- and a long, fully extended follow-through. The whole body drives each cut: the torso
	-- and hips twist, the front foot steps in and the stance drops into a lunge.

	-- Light 1: diagonal kesa cut from over the right shoulder down and across to the left.
	Slash1Windup = {
		RightArm = {
			upper = v(0.85, 0.35, 0.3),
			fore = v(-0.25, 0.85, 0.2),
			blade = v(0.3, 0.55, 0.78),
			edge = v(-0.3, 0.3, -1),
		},
		LeftArm = { upper = v(-0.2, -0.75, -0.6), fore = v(0.45, -0.2, -0.85) },
		Waist = { -4, -42, 0 },
		Neck = { 0, 34, 0 },
		Root = { 0, -18, 0, 0, -0.35, 0 },
		RightHip = { -10, 0, 0 },
		RightKnee = { -24, 0, 0 },
		LeftHip = { 26, 0, 0 },
		LeftKnee = { -38, 0, 0 },
	},

	Slash1Coil = {
		RightArm = {
			upper = v(0.8, 0.45, 0.4),
			fore = v(-0.3, 0.8, 0.35),
			blade = v(0.25, 0.4, 0.88),
			edge = v(-0.3, 0.3, -1),
		},
		LeftArm = { upper = v(-0.15, -0.7, -0.7), fore = v(0.5, -0.15, -0.85) },
		Waist = { -6, -54, 0 },
		Neck = { 0, 44, 0 },
		Root = { 2, -24, 0, 0, -0.5, 0 },
		RightHip = { -14, 0, 0 },
		RightKnee = { -30, 0, 0 },
		LeftHip = { 32, 0, 0 },
		LeftKnee = { -48, 0, 0 },
	},

	Slash1Strike = {
		RightArm = {
			upper = v(0.05, 0, -1),
			fore = v(-0.4, -0.1, -0.9),
			blade = v(-0.75, -0.25, -0.6),
			edge = v(-0.5, -0.8, 0.2),
		},
		LeftArm = { upper = v(-0.35, -0.8, 0.35), fore = v(-0.25, -0.55, 0.75) },
		Waist = { -12, 34, 0 },
		Neck = { 4, -26, 0 },
		Root = { -8, 20, 0, 0, -0.55, 0 },
		RightHip = { 40, 0, 0 },
		RightKnee = { -46, 0, 0 },
		LeftHip = { -28, 0, 0 },
		LeftKnee = { -22, 0, 0 },
	},

	-- Held: arm fully extended across the body, blade carried on around to the left.
	Slash1Follow = {
		RightArm = {
			upper = v(-0.55, -0.05, -0.83),
			fore = v(-0.85, -0.05, -0.52),
			blade = v(-0.88, -0.2, -0.42),
			edge = v(-0.2, -0.6, 0.8),
		},
		LeftArm = { upper = v(-0.4, -0.8, 0.45), fore = v(-0.2, -0.55, 0.8) },
		Waist = { -10, 40, 0 },
		Neck = { 4, -32, 0 },
		Root = { -8, 22, 0, 0, -0.6, 0 },
		RightHip = { 44, 0, 0 },
		RightKnee = { -50, 0, 0 },
		LeftHip = { -32, 0, 0 },
		LeftKnee = { -24, 0, 0 },
	},

	-- Light 2: rising backhand from the lower left up and out to the upper right.
	Slash2Windup = {
		RightArm = {
			upper = v(-0.4, -0.7, -0.6),
			fore = v(-0.95, -0.2, 0.2),
			blade = v(-0.4, -0.45, 0.8),
			edge = v(0.2, 0.7, -0.6),
		},
		LeftArm = { upper = v(-0.3, -0.8, 0.4), fore = v(-0.2, -0.5, 0.8) },
		Waist = { -4, 46, 0 },
		Neck = { 0, -34, 0 },
		Root = { 0, 14, 0, 0, -0.25, 0 },
		RightHip = { 14, 0, 0 },
		RightKnee = { -24, 0, 0 },
		LeftHip = { 0, 0, 0 },
		LeftKnee = { -16, 0, 0 },
	},
	Slash2Coil = {
		RightArm = {
			upper = v(-0.45, -0.72, -0.5),
			fore = v(-0.95, -0.25, 0.3),
			blade = v(-0.3, -0.5, 0.85),
			edge = v(0.2, 0.7, -0.6),
		},
		LeftArm = { upper = v(-0.3, -0.8, 0.45), fore = v(-0.2, -0.5, 0.85) },
		Waist = { -6, 56, 0 },
		Neck = { 0, -42, 0 },
		Root = { 2, 20, 0, 0, -0.35, 0 },
		RightHip = { 18, 0, 0 },
		RightKnee = { -30, 0, 0 },
		LeftHip = { 2, 0, 0 },
		LeftKnee = { -22, 0, 0 },
	},
	Slash2Strike = {
		RightArm = {
			upper = v(0.3, 0.1, -1),
			fore = v(0.5, 0.45, -0.8),
			blade = v(0.6, 0.5, -0.65),
			edge = v(0.5, 0.7, 0.3),
		},
		LeftArm = { upper = v(-0.4, -0.8, 0.2), fore = v(-0.3, -0.6, 0.5) },
		Waist = { -4, -22, 0 },
		Neck = { 0, 16, 0 },
		Root = { -4, -12, 0, 0, -0.3, 0 },
		RightHip = { -16, 0, 0 },
		RightKnee = { -16, 0, 0 },
		LeftHip = { 30, 0, 0 },
		LeftKnee = { -36, 0, 0 },
	},
	Slash2Follow = {
		RightArm = {
			upper = v(0.75, 0.35, -0.55),
			fore = v(0.65, 0.55, -0.52),
			blade = v(0.55, 0.62, -0.55),
			edge = v(0.2, 0.9, 0.3),
		},
		LeftArm = { upper = v(-0.45, -0.8, 0.1), fore = v(-0.3, -0.6, 0.4) },
		Waist = { 2, -34, 0 },
		Neck = { 0, 26, 0 },
		Root = { -4, -18, 0, 0, -0.45, 0 },
		RightHip = { -20, 0, 0 },
		RightKnee = { -18, 0, 0 },
		LeftHip = { 38, 0, 0 },
		LeftKnee = { -46, 0, 0 },
	},

	-- Light 3: two-handed overhead finisher, driven down into a deep lunge.
	Slash3Windup = {
		RightArm = {
			upper = v(0.25, 0.95, -0.05),
			fore = v(-0.05, 0.55, 0.85),
			blade = v(-0.05, 0.25, 1),
			edge = v(0, 1, 0),
		},
		LeftArm = { upper = v(-0.25, 0.95, -0.05), fore = v(0.3, 0.55, 0.8) },
		Waist = { 16, 0, 0 },
		Neck = { -12, 0, 0 },
		Root = { 6, 0, 0, 0, 0.05, 0 },
		RightHip = { 4, 0, 0 },
		RightKnee = { -10, 0, 0 },
		LeftHip = { 10, 0, 0 },
		LeftKnee = { -18, 0, 0 },
	},
	Slash3Strike = {
		RightArm = {
			upper = v(0.1, -0.15, -1),
			fore = v(0.05, -0.35, -1),
			blade = v(0, -0.5, -0.9),
			edge = v(0, -1, 0.4),
		},
		LeftArm = { upper = v(-0.15, -0.15, -1), fore = v(0.2, -0.35, -1) },
		Waist = { -24, 0, 0 },
		Neck = { 16, 0, 0 },
		Root = { -10, 0, 0, 0, -0.55, 0 },
		RightHip = { 46, 0, 0 },
		RightKnee = { -60, 0, 0 },
		LeftHip = { -26, 0, 0 },
		LeftKnee = { -34, 0, 0 },
	},
	Slash3Follow = {
		RightArm = {
			upper = v(0.1, -0.6, -0.8),
			fore = v(0, -0.7, -0.7),
			blade = v(0, -0.62, -0.78),
			edge = v(0, -0.3, 1),
		},
		LeftArm = { upper = v(-0.15, -0.6, -0.8), fore = v(0.15, -0.8, -0.6) },
		Waist = { -30, 0, 0 },
		Neck = { 20, 0, 0 },
		Root = { -12, 0, 0, 0, -0.7, 0 },
		RightHip = { 52, 0, 0 },
		RightKnee = { -70, 0, 0 },
		LeftHip = { -28, 0, 0 },
		LeftKnee = { -40, 0, 0 },
	},

	-- Perilous thrust: drawn back at the hip with the off hand aiming, then driven forward.
	ThrustWindup = {
		RightArm = { upper = v(0.3, -0.5, 0.8), fore = v(0, 0.05, -1), blade = v(-0.05, 0.05, -1), edge = DOWN },
		LeftArm = { upper = v(-0.1, 0, -1), fore = v(0, 0.1, -1) },
		Waist = { 4, -38, 0 },
		Neck = { 0, 32, 0 },
		Root = { 4, 0, 0, 0, -0.25, 0 },
	},
	ThrustStrike = {
		RightArm = { upper = v(0, 0.05, -1), fore = v(0, 0.05, -1), blade = v(0, 0, -1), edge = DOWN },
		LeftArm = { upper = v(-0.4, -0.6, 0.6), fore = v(-0.2, -0.5, 0.4) },
		Waist = { -12, 30, 0 },
		Neck = { 8, -26, 0 },
		Root = { -14, 0, 0, 0, -0.45, 0 },
	},

	-- Hold beats: a deeper coil at the end of a windup, so the strike visibly loads
	-- before it fires (the delayed timing Sekiro uses to bait early deflects).
	Slash3Hold = {
		RightArm = {
			upper = v(0.2, 0.98, 0.05),
			fore = v(-0.05, 0.4, 0.92),
			blade = v(-0.05, 0.05, 1),
			edge = v(0, 1, 0),
		},
		LeftArm = { upper = v(-0.2, 0.98, 0.05), fore = v(0.3, 0.4, 0.86) },
		Waist = { 22, 0, 0 },
		Neck = { -16, 0, 0 },
		Root = { 9, 0, 0, 0, 0.05, 0 },
		RightHip = { 4, 0, 0 },
		RightKnee = { -12, 0, 0 },
		LeftHip = { 12, 0, 0 },
		LeftKnee = { -22, 0, 0 },
	},
	ThrustHold = {
		RightArm = { upper = v(0.35, -0.45, 0.85), fore = v(0, 0.05, -1), blade = v(-0.05, 0.05, -1), edge = DOWN },
		LeftArm = { upper = v(-0.1, 0.05, -1), fore = v(0, 0.12, -1) },
		Waist = { 6, -48, 0 },
		Neck = { 0, 40, 0 },
		Root = { 6, 0, 0, 0, -0.4, 0 },
		RightHip = { 30, 0, 0 },
		RightKnee = { -45, 0, 0 },
		LeftHip = { -15, 0, 0 },
		LeftKnee = { -20, 0, 0 },
	},
	SweepHold = {
		RightArm = {
			upper = v(0.55, -0.55, 0.65),
			fore = v(0.35, -0.3, 0.9),
			blade = v(0.45, -0.35, 0.82),
			edge = v(-0.5, 0, -0.8),
		},
		LeftArm = { upper = v(-0.25, -0.35, -0.9), fore = v(0, -0.15, -1) },
		Waist = { 6, -44, 0 },
		Neck = { -8, 36, 0 },
		Root = { -12, 0, 0, 0, -1.05, 0 },
		RightHip = { 58, 0, 0 },
		RightKnee = { -92, 0, 0 },
		LeftHip = { 24, 0, 0 },
		LeftKnee = { -68, 0, 0 },
	},

	-- Perilous sweep: crouched low with the blade drawn back, then a flat cut at the ankles.
	SweepWindup = {
		RightArm = {
			upper = v(0.5, -0.6, 0.6),
			fore = v(0.3, -0.3, 0.9),
			blade = v(0.4, -0.35, 0.85),
			edge = v(-0.5, 0, -0.8),
		},
		LeftArm = { upper = v(-0.2, -0.4, -0.9), fore = v(0, -0.2, -1) },
		Waist = { 4, -35, 0 },
		Neck = { -8, 28, 0 },
		Root = { -10, 0, 0, 0, -0.9, 0 },
		RightHip = { 50, 0, 0 },
		RightKnee = { -80, 0, 0 },
		LeftHip = { 20, 0, 0 },
		LeftKnee = { -60, 0, 0 },
	},
	SweepStrike = {
		RightArm = {
			upper = v(-0.1, -0.5, -0.85),
			fore = v(-0.5, -0.4, -0.75),
			blade = v(-0.85, -0.3, -0.4),
			edge = v(-0.4, -0.1, 0.9),
		},
		LeftArm = { upper = v(-0.4, -0.6, 0.6), fore = v(-0.3, -0.5, 0.5) },
		Waist = { -10, 35, 0 },
		Neck = { 6, -28, 0 },
		Root = { -10, 0, 0, 0, -0.9, 0 },
		RightHip = { 50, 0, 0 },
		RightKnee = { -80, 0, 0 },
		LeftHip = { 20, 0, 0 },
		LeftKnee = { -60, 0, 0 },
	},

	-- A sip from the healing gourd: sword lowered, off hand raised to the mouth, head back.
	Drink = {
		RightArm = { upper = v(0.2, -0.95, 0.1), fore = v(0.1, -0.9, -0.3), blade = v(0.15, -0.7, -0.7), edge = DOWN },
		LeftArm = { upper = v(-0.25, -0.2, -0.95), fore = v(0.45, 0.85, -0.2) },
		Waist = { 6, 0, 0 },
		Neck = { 22, 0, 0 },
	},

	-- Mikiri Counter: stamping the thrusting blade into the ground.
	MikiriStomp = {
		RightArm = { upper = v(0.3, -0.7, 0.6), fore = v(0.2, -0.6, 0.75), blade = v(0.2, -0.3, 1), edge = DOWN },
		LeftArm = { upper = v(-0.7, -0.3, -0.6), fore = v(-0.5, 0, -0.85) },
		Waist = { -15, 0, 0 },
		Neck = { 12, 0, 0 },
		Root = { -6, 0, 0, 0, -0.3, 0 },
		RightHip = { 70, 0, 0 },
		RightKnee = { -20, 0, 0 },
		LeftHip = { -10, 0, 0 },
		LeftKnee = { -25, 0, 0 },
	},

	-- Thrown back and open after being deflected.
	Recoil = {
		RightArm = { upper = v(0.6, 0.7, 0.4), fore = v(0.3, 0.8, 0.5), blade = v(0.4, 0.6, 0.7), edge = v(0, 1, 0) },
		LeftArm = { upper = v(-0.7, -0.4, -0.4), fore = v(-0.5, -0.2, -0.8) },
		Waist = { 18, -20, 0 },
		Neck = { 14, 10, 0 },
		Root = { 8, 0, 0 },
	},

	HitReact = {
		RightArm = { upper = v(0.55, -0.6, 0.45), fore = v(0.4, -0.5, -0.3), blade = v(0.3, -0.6, -0.7), edge = DOWN },
		LeftArm = { upper = v(-0.6, -0.55, 0.35), fore = v(-0.5, -0.3, -0.3) },
		Waist = { 20, -12, 0 },
		Neck = { 24, 0, 0 },
	},

	-- Posture broken: hunched, sword arm limp, knees buckling.
	Broken = {
		RightArm = { upper = v(0.2, -0.95, 0.1), fore = v(0.05, -0.9, -0.35), blade = v(0.1, -0.8, -0.6), edge = DOWN },
		LeftArm = { upper = v(-0.2, -0.95, 0.05), fore = v(-0.05, -0.9, -0.3) },
		Waist = { -28, 0, 0 },
		Neck = { -25, 0, 0 },
		Root = { -12, 0, 0, 0, -0.7, 0 },
		RightHip = { 35, 0, 0 },
		RightKnee = { -55, 0, 0 },
		LeftHip = { 25, 0, 0 },
		LeftKnee = { -50, 0, 0 },
	},

	-- Deathblow: drawn back high, then driven into the broken opponent's chest.
	DeathblowWindup = {
		RightArm = { upper = v(0.4, 0.6, 0.7), fore = v(0, 0.2, -1), blade = v(0, -0.4, -1), edge = DOWN },
		LeftArm = { upper = v(-0.2, 0.3, 0.6), fore = v(0.3, 0.3, -0.9) },
		Waist = { 10, -20, 0 },
		Neck = { 0, 15, 0 },
		Root = { 4, 0, 0 },
	},
	DeathblowStrike = {
		RightArm = { upper = v(0, -0.2, -1), fore = v(0, -0.25, -1), blade = v(0, -0.3, -1), edge = DOWN },
		LeftArm = { upper = v(-0.1, -0.2, -1), fore = v(0.2, -0.25, -1) },
		Waist = { -25, 10, 0 },
		Neck = { 18, -5, 0 },
		Root = { -12, 0, 0, 0, -0.5, 0 },
		RightHip = { 30, 0, 0 },
		RightKnee = { -40, 0, 0 },
		LeftHip = { -10, 0, 0 },
		LeftKnee = { -30, 0, 0 },
	},

	-- Killed: sinks to the knees, arms limp, before the body falls.
	Executed = {
		RightArm = { upper = v(0.15, -1, 0.2), fore = v(0.1, -1, 0.3), blade = v(0.1, -0.9, 0.4), edge = v(0, 0, 1) },
		LeftArm = { upper = v(-0.15, -1, 0.2), fore = v(-0.1, -1, 0.3) },
		Waist = { -20, 0, 0 },
		Neck = { -30, 0, 0 },
		Root = { 0, 0, 0, 0, -1.6, 0 },
		RightHip = { 90, 0, 0 },
		RightKnee = { -90, 0, 0 },
		LeftHip = { 90, 0, 0 },
		LeftKnee = { -90, 0, 0 },
	},

	-- Dodge dash: low forward lean, blade trailing behind.
	Dash = {
		RightArm = { upper = v(0.35, -0.6, 0.7), fore = v(0.1, -0.5, 0.85), blade = v(0.1, -0.25, 1), edge = DOWN },
		LeftArm = { upper = v(-0.35, -0.55, 0.7), fore = v(-0.1, -0.5, 0.85) },
		Waist = { -24, 0, 0 },
		Neck = { 18, 0, 0 },
		Root = { -16, 0, 0, 0, -0.45, 0 },
		RightHip = { 45, 0, 0 },
		RightKnee = { -60, 0, 0 },
		LeftHip = { -25, 0, 0 },
		LeftKnee = { -35, 0, 0 },
	},
}

local Poses: { [string]: Pose } = {}
for name, spec in specs do
	Poses[name] = compile(spec)
end
-- Poses keyed in Blender (art/anim) and exported as joint Transforms override the
-- hand-written ones of the same name.
for name, pose in require(script.Parent.BakedPoses) do
	Poses[name] = pose
end

-- Reaction poses by weight (Kannagi's Damage01-04, GuardSuccess01-03, Hajiki Right / Left /
-- Back), composed from the poses above until authored ones arrive. `variant` adds extra
-- joint rotations (degrees) and offsets (studs) on top of a pose; `mix` blends two poses.
local function extra(value: { number }): CFrame
	local rad = math.rad
	return CFrame.new(value[4] or 0, value[5] or 0, value[6] or 0)
		* CFrame.Angles(rad(value[1]), rad(value[2]), rad(value[3]))
end

local function variant(baseName: string, extras: { [string]: { number } }): Pose
	local pose = table.clone(Poses[baseName])
	for joint, value in extras do
		pose[joint] = (pose[joint] or CFrame.identity) * extra(value)
	end
	return pose
end

local function mix(a: string, b: string, alpha: number): Pose
	local from, to = Poses[a], Poses[b]
	local pose: Pose = {}
	for joint, cf in from do
		pose[joint] = if to[joint] then cf:Lerp(to[joint], alpha) else cf
	end
	for joint, cf in to do
		if not pose[joint] then
			pose[joint] = cf
		end
	end
	return pose
end

local derived: { [string]: () -> Pose } = {
	-- Flinches: the small one is the plain HitReact; heavier ones fold further back and drop.
	HitMiddle = function()
		return variant("HitReact", { Waist = { 8, -6, 0 }, Neck = { 8, 0, 0 }, Root = { 4, 0, 0, 0, -0.15, 0 } })
	end,
	HitLarge = function()
		return variant("HitReact", {
			Waist = { 18, -10, 0 },
			Neck = { 14, 0, 0 },
			Root = { 10, 0, 0, 0, -0.35, 0.25 },
			RightHip = { -12, 0, 0 },
			LeftHip = { 20, 0, 0 },
			LeftKnee = { -30, 0, 0 },
		})
	end,
	-- Cut at the legs: the knees buckle toward the broken crouch.
	HitGedan = function()
		return mix("HitReact", "Broken", 0.55)
	end,
	-- Guard hits by size: the impact pose rocked further back for heavier blows.
	GuardImpactLarge = function()
		return variant("GuardImpact", { Waist = { 10, -6, 0 }, Root = { 6, 0, 0, 0, -0.2, 0.2 }, Neck = { 6, 0, 0 } })
	end,
	-- Deflects: the blade thrown to the side the blow came from, or straight back.
	DeflectRight = function()
		return variant("GuardImpact", { Waist = { 4, -14, 0 }, Neck = { 0, 8, 0 } })
	end,
	DeflectLeft = function()
		return variant("GuardImpact", { Waist = { 4, 18, 0 }, Neck = { 0, -10, 0 } })
	end,
	DeflectBack = function()
		return variant("GuardImpact", { Waist = { 12, 0, 0 }, Neck = { 8, 0, 0 }, Root = { 4, 0, 0, 0, -0.15, 0.15 } })
	end,
	-- The attacker's blade knocked aside by a deflect that doesn't recoil: half a recoil.
	Knocked = function()
		return mix("Ready", "Recoil", 0.5)
	end,
}
for name, build in derived do
	if not Poses[name] then -- an authored (baked) pose of the same name wins
		Poses[name] = build()
	end
end

return Poses
