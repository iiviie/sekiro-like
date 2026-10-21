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
local TweenService = game:GetService("TweenService")

local Animator = require(script.Parent.Animator)
local Audio = require(script.Parent.Audio)
local CombatHUD = require(script.Parent.CombatHUD)
local LocalCombat = require(script.Parent.LocalCombat)
local LockOn = require(script.Parent.LockOn)
local Motion = require(script.Parent.Motion)
local UI = require(script.Parent.UI)
local Assets = require(ReplicatedStorage.Shared.Assets)
local Config = require(ReplicatedStorage.Shared.Config)
local Types = require(ReplicatedStorage.Shared.Types)
local Bosses = require(ReplicatedStorage.Shared.Bosses)
local Blades = require(ReplicatedStorage.Shared.Cosmetics.Blades)
local Cosmetics = require(ReplicatedStorage.Shared.Cosmetics)
local CosmeticFX = require(script.Parent.CosmeticFX)
local Spacing = require(ReplicatedStorage.Shared.Spacing)
local Weapons = require(ReplicatedStorage.Shared.Weapons)

local combatEvent = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("CombatEvent") :: RemoteEvent
local player = Players.LocalPlayer

local GOLD = Color3.fromRGB(255, 214, 110)
local SPARK = Color3.fromRGB(255, 185, 90)
-- Hits throw sumi ink, not blood: the ink-and-brush look, and no gore on screen.
local INK = Color3.fromRGB(26, 22, 26)
local INK_WASH = Color3.fromRGB(70, 62, 70)
local CRIMSON = Color3.fromRGB(196, 40, 40) -- a flash of light, not a fluid
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

local function isLocal(model: Model?): boolean
	return model ~= nil and model == player.Character
end

-- Cue `key` (client/Audio: variations, 3D voices, music ducking) at a fighter; `focus` when
-- the moment is yours (it may duck the music).
local function playSound(key: string, at: BasePart?, focus: boolean?, pitch: number?)
	if at then
		Audio.play(key, { at = at, focus = focus, pitch = pitch })
	end
end

-- Near enough to your own body that a moment there is yours.
local function close(part: BasePart?): boolean
	local mine = rootOf(player.Character)
	return part ~= nil and mine ~= nil and (part.Position - mine.Position).Magnitude < 25
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

-- Studio test aid: the workspace attribute VfxSlowMo (0.02-1) slows the slash smears, sparks
-- and impact flashes (not the fight) so a screen capture can land mid-strike.
local IS_STUDIO = RunService:IsStudio()
local function vfxSlow(): number
	if not IS_STUDIO then
		return 1
	end
	local slow = workspace:GetAttribute("VfxSlowMo")
	return if typeof(slow) == "number" and slow > 0 and slow < 1 then math.max(slow, 0.02) else 1
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
	Debris:AddItem(anchor, 1.5 / vfxSlow())
	return anchor
end

-- Settings > reduced effects (a local player attribute like the other settings): fewer
-- particles, no lights, shorter smears.
local function reducedEffects(): boolean
	return player:GetAttribute("SettingReducedEffects") == true
end

local function scaled(count: number): number
	return if reducedEffects() then math.ceil(count * 0.4) else count
end

-- How much of an effect at a point is worth drawing for this camera: the arenas are hundreds
-- of studs apart, so a lobby player doesn't build every royale exchange. 2 = full, 1 = cheap
-- (half the particles, no lens stars, no lights), 0 = nothing. Gameplay cues (the perilous
-- kanji and outline, the glint, sounds) aren't gated.
local FULL_DETAIL_RANGE = 80
local ANY_DETAIL_RANGE = 200
local LIGHT_RANGE = 45 -- per-hit PointLights only this close
local function detailAt(position: Vector3): number
	local camera = workspace.CurrentCamera
	if not camera then
		return 2
	end
	local distance = (camera.CFrame.Position - position).Magnitude
	return if distance <= FULL_DETAIL_RANGE then 2 elseif distance <= ANY_DETAIL_RANGE then 1 else 0
end

local WHITE = Color3.new(1, 1, 1)

-- A bright bloom at a point in the world (deflects, impacts, Mikiri). `star` adds a lens
-- star: two thin crossed streaks that pinch shut as the bloom fades.
local function flare(position: Vector3, color: Color3, size: number, star: boolean?)
	local detail = detailAt(position)
	if detail == 0 then
		return
	end
	star = star and detail == 2
	local anchor = anchorAt(position)
	local gui = Instance.new("BillboardGui")
	gui.Adornee = anchor
	gui.AlwaysOnTop = true
	gui.LightInfluence = 0
	gui.Brightness = 2
	gui.Size = UDim2.fromScale(size, size)
	local glow = Instance.new("ImageLabel")
	glow.BackgroundTransparency = 1
	glow.Image = Assets.UI.Glow
	glow.ImageColor3 = color
	glow.Size = UDim2.fromScale(0.3, 0.3)
	glow.AnchorPoint = Vector2.new(0.5, 0.5)
	glow.Position = UDim2.fromScale(0.5, 0.5)
	glow.Parent = gui
	-- A small white-hot core inside the coloured bloom.
	local core = glow:Clone()
	core.ImageColor3 = WHITE
	core.Size = UDim2.fromScale(0.25, 0.25)
	core.Parent = gui
	local slow = vfxSlow()
	local out = TweenInfo.new(0.22 / slow, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	TweenService:Create(glow, out, { Size = UDim2.fromScale(1, 1), ImageTransparency = 1 }):Play()
	TweenService:Create(core, TweenInfo.new(0.12 / slow, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = UDim2.fromScale(0.45, 0.45),
		ImageTransparency = 1,
	}):Play()
	if star then
		local tilt = math.random(-25, 25)
		for i = 0, 1 do
			local ray = glow:Clone()
			ray.ImageColor3 = color:Lerp(WHITE, 0.6)
			ray.ImageTransparency = 0
			ray.Rotation = tilt + i * 90
			ray.Size = UDim2.fromScale(if i == 0 then 1.5 else 0.9, 0.05)
			ray.Parent = gui
			TweenService:Create(ray, TweenInfo.new(0.26 / slow, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
				Size = UDim2.fromScale(if i == 0 then 1.9 else 1.1, 0),
				ImageTransparency = 1,
			}):Play()
		end
	end
	gui.Parent = anchor
end

-- Hot streaking sparks, a light flash and a bloom. With a `direction` most of the sparks spray
-- along it (the way the blow carried them) and the rest scatter.
local function burst(
	position: Vector3,
	color: Color3,
	count: number,
	speed: number,
	flashSize: number,
	direction: Vector3?
)
	local detail = detailAt(position)
	if detail == 0 then
		return
	end
	local anchor = anchorAt(position)
	if direction and direction.Magnitude > 0.01 then
		anchor.CFrame = CFrame.lookAt(position, position + direction)
	end
	count = scaled(if detail == 2 then count else math.ceil(count / 2))

	local sparks = Instance.new("ParticleEmitter")
	sparks.Texture = Assets.UI.Glow
	sparks.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, WHITE),
		ColorSequenceKeypoint.new(0.35, WHITE:Lerp(color, 0.6)),
		ColorSequenceKeypoint.new(1, color),
	})
	sparks.LightEmission = 1
	sparks.LightInfluence = 0
	sparks.Brightness = 3
	sparks.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.2), NumberSequenceKeypoint.new(1, 0.02) })
	sparks.Speed = NumberRange.new(speed * 0.45, speed)
	sparks.EmissionDirection = Enum.NormalId.Front
	sparks.Lifetime = NumberRange.new(0.12, 0.34)
	sparks.Acceleration = Vector3.new(0, -50, 0)
	sparks.Drag = 5
	sparks.Rate = 0
	sparks.Orientation = Enum.ParticleOrientation.VelocityParallel
	sparks.Squash = NumberSequence.new(2.6) -- long thin streaks along the velocity
	sparks.TimeScale = vfxSlow()
	sparks.Parent = anchor
	if direction then
		sparks.SpreadAngle = Vector2.new(55, 55)
		sparks:Emit(math.ceil(count * 0.7))
		sparks.SpreadAngle = Vector2.new(180, 180)
		sparks:Emit(math.ceil(count * 0.3))
	else
		sparks.SpreadAngle = Vector2.new(180, 180)
		sparks:Emit(count)
	end

	local camera = workspace.CurrentCamera
	local near = camera ~= nil and (camera.CFrame.Position - position).Magnitude <= LIGHT_RANGE
	if near and not reducedEffects() then
		local light = Instance.new("PointLight")
		light.Color = color
		light.Brightness = 3
		light.Range = 10
		light.Shadows = false
		light.Parent = anchor
		TweenService:Create(light, TweenInfo.new(0.25 / vfxSlow()), { Brightness = 0 }):Play()
	end

	flare(position, color:Lerp(WHITE, 0.35), flashSize * 1.6)
