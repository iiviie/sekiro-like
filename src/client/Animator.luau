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
local ClipLibrary = require(ReplicatedStorage.Shared.Clips)

type Clip = ClipLibrary.Clip
type Ease = ClipLibrary.Ease
type PoseFrames = { [string]: CFrame }
type Weighted = { cf: CFrame, w: number }

type Key = { at: number, pose: PoseFrames, ease: Ease, trail: boolean }

type Action = {
	name: string,
	keys: { Key },
	hold: number,
	fadeOut: number,
	t: number,
}

type State = {
	model: Model,
	joints: { [string]: any }, -- Motor6D or AnimationConstraint; both expose Transform
	jointsDirty: boolean, -- joints replicate (and get rebuilt) after the model, so rescan on change
	base: { [string]: Weighted },
	baseTarget: PoseFrames?,
	action: Action?,
	freezeUntil: number,
	written: { [string]: CFrame },
	source: { [string]: CFrame },
}

local BASE_BLEND_RATE = 14

local Animator = {}

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

-- Samples the action layer. Returns nil once the clip has fully faded out.
local function sampleAction(action: Action): ({ [string]: Weighted }?, boolean)
	local keys = action.keys
	local t = action.t
	local out: { [string]: Weighted } = {}

	local first = keys[1]
	if t <= first.at then
		blendInto(out, nil, first.pose, ease(first.ease, t / math.max(first.at, 1e-3)), 1)
		return out, first.trail
	end
	for i = 2, #keys do
		local key = keys[i]
		if t <= key.at then
			local previous = keys[i - 1]
			local alpha = ease(key.ease, (t - previous.at) / math.max(key.at - previous.at, 1e-3))
			blendInto(out, previous.pose, key.pose, alpha, 1)
			return out, key.trail
		end
	end

	local last = keys[#keys]
	local after = t - last.at - action.hold
	if after <= 0 then
		blendInto(out, nil, last.pose, 1, 1)
		return out, false
	end
	if after >= action.fadeOut then
		return nil, false
	end
	blendInto(out, nil, last.pose, 1, 1 - ease("inOut", after / action.fadeOut))
	return out, false
end

-- Trails are colour-coded by what's swinging: steel-white for slashes, red for perilous.
local STEEL_TRAIL = ColorSequence.new(Color3.fromRGB(255, 255, 255), Color3.fromRGB(170, 200, 255))
local PERIL_TRAIL = ColorSequence.new(Color3.fromRGB(255, 90, 70), Color3.fromRGB(200, 20, 20))

local function setTrail(model: Model, enabled: boolean, clipName: string?)
	local sword = model:FindFirstChild("Sword")
	local trail = sword and sword:FindFirstChildOfClass("Trail")
	if trail and trail.Enabled ~= enabled then
		if enabled then
			local perilous = clipName == "Perilous" or clipName == "Sweep"
			trail.Color = if perilous then PERIL_TRAIL else STEEL_TRAIL
		end
		trail.Enabled = enabled
	end
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
	local actionPose: { [string]: Weighted }? = nil
	local trailOn = false
	local action = state.action
	if action then
		if os.clock() >= state.freezeUntil then
			action.t += dt
		end
		actionPose, trailOn = sampleAction(action)
		if not actionPose then
			state.action = nil
		end
	end
	setTrail(state.model, trailOn, action and action.name)

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
			result = result:Lerp(base.cf, base.w)
		end
		local layered = actionPose and actionPose[name]
		if layered then
			result = result:Lerp(layered.cf, layered.w)
		end
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
		action = nil,
		freezeUntil = 0,
		written = {},
		source = {},
	}
	states[model] = state

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
	end
end

-- Plays a clip from Clips.luau. `windup` is the time until impact, used to stretch
-- the clip's "windup" segment so the strike lands on the server's hitAt.
function Animator.play(model: Model, clipName: string, windup: number?)
	local state = states[model]
	local clip = ClipLibrary.Clips[clipName]
	if not state or not clip then
		return
	end

	-- The strike is the first timed segment after the last windup segment; impact lands
	-- partway through it, so the windup ends that much before hitAt.
	local strikeLead = 0
	for i, segment in clip.segments do
		if segment.duration == "windup" then
			local nextSegment = clip.segments[i + 1]
			local strike = if nextSegment and typeof(nextSegment.duration) == "number" then nextSegment.duration else 0
			strikeLead = strike * ClipLibrary.ImpactFraction
		end
	end
	local windupTime = math.max((windup or 0.3) - strikeLead, 0.04)

	local keys: { Key } = {}
	local at = 0
	for _, segment in clip.segments do
		local duration = segment.duration
		if duration == "windup" then
			duration = math.max(windupTime * (segment.share or 1), 0.02)
		end
		at += duration :: number
		table.insert(keys, {
			at = at,
			pose = poseFrames[segment.pose],
			ease = segment.ease or "linear",
			trail = segment.trail == true,
		})
	end

	state.action = {
		name = clipName,
		keys = keys,
		hold = clip.hold or 0,
		fadeOut = clip.fadeOut or 0.2,
		t = 0,
	}
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

function Animator.current(model: Model): string?
	local state = states[model]
	return state and state.action and state.action.name
end

-- Freezes the clip for a moment so impacts read as heavy.
function Animator.hitstop(model: Model, duration: number)
	local state = states[model]
	if state then
		state.freezeUntil = math.max(state.freezeUntil, os.clock() + duration)
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
