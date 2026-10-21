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
local LockOn = require(script.Parent.LockOn)
local Motion = require(script.Parent.Motion)
local Assets = require(ReplicatedStorage.Shared.Assets)
local Config = require(ReplicatedStorage.Shared.Config)
local Types = require(ReplicatedStorage.Shared.Types)
local Bosses = require(ReplicatedStorage.Shared.Bosses)
local Spacing = require(ReplicatedStorage.Shared.Spacing)
local Weapons = require(ReplicatedStorage.Shared.Weapons)

local combatEvent = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("CombatEvent") :: RemoteEvent
local player = Players.LocalPlayer

local SOUNDS = Assets.Sounds
local GOLD = Color3.fromRGB(255, 214, 110)
local SPARK = Color3.fromRGB(255, 185, 90)
local BLOOD = Color3.fromRGB(150, 8, 16)
local BLOOD_DARK = Color3.fromRGB(64, 4, 8)
local STEEL = Color3.fromRGB(200, 205, 215)

local CombatVisuals = {
	lastOwnHitAt = -math.huge, -- server time your latest swing lands (for dodge-cancel timing)
}

-- Bosses animate only from their own BossMove broadcasts (client/BossVisuals), so the
-- generic reaction clips here never cut into a boss's string.
local function playClip(model: Model, clip: string, windup: number?)
	if model:GetAttribute("Boss") ~= nil then
		return
	end
	Animator.play(model, clip, windup)
end

-- Your own swings start animating the moment you click (see predictAttack); the
-- server's Windup for that swing then only needs to add sounds and telegraphs.
local PREDICTION_MATCH_WINDOW = 0.5
local predicted: { kind: string, at: number, windup: number }? = nil

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

-- A directional camera kick: the view snaps along the line of the blow and settles,
-- rather than jittering at random (which reads as an explosion). Without a direction
-- it falls back to a small rattle.
local function shake(intensity: number, duration: number, from: Model?, to: Model?)
	if player:GetAttribute("SettingCameraShake") == false then
		return
	end
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = rootOf(character)
	if not humanoid or not root then
		return
	end
	local a, b = rootOf(from), rootOf(to)
	local direction: Vector3? = nil
	if a and b and (b.Position - a.Position).Magnitude > 0.1 then
		-- CameraOffset is in the root's object space.
		local world = (b.Position - a.Position).Unit
		direction = root.CFrame:VectorToObjectSpace(Vector3.new(world.X, world.Y * 0.3, world.Z)).Unit
	end
	local startedAt = os.clock()
	local connection: RBXScriptConnection
	connection = RunService.RenderStepped:Connect(function()
		local u = (os.clock() - startedAt) / duration
		if u >= 1 or not humanoid.Parent then
			humanoid.CameraOffset = Vector3.zero
			connection:Disconnect()
			return
		end
		local decay = (1 - u) * (1 - u)
		local jitter = Vector3.new(math.random() - 0.5, math.random() - 0.5, 0) * intensity * decay
		if direction then
			humanoid.CameraOffset = direction * intensity * decay * math.cos(u * math.pi * 2.5) + jitter * 0.2
		else
			humanoid.CameraOffset = jitter
		end
	end)
end

-- Blood: dark, unlit droplets thrown along the blow and pulled down by gravity, plus a
-- faint red mist. Deliberately not a glowing spark burst.
local function bloodSpray(position: Vector3, direction: Vector3?, count: number, speed: number)
	local anchor = anchorAt(position)
	if direction and direction.Magnitude > 0.01 then
		anchor.CFrame = CFrame.lookAt(position, position + direction)
	end

	local drops = Instance.new("ParticleEmitter")
	drops.Texture = Assets.UI.Glow
	drops.Color = ColorSequence.new(BLOOD, BLOOD_DARK)
	drops.LightEmission = 0
	drops.LightInfluence = 0.6
	drops.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.32), NumberSequenceKeypoint.new(1, 0.06) })
	drops.Speed = NumberRange.new(speed * 0.35, speed)
	drops.EmissionDirection = Enum.NormalId.Front
	drops.SpreadAngle = if direction then Vector2.new(38, 26) else Vector2.new(180, 180)
	drops.Lifetime = NumberRange.new(0.35, 0.7)
	drops.Acceleration = Vector3.new(0, -70, 0)
	drops.Drag = 1.5
	drops.Rate = 0
	drops.Orientation = Enum.ParticleOrientation.VelocityParallel
	drops.Squash = NumberSequence.new(1.6)
	drops.Parent = anchor
	drops:Emit(count)

	local mist = Instance.new("ParticleEmitter")
	mist.Texture = Assets.UI.Glow
	mist.Color = ColorSequence.new(BLOOD)
	mist.LightEmission = 0
	mist.LightInfluence = 0.6
	mist.Size = NumberSequence.new(0.8, 2.4)
	mist.Transparency = NumberSequence.new(0.55, 1)
	mist.Speed = NumberRange.new(2, 5)
	mist.EmissionDirection = Enum.NormalId.Front
	mist.SpreadAngle = Vector2.new(60, 60)
	mist.Lifetime = NumberRange.new(0.25, 0.45)
	mist.Rate = 0
	mist.Parent = anchor
	mist:Emit(math.ceil(count / 10))