end

-- A sword's edge in the world, guard to tip (its trail attachments), if it has one.
local function bladeLine(model: Model): (Vector3?, Vector3?)
	local sword = model:FindFirstChild("Sword")
	local from = sword and sword:FindFirstChild("TrailStart")
	local to = sword and sword:FindFirstChild("TrailEnd")
	if from and to and from:IsA("Attachment") and to:IsA("Attachment") then
		return from.WorldPosition, to.WorldPosition
	end
	return nil, nil
end

-- The closest points of segments p1-q1 and p2-q2 (Ericson, Real-Time Collision Detection 5.1.9).
local function closestBetween(p1: Vector3, q1: Vector3, p2: Vector3, q2: Vector3): (Vector3, Vector3)
	local d1, d2, r = q1 - p1, q2 - p2, p1 - p2
	local a, e, f = d1:Dot(d1), d2:Dot(d2), d2:Dot(r)
	local s, t
	if a < 1e-6 and e < 1e-6 then
		return p1, p2
	elseif a < 1e-6 then
		s, t = 0, math.clamp(f / e, 0, 1)
	else
		local c = d1:Dot(r)
		if e < 1e-6 then
			s, t = math.clamp(-c / a, 0, 1), 0
		else
			local b = d1:Dot(d2)
			local denom = a * e - b * b
			s = if denom > 1e-6 then math.clamp((b * f - c * e) / denom, 0, 1) else 0
			t = (b * s + f) / e
			if t < 0 then
				s, t = math.clamp(-c / a, 0, 1), 0
			elseif t > 1 then
				s, t = math.clamp((b - c) / a, 0, 1), 1
			end
		end
	end
	return p1 + d1 * s, p2 + d2 * t
end

-- Where two blades meet: the nearest points of the two edges when they really cross on this
-- screen, else partway up the defender's blade.
local function contactPoint(attacker: Model, defender: Model): Vector3?
	local guard, tip = bladeLine(defender)
	if guard and tip then
		local theirGuard, theirTip = bladeLine(attacker)
		if theirGuard and theirTip then
			local mine, theirs = closestBetween(guard, tip, theirGuard, theirTip)
			if (mine - theirs).Magnitude < 2.5 then
				return (mine + theirs) / 2
			end
		end
		return guard:Lerp(tip, 0.55)
	end
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

---------------------------------------------------------------------------------------
-- Slash smears
--
-- The blade's sweep drawn as a crescent of light in the swing plane. While Animator has the
-- sword's Trail switched on (the strike phase of every clip; the Trail itself is hidden here
-- and only serves as that signal and its colour), the blade's CFrame is sampled every frame
-- and the motion between two samples is subdivided by interpolating the CFrame, so a 70 ms
-- cut spanning four frames still draws a smooth arc. Each piece of the arc is one flat Beam
-- running from the inner edge out to the blade's edge (TrailStart to TrailEnd: the radius and
-- width come from the sword's own attachments), whose gradient along its length is clear near
-- the hilt with a hot core just inside the edge. As a piece ages it fades and its inner end
-- creeps out toward the edge, so the trailing end of the arc thins into a crescent. Beams are
-- pooled; a frame allocates no instances.

local SMEAR_LIFE = 0.24 -- seconds a piece of the arc lingers
local SMEAR_LIFE_HEAVY = 0.3
local SMEAR_STEP = 0.7 -- studs of tip travel per piece
local SMEAR_MAX_SPLIT = 8 -- pieces per blade per frame at most
local SMEAR_MAX_PIECES = 72 -- per blade
local SMEAR_RANGE = 220 -- studs from the camera
local SMEAR_OVERLAP = 1.03 -- pieces overlap a little so no seam shows between them
local SMEAR_INNER = 0.06 -- a fresh piece's inner end, as a fraction of TrailStart..TrailEnd
local SMEAR_INNER_AGED = 0.7 -- ...and where it has crept to as the piece dies
local FADE_LEVELS = 12
-- A piece whose middle comes this close to the camera fades out (gone by SMEAR_NEAR_GONE),
-- so a blade swung past the lens doesn't paint a sheet over half the screen.
local SMEAR_NEAR = 8
local SMEAR_NEAR_GONE = 3.5
local POOL_CAP = 260

-- Transparency along a piece, inner end (0) to the edge (1), at full strength.
local PROFILE = { { 0, 1 }, { 0.3, 0.93 }, { 0.6, 0.66 }, { 0.84, 0.25 }, { 0.95, 0 }, { 1, 0.35 } }
local FADE: { NumberSequence } = {}
for level = 1, FADE_LEVELS do
	local opacity = level / FADE_LEVELS
	local points = {}
	for i, point in PROFILE do
		points[i] = NumberSequenceKeypoint.new(point[1], 1 - (1 - point[2]) * opacity)
	end
	FADE[level] = NumberSequence.new(points)
end

local HIDDEN = NumberSequence.new(1)
local ANIMATOR_PERIL = Color3.fromRGB(255, 90, 70) -- client/Animator PERIL_TRAIL's first colour
local PERIL_CORE = Color3.fromRGB(255, 150, 125)
local PERIL_BODY = Color3.fromRGB(215, 25, 22)

local gradients: { [string]: ColorSequence } = {}
local function smearGradient(core: Color3, body: Color3): ColorSequence
	local key = core:ToHex() .. body:ToHex()
	local cached = gradients[key]
	if cached then
		return cached
	end
	local sequence = ColorSequence.new({
		ColorSequenceKeypoint.new(0, body),
		ColorSequenceKeypoint.new(0.6, body:Lerp(core, 0.45)),
		ColorSequenceKeypoint.new(0.93, core:Lerp(WHITE, 0.6)),
		ColorSequenceKeypoint.new(1, core),
	})
	gradients[key] = sequence
	return sequence
end

