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
local CombatHUD = require(script.Parent.CombatHUD)
local LocalCombat = require(script.Parent.LocalCombat)
local Motion = require(script.Parent.Motion)
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

local CombatVisuals = {
	lastOwnHitAt = -math.huge, -- server time your latest swing lands (for dodge-cancel timing)
}

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

-- A brush-kanji mark floating over a fighter's head (the perilous warning).
local function kanjiMark(model: Model, imageId: string, color: Color3, duration: number)
	local head = model:FindFirstChild("Head")
	if not head or not head:IsA("BasePart") then
		return
	end
	local gui = Instance.new("BillboardGui")
	gui.Adornee = head
	gui.AlwaysOnTop = true
	gui.LightInfluence = 0
	gui.Size = UDim2.fromOffset(150, 150)
	gui.StudsOffset = Vector3.new(0, 3.6, 0)
	gui.MaxDistance = 140

	local halo = Instance.new("ImageLabel")
	halo.BackgroundTransparency = 1
	halo.Image = Assets.UI.Glow
	halo.ImageColor3 = color
	halo.ImageTransparency = 0.35
	halo.AnchorPoint = Vector2.new(0.5, 0.5)
	halo.Position = UDim2.fromScale(0.5, 0.5)
	halo.Size = UDim2.fromScale(1.1, 1.1)
	halo.Parent = gui

	local glyph = Instance.new("ImageLabel")
	glyph.BackgroundTransparency = 1
	glyph.Image = imageId
	glyph.ImageColor3 = color
	glyph.ScaleType = Enum.ScaleType.Fit
	glyph.AnchorPoint = Vector2.new(0.5, 0.5)
	glyph.Position = UDim2.fromScale(0.5, 0.5)
	glyph.Size = UDim2.fromScale(1.35, 1.35)
	glyph.Parent = gui
	gui.Parent = player:WaitForChild("PlayerGui")

	-- Slam in large, settle, then fade as the strike lands.
	TweenService:Create(glyph, TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
		Size = UDim2.fromScale(0.8, 0.8),
	}):Play()
	task.delay(math.max(duration - 0.15, 0.2), function()
		local fade = TweenInfo.new(0.3)
		TweenService:Create(glyph, fade, { ImageTransparency = 1 }):Play()
		TweenService:Create(halo, fade, { ImageTransparency = 1 }):Play()
	end)
	Debris:AddItem(gui, duration + 0.4)
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

-- A bright bloom at a point in the world, for perfect deflects and Mikiri.
local function flare(position: Vector3, color: Color3, size: number)
	local anchor = anchorAt(position)
	local gui = Instance.new("BillboardGui")
	gui.Adornee = anchor
	gui.AlwaysOnTop = true
	gui.LightInfluence = 0
	gui.Size = UDim2.fromScale(size, size)
	local glow = Instance.new("ImageLabel")
	glow.BackgroundTransparency = 1
	glow.Image = Assets.UI.Glow
	glow.ImageColor3 = color
	glow.Size = UDim2.fromScale(0.3, 0.3)
	glow.AnchorPoint = Vector2.new(0.5, 0.5)
	glow.Position = UDim2.fromScale(0.5, 0.5)
	glow.Parent = gui
	gui.Parent = anchor
	TweenService:Create(glow, TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = UDim2.fromScale(1, 1),
		ImageTransparency = 1,
	}):Play()
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
-- Fighters don't collide, so the lunge stops short of anyone already within reach
-- instead of carrying you through them.
local LUNGE_STOP_DISTANCE = 3.5

local function lunge(speed: number)
	local character = player.Character
	local root = rootOf(character)
	if not root or speed <= 0 then
		return
	end
	local look = root.CFrame.LookVector
	local forward = Vector3.new(look.X, 0, look.Z).Unit
	for _, instance in CollectionService:GetTagged(Types.Tag) do
		local other = if instance ~= character and instance:IsA("Model") then rootOf(instance) else nil
		if other then
			local offset = other.Position - root.Position
			local flat = Vector3.new(offset.X, 0, offset.Z)
			if flat.Magnitude < LUNGE_STOP_DISTANCE + 2 and flat.Unit:Dot(forward) > 0.5 then
				return -- someone is right in front of us already
			end
		end
	end
	Motion.push(forward * speed, 0.12)
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
	highlight.FillTransparency = 0.9 -- a hint of red; the kanji and outline do the warning
	highlight.OutlineColor = Config.Visual.PerilousColor
	highlight.OutlineTransparency = 0.15
	highlight.DepthMode = Enum.HighlightDepthMode.Occluded
	highlight.Adornee = model
	highlight.Parent = model
	Debris:AddItem(highlight, duration + 0.1)

	kanjiMark(model, Assets.UI.KanjiPeril, Config.Visual.PerilousColor, duration)
	playSound(SOUNDS.PerfectDeflect, rootOf(model), 0.75, 1.7)

	-- If it's coming for you, the screen edges flash red too.
	local mine, theirs = rootOf(player.Character), rootOf(model)
	if mine and theirs and not isLocal(model) and (mine.Position - theirs.Position).Magnitude < 24 then
		CombatHUD.flashPeril()
	end
end

local alreadyShown: (attacker: Model, defender: Model) -> boolean

