--!strict
-- Local-only feedback: sword poses, telegraphs, sparks, floating text and camera shake.
-- Everything here is cosmetic; outcomes come from the server's CombatEvent broadcasts.

local CollectionService = game:GetService("CollectionService")
local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Config = require(ReplicatedStorage.Shared.Config)
local SwordPoses = require(ReplicatedStorage.Shared.SwordPoses)
local Types = require(ReplicatedStorage.Shared.Types)

local combatEvent = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("CombatEvent") :: RemoteEvent
local player = Players.LocalPlayer

local GOLD = Color3.fromRGB(255, 214, 110)
local SPARK = Color3.fromRGB(255, 190, 90)
local BLOOD = Color3.fromRGB(190, 20, 30)
local STEEL = Color3.fromRGB(190, 195, 205)

local CombatVisuals = {}

-- Bumped whenever a model's pose changes so stale delayed tweens can bail out.
local poseTokens: { [Model]: number } = {}

local function now(): number
	return workspace:GetServerTimeNow()
end

local function getSword(model: Model): (BasePart?, Weld?)
	local sword = model:FindFirstChild("Sword")
	if not sword or not sword:IsA("BasePart") then
		return nil, nil
	end
	local weld = sword:FindFirstChild("SwordGrip")
	return sword, if weld and weld:IsA("Weld") then weld else nil
end

