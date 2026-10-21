--!strict
-- Pre-fight intro clips (Shared/Intros), keyed in Blender on the R15 rig (art/intros/intros.blend,
-- built and baked by art/intros/build_intros.py into the Poses*, Clips and Props children; this
-- file is hand-written). Registered on demand like BakedBoss, so Animator, Poses and BakedPoses
-- stay untouched:
--   BakedIntros.register()                       -- adds the I.* poses and Intro_<Ref> clips
--   Animator.play(model, "Intro_Iai", nil, wait) -- `wait` holds the clip's first pose that long
--   BakedIntros.flourish("Iai")                  -- a short clip from the intro's best second
-- The clips' left arm is baked (two-hand IK in Blender where the hand is on the hilt), so they
-- play with twoHanded = false.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Decode = require(ReplicatedStorage.Shared.Baked.Decode)

local BakedIntros = {}

local registered = false

BakedIntros.Props = require(script.Props) :: { [string]: any }

function BakedIntros.register()
	if registered then
		return
	end
	registered = true
	local Poses = require(ReplicatedStorage.Shared.Poses) :: any
	local Clips = require(ReplicatedStorage.Shared.Clips) :: any
	for _, child in script:GetChildren() do
		if child:IsA("ModuleScript") and string.sub(child.Name, 1, 5) == "Poses" then
			for name, row in require(child) :: { [string]: { any } } do
				Poses[name] = Decode.pose(row)
			end
		end
	end
	for name, clip in require(script.Clips) :: { [string]: any } do
		Clips.Clips[name] = clip
	end
end

-- A clip made of `ref`'s segments between clip seconds `from` and `to` (blending in over
-- `blend`), registered as "IntroF_<ref>". Returns its name, or nil when the intro is unknown.
function BakedIntros.flourish(ref: string, from: number, to: number, blend: number?): string?
	BakedIntros.register()
	local Clips = require(ReplicatedStorage.Shared.Clips) :: any
	local name = `IntroF_{ref}`
	if Clips.Clips[name] then
		return name
	end
	local clip = Clips.Clips[`Intro_{ref}`]
	if not clip then
		return nil
	end
	local segments = {}
	local t = 0
	for _, segment in clip.segments do
		t += segment.duration
		if t >= from - 1e-3 and t <= to + 1e-3 then
			table.insert(segments, {
				pose = segment.pose,
				duration = if #segments == 0 then blend or 0.16 else segment.duration,
				ease = if #segments == 0 then "inOut" else segment.ease,
			})
		end
	end
	if #segments == 0 then
		return nil
	end
	Clips.Clips[name] = { segments = segments, hold = 0.05, fadeOut = 0.3, twoHanded = false }
	return name
end

return BakedIntros