end

-- A few overlapping dark pools on the floor under a deathblow, fading after a while.
local function bloodPool(position: Vector3, direction: Vector3?)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { workspace.Terrain, workspace:FindFirstChild("Castle") :: Instance }
	local hit = workspace:Raycast(position + Vector3.new(0, 2, 0), Vector3.new(0, -12, 0), params)
	if not hit then
		return
	end
	local flat = if direction then Vector3.new(direction.X, 0, direction.Z) else Vector3.zero
	flat = if flat.Magnitude > 0.01 then flat.Unit else Vector3.zero
	for i = 1, 4 do
		local pool = Instance.new("Part")
		pool.Shape = Enum.PartType.Cylinder
		pool.Anchored = true
		pool.CanCollide = false
		pool.CanQuery = false
		pool.CanTouch = false
		pool.CastShadow = false
		pool.Material = Enum.Material.SmoothPlastic
		pool.Color = BLOOD_DARK
		pool.Reflectance = 0.05
		local size = (2.8 - i * 0.45) * (0.8 + math.random() * 0.4)
		pool.Size = Vector3.new(0.04, size, size)
		local spread = flat * (i - 1) * 1.1 + Vector3.new(math.random() - 0.5, 0, math.random() - 0.5) * 0.8
		pool.CFrame = CFrame.new(hit.Position + spread + Vector3.new(0, 0.03 + i * 0.004, 0))
			* CFrame.Angles(0, 0, math.rad(90))
		pool.Transparency = 1
		pool.Parent = workspace
		TweenService:Create(pool, TweenInfo.new(0.25), { Transparency = 0.12 }):Play()
		task.delay(6, function()
			TweenService:Create(pool, TweenInfo.new(2.5), { Transparency = 1 }):Play()
		end)
		Debris:AddItem(pool, 9)
	end
end

-- The direction a blow travels, attacker to defender, flattened.
local function blowDirection(attacker: Model, defender: Model): Vector3?
	local a, b = rootOf(attacker), rootOf(defender)
	if not a or not b then
		return nil
	end
	local offset = b.Position - a.Position
	local flat = Vector3.new(offset.X, 0, offset.Z)
	return if flat.Magnitude > 0.1 then flat.Unit + Vector3.new(0, 0.35, 0) else nil
end

-- Drains the colour from the screen for a beat, tinted red: the deathblow's freeze-frame.
local function deathblowGrade()
	local camera = workspace.CurrentCamera
	local grade = Instance.new("ColorCorrectionEffect")
	grade.Saturation = -0.75
	grade.Contrast = 0.3
	grade.TintColor = Color3.fromRGB(255, 205, 200)
	grade.Parent = camera
	task.delay(0.18, function()
		TweenService:Create(grade, TweenInfo.new(0.7, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Saturation = 0,
			Contrast = 0,
			TintColor = Color3.new(1, 1, 1),
		}):Play()
	end)
	Debris:AddItem(grade, 1)
end

-- Pushes the local character forward during its own strike (players own their physics),
-- standing in for the clip's root motion (the Kannagi clips play in place). Bodies don't
-- overlap (Shared/Spacing), so the lunge is shortened to stop just outside the body of
-- anyone in front instead of carrying you into them.
local function lunge(speed: number, duration: number)
	local character = player.Character
	local root = rootOf(character)
	if not character or not root or speed <= 0 or duration <= 0 then
		return
	end
	local look = root.CFrame.LookVector
	local forward = Vector3.new(look.X, 0, look.Z)
	if forward.Magnitude < 1e-3 then
		return
	end
	forward = forward.Unit
	-- Motion.surge from 1.25x to 0.2x speed (quadratic ease) covers 0.55 x speed x duration.
	local distance = 0.55 * speed * duration
	local room = Spacing.room(character, root.Position, forward, distance)
	if room <= 0.1 then
		return -- someone is right in front of us already
	end
	local scale = room / distance
	-- Burst then settle; the lunge never carries you more than a short step.
	Motion.surge(forward, speed * 1.25 * scale, speed * 0.2 * scale, duration)
end

