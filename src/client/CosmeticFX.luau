--!strict
-- The look of the purchasable / earnable combat cosmetics (part C), drawn by client/CombatVisuals:
--
--   * Deathblow finishers (Shared/Cosmetics.Finishers): what the killing cut looks like. A
--     finisher only replaces the cut's light, particles, colour grade, stamp and sound. The
--     deathblow's clip, hitstop, shake, camera punch and every gameplay number are the
--     default's (CombatVisuals plays them the same for every finisher; the server never knows).
--   * Blade line levels: the L2 swing smear's extras (petals / bolts / feathers shed along the
--     arc) and the L3 deflect spark and sound.
--
-- Everything respects Settings > Reduced effects (fewer particles, no lights, no secondary
-- bolts) and the Studio VfxSlowMo test aid, through the helpers CombatVisuals hands over.

local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")

local Assets = require(ReplicatedStorage.Shared.Assets)
local BladeLook = require(ReplicatedStorage.Shared.Cosmetics.BladeLook)
local Blades = require(ReplicatedStorage.Shared.Cosmetics.Blades)
local Cosmetics = require(ReplicatedStorage.Shared.Cosmetics)

local C = Assets.Cosmetics
local GLOW = Assets.UI.Glow
local WHITE = Color3.new(1, 1, 1)
local player = Players.LocalPlayer

export type Kit = {
	flare: (position: Vector3, color: Color3, size: number, star: boolean?) -> (),
	burst: (
		position: Vector3,
		color: Color3,
		count: number,
		speed: number,
		flashSize: number,
		direction: Vector3?
	) -> (),
	cutStreak: (position: Vector3, direction: Vector3, length: number, width: number, color: Color3) -> (),
	shards: (position: Vector3, direction: Vector3?, count: number, speed: number) -> (),
	vfxSlow: () -> number,
	scaled: (count: number) -> number,
	reduced: () -> boolean,
}

-- What a deathblow knows: who, where the blade cut (`point`, along `sweep`), which way the
-- blow carried (`blow`), the defender's root.
export type Ctx = {
	attacker: Model,
	defender: Model,
	root: BasePart,
	point: Vector3,
	sweep: Vector3,
	blow: Vector3?,
	lethal: boolean,
}

-- A finisher's colour grade (only on the screens of the two fighters, like the default's).
export type Grade = { saturation: number, contrast: number, brightness: number, tint: Color3, hold: number }

local CosmeticFX = {}

local kit: Kit = nil :: any

function CosmeticFX.init(helpers: Kit)
	kit = helpers
end

---------------------------------------------------------------------------------------
-- Small helpers

local function slow(): number
	return kit.vfxSlow()
end

local function anchorAt(position: Vector3, life: number, facing: Vector3?): Part
	local anchor = Instance.new("Part")
	anchor.Anchored = true
	anchor.CanCollide, anchor.CanQuery, anchor.CanTouch = false, false, false
	anchor.Transparency = 1
	anchor.Size = Vector3.one * 0.2
	if facing and facing.Magnitude > 1e-3 then
		local unit = facing.Unit
		anchor.CFrame = if math.abs(unit.Y) > 0.99
			then CFrame.new(position) * CFrame.Angles(math.sign(unit.Y) * math.pi / 2, 0, 0) -- straight up/down
			else CFrame.lookAt(position, position + unit)
	else
		anchor.CFrame = CFrame.new(position)
	end
	anchor.Parent = workspace
	Debris:AddItem(anchor, life / slow())
	return anchor
end

