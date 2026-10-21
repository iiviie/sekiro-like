--!strict
-- Procedural animator: layers hand-authored poses on top of the Roblox locomotion
-- animations by writing joint Transforms every RunService.PreSimulation, after the
-- Animator has written its own. Works with both Motor6D and AnimationConstraint rigs.
--
-- Two layers per character:
--   base   a held stance (Ready, Guard, Broken) that blends smoothly when it changes
--   action a one-shot clip (a swing, a recoil) that fades in over its first segment
--          and back out to the base stance when it ends
-- Joints a pose doesn't mention keep whatever the locomotion animation gave them.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

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
}

local BASE_BLEND_RATE = 14
local MOVE_BLEND_RATE = 10
local MOVING_SPEED = 2.5 -- studs/s
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

	local root = state.model:FindFirstChild("HumanoidRootPart")
	local velocity = if root and root:IsA("BasePart") then root.AssemblyLinearVelocity else Vector3.zero
	local moving = if Vector3.new(velocity.X, 0, velocity.Z).Magnitude > MOVING_SPEED then 1 else 0
	state.move += (moving - state.move) * (1 - math.exp(-dt * MOVE_BLEND_RATE))
	local legsKept = 1 - state.move

	local function layer(result: CFrame, name: string, pose: { [string]: Weighted }?): CFrame
		local layered = pose and pose[name]
		if layered then
			local w = if LOWER_BODY[name] then layered.w * legsKept else layered.w
			return result:Lerp(scaled(layered.cf, state.scale), w)
		end
		return result
	end

	local results: { [string]: CFrame } = {}
	for name, joint in state.joints do
		local current = joint.Transform
		-- If the Animator didn't rewrite this joint since our last write, start from
		-- what it was before we touched it, so overrides don't compound frame to frame.
		if state.written[name] == current then
			current = state.source[name]
		end
		state.source[name] = current

		local result = current
		local base = state.base[name]
		if base then
			result = result:Lerp(scaled(base.cf, state.scale), base.w)
		end
		local layered = layer(result, name, actionPose)
		if previousPose then
			layered = layer(result, name, previousPose):Lerp(layered, cross)
		end
		results[name] = layered
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
	}
	states[model] = state
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

function Animator.start()
	RunService.PreSimulation:Connect(function(dt)
		for model, state in states do
			if model.Parent then
				if state.jointsDirty then
					state.joints = findJoints(model)
					state.jointsDirty = false
				end
				step(state, dt)
			end
		end
	end)
end

return Animator