type Quad = { a0: Attachment, a1: Attachment, beam: Beam }
type Piece = {
	quad: Quad,
	hilt: Vector3,
	tip: Vector3,
	hiltChord: Vector3,
	tipChord: Vector3,
	born: number,
	level: number,
}
type Track = { blade: BasePart, from: Vector3, to: Vector3, last: CFrame?, pieces: { Piece } }
type Smear = {
	model: Model,
	tracks: { Track },
	t: number,
	life: number,
	live: boolean,
	gradient: ColorSequence,
	emission: number,
	brightness: number,
	style: Blades.SmearStyle?, -- a blade line's L2 extras along the arc (client/CosmeticFX)
	pieces: number,
}
type Fighter = { sword: BasePart?, trail: Trail?, blades: { BasePart }, prev: { CFrame }, retryAt: number }

local smearPool: { Quad } = {}
local smears: { Smear } = {}
local liveSmear: { [Model]: Smear } = {}
local fighters: { [Model]: Fighter } = {}
local frozenUntil: { [Model]: number } = {} -- hitstop holds a smear where it is
local perilUntil: { [Model]: number } = {} -- a 危 attack is coming: its arc burns red
local heavyKind: { [Model]: boolean } = {}
local sweepDir: { [Model]: Vector3 } = {} -- the blade's latest direction of travel
local sweepAt: { [Model]: number } = {}
-- Per-model bookkeeping kept further down (the deflect chain, predicted defences, combat
-- stance), declared here so stepSmears can sweep out models that are gone.
local chainAt: { [Model]: number } = {}
local chainCount: { [Model]: number } = {}
local predictedDefences: { [Model]: number } = {}
local lastCombatAt: { [Model]: number } = {}
local MODEL_TABLES = { chainAt, chainCount, predictedDefences, lastCombatAt } :: { { [Model]: any } }
local SWEEP_INTERVAL = 2
local nextSweepAt = 0

local function acquireQuad(): Quad
	local quad = table.remove(smearPool)
	if quad then
		quad.beam.Enabled = true
		return quad
	end
	local terrain = workspace.Terrain
	local a0 = Instance.new("Attachment")
	a0.Name = "SmearInner"
	a0.Parent = terrain
	local a1 = Instance.new("Attachment")
	a1.Name = "SmearEdge"
	a1.Parent = terrain
	local beam = Instance.new("Beam")
	beam.Name = "Smear"
	beam.Attachment0 = a0
	beam.Attachment1 = a1
	beam.FaceCamera = false
	beam.Segments = 1
	beam.LightInfluence = 0
	beam.Parent = terrain
	return { a0 = a0, a1 = a1, beam = beam }
end

local function releaseQuad(quad: Quad)
	quad.beam.Enabled = false
	if #smearPool < POOL_CAP then
		table.insert(smearPool, quad)
	else
		quad.beam:Destroy()
		quad.a0:Destroy()
		quad.a1:Destroy()
	end
end

-- Puts one end of a smear piece at `position` spanning `chord`: a Beam that doesn't face the
-- camera lays each end's width along that attachment's own Y axis, so with Y on the chord and
-- the width its length, the piece's corners land exactly on the sampled hilt and tip points and
-- neighbouring pieces tile without gaps, however the blade twists.
local function place(attachment: Attachment, position: Vector3, along: Vector3, chord: Vector3)
	local y = chord.Unit
	local x = along - y * along:Dot(y)
	if x.Magnitude < 1e-4 then
		return
	end
	x = x.Unit
	attachment.CFrame = CFrame.fromMatrix(position, x, y, x:Cross(y))
end

local function addPiece(smear: Smear, track: Track, a: CFrame, b: CFrame, born: number)
	if #track.pieces >= SMEAR_MAX_PIECES then
		return
	end
	local ha, hb = a * track.from, b * track.from
	local ta, tb = a * track.to, b * track.to
	local tipSweep = tb - ta
	if tipSweep.Magnitude < 1e-3 then
		return
	end
	local hilt, tip = (ha + hb) / 2, (ta + tb) / 2
	local quad = acquireQuad()
	local beam = quad.beam
	beam.Color = smear.gradient
	beam.LightEmission = smear.emission
	beam.Brightness = smear.brightness
	beam.Width1 = tipSweep.Magnitude * SMEAR_OVERLAP
	place(quad.a1, tip, tip - hilt, tipSweep)
	table.insert(track.pieces, {
		quad = quad,
		hilt = hilt,
		tip = tip,
		hiltChord = hb - ha,
		tipChord = tipSweep,
		born = born,
		level = -1,
	})
	if track.blade.Name == "Sword" then
		sweepDir[smear.model] = tipSweep.Unit
		sweepAt[smear.model] = os.clock()
		local style = smear.style
		if style then
			smear.pieces += 1
			CosmeticFX.smearPiece(style, smear.pieces, tip, tipSweep)
		end
	end
end

local function sampleTrack(smear: Smear, track: Track, dt: number)
	local blade = track.blade
	if not blade.Parent then
		return
	end
	local cf = blade.CFrame
	local last = track.last
	track.last = cf
	if not last then
		return
	end
	local travel = ((cf * track.to) - (last * track.to)).Magnitude
	if travel < 0.04 then
		return
	end
	local splits = math.clamp(math.ceil(travel / SMEAR_STEP), 1, SMEAR_MAX_SPLIT)
	local previous = last
	for k = 1, splits do
		local nextCf = last:Lerp(cf, k / splits)
		addPiece(smear, track, previous, nextCf, smear.t - dt * (1 - k / splits))
		previous = nextCf
	end
end

-- Ages a blade's pieces; returns whether any are left.
local function updatePieces(smear: Smear, track: Track, eye: Vector3): boolean
	local pieces = track.pieces
	local kept = 0
	for i = 1, #pieces do
		local piece = pieces[i]
		local u = (smear.t - piece.born) / smear.life
		if u >= 1 then
			releaseQuad(piece.quad)
		else
			kept += 1
			pieces[kept] = piece
			u = math.max(u, 0)
			local f = SMEAR_INNER + (SMEAR_INNER_AGED - SMEAR_INNER) * u
			local inner = piece.hilt:Lerp(piece.tip, f)
			local near = math.clamp(
				(((inner + piece.tip) / 2 - eye).Magnitude - SMEAR_NEAR_GONE) / (SMEAR_NEAR - SMEAR_NEAR_GONE),
				0,
				1
			)
			local strength = (1 - u) * near
			local level = math.ceil(strength * math.sqrt(strength) * FADE_LEVELS)
			if near >= 1 then
				level = math.max(level, 1)
			end
			local beam = piece.quad.beam
			if level ~= piece.level then
				piece.level = level
				beam.Transparency = if level == 0 then HIDDEN else FADE[level]
			end
			local chord = piece.hiltChord:Lerp(piece.tipChord, f)
			if chord.Magnitude < 1e-3 then
				chord = piece.tipChord * 1e-3 -- the blade pivots here: the piece pinches to a point
			end
			beam.Width0 = chord.Magnitude * SMEAR_OVERLAP
			place(piece.quad.a0, inner, piece.tip - inner, chord)
		end
	end
	for i = kept + 1, #pieces do
		pieces[i] = nil
	end
	return kept > 0
end