local function seq(...: number): NumberSequence
	local values = { ... }
	local points = {}
	for i, v in values do
		table.insert(points, NumberSequenceKeypoint.new((i - 1) / math.max(#values - 1, 1), v))
	end
	if #points == 1 then
		return NumberSequence.new(values[1])
	end
	return NumberSequence.new(points)
end

-- Plays a sound at a part, stopping it (with a short fade) after `length` seconds.
local function sound(key: string, parent: Instance?, volume: number, pitch: number?, length: number?)
	local id = C.Sounds[key]
	if not id then
		return
	end
	local s = Instance.new("Sound")
	s.SoundId = id
	s.Volume = volume
	s.PlaybackSpeed = (pitch or 1) * (0.96 + math.random() * 0.08)
	s.RollOffMinDistance = 14
	s.RollOffMaxDistance = 180
	s.Parent = parent or SoundService
	s:Play()
	local cut = length or 3
	task.delay(cut, function()
		if s.Parent then
			TweenService:Create(s, TweenInfo.new(0.35), { Volume = 0 }):Play()
		end
	end)
	Debris:AddItem(s, cut + 0.5)
end

-- The on-screen angle (GUI rotation, degrees clockwise) of a world direction.
local function screenAngle(direction: Vector3): number
	local camera = workspace.CurrentCamera
	if not camera then
		return 0
	end
	local v = camera.CFrame:VectorToObjectSpace(direction)
	return math.deg(math.atan2(-v.Y, v.X))
end

local function light(parent: Instance, color: Color3, range: number, brightness: number, fade: number)
	if kit.reduced() then
		return
	end
	local l = Instance.new("PointLight")
	l.Color = color
	l.Range = range
	l.Brightness = brightness
	l.Shadows = false
	l.Parent = parent
	TweenService:Create(l, TweenInfo.new(fade / slow(), Enum.EasingStyle.Quad), { Brightness = 0 }):Play()
end

-- A brush-kanji stamp that slams down over the fallen and fades: the finisher's signature,
-- readable from the kill-cam and the spectator view.
local function stamp(defender: Model, key: string, color: Color3, halo: Color3, attacker: Model?)
	local head = defender:FindFirstChild("Head") or defender:FindFirstChild("HumanoidRootPart")
	local mine = player.Character ~= nil and (player.Character == defender or player.Character == attacker)
	local see = if mine then 0 else 0.4 -- onlookers: a lighter stamp they can see through
	local image = C.Kanji[key]
	if not head or not head:IsA("BasePart") or not image then
		return
	end
	local wide = key == "Yozakura" or key == "Raijin"
	local gui = Instance.new("BillboardGui")
	gui.Adornee = head
	gui.AlwaysOnTop = true
	gui.LightInfluence = 0
	local studs = if mine then 1 else 0.7
	gui.Size = UDim2.fromScale((if wide then 8.6 else 5.2) * studs, 5.2 * studs) -- studs
	gui.StudsOffsetWorldSpace = Vector3.new(0, 3.4, 0)
	gui.MaxDistance = 240
	local glow = Instance.new("ImageLabel")
	glow.BackgroundTransparency = 1
	glow.Image = GLOW
	glow.ImageColor3 = halo
	glow.ImageTransparency = 0.25 + see * 0.6
	glow.AnchorPoint = Vector2.new(0.5, 0.5)
	glow.Position = UDim2.fromScale(0.5, 0.5)
	glow.Size = UDim2.fromScale(1.3, 1.5)
	glow.Parent = gui
	local glyph = Instance.new("ImageLabel")
	glyph.BackgroundTransparency = 1
	glyph.Image = image
	glyph.ImageColor3 = color
	glyph.ScaleType = Enum.ScaleType.Fit
	glyph.AnchorPoint = Vector2.new(0.5, 0.5)
	glyph.Position = UDim2.fromScale(0.5, 0.5)
	glyph.Size = UDim2.fromScale(1.7, 1.7)
	glyph.ImageTransparency = 0.2
	glyph.Parent = gui
	gui.Parent = player:WaitForChild("PlayerGui")
	local s = slow()
	TweenService:Create(glyph, TweenInfo.new(0.16 / s, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
		Size = UDim2.fromScale(1, 1),
		ImageTransparency = see,
	}):Play()
	task.delay(0.95 / s, function()
		local fade = TweenInfo.new(0.45 / s)
		TweenService:Create(glyph, fade, { ImageTransparency = 1, Size = UDim2.fromScale(1.15, 1.15) }):Play()
		TweenService:Create(glow, fade, { ImageTransparency = 1 }):Play()
	end)
	Debris:AddItem(gui, 1.6 / s)
end

-- One burst of particles from a point.
local function emit(
	position: Vector3,
	count: number,
	life: number,
	configure: (ParticleEmitter) -> (),
	facing: Vector3?
): ParticleEmitter
	local anchor = anchorAt(position, life, facing)
	local e = Instance.new("ParticleEmitter")
	e.Rate = 0
	e.LightInfluence = 0
	e.EmissionDirection = Enum.NormalId.Front
	configure(e)
	e.TimeScale = slow()
	e.Parent = anchor
	e:Emit(kit.scaled(count))
	return e
end

local function petals(e: ParticleEmitter, color: Color3, glow: number)
	-- Saturated and fairly large: pale petals vanish against daylight sand.
	e.Texture = C.Petal
	e.Color = ColorSequence.new(color, color:Lerp(WHITE, 0.4))
	e.Size = seq(0.62, 0.58, 0.4)
	e.Transparency = seq(0, 0, 0.1, 1)
	e.Rotation = NumberRange.new(0, 360)
	e.RotSpeed = NumberRange.new(-260, 260)
	e.LightEmission = glow * 0.5
	e.LightInfluence = 0.15
end

local function feathers(e: ParticleEmitter, color: Color3)
	e.Texture = C.Feather
	e.Color = ColorSequence.new(color)
	e.Size = seq(0.75, 0.65, 0.5)
	e.Transparency = seq(0, 0, 1)
	e.Rotation = NumberRange.new(0, 360)
	e.RotSpeed = NumberRange.new(-220, 220)
	e.LightEmission = 0
	e.LightInfluence = 0.5
end

-- A lightning bolt between two points: a camera-facing beam with the bolt texture that
-- flickers between two shapes, then fades.
local function bolt(from: Vector3, to: Vector3, width: number, color: Color3, life: number)
	local s = slow()
	local anchor = anchorAt(from, life + 0.2)
	local a0 = Instance.new("Attachment")
	a0.Parent = anchor
	local a1 = Instance.new("Attachment")
	a1.Parent = anchor -- parented first: WorldPosition on a loose attachment is just an offset
	a1.WorldPosition = to
	local beam = Instance.new("Beam")
	beam.Attachment0 = a0
	beam.Attachment1 = a1
	beam.Texture = C.BoltA
	beam.TextureMode = Enum.TextureMode.Stretch
	beam.TextureLength = 1
	beam.FaceCamera = true
	beam.Width0 = width
	beam.Width1 = width * 0.7
	beam.LightEmission = 1
	beam.LightInfluence = 0
	beam.Brightness = 6
	beam.Color = ColorSequence.new(WHITE, color)
	beam.Transparency = NumberSequence.new(0)
	beam.Parent = anchor
	task.spawn(function()
		local started = os.clock()
		local flip = false
		while beam.Parent do
			local t = (os.clock() - started) * s / life
			if t >= 1 then
				break
			end
			flip = not flip
			beam.Texture = if flip then C.BoltB else C.BoltA
			beam.Transparency = NumberSequence.new(math.clamp(t * t, 0, 1))
			task.wait(0.035 / s)
		end
		beam.Transparency = NumberSequence.new(1)
	end)
end

-- A camera-facing image in the world (crescents, brush strokes), rotated to `angle` on screen.
local function sprite(
	position: Vector3,
	image: string,
	color: Color3,
	studs: Vector2,
	angle: number,
	life: number,
	brightness: number?
)
	local anchor = anchorAt(position, life + 0.1)
	local gui = Instance.new("BillboardGui")
	gui.Adornee = anchor
	gui.AlwaysOnTop = false
	gui.LightInfluence = 0
	gui.Brightness = brightness or 1.6
	gui.Size = UDim2.fromScale(studs.X, studs.Y)
	gui.Parent = anchor
	local label = Instance.new("ImageLabel")
	label.BackgroundTransparency = 1
	label.Image = image
	label.ImageColor3 = color
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.Position = UDim2.fromScale(0.5, 0.5)
	label.Size = UDim2.fromScale(1, 1)
	label.Rotation = angle
	label.Parent = gui
	return label, gui
end

local function grade(spec: Grade)
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end
	local cc = Instance.new("ColorCorrectionEffect")
	cc.Saturation = spec.saturation
	cc.Contrast = spec.contrast
	cc.Brightness = spec.brightness
	cc.TintColor = spec.tint
	cc.Parent = camera
	-- The same length as the default's red grade: a finisher may not hold the screen longer.
	local hold = math.min(spec.hold, 0.25)
	task.delay(hold, function()
		TweenService:Create(cc, TweenInfo.new(0.7, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Saturation = 0,
			Contrast = 0,
			Brightness = 0,
			TintColor = WHITE,
		}):Play()
	end)
	Debris:AddItem(cc, hold + 0.8)
end

-- An X of two cut streaks across the point (the default's shape, in the finisher's colour).
local function crossCut(ctx: Ctx, color: Color3, length: number)
	kit.cutStreak(ctx.point, ctx.sweep, length, 1.3, color)
	local axis = ctx.blow or Vector3.zAxis
	kit.cutStreak(
		ctx.point,
		CFrame.fromAxisAngle(axis, math.rad(75)):VectorToWorldSpace(ctx.sweep),
		length * 0.75,
		1,
		color
	)
end

-- Random body parts of a model, for arcs crawling over it.
local function bodyPoints(model: Model): { Vector3 }
	local points = {}
	for _, name in
		{ "Head", "UpperTorso", "LowerTorso", "LeftUpperArm", "RightUpperArm", "LeftLowerLeg", "RightLowerLeg" }
	do
		local part = model:FindFirstChild(name)
		if part and part:IsA("BasePart") then
			table.insert(points, part.Position)
		end
	end
	return points
end

---------------------------------------------------------------------------------------
-- Finishers

-- Ink Brush (墨): the cut is a stroke of sumi ink, and ink is what it throws.
local function inkBrush(ctx: Ctx): Grade
	local ink = Color3.fromRGB(14, 11, 13)
	local angle = screenAngle(ctx.sweep)
	-- Two great brush strokes in an X, wiped on along the cut.
	for i, spec in { { angle, 11, 0 }, { angle + 62, 8.5, 0.07 } } do
		task.delay(spec[3] / slow(), function()
			local label =
				sprite(ctx.point, Assets.UI.InkBand, ink, Vector2.new(spec[2], spec[2] * 0.26), spec[1], 1.5, 1)
			label.ImageTransparency = 0.02
			local wipe = Instance.new("UIGradient")
			wipe.Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0),
				NumberSequenceKeypoint.new(0.48, 0),
				NumberSequenceKeypoint.new(0.52, 1),
				NumberSequenceKeypoint.new(1, 1),
			})
			wipe.Offset = Vector2.new(-0.55, 0)
			wipe.Parent = label
			local s = slow()
			TweenService:Create(wipe, TweenInfo.new(0.1 / s, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
				Offset = Vector2.new(0.55, 0),
			}):Play()
			task.delay(0.75 / s, function()
				TweenService:Create(label, TweenInfo.new(0.55 / s), { ImageTransparency = 1 }):Play()
			end)
			if i == 1 then
				sound("InkSwish", ctx.root, 0.75, 1.15, 1.2)
			end
		end)
	end
	-- Ink thrown along the blow: big splats and fine droplets, falling.
	emit(ctx.point, 26, 2.2, function(e)
		e.Texture = C.InkSplats
		e.FlipbookLayout = Enum.ParticleFlipbookLayout.Grid2x2
		e.FlipbookMode = Enum.ParticleFlipbookMode.OneShot
		e.FlipbookStartRandom = true
		e.FlipbookFramerate = NumberRange.new(0)
		e.Color = ColorSequence.new(ink)
		e.Size = seq(0.5, 1.4, 1.2)
		e.Transparency = seq(0, 0, 1)
		e.Lifetime = NumberRange.new(0.5, 0.9)
		e.Speed = NumberRange.new(10, 26)
		e.SpreadAngle = Vector2.new(45, 35)
		e.Acceleration = Vector3.new(0, -50, 0)
		e.Drag = 2
		e.Rotation = NumberRange.new(0, 360)
	end, ctx.blow)
	emit(ctx.point, 110, 2, function(e)
		e.Texture = GLOW
		e.Color = ColorSequence.new(ink)
		e.Size = seq(0.3, 0.12)
		e.Lifetime = NumberRange.new(0.4, 0.8)
		e.Speed = NumberRange.new(14, 36)
		e.SpreadAngle = Vector2.new(40, 30)
		e.Acceleration = Vector3.new(0, -70, 0)
		e.Orientation = Enum.ParticleOrientation.VelocityParallel
		e.Squash = NumberSequence.new(1.4)
	end, ctx.blow)
	-- Ink pools on the floor.
	task.delay(0.12, function()
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = { ctx.attacker, ctx.defender }
		local hit = workspace:Raycast(ctx.root.Position + Vector3.new(0, 2, 0), Vector3.new(0, -12, 0), params)
		if not hit then
			return
		end
		local pool = Instance.new("Part")
		pool.Anchored = true
		pool.CanCollide, pool.CanQuery, pool.CanTouch = false, false, false
		pool.Transparency = 1
		pool.Size = Vector3.new(6, 0.05, 6)
		pool.CFrame = CFrame.new(hit.Position + Vector3.new(0, 0.04, 0))
			* CFrame.Angles(0, math.random() * math.pi * 2, 0)
		local decal = Instance.new("Decal")
		decal.Face = Enum.NormalId.Top
		decal.Texture = C.InkSplats
		decal.Color3 = ink
		decal.Transparency = 1
		decal.Parent = pool
		pool.Parent = workspace
		TweenService:Create(decal, TweenInfo.new(0.2), { Transparency = 0.05 }):Play()
		task.delay(6, function()
			TweenService:Create(decal, TweenInfo.new(2.5), { Transparency = 1 }):Play()
		end)
		Debris:AddItem(pool, 9)
		sound("InkSplash", pool, 0.45, 1.5, 0.8)
	end)
	kit.flare(ctx.point, Color3.fromRGB(245, 240, 230), 14, true)
	stamp(ctx.defender, "Ink", ink, Color3.fromRGB(245, 240, 230), ctx.attacker)
	return { saturation = -1, contrast = 0.4, brightness = 0.02, tint = WHITE, hold = 0.35 }
