--!strict
-- Procedural animator: writes joint Transforms every RunService.PreSimulation, after the
-- Roblox Animator has written its own. Works with both Motor6D and AnimationConstraint rigs.
--
-- Three layers per character, bottom to top:
--   loco   the swordsman stance and footwork (Shared/Gait): a low, wide idle with the hips
--          turned off the facing, and walk / run / strafe steps along the real ground velocity
--          with leg IK, so feet stay planted. It replaces Roblox's idle/walk/run on the ground
--          and hands back to Roblox's jump/fall/climb animations in the air. In Gait's "hybrid"
--          mode, walking and running forward show Roblox's default R15 walk and run instead
--          (played here on every rig at the top priority, timed like the Animate script), and
--          the footwork only takes slow steps, strafes, backpedals and standing.
--   base   a held stance (Ready, Guard, Broken) that blends smoothly when it changes
--   action a one-shot clip (a swing, a recoil) that fades in over its first segment
--          and back out to the base stance when it ends
-- Joints a pose doesn't mention keep the layer below. A pose's Waist is relative to its own
-- Root (or, if it has none, to a body square to the facing), so the chest keeps the facing a
-- pose was authored for however the hips below have turned.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Audio = require(script.Parent.Audio)
local Gait = require(ReplicatedStorage.Shared.Gait)
local Poses = require(ReplicatedStorage.Shared.Poses)
local Progression = require(ReplicatedStorage.Shared.Progression)
local ClipLibrary = require(ReplicatedStorage.Shared.Clips)

type Clip = ClipLibrary.Clip
type Ease = ClipLibrary.Ease
type PoseFrames = { [string]: CFrame }
type Weighted = { cf: CFrame, w: number }

type Key = { at: number, pose: PoseFrames, ease: Ease, trail: boolean }

type Action = {
	name: string,
	twoHanded: boolean,
	keys: { Key },
	hold: number,
	fadeOut: number,
	t: number,
	impactAt: number, -- clip time the strike lands (0 for clips without a windup)
	-- Playback speed until impactAt: a re-timed windup (Animator.retime) speeds up or slows down
	-- from where it is instead of restarting.
	rate: number,
	-- The pose on screen when this clip replaced another (unscaled joint Transforms): the first
	-- segment blends from it instead of from the stance, so chained swings flow on.
	from: PoseFrames?,
	fromGrip: number, -- how two-handed the grip was at that moment
}

type State = {
	model: Model,
	joints: { [string]: any }, -- Motor6D or AnimationConstraint; both expose Transform
	jointsDirty: boolean, -- joints replicate (and get rebuilt) after the model, so rescan on change
	base: { [string]: Weighted },
	baseTarget: PoseFrames?,
	baseName: string?,
	move: number, -- 0..1, how much the fighter is moving: legs follow the walk cycle
	action: Action?,
	-- The clip `action` replaced, still playing underneath for a short crossfade so the motion
	-- keeps its momentum through the switch.
	previous: Action?,
	crossT: number,
	grip: number, -- last frame's two-hand grip weight
	freezeUntil: number,
	frozenAction: Action?, -- the clip a hitstop froze; a clip started later plays on
	pinned: boolean, -- tooling froze it unconditionally (Animator.freeze)
	written: { [string]: CFrame },
	source: { [string]: CFrame },
	scale: number, -- BodyScale: pose offsets (a crouch's hip drop) are authored for a 1x body
	gait: Gait.Memory,
	loco: number, -- 0..1, how much the stance layer drives the body (0 in the air)
	ground: { [string]: number }, -- smoothed ground height under each foot (root space)
	squareRoot: CFrame, -- the Root a pose without one is relative to: square to the facing
	targets: Gait.Targets?, -- this frame's footwork targets (arm swing for held stances)
	lastPos: Vector3?, -- root position last frame: the footwork steps along the motion shown
	velocity: Vector3, -- smoothed world velocity from that motion
	-- Reused every frame (no per-frame tables for the joint results and layers).
	buffers: { { [string]: CFrame } },
	lodDt: number, -- time banked since the last full step (far rigs step at LOD_RATE)
	orphanedAt: number?, -- when the model lost its parent (dropped after ORPHAN_TIME)
	-- Hybrid gait: Roblox's default walk and run tracks on this rig (loaded the first time they're
	-- wanted), how much of the body they show this frame, the sword-side shoulder swing they show
	-- (radians, + = forward) and each foot's contact for their footsteps.
	authored: Authored?,
	authoredTried: boolean,
	authoredW: number,
	authoredSwing: number,
	footDown: { [string]: boolean },
	footLow: { [string]: number },
}

type Authored = { walk: AnimationTrack, run: AnimationTrack, playing: boolean, walkW: number, runW: number }

local BASE_BLEND_RATE = 14
local MOVE_BLEND_RATE = 10
local MOVING_SPEED = 2.5 -- studs/s
-- Faster than this (x BodyScale) is a lunge, dash or knockback, not walking: a clip playing then
-- keeps its own legs instead of handing them to the footwork.
local LUNGE_SPEED = 21
local LOCO_RATE = 10 -- the stance layer hands over to Roblox's air animations (and back) this fast
local GROUND_RATE = 18 -- smoothing of each foot's ground height
local REST_LEG = 1.8 -- hip-to-ankle length (studs) Shared/Gait's distances are authored for
local PROBE_RANGE = 150 -- beyond this distance from the camera, feet skip the ground probe
local VELOCITY_RATE = 14 -- smoothing of the velocity measured from the root's motion
-- Rigs further than LOD_RANGE from the camera are posed LOD_RATE times a second (the last pose is
-- held in between); dead bodies with nothing left to pose are left to Roblox's own animations
-- without any work. A model parented to nil for ORPHAN_TIME seconds is forgotten.
local LOD_RANGE = 90
local LOD_RATE = 15
local ORPHAN_TIME = 3
-- How much a held stance's arm swings with the stride (share of a free arm's swing): a one-handed
-- carry swings the sword hand a little with the blade kept steady, a two-handed guard barely.
local HELD_SWING = { one = 0.45, two = 0.08 }
-- Out of a fight the sword is carried (Poses.Relaxed is one of Poses' "Carry.<name>"): how each
-- carry moves with the stride. `swing` is its share of a free arm's swing; `out` and `abduct`
-- (degrees at a full run) turn a low blade's tip away from the leg and lift the arm clear of
-- it; `level` (degrees at a full run) tips the blade back down, since the run's forward lean
-- and arm carriage raise a blade pointing back by ~18 degrees (measured in Studio: the round-1
-- carry went from 21 degrees above level standing to 34-46 running). A blade over the shoulder
-- barely swings and needs no turning out.
type Carry = { swing: number, out: number, abduct: number, level: number }
local CARRIES: { [string]: Carry } = {
	Raised = { swing = 0.12, out = 0, abduct = 0, level = 0 },
	Back = { swing = 0.12, out = 0, abduct = 0, level = 18 },
	Flat = { swing = 0.12, out = 0, abduct = 0, level = 18 },
	Low = { swing = 0.3, out = -8, abduct = 6, level = 8 },
}
local carry: Carry = CARRIES[(Poses :: any).carry] or CARRIES.Back
-- Roblox's default R15 walk and run (the Animate script's own), for Gait's hybrid mode, and the
-- speeds they were authored for (the Animate script's setRunSpeed: studs/s / 16 x 1.25 / height
-- scale; the walk is drawn for 0.5 of that, the run for 1).
local DEFAULT_WALK = "rbxassetid://507777826"
local DEFAULT_RUN = "rbxassetid://507767714"
local AUTHORED_WALK_SPEED = 0.5
local AUTHORED_FADE = 0.12
-- Stances that hold the sword up for a fight: the footwork takes its low, wide shape under them.
local COMBAT_STANCES = { Ready = true, Guard = true, GuardImpact = true }
-- Humanoid states where Roblox's own animations (fall, climb, swim, sit, death) take the body.
local OFF_GROUND = {
	[Enum.HumanoidStateType.Dead] = true,
	[Enum.HumanoidStateType.Seated] = true,
	[Enum.HumanoidStateType.Climbing] = true,
	[Enum.HumanoidStateType.Swimming] = true,
	[Enum.HumanoidStateType.Freefall] = true,
	[Enum.HumanoidStateType.Jumping] = true,
	[Enum.HumanoidStateType.FallingDown] = true,
	[Enum.HumanoidStateType.Ragdoll] = true,
	[Enum.HumanoidStateType.PlatformStanding] = true,
}
-- A clip that replaces one still on screen crossfades out of it over this long (on top of
-- blending its first key in from the replaced pose).
local CROSSFADE = 0.08
-- The two-hand grip weight changes by at most this much per second, so a stance change (Relaxed
-- to Ready as a fight starts) brings the left hand to the hilt instead of snapping it there.
local GRIP_RATE = 5
-- While moving, attack poses leave these to the walk cycle, so the legs keep stepping
-- under a swing instead of freezing mid-stride.
local LOWER_BODY = {
	Root = true,
	RightHip = true,
	LeftHip = true,
	RightKnee = true,
	LeftKnee = true,
	RightAnkle = true,
	LeftAnkle = true,
}
-- Where the left wrist grips a two-handed hilt, in the right hand's space: behind the
-- right hand toward the pommel (the same grip the Blender rig is posed with).
local LEFT_GRIP = Vector3.new(0, -0.05, 0.38)
-- The left elbow points down, out and slightly back (in upper torso space).
local LEFT_POLE = Vector3.new(-1, -0.7, 0.35)