local function startSmear(model: Model, fighter: Fighter, trail: Trail, clock: number): Smear?
	local sword = fighter.sword
	local camera = workspace.CurrentCamera
	if not sword or not camera or (camera.CFrame.Position - sword.Position).Magnitude > SMEAR_RANGE then
		return nil
	end
	-- Red when Animator's Trail says the clip is perilous (Perilous, Sweep) or a 危 tell says
	-- this cut is, whatever the clip; otherwise the blade's own colours (Shared/Cosmetics: the
	-- skin, or a blade line, whose L2 adds its petals / bolts / feathers along the arc).
	local first = trail.Color.Keypoints[1].Value
	local perilous = clock < (perilUntil[model] or 0) or first == ANIMATOR_PERIL
	local look = Cosmetics.blade(model)
	local core = if perilous then PERIL_CORE else look.trail[1]
	local body = if perilous then PERIL_BODY else look.trail[2]
	local reds = core.R > core.B + 0.25
	local dark = look.dark and not perilous
	local smear: Smear = {
		model = model,
		tracks = {},
		t = 0,
		life = if reducedEffects()
			then SMEAR_LIFE * 0.6
			elseif perilous or heavyKind[model] then SMEAR_LIFE_HEAVY
			else SMEAR_LIFE,
		live = true,
		gradient = smearGradient(core, body),
		-- Additive glow washes a red arc out to pink in daylight, so red stays mostly solid; an
		-- ink-dark line blade (Karasu) isn't light at all.
		emission = if dark then 0 elseif reds then 0.2 else 0.4,
		brightness = if dark then 1 elseif reds then 1.2 else 1.1,
		style = if perilous then nil else look.smear,
		pieces = 0,
	}
	for i, blade in fighter.blades do
		local from = blade:FindFirstChild("TrailStart")
		local to = blade:FindFirstChild("TrailEnd")
		if from and to and from:IsA("Attachment") and to:IsA("Attachment") then
			table.insert(smear.tracks, {
				blade = blade,
				from = from.Position,
				to = to.Position,
				last = fighter.prev[i], -- last frame's pose, so the strike's first frame counts
				pieces = {},
			})
		end
	end
	table.insert(smears, smear)
	return smear
end

-- The motes a blade sheds (Shared/Cosmetics/BladeLook) thin out under reduced effects.
local function scaleMotes(sword: Instance)
	local factor = if reducedEffects() then 0.35 else 1
	for _, e in sword:GetDescendants() do
		local base = e:GetAttribute("BaseRate")
		if e:IsA("ParticleEmitter") and typeof(base) == "number" then
			e.Rate = base * factor
		end
	end
end

-- Finds a fighter's sword and Trail again after a respawn or re-rig, and hides the Trail.
local function refreshFighter(model: Model, fighter: Fighter)
	fighter.sword, fighter.trail = nil, nil
	table.clear(fighter.blades)
	table.clear(fighter.prev)
	local sword = model:FindFirstChild("Sword")
	local trail = sword and sword:FindFirstChildOfClass("Trail")
	if not sword or not sword:IsA("BasePart") or not trail then
		return
	end
	fighter.sword, fighter.trail = sword, trail
	table.insert(fighter.blades, sword)
	local second = model:FindFirstChild("Sword2") -- Niten's off-hand katana
	if second and second:IsA("BasePart") then
		table.insert(fighter.blades, second)
	end
	for _, blade in fighter.blades do
		local legacy = blade:FindFirstChildOfClass("Trail")
		if legacy then
			legacy.Transparency = HIDDEN -- the smear replaces it; Animator still switches it
		end
	end
	scaleMotes(sword)
end

---------------------------------------------------------------------------------------
-- Thrust streaks
--
-- A thrust drives the blade along its own length, so its smear is only a sliver. Every move
-- whose spec says `thrust` (the perilous thrust and the bosses' Tsuki, so also the blade a
-- Mikiri steps on) adds a straight streak: a tapered line of light from where the guard was
-- as the strike began to past the tip, stretching with the blade while the strike plays, then
-- fading as its tail closes up toward the point and the point drifts on (the afterimage). A
-- hot core inside a soft halo; red for perilous. The beams come from the smear pool and face
-- the camera only while they're in use.

local THRUST_EARLY = 0.3 -- the strike may begin this long before the hit...
local THRUST_LATE = 0.25 -- ...or this long after it
local THRUST_TRACK = 0.22 -- seconds the streak follows the blade at most
local THRUST_LIFE = 0.24 -- seconds it fades over once the strike is done
local THRUST_LIFE_REDUCED = 0.15
local THRUST_OVERSHOOT = 2.4 -- studs of point past the tip
local THRUST_DRIFT = 1.2 -- how much further the point runs on while it fades
local THRUST_WIDTH = 0.38 -- the core's width at the tip
local THRUST_HALO = 3.4 -- the halo is this many times wider

-- Transparency along the shaft (tail to tip) and the point (tip to end), at full strength.
local SHAFT_PROFILE = { { 0, 1 }, { 0.35, 0.7 }, { 0.8, 0.12 }, { 1, 0 } }
local POINT_PROFILE = { { 0, 0 }, { 0.6, 0.25 }, { 1, 1 } }
local function fadeLevels(profile: { { number } }, floor: number): { NumberSequence }
	local levels = {}
	for level = 1, FADE_LEVELS do
		local opacity = level / FADE_LEVELS * (1 - floor)
		local points = {}
		for i, point in profile do
			points[i] = NumberSequenceKeypoint.new(point[1], 1 - (1 - point[2]) * opacity)
		end
		levels[level] = NumberSequence.new(points)
	end
	return levels
end
local SHAFT_CORE, POINT_CORE = fadeLevels(SHAFT_PROFILE, 0), fadeLevels(POINT_PROFILE, 0)
local SHAFT_HALO, POINT_HALO = fadeLevels(SHAFT_PROFILE, 0.5), fadeLevels(POINT_PROFILE, 0.5)

type StreakPart = { quad: Quad, shaft: boolean, halo: boolean }
type Streak = {
	model: Model,
	blade: BasePart,
	from: Vector3, -- TrailStart / TrailEnd in the blade's space
	to: Vector3,
	tail: Vector3, -- world: the guard as the strike began
	tip: Vector3, -- world: the furthest the tip got
	dir: Vector3,
	startedAt: number,
	tracking: boolean,
	t: number, -- fade time (slowed by VfxSlowMo, held by hitstop)
	life: number,
	level: number,
	parts: { StreakPart },
}

local thrustStreaks: { Streak } = {}
local thrustAt: { [Model]: number } = {} -- os.clock() a thrust's hit lands, until its streak starts

