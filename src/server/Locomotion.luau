--!strict
-- Gives every fighter Roblox's Ninja animation pack for idle, run, jump and fall.
-- Players get it through their character's Animate script. Bots run on the server, where
-- that LocalScript doesn't, so their tracks are played directly here.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Assets = require(ReplicatedStorage.Shared.Assets)

local ANIMS = Assets.Locomotion

-- Animate script folders and the Animation objects inside them.
local ANIMATE_SLOTS: { [string]: { [string]: string } } = {
	idle = { Animation1 = ANIMS.Idle, Animation2 = ANIMS.IdleAlt },
	walk = { WalkAnim = ANIMS.Walk },
	run = { RunAnim = ANIMS.Run },
	jump = { JumpAnim = ANIMS.Jump },
	fall = { FallAnim = ANIMS.Fall },
	climb = { ClimbAnim = ANIMS.Climb },
}

local Locomotion = {}

-- Points the character's Animate script at the pack; the script reloads on change.
-- Roblox writes the avatar's own animation set in while the appearance loads, so call
-- this only after the appearance has loaded or it gets overwritten.
function Locomotion.applyToPlayer(character: Model)
	local animate = character:FindFirstChild("Animate")
	if not animate then
		return
	end
	for slot, animations in ANIMATE_SLOTS do
		local folder = animate:FindFirstChild(slot)
		if folder then
			for name, id in animations do
				local animation = folder:FindFirstChild(name)
				if animation and animation:IsA("Animation") then
					animation.AnimationId = id
				end
			end
		end
	end
end

function Locomotion.animateBot(humanoid: Humanoid)
	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = humanoid
	end

	local function load(id: string, priority: Enum.AnimationPriority): AnimationTrack?
		local animation = Instance.new("Animation")
		animation.AnimationId = id
		local ok, track = pcall(function()
			return (animator :: Animator):LoadAnimation(animation)
		end)
		if not ok or not track then
			return nil
		end
		track.Priority = priority
		return track
	end

	local idle = load(ANIMS.Idle, Enum.AnimationPriority.Idle)
	local run = load(ANIMS.Run, Enum.AnimationPriority.Movement)
	local jump = load(ANIMS.Jump, Enum.AnimationPriority.Movement)
	local fall = load(ANIMS.Fall, Enum.AnimationPriority.Movement)
	if idle then
		idle.Looped = true
		idle:Play()
	end

	humanoid.Running:Connect(function(speed)
		if not run then
			return
		end
		if speed > 0.5 then
			if not run.IsPlaying then
				run:Play(0.15)
			end
			run:AdjustSpeed(math.clamp(speed / 16, 0.4, 1.4))
		elseif run.IsPlaying then
			run:Stop(0.2)
		end
	end)

	humanoid.StateChanged:Connect(function(_, state)
		if state == Enum.HumanoidStateType.Jumping and jump then
			jump:Play(0.1)
		elseif state == Enum.HumanoidStateType.Freefall and fall then
			fall:Play(0.2)
		elseif state == Enum.HumanoidStateType.Landed then
			if fall then
				fall:Stop(0.15)
			end
			if jump then
				jump:Stop(0.15)
			end
		end
	end)
end

return Locomotion
