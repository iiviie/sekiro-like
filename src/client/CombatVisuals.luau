--!strict
-- Local-only feedback: body animation, sounds, sparks, telegraphs, hitstop and camera
-- shake, all driven by the server's CombatEvent broadcasts and replicated attributes.
-- Nothing here affects outcomes.

local CollectionService = game:GetService("CollectionService")
local ContentProvider = game:GetService("ContentProvider")
local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")

local Animator = require(script.Parent.Animator)
local Assets = require(ReplicatedStorage.Shared.Assets)
local Config = require(ReplicatedStorage.Shared.Config)
local Types = require(ReplicatedStorage.Shared.Types)

local combatEvent = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("CombatEvent") :: RemoteEvent
local player = Players.LocalPlayer

local SOUNDS = Assets.Sounds
local GOLD = Color3.fromRGB(255, 214, 110)
local SPARK = Color3.fromRGB(255, 185, 90)
local BLOOD = Color3.fromRGB(170, 10, 20)
local STEEL = Color3.fromRGB(200, 205, 215)

local CombatVisuals = {}

-- Your own swings start animating the moment you click (see predictAttack); the
-- server's Windup for that swing then only needs to add sounds and telegraphs.
local PREDICTION_MATCH_WINDOW = 0.5
local predicted: { kind: string, at: number }? = nil

local function now(): number
	return workspace:GetServerTimeNow()
end

local function rootOf(model: Model?): BasePart?
	local root = model and model:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
end

local function isLocal(model: Model?): boolean
	return model ~= nil and model == player.Character
end

local function playSound(id: string, parent: Instance?, volume: number?, pitch: number?)
	local sound = Instance.new("Sound")
	sound.SoundId = id
	sound.Volume = volume or 0.6
	sound.PlaybackSpeed = (pitch or 1) * (0.94 + math.random() * 0.12)
	sound.RollOffMaxDistance = 140
	sound.RollOffMinDistance = 12
	sound.Parent = parent or SoundService
	sound:Play()
	Debris:AddItem(sound, 4)
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
	label.Font = Enum.Font.Garamond
	label.Text = text
	label.TextColor3 = color
	label.TextScaled = true
	label.TextStrokeTransparency = 0.45
	label.Parent = gui
	gui.Parent = player:WaitForChild("PlayerGui")

	local info = TweenInfo.new(0.7, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	TweenService:Create(gui, info, { StudsOffset = Vector3.new(0, 4.5, 0) }):Play()
	TweenService:Create(label, info, { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
	Debris:AddItem(gui, 0.8)
end

local function anchorAt(position: Vector3): Part
	local anchor = Instance.new("Part")
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.Transparency = 1
	anchor.Size = Vector3.one * 0.2
	anchor.CFrame = CFrame.new(position)
	anchor.Parent = workspace
	Debris:AddItem(anchor, 1.5)
	return anchor
end

-- Sparks plus a light flash and an expanding glow ball.
local function burst(position: Vector3, color: Color3, count: number, speed: number, flashSize: number)
	local anchor = anchorAt(position)

	local sparks = Instance.new("ParticleEmitter")
	sparks.Color = ColorSequence.new(Color3.new(1, 1, 1), color)
	sparks.LightEmission = 1
	sparks.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.18), NumberSequenceKeypoint.new(1, 0) })
	sparks.Speed = NumberRange.new(speed * 0.5, speed)
	sparks.SpreadAngle = Vector2.new(180, 180)
	sparks.Lifetime = NumberRange.new(0.12, 0.3)
	sparks.Acceleration = Vector3.new(0, -40, 0)
	sparks.Drag = 4
	sparks.Rate = 0
	sparks.Orientation = Enum.ParticleOrientation.VelocityParallel
	sparks.Squash = NumberSequence.new(2)
	sparks.Parent = anchor
	sparks:Emit(count)

	local light = Instance.new("PointLight")
	light.Color = color
	light.Brightness = 6
	light.Range = 12
	light.Parent = anchor
	TweenService:Create(light, TweenInfo.new(0.25), { Brightness = 0 }):Play()

	local flash = Instance.new("Part")
	flash.Shape = Enum.PartType.Ball
	flash.Anchored = true
	flash.CanCollide = false
	flash.CanQuery = false
	flash.CanTouch = false
	flash.Material = Enum.Material.Neon
	flash.Color = color
	flash.Size = Vector3.one * 0.3
	flash.CFrame = CFrame.new(position)
	flash.Transparency = 0.1
	flash.Parent = workspace
	TweenService:Create(flash, TweenInfo.new(0.14, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = Vector3.one * flashSize,
		Transparency = 1,
	}):Play()
	Debris:AddItem(flash, 0.2)