local function startStreak(model: Model, fighter: Fighter, trail: Trail, clock: number)
	local blade = fighter.sword
	local camera = workspace.CurrentCamera
	if not blade or not camera or (camera.CFrame.Position - blade.Position).Magnitude > SMEAR_RANGE then
		return
	end
	local from = blade:FindFirstChild("TrailStart")
	local to = blade:FindFirstChild("TrailEnd")
	if not from or not to or not from:IsA("Attachment") or not to:IsA("Attachment") then
		return
	end
	local guard, tip = from.WorldPosition, to.WorldPosition
	if (tip - guard).Magnitude < 0.5 then
		return
	end
	local first = trail.Color.Keypoints[1].Value
	local perilous = clock < (perilUntil[model] or 0) or first == ANIMATOR_PERIL
	local look = Cosmetics.blade(model)
	local core = if perilous then PERIL_CORE else look.trail[1]
	local body = if perilous then PERIL_BODY else look.trail[2]
	local reds = core.R > core.B + 0.25
	-- The core's colour at the tip: white-hot steel, or a red that stays red under bloom.
	local hot = if reds then core:Lerp(body, 0.45) else core:Lerp(WHITE, 0.7)
	local reduced = reducedEffects()
	local streak: Streak = {
		model = model,
		blade = blade,
		from = from.Position,
		to = to.Position,
		tail = guard,
		tip = tip,
		dir = (tip - guard).Unit,
		startedAt = clock,
		tracking = true,
		t = 0,
		life = if reduced then THRUST_LIFE_REDUCED else THRUST_LIFE,
		level = -1,
		parts = {},
	}
	for _, halo in (if reduced then { false } else { true, false }) do
		for _, shaft in { true, false } do
			local quad = acquireQuad()
			local beam = quad.beam
			beam.FaceCamera = true
			beam.Color = if halo
				then ColorSequence.new(body)
				elseif shaft then ColorSequence.new(if reds then body else body:Lerp(core, 0.5), hot)
				else ColorSequence.new(hot, if reds then body else core)
			-- Additive glow washes red out to orange and pink in daylight, so red stays mostly solid.
			beam.LightEmission = if reds then (if halo then 0 else 0.15) elseif halo then 0.5 else 0.8
			beam.Brightness = if halo then 1.4 elseif reds then 1.8 else 3
			table.insert(streak.parts, { quad = quad, shaft = shaft, halo = halo })
		end
	end
	table.insert(thrustStreaks, streak)
end

local function releaseStreak(streak: Streak)
	for _, part in streak.parts do
		part.quad.beam.FaceCamera = false -- back to the smear's flat pieces
		releaseQuad(part.quad)
	end
	table.clear(streak.parts)
end

-- Follows the blade while the strike plays, then fades; returns whether it's still showing.
local function updateStreak(streak: Streak, dt: number, clock: number): boolean
	local blade = streak.blade
	if streak.tracking then
		local fighter = fighters[streak.model]
		local trail = fighter and fighter.trail
		if not blade.Parent or not trail or not trail.Enabled or clock - streak.startedAt > THRUST_TRACK then
			streak.tracking = false
		else
			-- Keep the furthest the tip has reached along the thrust, and the blade's line.
			local tip = blade.CFrame * streak.to
			if (tip - streak.tail):Dot(streak.dir) > (streak.tip - streak.tail):Dot(streak.dir) then
				streak.tip = tip
			end
			local guard = blade.CFrame * streak.from
			if (tip - guard).Magnitude > 0.5 then
				streak.dir = (tip - guard).Unit
			end
		end
	end
	if not streak.tracking and clock >= (frozenUntil[streak.model] or 0) then
		streak.t += dt * vfxSlow()
	end
	local u = math.clamp(streak.t / streak.life, 0, 1)
	if u >= 1 then
		releaseStreak(streak)
		return false
	end
	local strength = 1 - u
	local level = math.max(math.ceil(strength * math.sqrt(strength) * FADE_LEVELS), 1)
	local tail = streak.tail:Lerp(streak.tip, 0.8 * u)
	local front = streak.tip + streak.dir * (THRUST_OVERSHOOT + THRUST_DRIFT * u)
	local width = THRUST_WIDTH * (1 - 0.5 * u)
	for _, part in streak.parts do
		local quad = part.quad
		local beam = quad.beam
		local w = if part.halo then width * THRUST_HALO else width
		if part.shaft then
			quad.a0.CFrame = CFrame.new(tail)
			quad.a1.CFrame = CFrame.new(streak.tip)
			beam.Width0, beam.Width1 = w * 0.08, w
		else
			quad.a0.CFrame = CFrame.new(streak.tip)
			quad.a1.CFrame = CFrame.new(front)
			beam.Width0, beam.Width1 = w, 0
		end
		if level ~= streak.level then
			beam.Transparency = if part.halo
				then (if part.shaft then SHAFT_HALO else POINT_HALO)[level]
				else (if part.shaft then SHAFT_CORE else POINT_CORE)[level]
		end
	end
	streak.level = level
	return true
end