local function deflectEffects(attacker: Model, defender: Model, perfect: boolean)
	Animator.play(defender, "GuardImpact")
	Animator.play(attacker, "Recoil")
	hitstop(if perfect then Config.Visual.PerfectHitstop else Config.Visual.Hitstop, attacker, defender)

	local point = contactPoint(attacker, defender)
	local soundAt = rootOf(defender)
	playSound(if math.random() < 0.5 then SOUNDS.Deflect else SOUNDS.DeflectAlt, soundAt, 0.85)
	if perfect then
		-- A perfect deflect has to feel unmistakable: white-gold bloom, a ringing
		-- second layer of steel, and a heavier freeze and camera kick.
		if point then
			burst(point, GOLD, 70, 44, 7)
			flare(point, Color3.fromRGB(255, 244, 214), 16)
		end
		playSound(SOUNDS.PerfectDeflect, soundAt, 0.9, 1.1)
	elseif point then
		burst(point, SPARK, 30, 28, 3.5)
	end
	if isLocal(attacker) or isLocal(defender) then
		shake(if perfect then 0.7 else 0.3, if perfect then 0.2 else 0.15)
	end
end

local function guardEffects(attacker: Model, defender: Model)
	Animator.play(defender, "GuardImpact")
	hitstop(Config.Visual.Hitstop * 0.6, attacker, defender)
	local point = contactPoint(attacker, defender)
	if point then
		burst(point, STEEL, 10, 14, 1.8)
	end
	playSound(SOUNDS.Guard, rootOf(defender), 0.55)
end

-- Your own deflects are shown the instant the blow lands, predicted from your last block
-- press; the server's verdict follows later and shouldn't replay the same effects.
local PREDICTED_DEFENCE_WINDOW = 0.6
local predictedDefences: { [Model]: number } = {}

function alreadyShown(attacker: Model, defender: Model): boolean
	if not isLocal(defender) then
		return false
	end
	local at = predictedDefences[attacker]
	predictedDefences[attacker] = nil
	return at ~= nil and os.clock() - at < PREDICTED_DEFENCE_WINDOW
end

local function predictIncoming(attacker: Model, kind: Config.AttackKind, hitAt: number)
	local spec = Config.Attacks[kind]
	local mine, theirs = rootOf(player.Character), rootOf(attacker)
	if spec.unblockable or not mine or not theirs then
		return
	end
	local offset = theirs.Position - mine.Position
	local flat = Vector3.new(offset.X, 0, offset.Z)
	if flat.Magnitude > spec.range + 2 then
		return
	end
	task.delay(math.max(hitAt - now(), 0), function()
		local character = player.Character
		local root = rootOf(character)
		if not root or character:GetAttribute("CombatState") == "Dead" or not attacker.Parent then
			return
		end
		local toAttacker = theirs.Position - root.Position
		local facing = root.CFrame.LookVector:Dot(Vector3.new(toAttacker.X, 0, toAttacker.Z).Unit)
		if facing < Config.Deflect.FacingDot then
			return
		end
		local defence = LocalCombat.predictDefence(hitAt)
		if defence == "Perfect" or defence == "Deflect" then
			predictedDefences[attacker] = os.clock()
			LocalCombat.deflected()
			deflectEffects(attacker, character :: Model, defence == "Perfect")
		elseif defence == "Guard" and not spec.noGuard then
			predictedDefences[attacker] = os.clock()
			guardEffects(attacker, character :: Model)
		end
	end)
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
			CombatVisuals.lastOwnHitAt = data.hitAt
		end
		if not alreadyPlaying then
			Animator.play(model, kind, remaining)
		end

		local perilous = kind == "Perilous" or kind == "Sweep"
		local heavy = kind == "Light3" or perilous
		if perilous then
			telegraphPerilous(model, remaining)
		end
		if not isLocal(model) then
			predictIncoming(model, kind, data.hitAt)
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
		if not alreadyShown(attacker, defender) then
			deflectEffects(attacker, defender, data.perfect)
		end
	end,

	Guard = function(data)
		local attacker: Model, defender: Model = data.attacker, data.defender
		if not alreadyShown(attacker, defender) then
			guardEffects(attacker, defender)
		end
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
		-- A clean evade: a soft puff of dust where the blow passed, no text.
		local root = rootOf(data.defender)
		if root then
			burst(root.Position - Vector3.new(0, 2.4, 0), Color3.fromRGB(180, 168, 150), 10, 8, 1.5)
		end
	end,

	Jumped = function(data)
		if data.kick then
			-- Landed on the sweeper's head: a heavy posture hit.
			local root = rootOf(data.attacker)
			if root then
				burst(root.Position + Vector3.new(0, 2.6, 0), GOLD, 26, 18, 4)
			end
			playSound(SOUNDS.Guard, root, 0.8, 0.8)
			hitstop(Config.Visual.Hitstop, data.attacker, data.defender)
		end
		-- A clean evade: a soft puff of dust where the blow passed, no text.
		local root = rootOf(data.defender)
		if root then
			burst(root.Position - Vector3.new(0, 2.4, 0), Color3.fromRGB(180, 168, 150), 10, 8, 1.5)
		end
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
		local point = contactPoint(attacker, defender)
		if point then
			flare(point, Color3.fromRGB(255, 236, 200), 18)
		end
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