end

-- Where two blades meet: along the defender's sword if they have one.
local function contactPoint(attacker: Model, defender: Model): Vector3?
	local sword = defender:FindFirstChild("Sword")
	if sword and sword:IsA("BasePart") then
		return (sword.CFrame * CFrame.new(0, 0, 0.6)).Position
	end
	local a, b = rootOf(attacker), rootOf(defender)
	if not a or not b then
		return nil
	end
	return (a.Position + b.Position) / 2 + Vector3.new(0, 1, 0)
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

-- Pushes the local character forward during its own strike (players own their physics).
local function lunge(speed: number)
	local root = rootOf(player.Character)
	local attachment = root and root:FindFirstChild("RootAttachment")
	if not root or not attachment or not attachment:IsA("Attachment") or speed <= 0 then
		return
	end
	local look = root.CFrame.LookVector
	local velocity = Instance.new("LinearVelocity")
	velocity.Attachment0 = attachment
	velocity.RelativeTo = Enum.ActuatorRelativeTo.World
	velocity.VelocityConstraintMode = Enum.VelocityConstraintMode.Plane
	velocity.PrimaryTangentAxis = Vector3.xAxis
	velocity.SecondaryTangentAxis = Vector3.zAxis
	velocity.PlaneVelocity = Vector2.new(look.X, look.Z).Unit * speed
	velocity.MaxForce = 4e4
	velocity.Parent = root
	Debris:AddItem(velocity, 0.12)
end

local function hitstop(duration: number, ...: Model?)
	for i = 1, select("#", ...) do
		local model = select(i, ...)
		if model then
			Animator.hitstop(model, duration)
		end
	end
end

-- Starts your own swing animation immediately, before the server confirms it.
function CombatVisuals.predictAttack(model: Model, kind: Config.AttackKind)
	predicted = { kind = kind, at = os.clock() }
	Animator.play(model, kind, Config.Attacks[kind].windup)
end

-- A fading ghost copy of the body, left behind during a dash.
local function afterimage(model: Model)
	local ghost = Instance.new("Model")
	ghost.Name = "Afterimage"
	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") and part.Name ~= "HumanoidRootPart" and part.Transparency < 1 then
			local copy = part:Clone()
			copy:ClearAllChildren()
			copy.Anchored = true
			copy.CanCollide = false
			copy.CanQuery = false
			copy.CanTouch = false
			copy.CastShadow = false
			copy.Material = Enum.Material.Neon
			copy.Color = Color3.fromRGB(150, 175, 255)
			copy.Transparency = 0.35
			if copy:IsA("MeshPart") then
				copy.TextureID = ""
			end
			copy.Parent = ghost
			TweenService:Create(copy, TweenInfo.new(0.35, Enum.EasingStyle.Quad), { Transparency = 1 }):Play()
		end
	end
	ghost.Parent = workspace
	Debris:AddItem(ghost, 0.35)
end

-- Dash pose, afterimages and whoosh. Called straight from input for your own character
-- so the dodge feels instant, and from the Dodge broadcast for everyone else.
function CombatVisuals.dash(model: Model)
	Animator.play(model, "Dash")
	playSound(SOUNDS.Dodge, rootOf(model), 0.45)
	for i = 0, 2 do
		task.delay(i * 0.045, function()
			if model.Parent then
				afterimage(model)
			end
		end)
	end
end

local function telegraphPerilous(model: Model, duration: number)
	local highlight = Instance.new("Highlight")
	highlight.FillColor = Config.Visual.PerilousColor
	highlight.FillTransparency = 0.65
	highlight.OutlineColor = Config.Visual.PerilousColor
	highlight.OutlineTransparency = 0
	highlight.DepthMode = Enum.HighlightDepthMode.Occluded
	highlight.Adornee = model
	highlight.Parent = model
	Debris:AddItem(highlight, duration + 0.1)

	floatingText(model, "危", Config.Visual.PerilousColor, 1.6)
	playSound(SOUNDS.PerfectDeflect, rootOf(model), 0.5, 1.6)