local function stepStreaks(dt: number, clock: number)
	for i = #thrustStreaks, 1, -1 do
		if not updateStreak(thrustStreaks[i], dt, clock) then
			thrustStreaks[i] = thrustStreaks[#thrustStreaks]
			thrustStreaks[#thrustStreaks] = nil
		end
	end
end

local function stepSmears(dt: number)
	local clock = os.clock()
	for model, fighter in fighters do
		if not model.Parent then
			fighters[model] = nil
			liveSmear[model] = nil
			frozenUntil[model], perilUntil[model], heavyKind[model] = nil, nil, nil
			sweepDir[model], sweepAt[model], thrustAt[model] = nil, nil, nil
			continue
		end
		local trail = fighter.trail
		if not trail or trail.Parent ~= fighter.sword or (fighter.sword :: BasePart).Parent ~= model then
			if clock < fighter.retryAt then
				continue
			end
			fighter.retryAt = clock + 0.5
			refreshFighter(model, fighter)
			trail = fighter.trail
			if not trail then
				continue
			end
		end
		local smear = liveSmear[model]
		if trail.Enabled and not smear then
			liveSmear[model] = startSmear(model, fighter, trail, clock)
		elseif not trail.Enabled and smear then
			smear.live = false
			liveSmear[model] = nil
		end
		local hitClock = thrustAt[model]
		if hitClock and clock > hitClock + THRUST_LATE then
			thrustAt[model] = nil -- feinted, interrupted, or the strike never lit
		elseif hitClock and trail.Enabled and clock >= hitClock - THRUST_EARLY then
			thrustAt[model] = nil
			startStreak(model, fighter, trail, clock)
		end
		for i, blade in fighter.blades do
			fighter.prev[i] = blade.CFrame
		end
	end

	local eye = workspace.CurrentCamera.CFrame.Position
	for i = #smears, 1, -1 do
		local smear = smears[i]
		if clock >= (frozenUntil[smear.model] or 0) then
			smear.t += dt * vfxSlow()
		end
		local left = false
		for _, track in smear.tracks do
			if smear.live then
				sampleTrack(smear, track, dt)
			end
			if updatePieces(smear, track, eye) then
				left = true
			end
		end
		if smear.live and not smear.model.Parent then
			smear.live = false
		end
		if not left and not smear.live then
			smears[i] = smears[#smears]
			smears[#smears] = nil
		end
	end
	stepStreaks(dt, clock)
	if clock >= nextSweepAt then
		nextSweepAt = clock + SWEEP_INTERVAL
		for _, byModel in MODEL_TABLES do
			for model in byModel do
				if not model.Parent then
					byModel[model] = nil
				end
			end
		end
	end
end

-- The direction the attacker's blade was travelling as it struck, if it was just swinging.
local function recentSweep(attacker: Model): Vector3?
	if os.clock() - (sweepAt[attacker] or -math.huge) < 0.5 then
		return sweepDir[attacker]
	end
	return nil
end

-- A cut streak: a needle of light across the point of impact along the blade's path, thrown
-- open from the centre and pinched shut.
local function cutStreak(position: Vector3, direction: Vector3, length: number, width: number, color: Color3)
	if direction.Magnitude < 1e-3 or detailAt(position) == 0 then
		return
	end
	local dir = direction.Unit
	local anchor = anchorAt(position)
	local slow = vfxSlow()
	local centre = Instance.new("Attachment")
	centre.Parent = anchor
	for _, sign in { 1, -1 } do
		local tip = Instance.new("Attachment")
		tip.Position = dir * sign * length * 0.12
		tip.Parent = anchor
		local beam = Instance.new("Beam")
		beam.Attachment0 = centre
		beam.Attachment1 = tip
		beam.FaceCamera = true
		beam.Segments = 1
		beam.Width0 = width
		beam.Width1 = 0
		beam.LightEmission = 1
		beam.LightInfluence = 0
		beam.Brightness = 4
		beam.Color = ColorSequence.new(WHITE, color)
		beam.Transparency = NumberSequence.new(0, 0.25)
		beam.Parent = anchor
		TweenService:Create(tip, TweenInfo.new(0.07 / slow, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Position = dir * sign * length * 0.5,
		}):Play()
		TweenService:Create(beam, TweenInfo.new(0.24 / slow, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
			Width0 = 0,
		}):Play()
	end
end

-- Stylised shards off a struck body: short white-gold streaks and a few dark chips that fall.
local function shards(position: Vector3, direction: Vector3?, count: number, speed: number)
	local detail = detailAt(position)
	if detail == 0 then
		return
	end
	local anchor = anchorAt(position)
	if direction and direction.Magnitude > 0.01 then
		anchor.CFrame = CFrame.lookAt(position, position + direction)
	end
	count = scaled(if detail == 2 then count else math.ceil(count / 2))

	local streaks = Instance.new("ParticleEmitter")
	streaks.Texture = Assets.UI.Glow
	streaks.Color = ColorSequence.new(WHITE, Color3.fromRGB(255, 226, 170))
	streaks.LightEmission = 0.8
	streaks.LightInfluence = 0
	streaks.Brightness = 2
	streaks.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.32), NumberSequenceKeypoint.new(1, 0) })
	streaks.Speed = NumberRange.new(speed * 0.4, speed)
	streaks.EmissionDirection = Enum.NormalId.Front
	streaks.SpreadAngle = if direction then Vector2.new(50, 50) else Vector2.new(180, 180)
	streaks.Lifetime = NumberRange.new(0.1, 0.24)
	streaks.Drag = 7
	streaks.Rate = 0
	streaks.Orientation = Enum.ParticleOrientation.VelocityParallel
	streaks.Squash = NumberSequence.new(2.2)
	streaks.TimeScale = vfxSlow()
	streaks.Parent = anchor
	streaks:Emit(count)

	local chips = Instance.new("ParticleEmitter")
	chips.Color = ColorSequence.new(Color3.fromRGB(70, 66, 72), Color3.fromRGB(30, 28, 32))
	chips.LightInfluence = 0.5
	chips.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.16), NumberSequenceKeypoint.new(1, 0.08) })
	chips.Speed = NumberRange.new(speed * 0.25, speed * 0.6)
	chips.EmissionDirection = Enum.NormalId.Front
	chips.SpreadAngle = if direction then Vector2.new(60, 60) else Vector2.new(180, 180)
	chips.Lifetime = NumberRange.new(0.3, 0.55)
	chips.Acceleration = Vector3.new(0, -60, 0)
	chips.Drag = 2
	chips.Rate = 0
	chips.Rotation = NumberRange.new(0, 360)
	chips.RotSpeed = NumberRange.new(-400, 400)
	chips.TimeScale = vfxSlow()
	chips.Parent = anchor
	chips:Emit(math.ceil(count / 3))
end

-- The struck point on a body: its chest, a little toward whoever struck it.
local function impactPoint(attacker: Model, defender: Model): Vector3?
	local root = rootOf(defender)
	if not root then
		return nil
	end
	local chest = defender:FindFirstChild("UpperTorso")
	local point = if chest and chest:IsA("BasePart") then chest.Position else root.Position + Vector3.new(0, 0.8, 0)
	local toward = flatBetween(defender, attacker)
	return if toward then point + toward * 0.7 else point
end

-- A struck body's flash: the cut streak along the blade's path, a white bloom with a lens
-- star, shards. `heavy` for enders and perilous blows, `deathblow` for the finisher's X cut.
-- Where and along which line a blow cuts: the struck point, the blow's flat direction, and
-- the blade's direction of travel there.
local function cutOf(attacker: Model, defender: Model): (Vector3?, Vector3?, Vector3)
	local point = impactPoint(attacker, defender)
	local blow = flatBetween(attacker, defender)
	local sweep = recentSweep(attacker)
	if not sweep then
		-- No swing seen (out of range, or a boss hit without a trail): a diagonal cut.
		local across = if blow then blow:Cross(Vector3.yAxis) else Vector3.xAxis
		sweep = across + Vector3.yAxis * (if math.random() < 0.5 then 0.7 else -0.7)
	end
	return point, blow, sweep :: Vector3
end

local function impactEffects(attacker: Model, defender: Model, heavy: boolean, deathblow: boolean)
	local point, blow, sweepVector = cutOf(attacker, defender)
	if not point then
		return
	end
	local perilous = os.clock() < (perilUntil[attacker] or 0)
	local tint = if perilous or deathblow then Color3.fromRGB(255, 70, 55) else Color3.fromRGB(255, 236, 200)
	if deathblow then
		cutStreak(point, sweepVector, 13, 1.3, tint)
		-- The second stroke of the X, crossing the first.
		local axis = blow or Vector3.zAxis
		cutStreak(point, CFrame.fromAxisAngle(axis, math.rad(75)):VectorToWorldSpace(sweepVector), 10, 1, tint)
		flare(point, Color3.fromRGB(255, 225, 215), 20, true)
		shards(point, blow, 70, 38)
	else
		cutStreak(point, sweepVector, if heavy then 10 else 8, if heavy then 1.3 else 0.95, tint)
		flare(point, Color3.fromRGB(255, 246, 228), if heavy then 8 else 5.5, true)
		shards(point, blow, if heavy then 34 else 20, if heavy then 32 else 24)
	end
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

