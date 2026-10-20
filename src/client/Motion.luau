--!strict
-- The only way the client pushes its own character around (dashes and attack lunges).
-- One push at a time: a new one replaces the old, so two constraints never fight. Force
-- is capped, so a collision can never be "solved" by launching the character, and a
-- safety net clamps any runaway upward velocity that sneaks in some other way.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer

local MAX_FORCE = 4e4 -- plenty to move a character, nowhere near enough to fling one
local MAX_UPWARD_SPEED = 70 -- a normal jump is ~50

local Motion = {}

local active: LinearVelocity? = nil

local function rootOf(): BasePart?
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
end

-- Moves the character along the ground at `velocity` (y ignored) for `duration` seconds.
function Motion.push(velocity: Vector3, duration: number)
	local root = rootOf()
	local attachment = root and root:FindFirstChild("RootAttachment")
	if not root or not attachment or not attachment:IsA("Attachment") then
		return
	end
	if active then
		active:Destroy()
	end

	local push = Instance.new("LinearVelocity")
	push.Name = "CombatMotion"
	push.Attachment0 = attachment
	push.RelativeTo = Enum.ActuatorRelativeTo.World
	push.VelocityConstraintMode = Enum.VelocityConstraintMode.Plane
	push.PrimaryTangentAxis = Vector3.xAxis
	push.SecondaryTangentAxis = Vector3.zAxis
	push.PlaneVelocity = Vector2.new(velocity.X, velocity.Z)
	push.MaxForce = MAX_FORCE
	push.Parent = root
	active = push

	task.delay(duration, function()
		if active == push then
			active = nil
		end
		push:Destroy()
	end)
end

function Motion.start()
	RunService.PostSimulation:Connect(function()
		local root = rootOf()
		if root then
			local v = root.AssemblyLinearVelocity
			if v.Y > MAX_UPWARD_SPEED then
				root.AssemblyLinearVelocity = Vector3.new(v.X, 0, v.Z)
			end
		end
	end)
end

return Motion