local function tweenPose(model: Model, pose: CFrame, duration: number): number
	local token = (poseTokens[model] or 0) + 1
	poseTokens[model] = token
	local _, weld = getSword(model)
	if weld then
		local info = TweenInfo.new(math.max(duration, 0.01), Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		TweenService:Create(weld, info, { C0 = pose }):Play()
	end
	return token
end

local function restingPose(model: Model): CFrame
	if model:GetAttribute("CombatState") == "Broken" then
		return SwordPoses.Broken
	elseif model:GetAttribute("Blocking") then
		return SwordPoses.Guard
	end
	return SwordPoses.Rest
end

local function settle(model: Model)
	tweenPose(model, restingPose(model), 0.15)
	local sword = getSword(model)
	if sword then
		sword.Color = Config.Visual.SwordColor
		sword.Material = Enum.Material.Metal
	end
end

local function floatingText(model: Model, text: string, color: Color3, scale: number?)
	local head = model:FindFirstChild("Head")
	if not head or not head:IsA("BasePart") then
		return
	end
	local size = scale or 1

	local gui = Instance.new("BillboardGui")
	gui.Adornee = head
	gui.AlwaysOnTop = true
	gui.Size = UDim2.fromOffset(220 * size, 50 * size)
	gui.StudsOffset = Vector3.new(0, 3, 0)
	gui.MaxDistance = 120

	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Enum.Font.GothamBlack
	label.Text = text
	label.TextColor3 = color
	label.TextScaled = true
	label.TextStrokeTransparency = 0.3
	label.Parent = gui
	gui.Parent = player:WaitForChild("PlayerGui")

	local info = TweenInfo.new(0.7, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	TweenService:Create(gui, info, { StudsOffset = Vector3.new(0, 4.5, 0) }):Play()
	TweenService:Create(label, info, { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
	Debris:AddItem(gui, 0.8)
end

local function burst(position: Vector3, color: Color3, count: number, speed: number)
	local anchor = Instance.new("Part")
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.Transparency = 1
	anchor.Size = Vector3.one * 0.2
	anchor.CFrame = CFrame.new(position)

	local emitter = Instance.new("ParticleEmitter")
	emitter.Color = ColorSequence.new(color)
	emitter.LightEmission = 1
	emitter.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.35), NumberSequenceKeypoint.new(1, 0) })
	emitter.Speed = NumberRange.new(speed * 0.5, speed)
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.Lifetime = NumberRange.new(0.15, 0.35)
	emitter.Drag = 6
	emitter.Rate = 0
	emitter.Parent = anchor

	local light = Instance.new("PointLight")
	light.Color = color
	light.Brightness = 4
	light.Range = 10
	light.Parent = anchor

	anchor.Parent = workspace
	emitter:Emit(count)
	TweenService:Create(light, TweenInfo.new(0.25), { Brightness = 0 }):Play()
	Debris:AddItem(anchor, 1)
end

local function contactPoint(a: Model, b: Model): Vector3?
	local rootA = a:FindFirstChild("HumanoidRootPart") :: BasePart?
	local rootB = b:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not rootA or not rootB then
		return nil
	end
	return (rootA.Position + rootB.Position) / 2 + Vector3.new(0, 1, 0)
end

local function shake(intensity: number, duration: number)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end
	local endsAt = os.clock() + duration
	local connection: RBXScriptConnection
	connection = RunService.RenderStepped:Connect(function()
		local remaining = endsAt - os.clock()
		if remaining <= 0 then
			humanoid.CameraOffset = Vector3.zero
			connection:Disconnect()
			return
		end
		local strength = intensity * (remaining / duration)
		humanoid.CameraOffset = Vector3.new(math.random() - 0.5, math.random() - 0.5, 0) * strength
	end)
end

local function involvesLocal(...: Model?): boolean
	local character = player.Character
	for i = 1, select("#", ...) do
		if select(i, ...) == character then
			return true
		end
	end
	return false
end

local function playSwing(model: Model, kind: Config.AttackKind, hitAt: number)
	local perilous = kind == "Perilous"
	local windupPose = if perilous then SwordPoses.ThrustWindup else SwordPoses.Windup
	local strikePose = if perilous then SwordPoses.Thrust else SwordPoses.Strike

	-- Land the strike frame on hitAt even though this event arrived late.
	local remaining = math.max(hitAt - now(), 0)
	local strikeTime = math.min(Config.Visual.StrikeTime, remaining)
	local token = tweenPose(model, windupPose, remaining - strikeTime)

	local sword = getSword(model)
	if sword then
		sword.Material = Enum.Material.Neon
		sword.Color = if perilous then Config.Visual.PerilousColor else Config.Visual.WindupColor
	end
	if perilous then
		floatingText(model, "危", Config.Visual.PerilousColor, 1.6)
	end

	task.delay(remaining - strikeTime, function()
		if poseTokens[model] ~= token then
			return
		end
		local strikeToken = tweenPose(model, strikePose, strikeTime)
		task.delay(strikeTime + Config.Visual.StrikeHold, function()
			if poseTokens[model] == strikeToken then
				settle(model)
			end
		end)
	end)
end

local handlers: { [string]: (data: { [string]: any }) -> () } = {
	Windup = function(data)
		playSwing(data.attacker, data.kind, data.hitAt)
	end,
	Deflect = function(data)
		local point = contactPoint(data.attacker, data.defender)
		if point then
			burst(point, if data.perfect then GOLD else SPARK, if data.perfect then 45 else 25, 28)
		end
		floatingText(data.defender, if data.perfect then "PERFECT" else "DEFLECT", if data.perfect then GOLD else SPARK)
		if involvesLocal(data.attacker, data.defender) then
			shake(if data.perfect then 0.6 else 0.35, 0.15)
		end
	end,
	Guard = function(data)
		local point = contactPoint(data.attacker, data.defender)
		if point then
			burst(point, STEEL, 8, 12)
		end
	end,
	Hit = function(data)
		local root = data.defender:FindFirstChild("HumanoidRootPart")
		if root then
			burst(root.Position, BLOOD, 18, 16)
		end
		if involvesLocal(data.defender) then
			shake(0.5, 0.2)
		end
	end,
	PostureBroken = function(data)
		settle(data.model)
		floatingText(data.model, "BREAK", GOLD, 1.3)
		local root = data.model:FindFirstChild("HumanoidRootPart")
		if root then
			burst(root.Position + Vector3.new(0, 1.5, 0), GOLD, 30, 20)
		end
	end,
	Deathblow = function(data)
		floatingText(data.defender, "忍殺", BLOOD, 2)
		local root = data.defender:FindFirstChild("HumanoidRootPart")
		if root then
			burst(root.Position, BLOOD, 70, 30)
		end
		if involvesLocal(data.attacker, data.defender) then
			shake(0.9, 0.35)
		end
	end,
	Dodged = function(data)
		floatingText(data.defender, "EVADE", STEEL, 0.8)
	end,
	Feint = function(data)
		settle(data.model)
		floatingText(data.model, "FEINT", STEEL, 0.8)
	end,
	Interrupted = function(data)
		settle(data.model)
	end,
}

local function watch(instance: Instance)
	if not instance:IsA("Model") then
		return
	end
	local model = instance
	local function onChanged()
		local state = model:GetAttribute("CombatState")
		-- Swings drive their own poses; everything else snaps to the resting pose.
		if state ~= "Windup" and state ~= "Recovery" then
			settle(model)
		end
	end
	model:GetAttributeChangedSignal("Blocking"):Connect(onChanged)
	model:GetAttributeChangedSignal("CombatState"):Connect(onChanged)
	model.Destroying:Once(function()
		poseTokens[model] = nil
	end)
end

function CombatVisuals.start()
	combatEvent.OnClientEvent:Connect(function(kind: string, data: { [string]: any })
		local handler = handlers[kind]
		if handler then
			handler(data)
		end
	end)

	CollectionService:GetInstanceAddedSignal(Types.Tag):Connect(watch)
	for _, instance in CollectionService:GetTagged(Types.Tag) do
		watch(instance)
	end
end

return CombatVisuals