local Animator = {
	-- Studio tooling (CombatVisuals' AnimTest "trace"): when set, every frame and every play()
	-- on this model is logged into traceLog.
	traceModel = nil :: Model?,
	traceLog = {} :: { any },
	-- Studio A/B: true restores the old chaining (each clip blends in from the stance).
	legacyChain = false,
}

local states: { [Model]: State } = {}

-- Ground probes ignore every fighter (bodies, swords, accessories).
local groundParams = RaycastParams.new()
groundParams.FilterType = Enum.RaycastFilterType.Exclude
groundParams.RespectCanCollide = true

local function refreshGroundFilter()
	local fighters = {}
	for model in states do
		table.insert(fighters, model)
	end
	groundParams.FilterDescendantsInstances = fighters
end

-- Poses.luau compiles every pose to joint Transforms at load.
local poseFrames: { [string]: PoseFrames } = Poses

local function ease(kind: Ease, x: number): number
	x = math.clamp(x, 0, 1)
	if kind == "in" then
		return x * x * x
	elseif kind == "out" then
		return 1 - (1 - x) ^ 3
	elseif kind == "inOut" then
		return if x < 0.5 then 4 * x * x * x else 1 - (-2 * x + 2) ^ 3 / 2
	end
	return x
end

local function findJoints(model: Model): { [string]: any }
	local joints = {}
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("Motor6D") or descendant:IsA("AnimationConstraint") then
			joints[descendant.Name] = descendant
		end
	end
	return joints
end

-- Writes `from` blended towards `to` into `out` as weighted joint targets.
local function blendInto(out: { [string]: Weighted }, from: PoseFrames?, to: PoseFrames, alpha: number, weight: number)
	for joint, cf in to do
		local start = from and from[joint]
		if start then
			out[joint] = { cf = start:Lerp(cf, alpha), w = weight }
		else
			out[joint] = { cf = cf, w = weight * alpha }
		end
	end
	if from then
		for joint, cf in from do
			if not to[joint] then
				out[joint] = { cf = cf, w = weight * (1 - alpha) }
			end
		end
	end
end

-- Samples the action layer. Returns nil once the clip has fully faded out. The third value
-- is how far the first segment has blended in (1 past it).
local function sampleAction(action: Action): ({ [string]: Weighted }?, boolean, number)
	local keys = action.keys
	local t = action.t
	local out: { [string]: Weighted } = {}

	local first = keys[1]
	if t <= first.at then
		local alpha = ease(first.ease, t / math.max(first.at, 1e-3))
		blendInto(out, action.from, first.pose, alpha, 1)
		return out, first.trail, alpha
	end
	for i = 2, #keys do
		local key = keys[i]
		if t <= key.at then
			local previous = keys[i - 1]
			local alpha = ease(key.ease, (t - previous.at) / math.max(key.at - previous.at, 1e-3))
			blendInto(out, previous.pose, key.pose, alpha, 1)
			return out, key.trail, 1
		end
	end

	local last = keys[#keys]
	local after = t - last.at - action.hold
	if after <= 0 then
		blendInto(out, nil, last.pose, 1, 1)
		return out, false, 1
	end
	if after >= action.fadeOut then
		return nil, false, 1
	end
	blendInto(out, nil, last.pose, 1, 1 - ease("inOut", after / action.fadeOut))
	return out, false, 1
end

-- Advances a clip by `dt`, at its re-timed rate until the strike.
local function advance(action: Action, dt: number)
	local t = action.t
	if t < action.impactAt and action.rate ~= 1 then
		local nextT = t + dt * action.rate
		if nextT > action.impactAt then
			nextT = action.impactAt + (nextT - action.impactAt) / action.rate
		end
		action.t = nextT
	else
		action.t = t + dt
	end
end

-- Trails are colour-coded by what's swinging: steel-white for slashes, red for perilous.
local STEEL_TRAIL = ColorSequence.new(Color3.fromRGB(255, 255, 255), Color3.fromRGB(205, 220, 255))
local PERIL_TRAIL = ColorSequence.new(Color3.fromRGB(255, 90, 70), Color3.fromRGB(200, 20, 20))

local function setTrail(model: Model, enabled: boolean, clipName: string?)
	local sword = model:FindFirstChild("Sword")
	local trail = sword and sword:FindFirstChildOfClass("Trail")
	if trail and trail.Enabled ~= enabled then
		if enabled then
			local perilous = clipName == "Perilous" or clipName == "Sweep"
			local skinId = model:GetAttribute("Skin")
			local skin = if typeof(skinId) == "string" and skinId ~= "Steel" then Progression.skin(skinId) else nil
			trail.Color = if perilous
				then PERIL_TRAIL
				elseif skin then ColorSequence.new(skin.trail[1], skin.trail[2])
				else STEEL_TRAIL
		end
		trail.Enabled = enabled
	end
end

-- Smallest rotation taking direction `from` onto `to`.
local function between(from: Vector3, to: Vector3): CFrame
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

-- A joint's offsets on its parent and child parts: child = parent * a0 * Transform * a1^-1.
local function offsets(joint: any): (CFrame, CFrame)
	if joint:IsA("Motor6D") then
		return joint.C0, joint.C1
	end
	return joint.Attachment0.CFrame, joint.Attachment1.CFrame
end

local function link(joint: any, transform: CFrame): CFrame
	local a0, a1 = offsets(joint)
	return a0 * transform * a1:Inverse()
end

-- Two-hand grip: solves the left arm (shoulder, elbow, wrist) so the left wrist sits on the
-- hilt behind the right hand and the left hand matches the right hand's angle, all in
-- upper-torso space from this frame's joint results. Writes into `results`, blended by `w`.
local function solveGrip(state: State, results: { [string]: CFrame }, w: number)
	local j = state.joints
	local rs, re, rw = j.RightShoulder, j.RightElbow, j.RightWrist
	local ls, le, lw = j.LeftShoulder, j.LeftElbow, j.LeftWrist
	if not (rs and re and rw and ls and le and lw) then
		return
	end
	local hand = link(rs, results.RightShoulder) * link(re, results.RightElbow) * link(rw, results.RightWrist)
	local target = hand * LEFT_GRIP

	local lsA0, lsA1 = offsets(ls)
	local leA0, leA1 = offsets(le)
	local lwA0, lwA1 = offsets(lw)
	local shoulder = lsA0.Position
	local upperRest = leA0.Position - lsA1.Position -- shoulder to elbow, in upper arm space
	local lowerRest = lwA0.Position - leA1.Position -- elbow to wrist, in lower arm space
	local l1, l2 = upperRest.Magnitude, lowerRest.Magnitude
	if l1 < 1e-3 or l2 < 1e-3 then
		return
	end

	local d = target - shoulder
	local dist = math.clamp(d.Magnitude, 0.05, l1 + l2 - 1e-3)
	local dir = d.Unit
	local cosA = math.clamp((l1 * l1 + dist * dist - l2 * l2) / (2 * l1 * dist), -1, 1)
	local pole = LEFT_POLE - dir * LEFT_POLE:Dot(dir)
	pole = if pole.Magnitude > 1e-4 then pole.Unit else Vector3.new(0, -1, 0)
	local elbow = shoulder + dir * (l1 * cosA) + pole * (l1 * math.sqrt(1 - cosA * cosA))
	local wrist = shoulder + dir * dist

	-- Shoulder: point the upper arm at the elbow, with its hinge axis across the arm plane.
	local u = (elbow - shoulder).Unit
	local v = (wrist - elbow).Unit
	-- The bend plane's normal. u x v points the same way while the arm is bent but shrinks to
	-- noise as it straightens, flipping the upper arm's twist frame to frame; pole x dir is the
	-- same axis without that.
	local hinge = pole:Cross(dir)
	hinge = if hinge.Magnitude > 1e-4 then hinge.Unit else pole:Cross(u).Unit
	local a = upperRest.Unit
	local b = (Vector3.xAxis - a * a:Dot(Vector3.xAxis)).Unit
	local restFrame = CFrame.fromMatrix(Vector3.zero, a, b, a:Cross(b))
	local goalFrame = CFrame.fromMatrix(Vector3.zero, u, hinge, u:Cross(hinge))
	local upperRot = goalFrame * restFrame:Inverse()
	local tShoulder = lsA0.Rotation:Inverse() * upperRot * lsA1.Rotation

	-- Elbow: bend the forearm onto the wrist.
	local inUpper = upperRot:VectorToObjectSpace(v)
	local lowerRel = between(lowerRest.Unit, inUpper.Unit)
	local tElbow = leA0.Rotation:Inverse() * lowerRel * leA1.Rotation

	-- Wrist: the left hand matches the right hand's angle on the hilt.
	local lowerRot = upperRot * lowerRel
	local handRel = lowerRot:Inverse() * hand.Rotation
	local tWrist = lwA0.Rotation:Inverse() * handRel * lwA1.Rotation

	results.LeftShoulder = results.LeftShoulder:Lerp(tShoulder, w)
	results.LeftElbow = results.LeftElbow:Lerp(tElbow, w)
	results.LeftWrist = results.LeftWrist:Lerp(tWrist, w)
end

-- A pose's joint offset on a body `scale` times our size (rotations are scale-free).
local function scaled(cf: CFrame, scale: number): CFrame
	return if scale == 1 then cf else cf.Rotation + cf.Position * scale
end

-- The rotation taking direction `restDir` onto `dir` and, about it, `restFwd` onto `fwd`.
local function frameMap(restDir: Vector3, restFwd: Vector3, dir: Vector3, fwd: Vector3): CFrame
	local f0 = restFwd - restDir * restFwd:Dot(restDir)
	local f1 = fwd - dir * fwd:Dot(dir)
	if f0.Magnitude < 1e-4 or f1.Magnitude < 1e-4 then
		return between(restDir, dir)
	end
	f0, f1 = f0.Unit, f1.Unit
	local rest = CFrame.fromMatrix(Vector3.zero, restDir, f0, restDir:Cross(f0))
	local goal = CFrame.fromMatrix(Vector3.zero, dir, f1, dir:Cross(f1))
	return goal * rest:Inverse()
end

local FORWARD = Vector3.new(0, 0, -1)

-- Leg IK in HumanoidRootPart space: hip, knee and ankle Transforms that put the ankle pivot on
-- `target` with the knee bent over the toes and the foot at `footRot`. Writes into `out`.
local function solveLeg(
	side: string,
	j: { [string]: any },
	lowerTorso: CFrame,
	target: Vector3,
	footRot: CFrame,
	out: { [string]: CFrame }
)
	local hip, knee, ankle = j[side .. "Hip"], j[side .. "Knee"], j[side .. "Ankle"]
	local hC0, hC1 = offsets(hip)
	local kC0, kC1 = offsets(knee)
	local aC0, aC1 = offsets(ankle)
	local pivot = (lowerTorso * hC0).Position
	local upperRest = kC0.Position - hC1.Position -- hip to knee, in upper leg space
	local lowerRest = aC0.Position - kC1.Position -- knee to ankle, in lower leg space
	local l1, l2 = upperRest.Magnitude, lowerRest.Magnitude
	if l1 < 1e-3 or l2 < 1e-3 then
		return
	end
	local d = target - pivot
	local dist = math.clamp(d.Magnitude, 0.05, (l1 + l2) * 0.999)
	local dir = d.Unit
	local cosA = math.clamp((l1 * l1 + dist * dist - l2 * l2) / (2 * l1 * dist), -1, 1)
	local toes = footRot.LookVector
	local pole = toes - dir * toes:Dot(dir)
	pole = if pole.Magnitude > 1e-4 then pole.Unit else lowerTorso.LookVector
	local kneeAt = pivot + dir * (l1 * cosA) + pole * (l1 * math.sqrt(1 - cosA * cosA))
	local ankleAt = pivot + dir * dist
	local upper = frameMap(upperRest.Unit, FORWARD, (kneeAt - pivot).Unit, pole)
	local lower = frameMap(lowerRest.Unit, FORWARD, (ankleAt - kneeAt).Unit, pole)
	out[side .. "Hip"] = hC0.Rotation:Inverse() * lowerTorso.Rotation:Inverse() * upper * hC1.Rotation
	out[side .. "Knee"] = kC0.Rotation:Inverse() * upper:Inverse() * lower * kC1.Rotation
	out[side .. "Ankle"] = aC0.Rotation:Inverse() * lower:Inverse() * footRot.Rotation * aC1.Rotation
end

-- The rest ankle pivot of a leg in HumanoidRootPart space (every Transform identity).
local function restAnkle(side: string, j: { [string]: any }): Vector3
	local legTop = link(j.Root, CFrame.identity) * link(j[side .. "Hip"], CFrame.identity)
	local shin = legTop * link(j[side .. "Knee"], CFrame.identity)
	local ankleC0 = offsets(j[side .. "Ankle"])
	return (shin * ankleC0).Position
end

local LEG_JOINTS = { "Root", "RightHip", "RightKnee", "RightAnkle", "LeftHip", "LeftKnee", "LeftAnkle" }

-- The stance layer: advances the footwork and returns its full-body pose (nil when the body is
-- in the air, dead or not an R15 rig) and how strongly it applies.
-- Hybrid gait: plays (or stops) Roblox's default walk and run on the rig for `speed` studs/s,
-- weighted and timed as the Animate script does, at `presence` of full weight (the stance
-- layer's grounded share, so a jump's own animation takes over as smoothly as the footwork
-- hands it over). Returns 1 once both tracks are playing (0 while they load, or if the rig has
-- no Animator).
local function driveAuthored(state: State, humanoid: Humanoid, want: boolean, speed: number, presence: number): number
	local a = state.authored
	if not want or presence < 0.02 then
		if a and a.playing then
			a.walk:Stop(AUTHORED_FADE)
			a.run:Stop(AUTHORED_FADE)
			a.playing = false
		end
		return 0
	end
	if not a then
		if state.authoredTried then
			return 0
		end
		state.authoredTried = true
		local animator = humanoid:FindFirstChildOfClass("Animator")
		if not animator then
			return 0
		end
		local function load(id: string): AnimationTrack?
			local animation = Instance.new("Animation")
			animation.AnimationId = id
			local ok, track = pcall(function()
				return (animator :: Animator):LoadAnimation(animation)
			end)
			if not ok or not track then
				return nil
			end
			track.Priority = Enum.AnimationPriority.Action4
			track.Looped = true
			return track
		end
		local walk, run = load(DEFAULT_WALK), load(DEFAULT_RUN)
		if not walk or not run then
			return 0
		end
		a = { walk = walk, run = run, playing = false, walkW = 0, runW = 0 }
		state.authored = a
	end
	local tracks = a :: Authored
	if tracks.walk.Length <= 0 or tracks.run.Length <= 0 then
		return 0 -- still loading
	end
	local height = if humanoid.HipHeight > 0 then humanoid.HipHeight / 2 else 1
	local pace = speed / 16 * 1.25 / height
	local walkW, runW, walkRate, runRate = 1e-4, 1e-4, pace / AUTHORED_WALK_SPEED, pace
	if pace <= AUTHORED_WALK_SPEED then
		walkW = 1
	elseif pace < 1 then
		local f = (pace - AUTHORED_WALK_SPEED) / (1 - AUTHORED_WALK_SPEED)
		walkW, runW, walkRate, runRate = 1 - f, f, 1, 1
	else
		runW = 1
	end
	walkW, runW = math.max(walkW * presence, 1e-4), math.max(runW * presence, 1e-4)
	if not tracks.playing then
		-- (No fade in: the footwork hands over by Gait's own blend.)
		tracks.walk:Play(0, walkW, walkRate)
		tracks.run:Play(0, runW, runRate)
		tracks.playing = true
		tracks.walkW, tracks.runW = walkW, runW
		return 0 -- (it shows from the next frame)
	end
	if math.abs(walkW - tracks.walkW) > 0.02 or math.abs(runW - tracks.runW) > 0.02 then
		tracks.walk:AdjustWeight(walkW, 0.06)
		tracks.run:AdjustWeight(runW, 0.06)
		tracks.walkW, tracks.runW = walkW, runW
	end
	tracks.walk:AdjustSpeed(walkRate)
	tracks.run:AdjustSpeed(runRate)
	return 1
end

-- An ankle pivot in HumanoidRootPart space under the joint Transforms in `pose`, and the
-- direction its toes point.
local function ankleOf(side: string, j: { [string]: any }, pose: { [string]: CFrame }): (Vector3, Vector3)
	local top = link(j.Root, pose.Root or CFrame.identity)
		* link(j[side .. "Hip"], pose[side .. "Hip"] or CFrame.identity)
	local shin = top * link(j[side .. "Knee"], pose[side .. "Knee"] or CFrame.identity)
	local ankle = j[side .. "Ankle"]
	return (shin * offsets(ankle)).Position, (shin * link(ankle, pose[side .. "Ankle"] or CFrame.identity)).LookVector
end

local function locomotion(
	state: State,
	dt: number,
	root: BasePart?,
	humanoid: Humanoid?,
	owned: boolean,
	below: { [string]: CFrame }
): ({ [string]: CFrame }?, number)
	local j = state.joints
	for _, name in LEG_JOINTS do
		if not j[name] then
			return nil, 0
		end
	end
	if not root or not humanoid then
		return nil, 0
	end
	local hrp = root.CFrame
	local groundRest = -(humanoid.HipHeight + root.Size.Y / 2) -- the floor, in root space
	local ankles: { [string]: Vector3 } = { Right = restAnkle("Right", j), Left = restAnkle("Left", j) }
	local hipPivot = (link(j.Root, CFrame.identity) * offsets(j.RightHip)).Position
	local k = math.max((hipPivot - ankles.Right).Magnitude / REST_LEG, 0.2)
	-- The real foot (avatars' feet differ a lot): where the ankle pivot sits over sole, toe and heel.
	local ankleJoint = j.RightAnkle
	local footPart = if ankleJoint:IsA("Motor6D") then ankleJoint.Part1 else ankleJoint.Attachment1.Parent
	if footPart and footPart:IsA("BasePart") then
		local _, inFoot = offsets(ankleJoint)
		local size = footPart.Size
		local p = inFoot.Position
		Gait.setFoot(state.gait, (p.Y + size.Y / 2) / k, (p.Z + size.Z / 2) / k, (size.Z / 2 - p.Z) / k)
	end

	local alive = humanoid.Health > 0 and state.model:GetAttribute("CombatState") ~= "Dead"
	local grounded = alive
		and not OFF_GROUND[humanoid:GetState()]
		and workspace:Raycast(root.Position, hrp.UpVector * (groundRest - 1.2 * k), groundParams) ~= nil
	state.loco += ((if grounded then 1 else 0) - state.loco) * (1 - math.exp(-dt * LOCO_RATE))

	local base = state.baseName
	local combat = if (base and COMBAT_STANCES[base]) or state.action then 1 else 0
	-- Step along the motion actually shown (a remote body's interpolated position, Spacing's
	-- pushes), not the physics velocity alone; teleports are ignored.
	local measured = root.AssemblyLinearVelocity
	local last = state.lastPos
	if last and dt > 0 then
		local moved = (root.Position - last) / dt
		if moved.Magnitude < 120 then
			measured = moved
		end
	end
	state.lastPos = root.Position
	state.velocity += (measured - state.velocity) * (1 - math.exp(-dt * VELOCITY_RATE))
	local velocity = hrp:VectorToObjectSpace(state.velocity) / k
	local look = hrp.LookVector
	local facing = math.deg(math.atan2(-look.X, -look.Z))
	local t = Gait.step(state.gait, dt, velocity, combat, facing, root.Position / k, owned)
	state.targets = t
	-- Hybrid: Roblox's default walk / run take forward travel on the ground.
	local groundSpeed = Vector3.new(state.velocity.X, 0, state.velocity.Z).Magnitude
	local authored = driveAuthored(state, humanoid, t.authored > 0.02, groundSpeed, state.loco)
	local h = t.authored * authored
	state.authoredW = h
	if h > 1e-3 then
		local shoulder = below.RightShoulder
		state.authoredSwing = if shoulder then (shoulder:ToEulerAnglesXYZ()) else 0
		-- Their feet: footsteps when one comes down, and the standing places when the footwork
		-- takes over again.
		for _, side in { "Right", "Left" } do
			local ankle, toes = ankleOf(side, j, below)
			local height = (ankle.Y - ankles[side].Y) / k
			local low = math.min((state.footLow[side] or height) + dt * 0.5, height)
			state.footLow[side] = low
			if state.footDown[side] then
				if height > low + 0.25 then
					state.footDown[side] = false
				end
			elseif height < low + 0.08 then
				state.footDown[side] = true
				if h > 0.5 then
					local at = Vector3.new(ankle.X, groundRest, ankle.Z)
					Audio.footstep(state.model, hrp:PointToWorldSpace(at), groundSpeed)
				end
			end
			Gait.observeFoot(
				state.gait,
				side,
				Vector3.new(ankle.X, 0, ankle.Z) / k,
				math.deg(math.atan2(-toes.X, -toes.Z))
			)
		end
	end
	if state.loco < 1e-3 then
		state.ground = {}
		return nil, 0
	end

	-- Ground under each foot (uneven terrain, steps), smoothed; near the camera only.
	local camera = workspace.CurrentCamera
	local probe = camera ~= nil and (camera.CFrame.Position - root.Position).Magnitude < PROBE_RANGE
	local feet: { [string]: Gait.Foot } = { Right = t.right, Left = t.left }
	local lowest = groundRest
	for side, f in feet do
		local x, z = f.pos.X * k, f.pos.Z * k
		local ground = groundRest
		if probe then
			local from = hrp:PointToWorldSpace(Vector3.new(x, groundRest + 1.6 * k, z))
			local hit = workspace:Raycast(from, hrp.UpVector * (-3.2 * k), groundParams)
			if hit then
				ground = math.clamp(hrp:PointToObjectSpace(hit.Position).Y, groundRest - 1.2 * k, groundRest + 1.2 * k)
			end
		end
		local was = state.ground[side] or ground
		state.ground[side] = was + (ground - was) * (1 - math.exp(-dt * GROUND_RATE))
		lowest = math.min(lowest, state.ground[side])
	end

	local pose: { [string]: CFrame } = {}
	-- Hips: dropped into the stance (and further when a foot stands lower than the body), turned.
	local drop = t.drop * k + math.min(groundRest - lowest, 0.6 * k)
	local rootT = CFrame.new(t.sway * k, -drop, 0)
		* CFrame.Angles(0, t.hipYaw, 0)
		* CFrame.Angles(0, 0, t.hipRoll)
		* CFrame.Angles(t.hipPitch, 0, 0)
	pose.Root = rootT
	local lowerTorso = link(j.Root, rootT)
	-- The chest squares back up to the facing, leaning into a run or a turn and counter-turning
	-- against the hips; stance poses build on that. The head steadies itself on top.
	local square = CFrame.Angles(0, 0, t.bank) * CFrame.Angles(t.lean, 0, 0) * CFrame.Angles(0, t.chestYaw, 0)
	state.squareRoot = CFrame.new():Lerp(square, state.loco * (1 - h))
	pose.Waist = rootT.Rotation:Inverse() * square
	pose.Neck = CFrame.Angles(-t.lean * 0.5, -t.chestYaw * 0.8, -t.bank * 0.6)

	for side, f in feet do
		local rest = ankles[side]
		local target = Vector3.new(f.pos.X * k, state.ground[side] + (rest.Y - groundRest) + f.pos.Y * k, f.pos.Z * k)
		local footRot = CFrame.Angles(0, f.yaw, 0) * CFrame.Angles(f.pitch, 0, 0)
		solveLeg(side, j, lowerTorso, target, footRot, pose)
		if f.landed and state.loco > 0.5 and h <= 0.5 then
			local v = state.velocity
			Audio.footstep(state.model, hrp:PointToWorldSpace(target), Vector3.new(v.X, 0, v.Z).Magnitude)
		end
	end

	-- Arms hang loose and swing against the legs where no stance holds them: elbows bend
	-- further running, more on the forward swing, and the hands come in toward the chest.
	local swing, bend, run = t.armSwing, t.armBend, t.run * t.moveW
	local inward = math.rad(12) * run
	pose.LeftShoulder = CFrame.Angles(swing + math.rad(3 + 6 * run), -inward, math.rad(-7 + 2 * run))
	pose.LeftElbow = CFrame.Angles(bend + math.max(swing, 0) * 0.6, 0, 0)
	pose.LeftWrist = CFrame.Angles(math.rad(-6), 0, 0)
	pose.RightShoulder = CFrame.Angles(-swing + math.rad(3 + 6 * run), inward, math.rad(7 - 2 * run))
	pose.RightElbow = CFrame.Angles(bend + math.max(-swing, 0) * 0.6, 0, 0)
	pose.RightWrist = CFrame.Angles(math.rad(-6), 0, 0)
	-- (Hybrid: the authored walk / run below shows through by its share.)
	return pose, state.loco * (1 - h)
end

-- Swings an arm a stance holds by `angle` (radians, + = forward) at the shoulder, turning the
-- wrist back so the hand (and the blade in it) keeps its angle: the sword is carried steady.
-- `raise` (radians) tips the hand's blade up in the chest's frame (against a forward lean), `out`
-- turns it outward and `abduct` lifts the arm out to the side (running, the blade then passes
-- beside the driving knee instead of through it).
local function swingHeld(
	state: State,
	results: { [string]: CFrame },
	side: string,
	angle: number,
	raise: number,
	out: number,
	abduct: number
)
	local j = state.joints
	local s, e, w = j[side .. "Shoulder"], j[side .. "Elbow"], j[side .. "Wrist"]
	local tS, tE, tW = results[side .. "Shoulder"], results[side .. "Elbow"], results[side .. "Wrist"]
	if not (s and e and w and tS and tE and tW) or math.abs(angle) + math.abs(raise) + math.abs(abduct) < 1e-4 then
		return
	end
	local sign = if side == "Right" then 1 else -1
	local hand = CFrame.Angles(0, -out * sign, 0)
		* CFrame.Angles(raise, 0, 0)
		* (link(s, tS) * link(e, tE) * link(w, tW)).Rotation
	local sA0 = offsets(s).Rotation
	local swung = sA0:Inverse() * CFrame.Angles(0, 0, abduct * sign) * CFrame.Angles(angle, 0, 0) * sA0 * tS
	local wA0, wA1 = offsets(w)
	local arm = (link(s, swung) * link(e, tE)).Rotation
	local wrist = wA0.Rotation:Inverse() * arm:Inverse() * hand * wA1.Rotation
	results[side .. "Shoulder"] = swung
	results[side .. "Wrist"] = wrist + tW.Position
end

-- Lays a weighted pose over `below` (joint Transforms) and returns the result. Lower-body joints
-- take `legs` of their weight (the footwork keeps them while walking). The Waist is rotated so
-- the upper torso faces where the pose meant it to relative to the pose's own Root (or the
-- square Root, for poses without one), whatever Root the body ends up with.
local function applyLayer(
	state: State,
	below: { [string]: CFrame },
	pose: { [string]: Weighted }?,
	legs: number,
	out: { [string]: CFrame }
): { [string]: CFrame }
	if not pose then
		return below
	end
	table.clear(out)
	for name, cf in below do
		out[name] = cf
	end
	local poseRoot = pose.Root
	if poseRoot and below.Root then
		out.Root = below.Root:Lerp(scaled(poseRoot.cf, state.scale), poseRoot.w * legs)
	end
	for name, layered in pose do
		local current = below[name]
		if name ~= "Root" and current then
			local target = scaled(layered.cf, state.scale)
			local bodyRoot = out.Root
			if name == "Waist" and bodyRoot then
				local intended = if poseRoot then poseRoot.cf else state.squareRoot
				target = (bodyRoot.Rotation:Inverse() * intended.Rotation) * target
			end
			out[name] = current:Lerp(target, if LOWER_BODY[name] then layered.w * legs else layered.w)
		end
	end
	return out
end

local function step(state: State, dt: number)
	-- Base layer: ease every joint towards the target stance.
	local k = 1 - math.exp(-dt * BASE_BLEND_RATE)
	local target = state.baseTarget
	if target then
		for joint, cf in target do
			local current = state.base[joint]
			if current then
				current.cf = current.cf:Lerp(cf, k)
				current.w += (1 - current.w) * k
			else
				state.base[joint] = { cf = cf, w = k }
			end
		end
	end
	for joint, current in state.base do
		if not target or not target[joint] then
			current.w -= current.w * k
			if current.w < 1e-3 then
				state.base[joint] = nil
			end
		end
	end

	-- Action layer.
	-- Hitstop only holds the clip that was playing when it hit, and never a windup, so a
	-- swing started during a freeze (a riposte off a deflect) still lands on hitAt.
	local clock = os.clock()
	local function frozen(clip: Action): boolean
		return clock < state.freezeUntil and (state.pinned or (clip == state.frozenAction and clip.t >= clip.impactAt))
	end
	local actionPose: { [string]: Weighted }? = nil
	local trailOn = false
	local blendIn = 1
	local action = state.action
	if action then
		if not frozen(action) then
			advance(action, dt)
		end
		actionPose, trailOn, blendIn = sampleAction(action)
		if not actionPose then
			state.action = nil
		end
	end
	-- The replaced clip plays on under a short crossfade, so the switch keeps its momentum.
	local previousPose: { [string]: Weighted }? = nil
	local cross = 1
	local previous = state.previous
	if previous then
		state.crossT += dt
		if not frozen(previous) then
			advance(previous, dt)
		end
		local previousTrail
		previousPose, previousTrail = sampleAction(previous)
		if previousPose and state.crossT < CROSSFADE then
			cross = ease("inOut", state.crossT / CROSSFADE)
			trailOn = trailOn or previousTrail
		else
			previousPose = nil
			state.previous = nil
		end
	end
	setTrail(state.model, trailOn, action and action.name)
	if Animator.traceModel == state.model then
		table.insert(Animator.traceLog, {
			c = clock,
			a = action and action.name,
			t = action and action.t,
			w = actionPose and actionPose.RightShoulder and actionPose.RightShoulder.w or 0,
			x = cross,
		})
	end

	local rootPart = state.model:FindFirstChild("HumanoidRootPart")
	local root = if rootPart and rootPart:IsA("BasePart") then rootPart else nil
	local velocity = if root then root.AssemblyLinearVelocity else Vector3.zero
	local flatSpeed = Vector3.new(velocity.X, 0, velocity.Z).Magnitude
	-- Walking hands the legs to the footwork; a lunge or dash (faster) leaves them to the clip.
	local moving = if flatSpeed > MOVING_SPEED and flatSpeed < LUNGE_SPEED * state.scale then 1 else 0
	state.move += (moving - state.move) * (1 - math.exp(-dt * MOVE_BLEND_RATE))
	local legsKept = 1 - state.move

	local results = state.buffers[1]
	table.clear(results)
	for name, joint in state.joints do
		local current = joint.Transform
		-- If the Animator didn't rewrite this joint since our last write, start from
		-- what it was before we touched it, so overrides don't compound frame to frame.
		if state.written[name] == current then
			current = state.source[name]
		end
		state.source[name] = current
		results[name] = current
	end

	-- Stance and footwork under everything else. A clip or stance posing the legs while standing
	-- owns the feet: the footwork's standing places follow the stance instead of stepping.
	local function legWeight(pose: { [string]: Weighted }?): number
		local hip = pose and pose.RightHip
		return if hip then hip.w else 0
	end
	local owned = legsKept > 0.5 and math.max(legWeight(actionPose), legWeight(state.base)) > 0.5
	local locoPose, locoWeight =
		locomotion(state, dt, root, state.model:FindFirstChildOfClass("Humanoid"), owned, results)
	if locoPose then
		for name, cf in locoPose do
			local current = results[name]
			if current then
				results[name] = current:Lerp(cf, locoWeight)
			end
		end
	else
		state.squareRoot = CFrame.identity
	end

	local buffers = state.buffers
	results = applyLayer(state, results, state.base, legsKept, buffers[2])
	local based = results
	results = applyLayer(state, based, actionPose, legsKept, buffers[3])
	if previousPose then
		local fading = applyLayer(state, based, previousPose, legsKept, buffers[4])
		for name, cf in results do
			results[name] = fading[name]:Lerp(cf, cross)
		end
	end

	-- The arms a stance holds swing a little with the stride (not under a clip).
	local targets = state.targets
	if (locoPose or state.authoredW > 1e-3) and targets and targets.moveW > 1e-3 then
		local clipArm = if actionPose and actionPose.RightShoulder then actionPose.RightShoulder.w else 0
		local baseArm = if state.base.RightShoulder then state.base.RightShoulder.w else 0
		local name = state.baseName
		local two = name ~= nil and ClipLibrary.TwoHandedStances[name] == true
		local carried = if name == "Relaxed" then carry else nil
		-- (Hybrid: the authored cycle's own shoulder swing, so the hand keeps time with its legs.)
		local h = state.authoredW
		local presence = math.max(locoWeight, h)
		local kind = if two then HELD_SWING.two elseif carried then carried.swing else HELD_SWING.one
		local share = kind * baseArm * (1 - clipArm) * presence
		local swing = -targets.armSwing * (1 - h) + state.authoredSwing * h
		-- A one-handed stance held forward also tips the blade up against the run's lean so the
		-- tip stays clear of the ground, and turns it out beside the driving knee; a carry does
		-- what its entry says (a blade pointing back rises with the lean by itself).
		local held = if two then 0 else baseArm * (1 - clipArm) * presence
		local running = targets.run * targets.moveW * held
		swingHeld(
			state,
			results,
			"Right",
			swing * share,
			if carried then math.rad(carried.level) * running else -targets.lean * 1.4 * held * (1 - h),
			math.rad(if carried then carried.out else 10) * running,
			math.rad(if carried then carried.abduct else 8) * running
		)
	end

	-- Two-hand grip, as strong as the two-handed layers currently are.
	local baseLayer = state.base.RightShoulder
	local baseTwo = if baseLayer
			and state.baseName
			and ClipLibrary.TwoHandedStances[state.baseName]
		then baseLayer.w
		else 0
	local function gripOf(clip: Action?, pose: { [string]: Weighted }?): number
		local weight = if pose and pose.RightShoulder then pose.RightShoulder.w else 0
		local two = if clip and clip.twoHanded then 1 else 0
		return weight * two + (1 - weight) * baseTwo
	end
	local grip = gripOf(action, actionPose)
	if action and action.from and blendIn < 1 then
		grip = action.fromGrip + (grip - action.fromGrip) * blendIn -- from the grip on screen
	end
	if previousPose then
		local from = gripOf(previous, previousPose)
		grip = from + (grip - from) * cross
	end
	grip = state.grip + math.clamp(grip - state.grip, -dt * GRIP_RATE, dt * GRIP_RATE)
	state.grip = grip
	if grip > 1e-3 and results.LeftShoulder and results.RightShoulder then
		solveGrip(state, results, grip)
	end

	for name, joint in state.joints do
		local result = results[name]
		joint.Transform = result
		state.written[name] = result
	end
end

function Animator.attach(model: Model)
	if states[model] then
		return
	end
	local state: State = {
		model = model,
		joints = {},
		jointsDirty = true,
		base = {},
		baseTarget = nil,
		baseName = nil,
		move = 0,
		action = nil,
		previous = nil,
		crossT = 0,
		grip = 0,
		freezeUntil = 0,
		frozenAction = nil,
		pinned = false,
		written = {},
		source = {},
		scale = 1,
		gait = Gait.new(),
		loco = 0,
		ground = {},
		squareRoot = CFrame.identity,
		targets = nil,
		lastPos = nil,
		velocity = Vector3.zero,
		buffers = { {}, {}, {}, {} },
		lodDt = 0,
		orphanedAt = nil,
		authored = nil,
		authoredTried = false,
		authoredW = 0,
		authoredSwing = 0,
		footDown = {},
		footLow = {},
	}
	states[model] = state
	refreshGroundFilter()
	local function readScale()
		local scale = model:GetAttribute("BodyScale")
		state.scale = if typeof(scale) == "number" and scale > 0 then scale else 1
	end
	readScale()
	model:GetAttributeChangedSignal("BodyScale"):Connect(readScale)

	local function markIfJoint(descendant: Instance)
		if descendant:IsA("Motor6D") or descendant:IsA("AnimationConstraint") then
			state.jointsDirty = true
		end
	end
	model.DescendantAdded:Connect(markIfJoint)
	model.DescendantRemoving:Connect(markIfJoint)
	model.Destroying:Once(function()
		states[model] = nil
		refreshGroundFilter()
	end)
end

-- Holds a named pose from Poses.luau as the stance, or clears it with nil.
function Animator.setBase(model: Model, poseName: string?)
	local state = states[model]
	if state then
		state.baseTarget = if poseName then poseFrames[poseName] else nil
		state.baseName = poseName
	end
end

-- Plays a clip from Clips.luau. `windup` is the time until impact, used to stretch
-- the clip's "windup" segment so the strike lands on the server's hitAt.
-- `freeze` is Kannagi's PauseBlendIn (KannagiMoves `hold`; a clip may carry it as `freeze`):
-- the montage sits on its first frame for that long while it blends in from the stance,
-- then plays. The first segment (the blend into the first frame) lasts the freeze and the
-- remaining windup segments share what is left of the windup, so a boss's frozen tell holds
-- still instead of the whole windup playing in slow motion; impact still lands on hitAt.
function Animator.play(model: Model, clipName: string, windup: number?, freeze: number?)
	local state = states[model]
	local clip = ClipLibrary.Clips[clipName]
	if not state or not clip then
		return
	end

	-- The strike is the first timed segment after the last windup segment; impact lands
	-- partway through it, so the windup ends that much before hitAt.
	local strikeLead = 0
	for i, segment in if clip.baked then {} else clip.segments do
		if segment.duration == "windup" then
			local nextSegment = clip.segments[i + 1]
			local strike = if nextSegment and typeof(nextSegment.duration) == "number" then nextSegment.duration else 0
			strikeLead = strike * ClipLibrary.ImpactFraction
		end
	end
	if clip.baked then
		strikeLead = clip.impactLead or 0 -- mid-cut lands on hitAt (see Clips.impactLead)
	end
	local windupTime = math.max((windup or 0.3) - strikeLead, 0.04)

	-- The frozen first frame. With a windup it takes the first segment and the rest of the
	-- windup segments stretch over what remains (never under 30% of the windup); without
	-- one it simply delays the clip.
	local hold = freeze or clip.freeze or 0
	hold = if hold == hold and hold > 0 then hold else 0 -- (NaN guard)
	local firstShare, totalShare, windups = 0, 0, 0
	for _, segment in clip.segments do
		if segment.duration == "windup" then
			windups += 1
			local share = segment.share or 1
			totalShare += share
			if windups == 1 then
				firstShare = share
			end
		end
	end
	local firstWindup: number? = nil
	local restScale = 1
	if hold > 0 and windups >= 2 and totalShare > firstShare then
		local first = math.max(math.min(hold, windupTime * 0.7), windupTime * firstShare)
		firstWindup = first
		restScale = (windupTime - first) / (windupTime * (totalShare - firstShare))
	end

	local keys: { Key } = {}
	local at = if windups == 0 then hold else 0
	local impactAt = 0
	local seenWindup = false
	for _, segment in clip.segments do
		local duration = segment.duration
		local isWindup = duration == "windup"
		if isWindup then
			local share = segment.share or 1
			if firstWindup and not seenWindup then
				duration = firstWindup
			else
				-- No per-segment floor beyond a millisecond: a dense bake has many keys a few ms
				-- apart, and a 20 ms floor used to stretch the windup past the server's hit.
				duration = math.max(windupTime * share * (if firstWindup then restScale else 1), 0.001)
			end
			seenWindup = true
		end
		at += duration :: number
		if isWindup then
			impactAt = at + strikeLead
		end
		table.insert(keys, {
			at = at,
			pose = poseFrames[segment.pose],
			ease = segment.ease or "linear",
			trail = segment.trail == true,
		})
	end

	if Animator.traceModel == model then
		local previous = state.action
		table.insert(Animator.traceLog, {
			c = os.clock(),
			play = clipName,
			windup = windup,
			prev = previous and previous.name,
			prevT = previous and previous.t,
			src = debug.traceback("", 2),
		})
	end
	-- Replacing a clip still on screen (a chained swing, a reaction cutting in): the new clip
	-- starts from the pose being shown, not the stance, and the old one plays on underneath
	-- for a short crossfade.
	local replaced = state.action
	local from: PoseFrames? = nil
	if replaced and not Animator.legacyChain then
		from = {}
		local inverse = 1 / state.scale
		for joint, cf in state.written do
			(from :: PoseFrames)[joint] = if state.scale == 1 then cf else cf.Rotation + cf.Position * inverse
		end
		state.previous = replaced
		state.crossT = 0
	else
		state.previous = nil
	end
	state.action = {
		name = clipName,
		twoHanded = clip.twoHanded == true,
		keys = keys,
		hold = clip.hold or 0,
		fadeOut = clip.fadeOut or 0.2,
		t = 0,
		impactAt = impactAt,
		rate = 1,
		from = from,
		fromGrip = state.grip,
	}
end

-- The server confirmed the clip that's already playing (a predicted swing) with a slightly
-- different hit time: speed it up or slow it down from where it is so the strike still lands
-- `windup` seconds from now, instead of restarting it. False when that clip isn't in its windup.
function Animator.retime(model: Model, clipName: string, windup: number): boolean
	local state = states[model]
	local action = state and state.action
	if not action or action.name ~= clipName or action.t >= action.impactAt or Animator.legacyChain then
		return false
	end
	local left = action.impactAt - action.t
	action.rate = math.clamp(left / math.max(windup, 1e-3), 0.5, 2.5)
	return true
end

-- Fades the current clip out early (feints, interrupts).
function Animator.stop(model: Model)
	local state = states[model]
	local action = state and state.action
	if action then
		local last = action.keys[#action.keys]
		action.t = math.max(action.t, last.at + action.hold)
	end
end

-- Holds the current clip's last pose for at least `seconds` (a boss's death anim stays down).
function Animator.holdLast(model: Model, seconds: number)
	local state = states[model]
	local action = state and state.action
	if action then
		action.hold = math.max(action.hold, seconds)
	end
end

function Animator.current(model: Model): string?
	local state = states[model]
	return state and state.action and state.action.name
end

-- Freezes the clip playing right now for a moment so impacts read as heavy. Clips started
-- during the freeze, and windups, keep playing (see step).
function Animator.hitstop(model: Model, duration: number)
	local state = states[model]
	if state then
		if state.action ~= state.frozenAction or os.clock() >= state.freezeUntil then
			state.frozenAction = state.action
		end
		state.freezeUntil = math.max(state.freezeUntil, os.clock() + duration)
	end
end

-- Holds whatever is playing, windup or not, for `duration` (Studio review tooling).
function Animator.freeze(model: Model, duration: number)
	local state = states[model]
	if state then
		state.pinned = true
		state.freezeUntil = os.clock() + duration
	end
end

-- Ends any freeze immediately (tooling).
function Animator.unfreeze(model: Model)
	local state = states[model]
	if state then
		state.freezeUntil = 0
		state.pinned = false
	end
end

-- Nothing left to pose: no stance, no clip, and the footwork has handed the body to Roblox.
local function idle(state: State): boolean
	return state.baseTarget == nil
		and next(state.base) == nil
		and state.action == nil
		and state.previous == nil
		and state.loco < 1e-3
		and state.grip < 1e-3
end

-- Studio A/B of the carries: workspace attribute CarryMode ("Back", "Low", "Flat", "Raised")
-- swaps Poses.Relaxed live; CarrySpec ("ux uy uz fx fy fz bx by bz ex ey ez": upper arm,
-- forearm, blade and edge directions in Poses' upper-torso space) tunes one, moving as CarryMode
-- (or Back) says.
local shippedRelaxed = poseFrames.Relaxed
local carryKey: string? = nil
local function studioCarry()
	local mode = workspace:GetAttribute("CarryMode")
	local spec = workspace:GetAttribute("CarrySpec")
	local key = `{mode}|{spec}`
	if key == carryKey then
		return
	end
	carryKey = key
	local name = if typeof(mode) == "string" and CARRIES[mode] then mode else (Poses :: any).carry
	local pose = poseFrames["Carry." .. name] or shippedRelaxed
	if typeof(spec) == "string" then
		local n = {}
		for word in spec:gmatch("[^%s,]+") do
			table.insert(n, tonumber(word) or 0)
		end
		if #n == 12 then
			local function d(i: number): Vector3
				return Vector3.new(n[i], n[i + 1], n[i + 2]).Unit
			end
			pose = (Poses :: any).compile({ RightArm = { upper = d(1), fore = d(4), blade = d(7), edge = d(10) } })
		end
	end
	carry = CARRIES[name] or CARRIES.Back
	poseFrames.Relaxed = pose
	for _, state in states do
		if state.baseName == "Relaxed" then
			state.baseTarget = pose
		end
	end
end

function Animator.start()
	local studio = RunService:IsStudio()
	RunService.PreSimulation:Connect(function(dt)
		if studio then
			local mode = workspace:GetAttribute("GaitMode") -- Studio A/B (see Shared/Gait)
			if mode == "hybrid" or mode == "procedural" then
				Gait.Mode = mode
			end
			studioCarry()
		end
		local camera = workspace.CurrentCamera
		local eye = if camera then camera.CFrame.Position else nil
		local clock = os.clock()
		for model, state in states do
			if not model.Parent then
				state.orphanedAt = state.orphanedAt or clock
				if clock - (state.orphanedAt :: number) > ORPHAN_TIME then
					states[model] = nil -- (old characters parented to nil, never destroyed)
					refreshGroundFilter()
				end
				continue
			end
			state.orphanedAt = nil
			if state.jointsDirty then
				state.joints = findJoints(model)
				state.jointsDirty = false
			end
			local humanoid = model:FindFirstChildOfClass("Humanoid")
			if humanoid and humanoid.Health <= 0 and idle(state) then
				table.clear(state.written) -- (the next full step starts from Roblox's pose)
				continue
			end
			local root = model.PrimaryPart
			local stepDt = dt
			if eye and root and (root.Position - eye).Magnitude > LOD_RANGE then
				state.lodDt += dt
				if state.lodDt < 1 / LOD_RATE then
					-- Far away: hold the last pose (Roblox's Animator may have written its own since).
					for name, joint in state.joints do
						local cf = state.written[name]
						if cf then
							joint.Transform = cf
						end
					end
					continue
				end
				stepDt = state.lodDt
			end
			state.lodDt = 0
			step(state, stepDt)
		end
	end)
end

return Animator
