--!strict
-- Locomotion feel for your own character. The client owns its character's physics, so
-- speed is decided here, every frame, the instant your state changes, instead of waiting
-- a round trip for the server to change WalkSpeed:
--   * starting from a standstill ramps up from StartFraction of full speed (~0.15 s)
--   * slowing for a swing, a guard or a sip blends instead of snapping 16 -> 6
-- The server sets WalkSpeed only for bots.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage.Shared.Config)
local LocalCombat = require(script.Parent.LocalCombat)

local player = Players.LocalPlayer
local MOVE = Config.Movement

local Movement = {}

local speed = 0
local wasMoving = false

local function targetSpeed(character: Model): number
	local state = character:GetAttribute("CombatState")
	if state == "Dead" then
		return 0
	elseif state == "Broken" then
		return Config.BrokenWalkSpeed
	elseif
		state == "Windup"
		or state == "Recovery"
		or state == "Staggered"
		or state == "Drinking"
		or os.clock() < LocalCombat.attackingUntil -- our own swing, before the server confirms it
	then
		return Config.AttackWalkSpeed
	elseif LocalCombat.blocking or character:GetAttribute("Blocking") then
		return Config.BlockWalkSpeed
	end
	return Config.WalkSpeed
end

function Movement.start()
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
		local rate = if speed < target then MOVE.Acceleration else MOVE.SpeedBlend
		speed += (target - speed) * (1 - math.exp(-dt * rate))
		if not moving then
			speed = math.min(speed, target * MOVE.StartFraction)
		end
		humanoid.WalkSpeed = speed
	end)
end

return Movement
