--!strict
-- The only way the client pushes its own character around (dashes and attack lunges).
-- `push` holds a constant velocity; `surge` eases one out, which is what dashes and lunges
-- use so they burst and settle rather than start and stop dead.
-- One push at a time: a new one replaces the old, so two constraints never fight. Force
-- is capped, so a collision can never be "solved" by launching the character, and a
-- safety net clamps any runaway upward velocity that sneaks in some other way.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Spacing = require(ReplicatedStorage.Shared.Spacing)

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

-- A push whose speed eases out from `startSpeed` to `endSpeed` over `duration`
-- (quadratic ease-out): a burst that settles into the run instead of stopping dead.
-- It stops at another fighter's body (Shared/Spacing) unless `passThrough` (a dodge).
function Motion.surge(direction: Vector3, startSpeed: number, endSpeed: number, duration: number, passThrough: boolean?)
	local flat = Vector3.new(direction.X, 0, direction.Z)
	if flat.Magnitude < 1e-3 then
		return
	end
	flat = flat.Unit
	Motion.push(flat * startSpeed, duration)
	local push = active
	if not push then
		return
	end
	local startedAt = os.clock()
	local connection: RBXScriptConnection
	connection = RunService.PreSimulation:Connect(function(dt: number)
		if active ~= push then
			connection:Disconnect()
			return
		end
		local u = math.clamp((os.clock() - startedAt) / duration, 0, 1)
		local speed = endSpeed + (startSpeed - endSpeed) * (1 - u) * (1 - u)
		local velocity = flat * speed
		local character = player.Character
		local root = rootOf()
		if not passThrough and character and root then
			velocity = Spacing.limit(character, root.Position, velocity, dt)
		end
		push.PlaneVelocity = Vector2.new(velocity.X, velocity.Z)
		if u >= 1 then
			connection:Disconnect()
		end
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