end

local function petalStorm(ctx: Ctx, color: Color3, count: number, glow: number)
	emit(ctx.point, count, 2.6, function(e)
		petals(e, color, glow)
		e.Lifetime = NumberRange.new(1.2, 2)
		e.Speed = NumberRange.new(10, 24)
		e.SpreadAngle = Vector2.new(180, 180)
		e.Drag = 3.6
		e.Acceleration = Vector3.new(3, -3.5, 1)
	end)
	-- A ring of petals thrown out flat around the body, then a slow fall around it.
	emit(ctx.root.Position, math.floor(count * 0.5), 3.2, function(e)
		petals(e, color, glow)
		e.Lifetime = NumberRange.new(1.4, 2.2)
		e.Speed = NumberRange.new(18, 26)
		e.SpreadAngle = Vector2.new(180, 6)
		e.Drag = 3.5
		e.Acceleration = Vector3.new(2, -2.5, 0)
	end, Vector3.xAxis)
	local fall = emit(ctx.root.Position + Vector3.new(0, 7, 0), 0, 3.5, function(e)
		petals(e, color, glow)
		e.Lifetime = NumberRange.new(1.4, 2)
		e.Speed = NumberRange.new(2, 5)
		e.SpreadAngle = Vector2.new(180, 180)
		e.Drag = 1.2
		e.Acceleration = Vector3.new(1.5, -3, 0.5)
	end, Vector3.yAxis)
	fall.Rate = if kit.reduced() then 8 else 22
	task.delay(1.2 / slow(), function()
		fall.Enabled = false
	end)