-- Ink: dark, unlit droplets and a few brush splats thrown along the blow and pulled down
-- by gravity, plus a faint grey wash. Deliberately not a glowing spark burst.
local function inkSpray(position: Vector3, direction: Vector3?, count: number, speed: number)
	local detail = detailAt(position)
	if detail == 0 then
		return
	end
	if detail == 1 then
		count = math.ceil(count / 2)
	end
	local anchor = anchorAt(position)
	if direction and direction.Magnitude > 0.01 then
		anchor.CFrame = CFrame.lookAt(position, position + direction)
	end

	local drops = Instance.new("ParticleEmitter")
	drops.Texture = Assets.UI.Glow
	drops.Color = ColorSequence.new(INK, INK_WASH)
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

	local splats = Instance.new("ParticleEmitter")
	splats.Texture = Assets.Cosmetics.InkSplats
	splats.FlipbookLayout = Enum.ParticleFlipbookLayout.Grid2x2
	splats.FlipbookMode = Enum.ParticleFlipbookMode.OneShot
	splats.FlipbookStartRandom = true
	splats.FlipbookFramerate = NumberRange.new(0)
	splats.Color = ColorSequence.new(INK)
	splats.LightEmission = 0
	splats.LightInfluence = 0.6
	splats.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.4), NumberSequenceKeypoint.new(1, 1) })
	splats.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.7, 0.1),
		NumberSequenceKeypoint.new(1, 1),
	})
	splats.Speed = NumberRange.new(speed * 0.25, speed * 0.6)
	splats.EmissionDirection = Enum.NormalId.Front
	splats.SpreadAngle = if direction then Vector2.new(40, 30) else Vector2.new(180, 180)
	splats.Lifetime = NumberRange.new(0.4, 0.7)
	splats.Acceleration = Vector3.new(0, -45, 0)
	splats.Drag = 2
	splats.Rotation = NumberRange.new(0, 360)
	splats.Rate = 0
	splats.Parent = anchor
	splats:Emit(math.ceil(count / 8))

	local wash = Instance.new("ParticleEmitter")
	wash.Texture = Assets.UI.Glow
	wash.Color = ColorSequence.new(INK_WASH)
	wash.LightEmission = 0
	wash.LightInfluence = 0.6
	wash.Size = NumberSequence.new(0.8, 2.4)
	wash.Transparency = NumberSequence.new(0.6, 1)
	wash.Speed = NumberRange.new(2, 5)
	wash.EmissionDirection = Enum.NormalId.Front
	wash.SpreadAngle = Vector2.new(60, 60)
	wash.Lifetime = NumberRange.new(0.25, 0.45)
	wash.Rate = 0
	wash.Parent = anchor
	wash:Emit(math.ceil(count / 10))
end

