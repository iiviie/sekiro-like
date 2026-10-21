--!strict
-- Locomotion feel for your own character. The client owns its character's physics, so
-- speed is decided here, every frame, the instant your state changes, instead of waiting
-- a round trip for the server to change WalkSpeed:
--   * starting from a standstill ramps up from StartFraction of full speed (~0.15 s)
--   * slowing for a guard or a sip blends instead of snapping; a swing stops you (its
--     lunge is the only movement), and jumping is off until you're free again
-- The server sets WalkSpeed only for bots.
-- It also keeps your body out of other fighters' (Shared/Spacing, Kannagi's capsules): after
-- each physics step you're moved out of anyone you overlap in your fight, so you stop at
-- their body and slide around it instead of walking into it. Dashes pass through.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage.Shared.Config)
local Spacing = require(ReplicatedStorage.Shared.Spacing)
local LocalCombat = require(script.Parent.LocalCombat)

local player = Players.LocalPlayer
local MOVE = Config.Movement

local Movement = {}

local speed = 0
local wasMoving = false

local function targetSpeed(character: Model): number
	local state = character:GetAttribute("CombatState")
	if state == "Dead" or state == "Downed" then
		return 0
	elseif state == "Broken" then
		return Config.BrokenWalkSpeed
	elseif state == "Windup" or state == "Recovery" or LocalCombat.swinging(character) then
		-- A swing is committed (Kannagi's RunStop): only its lunge moves you.
		return Config.AttackWalkSpeed
	elseif state == "Staggered" then
		return Config.StaggerWalkSpeed
	elseif state == "Drinking" then
		return Config.DrinkWalkSpeed
	elseif LocalCombat.blocking or character:GetAttribute("Blocking") then
		return Config.BlockWalkSpeed
	end
	return Config.WalkSpeed
end

-- Your share of an overlap: all of it against a bot or boss (the server never pushes them
-- into you), half against another player (their client takes the other half).
local function share(other: Model): number
	return if Players:GetPlayerFromCharacter(other) then 0.5 else 1
end

local function separate()
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not character or not root or not root:IsA("BasePart") or not Spacing.solid(character) then
		return
	end
	-- The server's Dodging state arrives a ping late: our own dash passes through at once.
	if workspace:GetServerTimeNow() - LocalCombat.dodgeAt < Config.Dodge.Duration then
		return
	end
	local push = Spacing.separation(character, root.Position, share)
	if push.Magnitude > 1e-3 then
		root.CFrame += push
		local v = root.AssemblyLinearVelocity
		local out = push.Unit
		local into = v:Dot(out)
		if into < 0 then
			root.AssemblyLinearVelocity = v - out * into
		end
	end
end

function Movement.start()
	RunService.PostSimulation:Connect(separate)
	RunService.PreSimulation:Connect(function(dt)
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if not character or not humanoid or humanoid.Health <= 0 then
			return
		end
		local target = targetSpeed(character)
		local moving = humanoid.MoveDirection.Magnitude > 0.05
		if moving and not wasMoving then
			speed = math.min(speed, target * MOVE.StartFraction) -- push off from standstill
		end
		wasMoving = moving
		local rate = if speed < target then MOVE.Acceleration elseif target <= 0 then MOVE.StopBlend else MOVE.SpeedBlend
		speed += (target - speed) * (1 - math.exp(-dt * rate))
		if not moving then
			speed = math.min(speed, target * MOVE.StartFraction)
		end
		humanoid.WalkSpeed = speed
		-- No jumping out of a swing, a flinch or a sip: the press waits in CombatInput's
		-- buffer and fires the frame this turns back on.
		local canJump = LocalCombat.canAct(character, "Jump")
		if humanoid:GetStateEnabled(Enum.HumanoidStateType.Jumping) ~= canJump then
			humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, canJump)
		end
	end)
end

return Movement
