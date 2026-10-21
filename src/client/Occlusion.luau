--!strict
-- Fighters pass through each other, so an opponent often ends up between the camera and
-- your own character and blots out the screen. Anyone standing in that line, or right on
-- top of the camera, fades out on your screen only (LocalTransparencyModifier) until they
-- step clear. Their blade stays visible enough to read a swing.
-- Locked on at contact range your own body can hide the target's torso from the camera behind
-- you; then your body (not your blade) fades to SELF_FADE until the target is in clear view.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Types = require(ReplicatedStorage.Shared.Types)
local LockOn = require(script.Parent.LockOn)

local player = Players.LocalPlayer

local FADE = 0.72 -- how see-through an occluding fighter becomes
local NEAR_CAMERA = 4.5 -- studs: anyone this close to the lens fades
local LINE_RADIUS = 2.4 -- studs from the camera-to-you line that counts as "in the way"
local RATE = 14 -- fade speed
local SELF_FADE = 0.55 -- how see-through your own body gets while it hides your lock-on target

local Occlusion = {}

local faded: { [Model]: number } = {}
local parts: { [Model]: { BasePart | Decal } } = {}

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
	model.DescendantAdded:Once(function()
		parts[model] = nil
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
local selfParams = RaycastParams.new()
selfParams.FilterType = Enum.RaycastFilterType.Include

-- Whether our own body stands between the camera and the target's head or chest.
local function hidesTarget(character: Model, target: Model, from: Vector3): boolean
	local body = {}
	for _, part in partsOf(character) do
		if part:IsA("BasePart") and part.Name ~= "Sword" and part.Name ~= "Sword2" then
			table.insert(body, part)
		end
	end
	selfParams.FilterDescendantsInstances = body
	for _, name in { "UpperTorso", "Head" } do
		local part = target:FindFirstChild(name)
		if part and part:IsA("BasePart") and workspace:Raycast(from, part.Position - from, selfParams) then
			return true
		end
	end
	return false
end

local function fadeSelf(character: Model, from: Vector3, dt: number)
	local target = LockOn.target()
	local goal = if target and target.Parent and hidesTarget(character, target, from) then SELF_FADE else 0
	if goal == 0 and selfFade == 0 then
		return -- nothing to undo: leave the parts to Roblox's own camera
	end
	selfFade += (goal - selfFade) * math.min(1, dt * RATE)
	if math.abs(selfFade - goal) < 0.02 then
		selfFade = goal
	end
	for _, part in partsOf(character) do
		if part.Parent and part.Name ~= "Sword" and part.Name ~= "Sword2" then
			(part :: any).LocalTransparencyModifier = selfFade
		end
	end
end

function Occlusion.start()
	RunService.RenderStepped:Connect(function(dt)
		local camera = workspace.CurrentCamera
		local character = player.Character
		local head = character and character:FindFirstChild("Head")
		if not camera or not head or not head:IsA("BasePart") then
			return
		end
		local from, to = camera.CFrame.Position, head.Position
		fadeSelf(character :: Model, from, dt)
		local alpha = math.min(1, dt * RATE)
		for _, instance in CollectionService:GetTagged(Types.Tag) do
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
		end
	end)
end

return Occlusion