end

local function refreshBase(model: Model)
	local state = model:GetAttribute("CombatState")
	if state == "Dead" then
		Animator.setBase(model, nil)
	elseif state == "Broken" then
		Animator.setBase(model, "Broken")
	elseif model:GetAttribute("Blocking") then
		Animator.setBase(model, "Guard")
	else
		Animator.setBase(model, "Ready")
	end
end

local handlers: { [string]: (data: { [string]: any }) -> () } = {
	Windup = function(data)
		local model: Model = data.attacker
		local kind: Config.AttackKind = data.kind
		local remaining = math.max(data.hitAt - now(), 0)
		local guess = predicted
		local alreadyPlaying = isLocal(model)
			and guess ~= nil
			and guess.kind == kind
			and os.clock() - guess.at < PREDICTION_MATCH_WINDOW
		if isLocal(model) then
			predicted = nil
		end
		if not alreadyPlaying then
			Animator.play(model, kind, remaining)
		end

		local perilous = kind == "Perilous" or kind == "Sweep"
		local heavy = kind == "Light3" or perilous
		if perilous then
			telegraphPerilous(model, remaining)
		end
		task.delay(math.max(remaining - 0.05, 0), function()
			if not model.Parent then
				return
			end
			playSound(if heavy then SOUNDS.HeavySwing else SOUNDS.Swing, rootOf(model), if heavy then 0.7 else 0.55)
			if isLocal(model) then
				lunge(Config.Attacks[kind].lunge)
			end
		end)
	end,

	Deflect = function(data)
		local attacker: Model, defender: Model = data.attacker, data.defender
		local perfect: boolean = data.perfect
		Animator.play(defender, "GuardImpact")
		Animator.play(attacker, "Recoil")
		hitstop(if perfect then Config.Visual.PerfectHitstop else Config.Visual.Hitstop, attacker, defender)

		local point = contactPoint(attacker, defender)
		if point then
			burst(
				point,
				if perfect then GOLD else SPARK,
				if perfect then 60 else 30,
				if perfect then 40 else 28,
				if perfect then 6 else 3.5
			)
		end
		local soundAt = rootOf(defender)
		playSound(if math.random() < 0.5 then SOUNDS.Deflect else SOUNDS.DeflectAlt, soundAt, 0.8)
		if perfect then
			playSound(SOUNDS.PerfectDeflect, soundAt, 0.7, 1.15)
			floatingText(defender, "PERFECT", GOLD, 0.9)
		end
		if isLocal(attacker) or isLocal(defender) then
			shake(if perfect then 0.55 else 0.3, 0.15)
		end
	end,

	Guard = function(data)
		local attacker: Model, defender: Model = data.attacker, data.defender
		Animator.play(defender, "GuardImpact")
		hitstop(Config.Visual.Hitstop * 0.6, attacker, defender)
		local point = contactPoint(attacker, defender)
		if point then
			burst(point, STEEL, 10, 14, 1.8)
		end
		playSound(SOUNDS.Guard, rootOf(defender), 0.55)
	end,

	Hit = function(data)
		local attacker: Model, defender: Model = data.attacker, data.defender
		Animator.play(defender, "HitReact")
		hitstop(Config.Visual.Hitstop, attacker, defender)
		local root = rootOf(defender)
		if root then
			burst(root.Position + Vector3.new(0, 0.8, 0), BLOOD, 22, 18, 2)
		end
		playSound(if math.random() < 0.5 then SOUNDS.Hit else SOUNDS.HitAlt, root, 0.7)
		if isLocal(defender) then
			shake(0.5, 0.2)
		end
	end,

	PostureBroken = function(data)
		local model: Model = data.model
		Animator.stop(model)
		floatingText(model, "BREAK", GOLD, 1.3)
		local root = rootOf(model)
		if root then
			burst(root.Position + Vector3.new(0, 1.5, 0), GOLD, 40, 24, 5)
		end
		playSound(SOUNDS.PostureBreak, root, 0.8)
	end,

	Deathblow = function(data)
		local attacker: Model, defender: Model = data.attacker, data.defender
		Animator.play(attacker, "Deathblow")
		Animator.play(defender, "Executed")
		hitstop(Config.Visual.DeathblowHitstop, attacker, defender)
		floatingText(defender, "忍殺", BLOOD, 2)
		local root = rootOf(defender)
		if root then
			burst(root.Position, BLOOD, 80, 30, 7)
		end
		playSound(SOUNDS.PostureBreak, root, 0.9, 0.8)
		playSound(SOUNDS.HitAlt, root, 0.9, 0.85)
		if isLocal(attacker) or isLocal(defender) then
			shake(0.9, 0.35)
		end
	end,

	Died = function(data)
		local model: Model = data.model
		if Animator.current(model) ~= "Executed" then
			Animator.play(model, "Executed")
		end
	end,

	Dodge = function(data)
		if not isLocal(data.model) then
			CombatVisuals.dash(data.model)
		end
	end,

	Dodged = function(data)
		floatingText(data.defender, "EVADE", STEEL, 0.8)
	end,

	Jumped = function(data)
		floatingText(data.defender, "EVADE", STEEL, 0.8)
	end,

	Mikiri = function(data)
		local attacker: Model, defender: Model = data.attacker, data.defender
		Animator.play(defender, "Mikiri")
		Animator.play(attacker, "Recoil")
		hitstop(Config.Visual.PerfectHitstop, attacker, defender)
		local root = rootOf(defender)
		if root then
			burst(root.Position + root.CFrame.LookVector * 2 - Vector3.new(0, 2, 0), GOLD, 50, 26, 5)
		end
		floatingText(defender, "MIKIRI", GOLD, 1.1)
		playSound(SOUNDS.PerfectDeflect, root, 0.8, 0.9)
		playSound(SOUNDS.PostureBreak, root, 0.6, 1.2)
		if isLocal(attacker) or isLocal(defender) then
			shake(0.6, 0.2)
		end
	end,

	Drink = function(data)
		local model: Model = data.model
		Animator.play(model, "Drink")
		-- A small gourd in the off hand for the length of the sip.
		local hand = model:FindFirstChild("LeftHand")
		if hand and hand:IsA("BasePart") then
			local gourd = Instance.new("Part")
			gourd.Shape = Enum.PartType.Ball
			gourd.Size = Vector3.new(0.55, 0.55, 0.55)
			gourd.Color = Color3.fromRGB(150, 96, 48)
			gourd.Material = Enum.Material.Wood
			gourd.CanCollide = false
			gourd.CanQuery = false
			gourd.CanTouch = false
			gourd.Massless = true
			gourd.CastShadow = false
			local weld = Instance.new("Weld")
			weld.Part0 = hand
			weld.Part1 = gourd
			weld.C0 = CFrame.new(0, -0.35, -0.1)
			weld.Parent = gourd
			gourd.Parent = model
			Debris:AddItem(gourd, Config.Gourd.DrinkTime)
		end
	end,

	Healed = function(data)
		local root = rootOf(data.model)
		if root then
			burst(root.Position, Color3.fromRGB(255, 196, 120), 14, 6, 3)
		end
	end,

	Feint = function(data)
		Animator.stop(data.model)
		floatingText(data.model, "FEINT", STEEL, 0.8)
	end,

	Interrupted = function(data)
		Animator.stop(data.model)
	end,
}

local function watch(instance: Instance)
	if not instance:IsA("Model") then
		return
	end
	local model = instance
	Animator.attach(model)
	refreshBase(model)
	model:GetAttributeChangedSignal("Blocking"):Connect(function()
		refreshBase(model)
	end)
	model:GetAttributeChangedSignal("CombatState"):Connect(function()
		refreshBase(model)
	end)
end

function CombatVisuals.start()
	Animator.start()

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

	task.spawn(function()
		local preload = {}
		for _, id in SOUNDS do
			local sound = Instance.new("Sound")
			sound.SoundId = id
			table.insert(preload, sound)
		end
		ContentProvider:PreloadAsync(preload)
	end)
end

return CombatVisuals
