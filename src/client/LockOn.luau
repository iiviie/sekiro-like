--!strict
-- Sekiro-style lock-on: picks the enemy nearest the centre of the screen, keeps a
-- reticle on them, and drives an over-the-shoulder camera that frames both fighters.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage.Shared.Config)
local Types = require(ReplicatedStorage.Shared.Types)

local player = Players.LocalPlayer
local settings = Config.LockOn

local LockOn = {}

local target: Model? = nil
local reticle: BillboardGui? = nil

local function rootOf(model: Model?): BasePart?
	local root = model and model:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
end

local function isValid(model: Model?, maxDistance: number): boolean
	if not model or not model.Parent or model:GetAttribute("CombatState") == "Dead" then
		return false
	end
	local mine, theirs = rootOf(player.Character), rootOf(model)
	return mine ~= nil and theirs ~= nil and (theirs.Position - mine.Position).Magnitude <= maxDistance
end

local function makeReticle(model: Model): BillboardGui?
	local torso = model:FindFirstChild("UpperTorso") or rootOf(model)
	if not torso or not torso:IsA("BasePart") then
		return nil
	end
	local gui = Instance.new("BillboardGui")
	gui.Name = "LockOnReticle"
	gui.Adornee = torso
	gui.AlwaysOnTop = true
	gui.Size = UDim2.fromOffset(18, 18)

	local dot = Instance.new("Frame")
	dot.AnchorPoint = Vector2.new(0.5, 0.5)
	dot.Position = UDim2.fromScale(0.5, 0.5)
	dot.Size = UDim2.fromOffset(10, 10)
	dot.Rotation = 45
	dot.BackgroundColor3 = Color3.fromRGB(255, 240, 220)
	dot.BorderSizePixel = 0
	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(150, 20, 20)
	stroke.Thickness = 2
	stroke.Parent = dot
	dot.Parent = gui

	gui.Parent = player:WaitForChild("PlayerGui")
	return gui
end

-- Best enemy for the camera direction: close to screen centre, then close in distance.
function LockOn.findBest(maxDistance: number): Model?
	local character = player.Character
	local mine = rootOf(character)
	if not mine then
		return nil
	end
	local look = workspace.CurrentCamera.CFrame.LookVector
	local facing = Vector3.new(look.X, 0, look.Z)
	facing = if facing.Magnitude > 1e-3 then facing.Unit else mine.CFrame.LookVector

	local best: Model? = nil
	local bestScore = -math.huge
	for _, instance in CollectionService:GetTagged(Types.Tag) do
		if instance ~= character and instance:IsA("Model") and isValid(instance, maxDistance) then
			local theirs = rootOf(instance) :: BasePart
			local offset = theirs.Position - mine.Position
			local flat = Vector3.new(offset.X, 0, offset.Z)
			local distance = flat.Magnitude
			if distance > 0.1 then
				local score = flat.Unit:Dot(facing) * 2 - distance / maxDistance
				if score > bestScore then
					best, bestScore = instance, score
				end
			end
		end
	end
	return best
end

function LockOn.target(): Model?
	return target
end

function LockOn.set(model: Model?)
	if reticle then
		reticle:Destroy()
		reticle = nil
	end
	target = model
	local camera = workspace.CurrentCamera
	if model then
		reticle = makeReticle(model)
		camera.CameraType = Enum.CameraType.Scriptable
	else
		camera.CameraType = Enum.CameraType.Custom
	end
end

function LockOn.toggle()
	if target then
		LockOn.set(nil)
	else
		LockOn.set(LockOn.findBest(settings.Range))
	end
end

local function updateCamera(dt: number)
	if not target then
		return
	end
	if not isValid(target, settings.BreakRange) then
		LockOn.set(nil)
		return
	end
	local mine, theirs = rootOf(player.Character), rootOf(target)
	if not mine or not theirs then
		return
	end

	local offset = theirs.Position - mine.Position
	local flat = Vector3.new(offset.X, 0, offset.Z)
	local forward = if flat.Magnitude > 0.1 then flat.Unit else mine.CFrame.LookVector
	local right = forward:Cross(Vector3.yAxis)

	local eye = mine.Position
		- forward * settings.CameraDistance
		+ Vector3.yAxis * settings.CameraHeight
		+ right * settings.CameraShoulder
	local focus = mine.Position:Lerp(theirs.Position, 0.55) + Vector3.yAxis * 1.2
	local camera = workspace.CurrentCamera
	local alpha = 1 - math.exp(-dt * settings.CameraSmoothing)
	camera.CFrame = camera.CFrame:Lerp(CFrame.lookAt(eye, focus), alpha)
end

function LockOn.start()
	RunService:BindToRenderStep("SekiroLockOn", Enum.RenderPriority.Camera.Value + 1, updateCamera)
	player.CharacterAdded:Connect(function()
		LockOn.set(nil)
	end)
end

return LockOn