end

-- Sakura Scatter (桜): the cut throws a storm of cherry petals.
local function sakuraScatter(ctx: Ctx): Grade
	local pink = Color3.fromRGB(252, 156, 198)
	crossCut(ctx, Color3.fromRGB(255, 190, 215), 13)
	kit.flare(ctx.point, Color3.fromRGB(255, 214, 230), 18, true)
	petalStorm(ctx, pink, 90, 0.25)
	stamp(ctx.defender, "Sakura", pink, WHITE, ctx.attacker)
	sound("Chimes", ctx.root, 0.75, 1, 2.6)
	return { saturation = -0.25, contrast = 0.15, brightness = 0.03, tint = Color3.fromRGB(255, 226, 236), hold = 0.3 }
end

local function featherBurst(ctx: Ctx, color: Color3, count: number)
	emit(ctx.point, count, 3, function(e)
		feathers(e, color)
		e.Lifetime = NumberRange.new(1.2, 2)
		e.Speed = NumberRange.new(14, 30)
		e.SpreadAngle = Vector2.new(180, 180)
		e.Drag = 2.8
		e.Acceleration = Vector3.new(0.5, -4, 0)
	end)
	-- A few big dark shapes beat upward and away, like crows taking off.
	emit(ctx.root.Position + Vector3.new(0, 1, 0), 8, 2.5, function(e)
		feathers(e, color)
		e.Size = seq(1.2, 1.5, 0.8)
		e.Lifetime = NumberRange.new(0.9, 1.4)
		e.Speed = NumberRange.new(10, 18)
		e.SpreadAngle = Vector2.new(50, 50)
		e.Acceleration = Vector3.new(0, 14, 0)
		e.RotSpeed = NumberRange.new(-500, 500)
	end, Vector3.yAxis)
	emit(ctx.root.Position + Vector3.new(0, 1, 0), 6, 2, function(e)
		e.Texture = GLOW
		e.Color = ColorSequence.new(Color3.fromRGB(26, 20, 34))
		e.Size = seq(1.6, 3.2, 4.2)
		e.Transparency = seq(0.55, 0.75, 1)
		e.Lifetime = NumberRange.new(0.6, 1)
		e.Speed = NumberRange.new(3, 7)
		e.SpreadAngle = Vector2.new(180, 180)
		e.LightEmission = 0
	end)
