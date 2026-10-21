--!strict
-- Fighters pass through each other, so an opponent often ends up between the camera and
-- your own character and blots out the screen. Anyone standing in that line, or right on
-- top of the camera, fades out on your screen only (LocalTransparencyModifier) until they
-- step clear. Their blade stays visible enough to read a swing.
-- Locked on at contact range the camera swings round the pair (LockOn) so your own body rarely
-- hides the target; as a last resort, when it hides both their head and their chest, your body
-- (not your blade) fades to SELF_FADE until one of them is in clear view. And when a wall or rock
-- pulls the locked-on camera in close behind you, your body fades out as the lens nears your
-- head (as Roblox's own camera does), so the screen never fills with your hair.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Tagged = require(ReplicatedStorage.Shared.Tagged)
local Types = require(ReplicatedStorage.Shared.Types)
local LockOn = require(script.Parent.LockOn)

local player = Players.LocalPlayer

local FADE = 0.72 -- how see-through an occluding fighter becomes
local NEAR_CAMERA = 4.5 -- studs: anyone this close to the lens fades
local LINE_RADIUS = 2.4 -- studs from the camera-to-you line that counts as "in the way"
local RATE = 14 -- fade speed
local SELF_FADE = 0.55 -- how see-through your own body gets while it hides your lock-on target
-- Locked on, your body fades from NEAR_FAR studs between the lens and your head to NEAR_FADE at
-- NEAR_CLOSE (at once: the camera is pulled in at once too).
local NEAR_FAR = 3.2
local NEAR_CLOSE = 1.6
local NEAR_FADE = 0.92

local Occlusion = {}

local faded: { [Model]: number } = {}
local parts: { [Model]: { BasePart | Decal } } = {}
local bodies: { [Model]: { Instance } } = {} -- partsOf minus the blade (hidesTarget's filter)

local function partsOf(model: Model): { BasePart | Decal }
	local list = parts[model]
	if list then
		return list
	end
	local found: { BasePart | Decal } = {}
	for _, d in model:GetDescendants() do
		if (d:IsA("BasePart") and d.Name ~= "HumanoidRootPart") or d:IsA("Decal") then
			table.insert(found, d :: any)
		end
	end
	parts[model] = found
	-- Only a new part or decal invalidates the list (not every hit sound or kanji billboard).
	local connection: RBXScriptConnection
	connection = model.DescendantAdded:Connect(function(d)
		if d:IsA("BasePart") or d:IsA("Decal") then
			parts[model] = nil
			bodies[model] = nil
			connection:Disconnect()
		end
	end)
	return found
end

local function apply(model: Model, amount: number)
	for _, part in partsOf(model) do
		if part.Parent then
			(part :: any).LocalTransparencyModifier = amount
		end
	end
end

local function blocking(model: Model, from: Vector3, to: Vector3): boolean
	local root = model:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return false
	end
	local p = root.Position
	if (p - from).Magnitude < NEAR_CAMERA then
		return true
	end
	local line = to - from
	local length = line.Magnitude
	if length < 0.1 then
		return false
	end
	local along = (p - from):Dot(line.Unit)
	if along <= 0 or along >= length - 1.5 then
		return false -- behind the camera, or level with / past you
	end
	local closest = from + line.Unit * along
	return (p - closest).Magnitude < LINE_RADIUS
end

local selfFade = 0

-- The sword and everything welded to it (tsuba, pommel, edge line) stay solid.
local function isBlade(part: Instance): boolean
	return part.Name == "Sword"
		or part.Name == "Sword2"
		or part:FindFirstAncestor("Sword") ~= nil
		or part:FindFirstAncestor("Sword2") ~= nil
end
local selfParams = RaycastParams.new()
selfParams.FilterType = Enum.RaycastFilterType.Include
local selfBody: { Instance }? = nil -- the list selfParams filters on

-- Whether our own body stands between the camera and both the target's head and chest.
local function hidesTarget(character: Model, target: Model, from: Vector3): boolean
	local list = partsOf(character)
	local body = bodies[character]
	if not body then
		local built: { Instance } = {}
		for _, part in list do
			if part:IsA("BasePart") and not isBlade(part) then
				table.insert(built, part)
			end
		end
		bodies[character] = built
		body = built
	end
	if body ~= selfBody then
		selfParams.FilterDescendantsInstances = body :: { Instance }
		selfBody = body
	end
	local hidden = 0
	for _, name in { "UpperTorso", "Head" } do
		local part = target:FindFirstChild(name)
		if part and part:IsA("BasePart") then
			if not workspace:Raycast(from, part.Position - from, selfParams) then
				return false
			end
			hidden += 1
		end
	end
	return hidden > 0
end

local function fadeSelf(character: Model, from: Vector3, head: Vector3, dt: number)
	local target = LockOn.target()
	local locked = target ~= nil and target.Parent ~= nil
	local goal = if locked and hidesTarget(character, target :: Model, from) then SELF_FADE else 0
	local near = 0
	if locked then
		near = math.clamp((NEAR_FAR - (from - head).Magnitude) / (NEAR_FAR - NEAR_CLOSE), 0, 1) * NEAR_FADE
		goal = math.max(goal, near)
	end
	if goal == 0 and selfFade == 0 then
		return -- nothing to undo: leave the parts to Roblox's own camera
	end
	if near > selfFade then
		selfFade = near -- the lens is in your hair now: fade now
	end
	selfFade += (goal - selfFade) * math.min(1, dt * RATE)
	if math.abs(selfFade - goal) < 0.02 then
		selfFade = goal
	end
	for _, part in partsOf(character) do
		if part.Parent and not isBlade(part) then
			(part :: any).LocalTransparencyModifier = selfFade
		end
	end
end

function Occlusion.start()
	-- (After the lock-on camera has moved this frame, so the fade matches the frame drawn.)
	RunService:BindToRenderStep("Occlusion", Enum.RenderPriority.Camera.Value + 2, function(dt)
		local camera = workspace.CurrentCamera
		local character = player.Character
		local head = character and character:FindFirstChild("Head")
		if not camera or not head or not head:IsA("BasePart") then
			return
		end
		local from, to = camera.CFrame.Position, head.Position
		fadeSelf(character :: Model, from, to, dt)
		local alpha = math.min(1, dt * RATE)
		for _, instance in Tagged.list(Types.Tag) do
			if instance:IsA("Model") and instance ~= character then
				local goal = if blocking(instance, from, to) then FADE else 0
				local current = faded[instance] or 0
				if current ~= goal then
					local nextValue = current + (goal - current) * alpha
					if math.abs(nextValue - goal) < 0.02 then
						nextValue = goal
					end
					faded[instance] = nextValue
					apply(instance, nextValue)
				end
			end
		end
	end)
	CollectionService:GetInstanceRemovedSignal(Types.Tag):Connect(function(instance)
		if instance:IsA("Model") then
			faded[instance] = nil
			parts[instance] = nil
			bodies[instance] = nil
		end
	end)
end

return Occlusion