-- A brush splat of ink on the floor under a deathblow, fading after a while.
local poolParams = RaycastParams.new()
poolParams.FilterType = Enum.RaycastFilterType.Include
local function inkPool(position: Vector3, direction: Vector3?)
	if detailAt(position) == 0 then
		return
	end
	local params = poolParams
	params.FilterDescendantsInstances = { workspace.Terrain, workspace:FindFirstChild("Castle") :: Instance }
	local hit = workspace:Raycast(position + Vector3.new(0, 2, 0), Vector3.new(0, -12, 0), params)
	if not hit then
		return
	end
	local flat = if direction then Vector3.new(direction.X, 0, direction.Z) else Vector3.zero
	flat = if flat.Magnitude > 0.01 then flat.Unit else Vector3.zero
	for i = 1, 2 do
		local pool = Instance.new("Part")
		pool.Anchored = true
		pool.CanCollide = false
		pool.CanQuery = false
		pool.CanTouch = false
		pool.CastShadow = false
		pool.Transparency = 1
		local size = (if i == 1 then 5 else 3) * (0.85 + math.random() * 0.3)
		pool.Size = Vector3.new(size, 0.05, size)
		pool.CFrame = CFrame.new(hit.Position + flat * (i - 1) * 1.8 + Vector3.new(0, 0.04 + i * 0.004, 0))
			* CFrame.Angles(0, math.random() * math.pi * 2, 0)
		local decal = Instance.new("Decal")
		decal.Face = Enum.NormalId.Top
		decal.Texture = Assets.Cosmetics.InkSplats
		decal.Color3 = INK
		decal.Transparency = 1
		decal.Parent = pool
		pool.Parent = workspace
		TweenService:Create(decal, TweenInfo.new(0.25), { Transparency = 0.08 }):Play()
		task.delay(6, function()
			TweenService:Create(decal, TweenInfo.new(2.5), { Transparency = 1 }):Play()
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

local function hitstop(duration: number, ...: Model?)
	if player:GetAttribute("SettingHitstop") == false then
		return
	end
	for i = 1, select("#", ...) do
		local model = select(i, ...)
		if model then
			Animator.hitstop(model, duration)
			frozenUntil[model] = os.clock() + duration -- the slash smear holds still too
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
local AFTERIMAGE_RANGE = 60
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
	playSound("Dodge", rootOf(model), isLocal(model))
	-- One ghost (it clones the whole body), only for a dash near the camera and not under
	-- reduced effects.
	local root = rootOf(model)
	local camera = workspace.CurrentCamera
	if
		root
		and camera
		and not reducedEffects()
		and (camera.CFrame.Position - root.Position).Magnitude <= AFTERIMAGE_RANGE
	then
		task.delay(0.045, function()
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
	perilUntil[model] = os.clock() + duration + 0.35 -- its cut's smear burns red
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
	playSound("PerilousWarn", rootOf(model), not isLocal(model) and close(rootOf(model)))

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
local GLINT_LEAD = Config.Visual.GlintLead
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
	-- Starts above the EnemyBars billboard (2.9 studs over the head), not on it.
	gui.StudsOffsetWorldSpace = Vector3.new((math.random() - 0.5) * 1.5, 4.2, 0)
	gui.AlwaysOnTop = true
	gui.LightInfluence = 0
	gui.MaxDistance = 60
	gui.Adornee = head
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.FontFace = UI.Fonts.Number
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
	-- Sparks fly on along the attacker's cut, kicked up and away from the defender.
	local carry = recentSweep(attacker)
	local away = flatBetween(defender, attacker)
	local sprayDir = if carry and away
		then carry + away * 0.8 + Vector3.yAxis * 0.5
		elseif away then away + Vector3.yAxis * 0.6
		else nil
	local mine = isLocal(attacker) or isLocal(defender)
	playSound("Deflect", soundAt, mine, pitch)
	if perfect then
		-- A perfect deflect has to feel unmistakable: white-gold bloom, a ringing
		-- second layer of steel, and a heavier freeze and camera kick.
		if point then
			burst(point, GOLD, 90, 52, 7, sprayDir)
			burst(point, Color3.fromRGB(255, 150, 60), 30, 30, 3)
			flare(point, Color3.fromRGB(255, 244, 214), 22, true)
		end
		playSound("PerfectDeflect", soundAt, mine, pitch)
		if isLocal(defender) then
			CombatHUD.flashPerfect()
		end
	elseif point then
		burst(point, SPARK, 40, 36, 3.5, sprayDir)
		flare(point, Color3.fromRGB(255, 226, 170), 9, true)
	end
	-- A blade line at L3 brings the defender's own deflect spark and sound.
	local style = Cosmetics.blade(defender).deflect
	if style and point and detailAt(point) > 0 then
		CosmeticFX.deflect(style, point, sprayDir, perfect)
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
		burst(point, STEEL, 12, 14, 1.4, flatBetween(defender, attacker))
	end
	playSound("Guard", rootOf(defender))
end

-- Your own deflects are shown the instant the blow lands, predicted from your last block
-- press; the server's verdict follows later and shouldn't replay the same effects.
local PREDICTED_DEFENCE_WINDOW = 0.6

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
		heavyKind[model] = heavy
		if perilous then
			telegraphPerilous(model, remaining)
		end
		if not isLocal(model) then
			predictIncoming(model, kind, data.hitAt)
			glint(model, data.hitAt)
		end
		local swingSpec = specOf(model, kind)
		if swingSpec and swingSpec.thrust then
			thrustAt[model] = os.clock() + remaining -- the strike draws a thrust streak (stepSmears)
		end
		task.delay(math.max(remaining + (if swingSpec then swingSpec.lungeAt else -0.05), 0), function()
			if not model.Parent then
				return
			end
			playSound(Audio.swingKey(model, kind, heavy), rootOf(model), isLocal(model))
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
		impactEffects(attacker, defender, ender, false)
		local root = rootOf(defender)
		if root then
			inkSpray(
				root.Position + Vector3.new(0, 0.8, 0),
				blowDirection(attacker, defender),
				if ender then 40 else 26,
				if ender then 28 else 22
			)
		end
		playSound(if ender then "HitHeavy" else "Hit", root, isLocal(attacker) or isLocal(defender))
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
		playSound("PostureBreak", root, isLocal(model) or close(root))
	end,

	Deathblow = function(data)
		local attacker: Model, defender: Model = data.attacker, data.defender
		-- Only on a knock-down, where "-65" is news: a kill or a boss's lost life already gets
		-- the 斬 splash, and four labels would pile up over the body.
		if isLocal(attacker) and data.lethal == false and not data.boss and defender:GetAttribute("Boss") == nil then
			popText(defender, `DEATHBLOW  -{Config.DeathblowDamage}`, Color3.fromRGB(230, 50, 40), true)
		end
		playClip(attacker, "Deathblow")
		-- A deathblow on an unwounded fighter knocks them down instead of killing.
		playClip(defender, if data.lethal == false then "HitReact" else "Executed")
		hitstop(Config.Visual.DeathblowHitstop, attacker, defender)
		local root = rootOf(defender)
		-- The attacker's finisher draws the cut (client/CosmeticFX); everything else here, the
		-- clips, hitstop, shake and camera punch, is the same for every finisher.
		local finisher = if typeof(data.finisher) == "string" then data.finisher else Cosmetics.finisher(attacker)
		local grade: CosmeticFX.Grade? = nil
		if root and finisher ~= "Default" and detailAt(root.Position) > 0 then
			local point, blow, sweep = cutOf(attacker, defender)
			grade = CosmeticFX.deathblow(finisher, {
				attacker = attacker,
				defender = defender,
				root = root,
				point = point or root.Position + Vector3.new(0, 0.8, 0),
				sweep = sweep,
				blow = blow,
				lethal = data.lethal ~= false,
			})
		end
		if root and not grade then
			local direction = blowDirection(attacker, defender)
			-- The cut lands a beat into the deathblow clip: a long arc of ink, then splats.
			inkSpray(root.Position + Vector3.new(0, 0.6, 0), direction, 90, 34)
			flare(root.Position + Vector3.new(0, 0.6, 0), STEEL, 10)
			impactEffects(attacker, defender, true, true)
			task.delay(0.12, function()
				if root.Parent then
					inkSpray(root.Position + Vector3.new(0, 0.2, 0), direction, 40, 20)
					inkPool(root.Position, direction)
				end
			end)
		end
		playSound("Deathblow", root, isLocal(attacker) or isLocal(defender))
		if isLocal(attacker) or isLocal(defender) then
			shake(0.9, 0.35, attacker, defender)
			if grade then
				CosmeticFX.applyGrade(grade)
			else
				deathblowGrade()
			end
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
			flare(root.Position, CRIMSON, 8)
		end
		playSound("CutDown", root, isLocal(model) or close(root))
	end,

	Resurrected = function(data)
		local model: Model = data.model
		playClip(model, "Revive")
		local root = rootOf(model)
		if root then
			burst(root.Position + Vector3.new(0, 1, 0), Color3.fromRGB(255, 70, 60), 50, 30, 6)
			flare(root.Position + Vector3.new(0, 1, 0), Color3.fromRGB(255, 90, 70), 14)
		end
		playSound("Resurrect", root, isLocal(model))
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
		playSound("Stomp", root, isLocal(attacker) or isLocal(defender))
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
		playSound("Mikiri", root, isLocal(attacker) or isLocal(defender))
		if isLocal(attacker) or isLocal(defender) then
			shake(0.6, 0.2, attacker, defender)
		end
	end,

	Drink = function(data)
		local model: Model = data.model
		playClip(model, "Drink")
		playSound("GourdSip", rootOf(model), isLocal(model))
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
	fighters[model] = { blades = {}, prev = {}, retryAt = 0 }
	model.ChildAdded:Connect(function(child)
		local fighter = fighters[model]
		if fighter and (child.Name == "Sword" or child.Name == "Sword2") then
			fighter.trail, fighter.retryAt = nil, 0 -- re-rigged: find the blades again
		end
	end)
	-- A re-dressed blade's new motes (Shared/Cosmetics/BladeLook) obey reduced effects too.
	model.DescendantAdded:Connect(function(child)
		if child:IsA("ParticleEmitter") and child:GetAttribute("BaseRate") ~= nil and reducedEffects() then
			task.defer(function()
				local base = child:GetAttribute("BaseRate")
				if typeof(base) == "number" then
					child.Rate = base * 0.35
				end
			end)
		end
	end)
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
	-- The textures of the first glint, 危, deflect and deathblow, so a slow phone doesn't draw
	-- the first one blank (the glint is a timing cue). Not blocking; sounds preload in Audio.
	task.spawn(function()
		local images = {}
		for _, id in { Assets.UI.Glow, Assets.UI.KanjiPeril, Assets.UI.KanjiDeath, Assets.Cosmetics.InkSplats } do
			local image = Instance.new("ImageLabel")
			image.Image = id
			table.insert(images, image)
		end
		pcall(function()
			ContentProvider:PreloadAsync(images)
		end)
	end)
	CosmeticFX.init({
		flare = flare,
		burst = burst,
		cutStreak = cutStreak,
		shards = shards,
		vfxSlow = vfxSlow,
		scaled = scaled,
		reduced = reducedEffects,
	})
	player:GetAttributeChangedSignal("SettingReducedEffects"):Connect(function()
		for _, fighter in fighters do
			if fighter.sword then
				scaleMotes(fighter.sword)
			end
		end
	end)

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

		-- CosmeticTest:Invoke("finisher", "InkBrush") etc. runs client/CosmeticPreview (tooling).
		local cosmetic = Instance.new("BindableFunction")
		cosmetic.Name = "CosmeticTest"
		cosmetic.OnInvoke = function(command: string, ...: any)
			local preview = require(script.Parent.CosmeticPreview) :: any
			return preview[command](...)
		end
		cosmetic.Parent = player:WaitForChild("PlayerScripts")
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

	RunService.Heartbeat:Connect(stepSmears) -- after Animator's PreSimulation pose lands

	CollectionService:GetInstanceAddedSignal(Types.Tag):Connect(watch)
	for _, instance in CollectionService:GetTagged(Types.Tag) do
		watch(instance)
	end
end

---------------------------------------------------------------------------------------
-- Previews (client/CosmeticPreview): the real effects, played locally on models of your
-- choosing, with no server involved and no gameplay effect.

-- A deathblow by `attacker` on `defender` with finisher `ref` (the clips, hitstop, shake, grade
-- and camera punch included when `attacker` is you).
function CombatVisuals.previewDeathblow(attacker: Model, defender: Model, ref: string)
	handlers.Deathblow({ attacker = attacker, defender = defender, lethal = true, finisher = ref })
end

-- Animates a local-only preview rig and draws its blade's smear, like any fighter's.
function CombatVisuals.watchPreview(model: Model)
	watch(model)
end

-- `defender` deflects a light cut from `attacker` (perfect or not).
function CombatVisuals.previewDeflect(attacker: Model, defender: Model, perfect: boolean)
	deflectEffects(attacker, defender, perfect, "Light1", false)
end

return CombatVisuals