end

-- Crow Feathers (鴉): the fallen burst into black feathers and the crows lift away.
local function crowFeathers(ctx: Ctx): Grade
	local black = Color3.fromRGB(24, 20, 32)
	crossCut(ctx, Color3.fromRGB(220, 212, 255), 12)
	kit.flare(ctx.point, Color3.fromRGB(200, 190, 255), 14, true)
	featherBurst(ctx, black, 60)
	stamp(ctx.defender, "Crow", black, Color3.fromRGB(150, 125, 230), ctx.attacker)
	sound("Wings", ctx.root, 0.85, 1, 2)
	task.delay(0.15, function()
		sound("Caw", ctx.root, 0.55, 1, 2)
	end)
	return { saturation = -0.6, contrast = 0.25, brightness = -0.08, tint = Color3.fromRGB(215, 205, 255), hold = 0.35 }
end

local function strike(ctx: Ctx, color: Color3, offset: Vector3, width: number)
	local top = ctx.root.Position + offset + Vector3.new(0, 45, 0)
	local bottom = ctx.root.Position + offset * 0.2 + Vector3.new(0, -2.5, 0)
	bolt(top, bottom, width, color, 0.32)
	if not kit.reduced() then
		bolt(top + Vector3.new(2, 0, -1), bottom, width * 0.45, color, 0.22)
	end
end