-- Slides the local character `distance` studs along `direction` over Knockback.Duration,
-- easing out (Kannagi's knockback curve). Bots are slid by the server.
local function knockLocal(direction: Vector3?, distance: number)
	if not direction or distance <= 0.05 then
		return
	end
	local duration = Config.Knockback.Duration
	Motion.surge(direction, 3 * distance / duration, 0, duration)
end

-- The flat direction from one fighter to another.
local function flatBetween(from: Model, to: Model): Vector3?
	local a, b = rootOf(from), rootOf(to)
	if not a or not b then
		return nil
	end
	local offset = b.Position - a.Position
	local flat = Vector3.new(offset.X, 0, offset.Z)
	return if flat.Magnitude > 0.1 then flat.Unit else nil
end

local function hitstop(duration: number, ...: Model?)
	if player:GetAttribute("SettingHitstop") == false then
		return
	end
	for i = 1, select("#", ...) do
		local model = select(i, ...)
		if model then
			Animator.hitstop(model, duration)
		end
	end
end

-- Starts your own swing animation immediately, before the server confirms it.
function CombatVisuals.predictAttack(model: Model, kind: Config.AttackKind, windup: number?)
	local spec = Weapons.spec(Weapons.of(model), kind)
	local duration = windup or spec.windup
	predicted = { kind = kind, at = os.clock(), windup = duration }
	LocalCombat.attackingUntil = os.clock() + duration + Config.Net.ResolveGrace + spec.recovery
	LocalCombat.swing = { kind = kind, startedAt = now(), hitAt = now() + duration, confirmed = false }
	playClip(model, kind, duration)
end

-- A fading ghost copy of the body, left behind during a dash.
local function afterimage(model: Model)
	local ghost = Instance.new("Model")
	ghost.Name = "Afterimage"
	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") and part.Name ~= "HumanoidRootPart" and part.Transparency < 1 then
			local copy = part:Clone()
			copy:ClearAllChildren()
			-- Keep the shape of mesh-built pieces (katana, kasa), just untextured.
			local mesh = part:FindFirstChildOfClass("SpecialMesh")
			if mesh then
				local shape = mesh:Clone()
				shape.TextureId = ""
				shape.Parent = copy
			end
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

-- The dodge clip for a dash direction relative to the body (Kannagi's 4-way dodges).
local function dodgeClip(model: Model, direction: Vector3?): string
	local root = rootOf(model)
	if not root or not direction or direction.Magnitude < 0.1 then
		return "Dash"
	end
	local localDir = root.CFrame:VectorToObjectSpace(direction)
	if math.abs(localDir.X) > math.abs(localDir.Z) then
		return if localDir.X > 0 then "DodgeRight" else "DodgeLeft"
	end
	return if localDir.Z > 0 then "DodgeBack" else "Dash"
end

-- Dash pose, afterimages and whoosh. Called straight from input for your own character
-- (with the dash direction) so the dodge feels instant, and from the Dodge broadcast for
-- everyone else (the direction is then read from their velocity a moment later).
function CombatVisuals.dash(model: Model, direction: Vector3?)
	if direction then
		playClip(model, dodgeClip(model, direction))
	else
		playClip(model, "Dash")
		task.delay(0.05, function()
			local root = rootOf(model)
			if root and Animator.current(model) == "Dash" then
				local v = root.AssemblyLinearVelocity
				local clip = dodgeClip(model, Vector3.new(v.X, 0, v.Z))
				if clip ~= "Dash" then
					playClip(model, clip)
				end
			end
		end)
	end
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
	if model:GetAttribute("Boss") ~= nil then
		-- A boss's 危 can come well before its hit: keep the warning up to the impact.
		duration = math.max(duration, 0.35)
	end
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

CombatVisuals.telegraphPerilous = telegraphPerilous

-- The parry cue: a white glint at the blade tip a fixed time before impact, on every
-- swing coming at you. Pressing block as it flashes lands the deflect window at typical
-- reaction times, so the rhythm is learnable instead of a guess at a moving blade.
local GLINT_LEAD = 0.3
local GLINT_RANGE = 26

local function glint(model: Model, hitAt: number)
	local mine, theirs = rootOf(player.Character), rootOf(model)
	if not mine or not theirs or (mine.Position - theirs.Position).Magnitude > GLINT_RANGE then
		return
	end
	task.delay(math.max(hitAt - GLINT_LEAD - now(), 0), function()
		if not model.Parent or model:GetAttribute("CombatState") ~= "Windup" then
			return -- interrupted or feinted before the tell
		end
		local sword = model:FindFirstChild("Sword")
		local tip = sword and sword:FindFirstChild("TrailEnd")
		local position = if tip and tip:IsA("Attachment")
			then tip.WorldPosition
			else theirs.Position + Vector3.new(0, 2, 0)
		flare(position, Color3.fromRGB(255, 252, 240), 7)
		burst(position, Color3.fromRGB(255, 250, 235), 6, 6, 0.8)
	end)
end

-- Floating outcome text over the fighter you struck: why that hit did (or didn't) land.
local function popText(target: Model, text: string, color: Color3, big: boolean?)
	local head = target:FindFirstChild("Head")
	if not head or not head:IsA("BasePart") then
		return
	end
	local gui = Instance.new("BillboardGui")
	gui.Size = UDim2.fromOffset(220, 40)
	gui.StudsOffsetWorldSpace = Vector3.new((math.random() - 0.5) * 1.5, 2.2, 0)
	gui.AlwaysOnTop = true
	gui.LightInfluence = 0
	gui.MaxDistance = 60
	gui.Adornee = head
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Enum.Font.SourceSansBold
	label.TextSize = if big then 30 else 22
	label.TextColor3 = color
	label.TextStrokeTransparency = 0.3
	label.Text = text
	label.Parent = gui
	gui.Parent = head
	TweenService:Create(gui, TweenInfo.new(0.9, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		StudsOffsetWorldSpace = gui.StudsOffsetWorldSpace + Vector3.new(0, 2.2, 0),
	}):Play()
	TweenService:Create(label, TweenInfo.new(0.9, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
		TextTransparency = 1,
		TextStrokeTransparency = 1,
	}):Play()
	Debris:AddItem(gui, 1)
end

local alreadyShown: (attacker: Model, defender: Model) -> boolean

-- Deflects chained in quick succession ring a little higher each time, so the rhythm of a
-- good exchange can be heard. Tracked per defender.
local chainAt: { [Model]: number } = {}
local chainCount: { [Model]: number } = {}

local function specOf(attacker: Model, kind: any): Config.AttackSpec?
	return Bosses.specFor(Weapons.of(attacker), kind) -- a weapon move, or a boss hit
end

-- `recoil`: the attacker is thrown back (an ender or a thrust); otherwise its blade is only
-- knocked aside and its string goes on.
-- The defender's deflect clip: thrown to the side the blade came from, the Middle version for
-- a Middle or Large blow (Kannagi's HajikiReaction RightMiddle / LeftMiddle).
local function deflectClip(spec: Config.AttackSpec?): string
	local side = if spec then spec.deflectSide else "Right"
	if side ~= "Back" and spec and spec.guardReaction ~= "Small" then
		return "Deflect" .. side .. "Middle"
	end
	return "Deflect" .. side
end

-- The attacker's recoil: Kannagi's ReHajikiReaction is the mirror of the defender's side, so a
-- cut deflected to the defender's right (Light2, Riposte2, DodgeSlash, MikiriSlash) recoils left.
local function recoilClip(spec: Config.AttackSpec?, recoil: boolean): string
	if not recoil then
		return "Knocked"
	end
	return if spec and spec.deflectSide == "Right" then "RecoilLeft" else "Recoil"
end

local function deflectEffects(attacker: Model, defender: Model, perfect: boolean, kind: string?, recoil: boolean)
	local spec = specOf(attacker, kind)
	playClip(defender, deflectClip(spec))
	playClip(attacker, recoilClip(spec, recoil))
	hitstop(if perfect then Config.Visual.PerfectHitstop else Config.Visual.Hitstop, attacker, defender)
	if isLocal(defender) and spec then
		knockLocal(flatBetween(attacker, defender), spec.knockback * Config.Knockback.Deflect)
	end

	local t = os.clock()
	local chain = if t - (chainAt[defender] or -math.huge) < Config.Deflect.ChainWindow
		then (chainCount[defender] or 0) + 1
		else 0
	chainAt[defender], chainCount[defender] = t, chain
	local pitch = 1 + math.min(chain, 5) * 0.045 + (math.random() - 0.5) * 0.06

	local point = contactPoint(attacker, defender)
	local soundAt = rootOf(defender)
	playSound(if math.random() < 0.5 then SOUNDS.Deflect else SOUNDS.DeflectAlt, soundAt, 0.85, pitch)
	if perfect then
		-- A perfect deflect has to feel unmistakable: white-gold bloom, a ringing
		-- second layer of steel, and a heavier freeze and camera kick.
		if point then
			burst(point, GOLD, 70, 44, 7)
			flare(point, Color3.fromRGB(255, 244, 214), 16)
		end
		playSound(SOUNDS.PerfectDeflect, soundAt, 0.9, 1.1 * pitch)
		if isLocal(defender) then
			CombatHUD.flashPerfect()
		end
	elseif point then
		burst(point, SPARK, 30, 28, 3.5)
	end
	if isLocal(attacker) or isLocal(defender) then
		shake(if perfect then 0.7 else 0.3, if perfect then 0.2 else 0.15)
		-- A rally you can see: each chained deflect counts up and warms toward gold.
		if chain >= 1 then
			local heat = math.min(chain / 4, 1)
			popText(
				if isLocal(defender) then attacker else defender,
				`{chain + 1} CLASHES`,
				Color3.fromRGB(235, 235, 245):Lerp(GOLD, heat),
				chain >= 3
			)
		end
	end
end

-- Holding guard is the dullest tier: a short freeze, a knock sized by the blow, grey sparks.
local function guardEffects(attacker: Model, defender: Model, kind: string?)
	local spec = specOf(attacker, kind)
	playClip(defender, "Guard" .. (if spec then spec.guardReaction else "Small"))
	hitstop(Config.Visual.GuardHitstop, attacker, defender)
	if isLocal(defender) and spec then
		knockLocal(flatBetween(attacker, defender), spec.knockback * Config.Knockback.Guard)
	end
	local point = contactPoint(attacker, defender)
	if point then
		burst(point, STEEL, 8, 10, 1.2)
	end
	playSound(SOUNDS.Guard, rootOf(defender), 0.5, 0.82 + math.random() * 0.06)
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
	local spec = specOf(attacker, kind)
	local mine, theirs = rootOf(player.Character), rootOf(attacker)
	if not spec or spec.unblockable or not mine or not theirs then
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
			LocalCombat.defended(spec.recoilOnDeflect)
			deflectEffects(attacker, character :: Model, defence == "Perfect", kind, spec.recoilOnDeflect)
		elseif defence == "Guard" and not spec.noGuard then
			predictedDefences[attacker] = os.clock()
			LocalCombat.defended(false)
			guardEffects(attacker, character :: Model, kind)
		end
	end)
end

-- Fighters relax (sword low at the side) out of combat and raise a guard stance once
-- they're in a fight: locked on, or within COMBAT_LINGER seconds of any exchange.
local COMBAT_LINGER = 4
local lastCombatAt: { [Model]: number } = {}

local function inCombat(model: Model): boolean
	if isLocal(model) and LockOn.target() ~= nil then
		return true
	end
	return os.clock() - (lastCombatAt[model] or -math.huge) < COMBAT_LINGER
end

local heldTestPose: string? = nil -- Studio tooling (AnimTest) is holding a pose for review

local function refreshBase(model: Model)
	if heldTestPose and isLocal(model) then
		return -- Studio tooling is holding a pose for review
	end
	local state = model:GetAttribute("CombatState")
	if state == "Dead" then
		Animator.setBase(model, nil)
	elseif state == "Downed" then
		Animator.setBase(model, "Executed")
	elseif state == "Broken" then
		Animator.setBase(model, "Broken")
	elseif model:GetAttribute("Blocking") then
		Animator.setBase(model, "Guard")
	elseif inCombat(model) then
		Animator.setBase(model, "Ready")
	else
		Animator.setBase(model, "Relaxed")
	end
end

local handlers: { [string]: (data: { [string]: any }) -> () } = {
	Windup = function(data)
		local model: Model = data.attacker
		local kind: Config.AttackKind = data.kind
		local remaining = math.max(data.hitAt - now(), 0)
		local guess = predicted
		-- Keep our predicted swing unless the server's timing differs noticeably (say the
		-- string didn't speed up after all); then re-time it to the real impact.
		local alreadyPlaying = isLocal(model)
			and guess ~= nil
			and guess.kind == kind
			and os.clock() - guess.at < PREDICTION_MATCH_WINDOW
			and math.abs((guess.at + guess.windup - os.clock()) - remaining) < 0.08
		if isLocal(model) then
			predicted = nil
			CombatVisuals.lastOwnHitAt = data.hitAt
			local swing = LocalCombat.swing
			local startedAt = if alreadyPlaying and swing then swing.startedAt else now()
			LocalCombat.swing = { kind = kind, startedAt = startedAt, hitAt = data.hitAt, confirmed = true }
		end
		-- Our own predicted swing is re-timed where it stands, never restarted: a restart rewinds the
		-- blade to its first frame a round trip after the click.
		local retimed = isLocal(model) and Animator.retime(model, kind, remaining)
		if not alreadyPlaying and not retimed and not data.boss then
			playClip(model, kind, remaining)
		end

		local perilous = kind == "Perilous" or kind == "Sweep"
		local heavy = kind == "Light3" or kind == "Overhead" or kind == "MikiriSlash" or kind == "Riposte2" or perilous
		if perilous then
			telegraphPerilous(model, remaining)
		end
		if not isLocal(model) then
			predictIncoming(model, kind, data.hitAt)
			glint(model, data.hitAt)
		end
		local swingSpec = specOf(model, kind)
		task.delay(math.max(remaining + (if swingSpec then swingSpec.lungeAt else -0.05), 0), function()
			if not model.Parent then
				return
			end
			playSound(if heavy then SOUNDS.HeavySwing else SOUNDS.Swing, rootOf(model), if heavy then 0.7 else 0.55)
			if isLocal(model) then
				local spec = Weapons.spec(Weapons.of(model), kind)
				lunge(spec.lunge, spec.lungeTime)
			end
		end)
	end,

	Deflect = function(data)
		local attacker: Model, defender: Model = data.attacker, data.defender
		local recoil = data.recoil == true
		if isLocal(attacker) then
			popText(defender, if data.perfect then "PERFECT DEFLECT" else "DEFLECTED", Color3.fromRGB(255, 196, 90))
		end
		if isLocal(defender) then
			-- Opens the riposte after a recoil or a break (also mirrored by prediction).
			LocalCombat.defended(recoil or data.broke == true)
			local pull = data.pull
			if data.broke then
				playClip(defender, "DeflectBreak")
			end
			if data.broke and typeof(pull) == "number" and pull > 0.1 then
				-- The deflect broke them: close in for the deathblow.
				local direction = flatBetween(defender, attacker)
				if direction then
					Motion.surge(direction, 3 * pull / 0.35, 0, 0.35)
				end
			end
		end
		if not alreadyShown(attacker, defender) then
			deflectEffects(attacker, defender, data.perfect, data.kind, recoil)
		elseif
			isLocal(defender)
			and recoil ~= (specOf(attacker, data.kind or "Light1") or { recoilOnDeflect = false }).recoilOnDeflect
		then
			playClip(attacker, recoilClip(specOf(attacker, data.kind), recoil))
		end
	end,

	Guard = function(data)
		local attacker: Model, defender: Model = data.attacker, data.defender
		if isLocal(attacker) then
			popText(defender, "GUARDED", Color3.fromRGB(190, 195, 205))
		end
		if isLocal(defender) then
			LocalCombat.defended(false)
		end
		if not alreadyShown(attacker, defender) then
			guardEffects(attacker, defender, data.kind)
		end
	end,

	Hit = function(data)
		local attacker: Model, defender: Model = data.attacker, data.defender
		if isLocal(attacker) then
			LocalCombat.lastSlashLanded = true -- our next chained slash speeds up
			popText(defender, `-{math.floor((data.damage or 0) + 0.5)}`, Color3.fromRGB(255, 250, 240))
		end
		-- The flinch is sized by the move (Kannagi's DamageReaction), with a knockback slide
		-- and a snap to face the blow on your own screen (bots are moved by the server).
		local kind = data.kind
		local spec = specOf(attacker, kind)
		local reaction = if spec then spec.reaction else "Small"
		if data.flinch ~= false then
			playClip(defender, "Hit" .. reaction)
		end
		if isLocal(defender) then
			LocalCombat.contact()
			local root = rootOf(defender)
			local direction = flatBetween(attacker, defender)
			if data.flinch ~= false and root and direction then
				root.CFrame = CFrame.lookAt(root.Position, root.Position - direction)
				local v = root.AssemblyLinearVelocity
				if v.Y > 0 then
					root.AssemblyLinearVelocity = Vector3.new(v.X, 0, v.Z) -- no juggling
				end
				knockLocal(direction, (if spec then spec.knockback else 1) * Config.Knockback.Hit)
			end
		end
		-- Hits escalate through a string: a longer freeze, a heavier sound and a camera
		-- kick on enders and perilous attacks.
		local ender = reaction ~= "Small"
		hitstop(Config.Visual.HitHitstop[kind] or Config.Visual.Hitstop, attacker, defender)
		local root = rootOf(defender)
		if root then
			bloodSpray(
				root.Position + Vector3.new(0, 0.8, 0),
				blowDirection(attacker, defender),
				if ender then 40 else 26,
				if ender then 28 else 22
			)
		end
		playSound(if math.random() < 0.5 then SOUNDS.Hit else SOUNDS.HitAlt, root, 0.7, if ender then 0.86 else 1)
		if isLocal(defender) or isLocal(attacker) then
			local strength = if isLocal(defender) then 0.5 else 0.25
			shake(if ender then strength * 1.6 else strength, 0.2, attacker, defender)
		end
	end,

	PostureBroken = function(data)
		local model: Model = data.model
		playClip(model, "GuardBreak") -- then the Broken stance holds underneath
		local root = rootOf(model)
		if root then
			burst(root.Position + Vector3.new(0, 1.5, 0), GOLD, 40, 24, 5)
		end
		playSound(SOUNDS.PostureBreak, root, 0.8)
	end,

	Deathblow = function(data)
		local attacker: Model, defender: Model = data.attacker, data.defender
		if isLocal(attacker) then
			popText(defender, `DEATHBLOW  -{Config.DeathblowDamage}`, Color3.fromRGB(230, 50, 40), true)
		end
		playClip(attacker, "Deathblow")
		-- A deathblow on an unwounded fighter knocks them down instead of killing.
		playClip(defender, if data.lethal == false then "HitReact" else "Executed")
		hitstop(Config.Visual.DeathblowHitstop, attacker, defender)
		local root = rootOf(defender)
		if root then
			local direction = blowDirection(attacker, defender)
			-- The cut lands a beat into the deathblow clip: a long arc of blood, then pools.
			bloodSpray(root.Position + Vector3.new(0, 0.6, 0), direction, 90, 34)
			flare(root.Position + Vector3.new(0, 0.6, 0), BLOOD, 10)
			task.delay(0.12, function()
				if root.Parent then
					bloodSpray(root.Position + Vector3.new(0, 0.2, 0), direction, 40, 20)
					bloodPool(root.Position, direction)
				end
			end)
		end
		playSound(SOUNDS.PostureBreak, root, 0.9, 0.8)
		playSound(SOUNDS.HitAlt, root, 0.9, 0.85)
		if isLocal(attacker) or isLocal(defender) then
			shake(0.9, 0.35, attacker, defender)
			deathblowGrade()
		end
		if isLocal(attacker) and data.lethal ~= false then
			-- Your killing deathblow: the lens punches in and eases back, a beat of cinema.
			local camera = workspace.CurrentCamera
			local base = camera.FieldOfView
			TweenService:Create(camera, TweenInfo.new(0.09, Enum.EasingStyle.Quad), { FieldOfView = base - 16 }):Play()
			task.delay(0.35, function()
				TweenService:Create(
					camera,
					TweenInfo.new(0.6, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut),
					{ FieldOfView = LockOn.baseFov() } -- the lock may have let go meanwhile
				):Play()
			end)
		end
	end,

	-- Cut down with a resurrection left: they sink to their knees, then rise in a burst of
	-- red light.
	CutDown = function(data)
		local model: Model = data.model
		playClip(model, "Executed")
		local root = rootOf(model)
		if root then
			flare(root.Position, BLOOD, 8)
		end
		playSound(SOUNDS.PostureBreak, root, 0.7, 0.6)
	end,

	Resurrected = function(data)
		local model: Model = data.model
		playClip(model, "Revive")
		local root = rootOf(model)
		if root then
			burst(root.Position + Vector3.new(0, 1, 0), Color3.fromRGB(255, 70, 60), 50, 30, 6)
			flare(root.Position + Vector3.new(0, 1, 0), Color3.fromRGB(255, 90, 70), 14)
		end
		playSound(SOUNDS.PerfectDeflect, root, 0.9, 0.55)
		if isLocal(model) then
			shake(0.5, 0.3, model, model)
		end
	end,

	Died = function(data)
		local model: Model = data.model
		local current = Animator.current(model)
		-- A boss already lies in its own death anim (BossVisuals holds it): don't kneel it back up.
		local bossDeath = current ~= nil and string.find(current, "_Die", 1, true) ~= nil
		if current ~= "Executed" and not bossDeath then
			playClip(model, "Executed")
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

	-- A second jump press over a sweeper: a stomp on their head.
	Stomp = function(data)
		local attacker: Model, defender: Model = data.attacker, data.defender
		local root = rootOf(attacker)
		if root then
			burst(root.Position + Vector3.new(0, 2.6, 0), GOLD, 30, 20, 4.5)
		end
		playSound(SOUNDS.Guard, root, 0.85, 0.75)
		playSound(SOUNDS.PostureBreak, root, 0.6, 1.3)
		playClip(attacker, "HitLarge")
		playClip(defender, "Mikiri")
		hitstop(Config.Visual.Hitstop, attacker, defender)
		if isLocal(defender) then
			local mine = rootOf(defender)
			if mine then
				local v = mine.AssemblyLinearVelocity
				mine.AssemblyLinearVelocity = Vector3.new(v.X, Config.Stomp.Launch, v.Z)
			end
		end
		if isLocal(attacker) or isLocal(defender) then
			shake(0.6, 0.25, defender, attacker)
		end
		if isLocal(defender) then
			popText(attacker, "STOMP", GOLD, true)
		end
	end,

	Jumped = function(data)
		-- A clean evade: a soft puff of dust where the blow passed, no text.
		local root = rootOf(data.defender)
		if root then
			burst(root.Position - Vector3.new(0, 2.4, 0), Color3.fromRGB(180, 168, 150), 10, 8, 1.5)
		end
	end,

	Mikiri = function(data)
		local attacker: Model, defender: Model = data.attacker, data.defender
		playClip(defender, "Mikiri")
		playClip(attacker, "Recoil")
		if isLocal(defender) then
			-- The counter slides you onto the blade and opens the MikiriSlash follow-up.
			LocalCombat.mikiriUntil = now() + Config.Mikiri.FollowWindow
			LocalCombat.contact()
			local direction = flatBetween(defender, attacker)
			local distance = data.lunge
			if direction and typeof(distance) == "number" and distance > 0.1 then
				Motion.surge(direction, 3 * distance / 0.5, 0, 0.5)
			end
		end
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
			shake(0.6, 0.2, attacker, defender)
		end
	end,

	Drink = function(data)
		local model: Model = data.model
		playClip(model, "Drink")
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
		if isLocal(data.model) then
			LocalCombat.attackingUntil = 0
		end
	end,

	Interrupted = function(data)
		Animator.stop(data.model)
		if isLocal(data.model) then
			LocalCombat.attackingUntil = 0
		end
	end,
}

-- Reaction clips that end with the stun or recoil they show.
local STUN_CLIPS: { [string]: boolean } = {
	HitSmall = true,
	HitMiddle = true,
	HitLarge = true,
	HitGedan = true,
	HitReact = true,
	Recoil = true,
	RecoilLeft = true,
	Knocked = true,
	GuardBreak = true,
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
		-- Kannagi's reaction clips run longer than our stuns (HitSmall 0.63 s vs 0.25 s): when the
		-- stun or recoil ends, blend out so the reaction never hides that the fighter is free.
		local state = model:GetAttribute("CombatState")
		local clip = Animator.current(model)
		if state == "Idle" and clip and STUN_CLIPS[clip] then
			Animator.stop(model)
		end
	end)
	-- Jumps play Kannagi's jump clip (on every client that sees the humanoid jump).
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.StateChanged:Connect(function(_, new)
			if new == Enum.HumanoidStateType.Jumping and model:GetAttribute("CombatState") == "Idle" then
				playClip(model, "Jump")
			end
		end)
	end
end

function CombatVisuals.start()
	Animator.start()

	-- Studio-only: lets tooling sample a clip at an exact time, e.g.
	-- AnimTest:Invoke("sample", model, "Light1", 0.5, 0.2) plays it, then freezes 0.2 s in.
	if RunService:IsStudio() then
		local hook = Instance.new("BindableFunction")
		hook.Name = "AnimTest"
		hook.OnInvoke = function(command: string, model: Model, clip: string, windup: number, at: number)
			if command == "sample" then
				Animator.unfreeze(model)
				Animator.play(model, clip, windup)
				task.wait(at)
				Animator.freeze(model, 30)
			elseif command == "pose" then
				-- Hold a named pose as the stance until released (clip = pose name).
				heldTestPose = clip
				Animator.setBase(model, clip)
			elseif command == "legacyChain" then
				Animator.legacyChain = clip == "on" -- A/B the old clip chaining
			elseif command == "trace" then
				-- Start (model given) or stop and collect (nil) a per-frame trace of the animator.
				local log = Animator.traceLog
				Animator.traceModel = model
				Animator.traceLog = {}
				return log
			elseif command == "release" then
				heldTestPose = nil
				Animator.unfreeze(model)
				Animator.stop(model)
			end
			return true
		end
		hook.Parent = player:WaitForChild("PlayerScripts")
	end

	combatEvent.OnClientEvent:Connect(function(kind: string, data: { [string]: any })
		-- Anyone swinging or being swung at is in combat for a few seconds.
		for _, key in { "attacker", "defender", "model" } do
			local model = data[key]
			if typeof(model) == "Instance" and model:IsA("Model") then
				local wasInCombat = inCombat(model)
				lastCombatAt[model] = os.clock()
				if not wasInCombat then
					refreshBase(model)
				end
			end
		end
		local handler = handlers[kind]
		if handler then
			handler(data)
		end
	end)

	-- Drop back to the relaxed stance once a fight has gone quiet.
	task.spawn(function()
		while true do
			task.wait(0.5)
			for _, instance in CollectionService:GetTagged(Types.Tag) do
				if instance:IsA("Model") then
					refreshBase(instance)
				end
			end
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