local function crawl(ctx: Ctx, color: Color3, count: number)
	if kit.reduced() then
		count = math.min(count, 2)
	end
	for i = 1, count do
		task.delay((i - 1) * 0.07 / slow(), function()
			local points = bodyPoints(ctx.defender)
			if #points >= 2 then
				local a = points[math.random(#points)]
				local b = points[math.random(#points)]
				if (a - b).Magnitude > 0.5 then
					bolt(a, b, 0.7, color, 0.14)
				end
			end
		end)
	end
end

-- Lightning Sheath (雷): as the blade returns, lightning falls on the cut.
local function lightningSheath(ctx: Ctx): Grade
	local violet = Color3.fromRGB(200, 186, 255)
	crossCut(ctx, Color3.fromRGB(235, 228, 255), 12)
	strike(ctx, violet, Vector3.zero, 2.6)
	kit.burst(ctx.point, violet, 80, 46, 8, ctx.blow)
	kit.flare(ctx.root.Position, Color3.fromRGB(230, 225, 255), 20, true)
	light(ctx.root, violet, 18, 2.5, 0.4)
	crawl(ctx, violet, 6)
	stamp(ctx.defender, "Thunder", violet, WHITE, ctx.attacker)
	sound("Thunder", ctx.root, 0.9, 1, 2.6)
	sound("Zap", ctx.root, 0.6, 1.1, 1)
	return { saturation = -0.5, contrast = 0.3, brightness = 0.15, tint = Color3.fromRGB(225, 220, 255), hold = 0.12 }
end

-- A crescent drawn across the cut. Centred a little past the fallen (along the blow) so it
-- frames them instead of washing over the attacker, and lit at 1x so it keeps its colour in
-- daylight instead of blowing out to white.
local function crescentCut(ctx: Ctx, color: Color3, size: number)
	local angle = screenAngle(ctx.sweep)
	local s = slow()
	local blow = ctx.blow or Vector3.zero
	local centre = ctx.point + Vector3.new(blow.X, 0, blow.Z) * 1.2
	for i, spec in { { size, 0 }, { size * 0.7, 0.05 } } do
		task.delay(spec[2] / s, function()
			local label = sprite(centre, C.Crescent, color, Vector2.new(spec[1], spec[1]), angle - 45, 1.3, 1)
			label.Size = UDim2.fromScale(0.55, 0.55)
			label.ImageTransparency = if i == 1 then 0 else 0.35
			TweenService:Create(label, TweenInfo.new(0.14 / s, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
				Size = UDim2.fromScale(1, 1),
				Rotation = angle - 15,
			}):Play()
			task.delay(0.45 / s, function()
				TweenService:Create(label, TweenInfo.new(0.6 / s), {
					ImageTransparency = 1,
					Size = UDim2.fromScale(1.15, 1.15),
				}):Play()
			end)
		end)
	end
end

local function moonGlints(ctx: Ctx, color: Color3, count: number)
	emit(ctx.point, count, 2.5, function(e)
		e.Texture = GLOW
		e.Color = ColorSequence.new(WHITE, color)
		e.Size = seq(0, 0.35, 0)
		e.Lifetime = NumberRange.new(0.8, 1.6)
		e.Speed = NumberRange.new(2, 9)
		e.SpreadAngle = Vector2.new(180, 180)
		e.Drag = 2
		e.Acceleration = Vector3.new(0, 1.5, 0)
		e.LightEmission = 1
		e.Brightness = 4
	end)
end

-- Moon Crescent (月): one stroke draws the new moon across the cut, under a pale moon.
local function moonCrescent(ctx: Ctx): Grade
	local moon = Color3.fromRGB(214, 228, 255)
	kit.cutStreak(ctx.point, ctx.sweep, 17, 1.2, moon)
	crescentCut(ctx, moon, 10)
	-- A pale full moon rises over the fallen for a moment.
	local orb =
		sprite(ctx.root.Position + Vector3.new(0, 9, 0), GLOW, Color3.fromRGB(225, 235, 255), Vector2.new(9, 9), 0, 1.8)
	orb.ImageTransparency = 1
	local s = slow()
	TweenService:Create(orb, TweenInfo.new(0.3 / s), { ImageTransparency = 0.15 }):Play()
	task.delay(0.9 / s, function()
		TweenService:Create(orb, TweenInfo.new(0.7 / s), { ImageTransparency = 1 }):Play()
	end)
	moonGlints(ctx, Color3.fromRGB(170, 200, 255), 60)
	kit.flare(ctx.point, Color3.fromRGB(220, 232, 255), 20, true)
	light(ctx.root, Color3.fromRGB(170, 195, 255), 16, 1.5, 0.8)
	stamp(ctx.defender, "Moon", moon, Color3.fromRGB(120, 155, 255), ctx.attacker)
	sound("TempleBell", ctx.root, 0.8, 1, 2.8)
	sound("MoonHum", ctx.root, 0.35, 1.2, 1.4)
	return { saturation = -0.55, contrast = 0.25, brightness = -0.12, tint = Color3.fromRGB(192, 208, 255), hold = 0.4 }
end

-- Yozakura Finale (夜桜): night falls, a pink crescent and a storm of glowing petals.
local function yozakura(ctx: Ctx): Grade
	local pink = Color3.fromRGB(240, 128, 182)
	crescentCut(ctx, Color3.fromRGB(246, 150, 202), 10)
	kit.cutStreak(ctx.point, ctx.sweep, 15, 1.2, Color3.fromRGB(255, 205, 228))
	petalStorm(ctx, pink, 110, 0.3)
	-- A spiral column of petals rising off the fallen.
	local column = emit(ctx.root.Position + Vector3.new(0, -2, 0), 0, 2.8, function(e)
		petals(e, pink, 0.3)
		e.Lifetime = NumberRange.new(1, 1.6)
		e.Speed = NumberRange.new(6, 10)
		e.SpreadAngle = Vector2.new(14, 14)
		e.Acceleration = Vector3.new(0, 4, 0)
		e.Drag = 0.5
	end, Vector3.yAxis)
	column.Rate = if kit.reduced() then 14 else 40
	task.delay(0.8 / slow(), function()
		column.Enabled = false
	end)
	light(ctx.root, pink, 16, 1.5, 0.8)
	kit.flare(ctx.point, Color3.fromRGB(255, 220, 238), 22, true)
	stamp(ctx.defender, "Yozakura", pink, Color3.fromRGB(120, 40, 120), ctx.attacker)
	sound("Chimes", ctx.root, 0.8, 0.9, 2.8)
	sound("TempleBell", ctx.root, 0.45, 1.2, 2.4)
	return { saturation = -0.2, contrast = 0.3, brightness = -0.14, tint = Color3.fromRGB(232, 196, 240), hold = 0.45 }
end

-- A flat shock ring racing out over the ground.
local function shockRing(position: Vector3, color: Color3, radius: number)
	if kit.reduced() then
		return
	end
	local ring = Instance.new("Part")
	ring.Shape = Enum.PartType.Cylinder
	ring.Anchored = true
	ring.CanCollide, ring.CanQuery, ring.CanTouch = false, false, false
	ring.CastShadow = false
	ring.Material = Enum.Material.Neon
	ring.Color = color
	ring.Transparency = 0.2
	ring.Size = Vector3.new(0.08, 1, 1)
	ring.CFrame = CFrame.new(position) * CFrame.Angles(0, 0, math.rad(90))
	ring.Parent = workspace
	local s = slow()
	TweenService:Create(ring, TweenInfo.new(0.45 / s, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = Vector3.new(0.08, radius * 2, radius * 2),
		Transparency = 1,
	}):Play()
	Debris:AddItem(ring, 0.6 / s)
end

-- Raijin Finale (雷神): the thunder god answers: three strikes and a shock across the ground.
local function raijin(ctx: Ctx): Grade
	local violet = Color3.fromRGB(196, 178, 255)
	crossCut(ctx, Color3.fromRGB(240, 235, 255), 13)
	strike(ctx, violet, Vector3.zero, 3.2)
	for i, offset in { Vector3.new(5, 0, 3), Vector3.new(-4, 0, 4) } do
		task.delay(i * 0.09 / slow(), function()
			strike(ctx, violet, offset, 1.8)
		end)
	end
	local ground = ctx.root.Position - Vector3.new(0, 2.6, 0)
	shockRing(ground, violet, 16)
	kit.burst(ctx.point, violet, 110, 52, 9, ctx.blow)
	kit.flare(ctx.root.Position, Color3.fromRGB(235, 230, 255), 22, true)
	light(ctx.root, violet, 20, 3, 0.45)
	crawl(ctx, violet, 9)
	stamp(ctx.defender, "Raijin", violet, WHITE, ctx.attacker)
	sound("Thunder", ctx.root, 1, 0.9, 3)
	sound("Zap", ctx.root, 0.7, 1, 1.2)
	return { saturation = -0.45, contrast = 0.35, brightness = 0.18, tint = Color3.fromRGB(222, 215, 255), hold = 0.15 }
end

-- Karasu Finale (烏): a black crescent, a murder of crows, the light going out.
local function karasu(ctx: Ctx): Grade
	local black = Color3.fromRGB(22, 18, 30)
	crescentCut(ctx, Color3.fromRGB(24, 20, 34), 10) -- an ink-black crescent
	featherBurst(ctx, black, 70)
	task.delay(0.12 / slow(), function()
		featherBurst(ctx, black, 30)
	end)
	kit.flare(ctx.point, Color3.fromRGB(190, 195, 230), 14, true)
	stamp(ctx.defender, "Karasu", black, Color3.fromRGB(150, 130, 220), ctx.attacker)
	sound("Wings", ctx.root, 0.9, 0.9, 2.4)
	task.delay(0.1, function()
		sound("Caw", ctx.root, 0.6, 0.85, 2)
	end)
	task.delay(0.35, function()
		sound("Caw", ctx.root, 0.45, 1.05, 2)
	end)
	return { saturation = -0.75, contrast = 0.35, brightness = -0.15, tint = Color3.fromRGB(205, 200, 240), hold = 0.45 }
end

local FINISHERS: { [string]: (Ctx) -> Grade } = {
	InkBrush = inkBrush,
	SakuraScatter = sakuraScatter,
	CrowFeathers = crowFeathers,
	LightningSheath = lightningSheath,
	MoonCrescent = moonCrescent,
	Yozakura = yozakura,
	Raijin = raijin,
	Karasu = karasu,
}

-- Plays finisher `ref`'s cut. Returns its grade, or nil for the default (CombatVisuals then
-- plays the default cut, ink and grade itself).
function CosmeticFX.deathblow(ref: string, ctx: Ctx): Grade?
	local play = FINISHERS[ref]
	if not play then
		return nil
	end
	return play(ctx)
end

function CosmeticFX.applyGrade(spec: Grade)
	grade(spec)
end

-- Every finisher ref this module draws (the default draws nothing here).
function CosmeticFX.finishers(): { string }
	local list = {}
	for ref in Cosmetics.Finishers do
		if FINISHERS[ref] then
			table.insert(list, ref)
		end
	end
	table.sort(list)
	return list
end

---------------------------------------------------------------------------------------
-- Blade lines: L2 smear extras and L3 deflects

-- Pooled world-space emitters for smear motes, one per kind and colour.
local smearEmitters: { [string]: { attachment: Attachment, emitter: ParticleEmitter } } = {}

local function smearEmitter(style: Blades.SmearStyle): (Attachment, ParticleEmitter)
	local key = style.kind .. style.color:ToHex()
	local entry = smearEmitters[key]
	if not entry or not entry.attachment.Parent then
		local attachment = Instance.new("Attachment")
		attachment.Name = "LineSmearMotes"
		attachment.Parent = workspace.Terrain
		local e = BladeLook.emitter(style.kind, style.color)
		e.Name = "LineSmearMotes"
		if style.kind == "petals" then
			e.LightEmission = 0.15
			e.Speed = NumberRange.new(1, 3)
		elseif style.kind == "feathers" then
			e.Speed = NumberRange.new(1, 2.5)
		end
		e.Parent = attachment
		entry = { attachment = attachment, emitter = e }
		smearEmitters[key] = entry
	end
	return entry.attachment, entry.emitter
end

local boltPool: { { a0: Attachment, a1: Attachment, beam: Beam, until_: number } } = {}

local function smearBolt(tip: Vector3, chord: Vector3, color: Color3)
	local now = os.clock()
	local slot
	for _, b in boltPool do
		if b.until_ < now then
			slot = b
			break
		end
	end
	if not slot then
		if #boltPool >= 8 then
			return
		end
		local a0 = Instance.new("Attachment")
		a0.Parent = workspace.Terrain
		local a1 = Instance.new("Attachment")
		a1.Parent = workspace.Terrain
		local beam = Instance.new("Beam")
		beam.Attachment0 = a0
		beam.Attachment1 = a1
		beam.TextureMode = Enum.TextureMode.Stretch
		beam.FaceCamera = true
		beam.LightEmission = 1
		beam.LightInfluence = 0
		beam.Brightness = 5
		beam.Parent = workspace.Terrain
		slot = { a0 = a0, a1 = a1, beam = beam, until_ = 0 }
		table.insert(boltPool, slot)
	end
	local life = 0.09 / slow()
	local jitter = Vector3.new(math.random() - 0.5, math.random() - 0.5, math.random() - 0.5) * 2.4
	slot.a0.WorldPosition = tip
	slot.a1.WorldPosition = tip - chord * (1 + math.random()) + jitter
	slot.beam.Texture = if math.random() < 0.5 then C.BoltA else C.BoltB
	slot.beam.Color = ColorSequence.new(WHITE, color)
	slot.beam.Width0 = 0.5
	slot.beam.Width1 = 0.25
	slot.beam.Transparency = NumberSequence.new(0)
	slot.beam.Enabled = true
	slot.until_ = now + life
	local beam = slot.beam
	task.delay(life, function()
		if slot.until_ <= os.clock() + 1e-3 then
			beam.Enabled = false
		end
	end)
end

-- Called by the smear for each new piece of a line blade's arc (`index` counts pieces).
function CosmeticFX.smearPiece(style: Blades.SmearStyle, index: number, tip: Vector3, chord: Vector3)
	if index % style.every ~= 0 then
		return
	end
	if style.kind == "bolts" then
		if not kit.reduced() or index % (style.every * 2) == 0 then
			smearBolt(tip, chord, style.color)
		end
		return
	end
	local attachment, e = smearEmitter(style)
	attachment.WorldPosition = tip
	e.TimeScale = slow()
	e:Emit(if kit.reduced() then 1 else style.count)
end

-- A line's L3 deflect: its own spark and sound on top of the steel clash.
function CosmeticFX.deflect(style: Blades.DeflectStyle, point: Vector3, direction: Vector3?, perfect: boolean)
	local scale = if perfect then 1.6 else 1
	if style.kind == "petals" then
		emit(point, math.floor(36 * scale), 2.5, function(e)
			petals(e, style.spark, 0.25)
			e.Size = seq(0.32, 0.28, 0.12)
			e.Lifetime = NumberRange.new(0.9, 1.5)
			e.Speed = NumberRange.new(10, 22)
			e.SpreadAngle = Vector2.new(70, 70)
			e.Drag = 3.5
			e.Acceleration = Vector3.new(1.5, -3, 0)
		end, direction)
	elseif style.kind == "bolts" then
		local count = if kit.reduced() then 2 else math.floor(4 * scale)
		for _ = 1, count do
			local dir = (direction or Vector3.yAxis)
				+ Vector3.new(math.random() - 0.5, math.random() - 0.3, math.random() - 0.5) * 1.6
			bolt(point, point + dir.Unit * (3 + math.random() * 3), 0.8, style.spark, 0.12)
		end
		kit.burst(point, style.spark, math.floor(30 * scale), 40, 3, direction)
	else
		emit(point, math.floor(22 * scale), 2.5, function(e)
			feathers(e, Color3.fromRGB(26, 22, 36))
			e.Size = seq(0.5, 0.45, 0.35)
			e.Lifetime = NumberRange.new(1, 1.6)
			e.Speed = NumberRange.new(8, 18)
			e.SpreadAngle = Vector2.new(80, 80)
			e.Drag = 3
			e.Acceleration = Vector3.new(0.4, -3, 0)
		end, direction)
	end
	kit.flare(point, style.spark:Lerp(WHITE, 0.3), if perfect then 14 else 9, true)
	sound(
		style.sound,
		anchorAt(point, 1.8),
		style.volume * (if perfect then 1 else 0.8),
		if perfect then 1.1 else 1,
		1.2
	)
end

return CosmeticFX
