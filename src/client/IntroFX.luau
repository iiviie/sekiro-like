--!strict
-- The props and effects of the pre-fight intros (Shared/Intros), timed against each intro's
-- clip (Shared/BakedIntros). Everything is local to this client: parts welded to a fighter's
-- body (saya, kasa, war fan) and particles / beams / billboards in a folder that's cleared when
-- the intro ends. Built from part C's cosmetic kit (Assets.Cosmetics: petals, feathers, bolts,
-- crescent, ink, brush kanji, sounds); nothing red reads as blood (ink, gold, petals, light).
-- Settings > Reduced effects thins the particles.

local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Assets = require(ReplicatedStorage.Shared.Assets)
local BakedIntros = require(ReplicatedStorage.Shared.BakedIntros)

local C = Assets.Cosmetics
local GLOW = Assets.UI.Glow
local player = Players.LocalPlayer

local IntroFX = {}

export type Handle = {
	model: Model,
	folder: Folder,
	props: { [string]: BasePart },
	alive: boolean,
	accent: Color3,
	sheathed: boolean?, -- the sword is hidden while a hilt sits in the saya (SHEATHED)
}

local function reduced(): boolean
	return player:GetAttribute("SettingReducedEffects") == true
end

local function count(n: number): number
	return if reduced() then math.max(1, math.floor(n * 0.4)) else n
end

local function part(props: { [string]: any }, parent: Instance): BasePart
	local p = Instance.new(props.Shape and "Part" or "Part") :: Part
	p.Anchored = props.Anchored == true
	p.CanCollide, p.CanQuery, p.CanTouch = false, false, false
	p.CastShadow = false
	p.Massless = true
	p.Material = props.Material or Enum.Material.SmoothPlastic
	p.Color = props.Color or Color3.new(1, 1, 1)
	p.Size = props.Size or Vector3.one
	if props.Shape then
		p.Shape = props.Shape
	end
	p.Transparency = props.Transparency or 0
	p.Name = props.Name or "IntroProp"
	if props.CFrame then
		p.CFrame = props.CFrame
	end
	p.Parent = parent
	return p
end

local function sound(id: string?, at: Instance, volume: number, pitch: number?, length: number?)
	if not id then
		return
	end
	local s = Instance.new("Sound")
	s.SoundId = id
	s.Volume = volume
	s.PlaybackSpeed = (pitch or 1) * (0.97 + math.random() * 0.06)
	s.RollOffMinDistance = 16
	s.RollOffMaxDistance = 200
	s.Parent = at
	s:Play()
	local cut = length or 3
	task.delay(cut, function()
		if s.Parent then
			TweenService:Create(s, TweenInfo.new(0.3), { Volume = 0 }):Play()
		end
	end)
	Debris:AddItem(s, cut + 0.5)
end

local function anchorAt(h: Handle, position: Vector3, life: number): Part
	local a = part(
		{ Anchored = true, Transparency = 1, Size = Vector3.one * 0.2, CFrame = CFrame.new(position) },
		h.folder
	) :: Part
	Debris:AddItem(a, life)
	return a
end

local function seq(...: number): NumberSequence
	local values = { ... }
	if #values == 1 then
		return NumberSequence.new(values[1])
	end
	local points = {}
	for i, v in values do
		table.insert(points, NumberSequenceKeypoint.new((i - 1) / (#values - 1), v))
	end
	return NumberSequence.new(points)
end

-- A one-shot burst of `n` particles from `parent`.
local function burst(parent: Instance, n: number, props: { [string]: any }, life: number?): ParticleEmitter
	local e = Instance.new("ParticleEmitter")
	e.Enabled = false
	e.Texture = props.Texture or GLOW
	e.Color = ColorSequence.new(props.Color or Color3.new(1, 1, 1))
	e.LightEmission = props.LightEmission or 0
	e.LightInfluence = props.LightInfluence or 0
	e.Size = props.Size or seq(0.4, 0)
	e.Transparency = props.Transparency or seq(0, 1)
	e.Lifetime = props.Lifetime or NumberRange.new(0.5, 1)
	e.Speed = props.Speed or NumberRange.new(4, 10)
	e.SpreadAngle = props.SpreadAngle or Vector2.new(180, 180)
	e.Acceleration = props.Acceleration or Vector3.zero
	e.Drag = props.Drag or 2
	e.Rotation = props.Rotation or NumberRange.new(0, 360)
	e.RotSpeed = props.RotSpeed or NumberRange.new(-120, 120)
	e.EmissionDirection = props.EmissionDirection or Enum.NormalId.Top
	e.Orientation = props.Orientation or Enum.ParticleOrientation.FacingCamera
	e.Parent = parent
	e:Emit(count(n))
	Debris:AddItem(e, life or 4)
	return e
end

local function flare(h: Handle, position: Vector3, color: Color3, size: number, life: number)
	local a = anchorAt(h, position, life + 0.2)
	local bb = Instance.new("BillboardGui")
	bb.Size = UDim2.fromScale(size, size)
	bb.AlwaysOnTop = false
	bb.LightInfluence = 0
	bb.Parent = a
	local img = Instance.new("ImageLabel")
	img.BackgroundTransparency = 1
	img.Size = UDim2.fromScale(1, 1)
	img.Image = GLOW
	img.ImageColor3 = color
	img.Parent = bb
	TweenService
		:Create(bb, TweenInfo.new(life, Enum.EasingStyle.Quad), { Size = UDim2.fromScale(size * 0.2, size * 0.2) })
		:Play()
	TweenService:Create(img, TweenInfo.new(life), { ImageTransparency = 1 }):Play()
end

local function light(at: Instance, color: Color3, range: number, brightness: number, fade: number)
	if reduced() then
		return
	end
	local l = Instance.new("PointLight")
	l.Color = color
	l.Range = range
	l.Brightness = brightness
	l.Shadows = false
	l.Parent = at
	TweenService:Create(l, TweenInfo.new(fade), { Brightness = 0 }):Play()
	Debris:AddItem(l, fade + 0.1)
end

local function bolt(h: Handle, from: Vector3, to: Vector3, width: number, color: Color3, life: number)
	local a = anchorAt(h, from, life + 0.1)
	local b = anchorAt(h, to, life + 0.1)
	local a0 = Instance.new("Attachment")
	a0.Parent = a
	local a1 = Instance.new("Attachment")
	a1.Parent = b
	local beam = Instance.new("Beam")
	beam.Attachment0, beam.Attachment1 = a0, a1
	beam.Texture = if math.random() < 0.5 then C.BoltA else C.BoltB
	beam.TextureMode = Enum.TextureMode.Stretch
	beam.Width0, beam.Width1 = width, width * 0.6
	beam.LightEmission = 1
	beam.LightInfluence = 0
	beam.FaceCamera = true
	beam.Color = ColorSequence.new(color)
	beam.Transparency = NumberSequence.new(0)
	beam.Parent = a
	TweenService:Create(beam, TweenInfo.new(life), { Width0 = 0, Width1 = 0 }):Play()
end

-- An expanding flat ring on the ground (impacts).
local function shockRing(h: Handle, position: Vector3, color: Color3, radius: number)
	if reduced() then
		return
	end
	local ring = part({
		Anchored = true,
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.08, 1, 1),
		Material = Enum.Material.Neon,
		Color = color,
		Transparency = 0.25,
		CFrame = CFrame.new(position) * CFrame.Angles(0, 0, math.pi / 2),
	}, h.folder)
	TweenService:Create(ring, TweenInfo.new(0.45, Enum.EasingStyle.Quad), {
		Size = Vector3.new(0.04, radius * 2, radius * 2),
		Transparency = 1,
	}):Play()
	Debris:AddItem(ring, 0.6)
end

local function dust(h: Handle, position: Vector3, color: Color3, n: number, speed: number)
	local a = anchorAt(h, position, 3)
	burst(a, n, {
		Color = color,
		Size = seq(0.9, 2.2),
		Transparency = seq(0.35, 1),
		Lifetime = NumberRange.new(0.6, 1.2),
		Speed = NumberRange.new(speed * 0.5, speed),
		SpreadAngle = Vector2.new(85, 10),
		Drag = 5,
		Acceleration = Vector3.new(0, 2, 0),
		LightInfluence = 1,
	})
end

local function kanjiBoard(h: Handle, position: Vector3, image: string, color: Color3, size: number, hold: number)
	local a = anchorAt(h, position, hold + 1.2)
	local bb = Instance.new("BillboardGui")
	bb.Size = UDim2.fromScale(size, size)
	bb.LightInfluence = 0
	bb.Parent = a
	local img = Instance.new("ImageLabel")
	img.BackgroundTransparency = 1
	img.Size = UDim2.fromScale(1, 1)
	img.Image = image
	img.ImageColor3 = color
	img.ImageTransparency = 1
	img.Parent = bb
	TweenService:Create(img, TweenInfo.new(0.25), { ImageTransparency = 0 }):Play()
	task.delay(hold, function()
		if img.Parent then
			TweenService:Create(img, TweenInfo.new(0.6), { ImageTransparency = 1 }):Play()
			TweenService:Create(bb, TweenInfo.new(0.6), { Size = UDim2.fromScale(size * 1.25, size * 1.25) }):Play()
		end
	end)
end

---------------------------------------------------------------------------------------
-- Where things are on the body

local function root(h: Handle): BasePart?
	local r = h.model:FindFirstChild("HumanoidRootPart")
	return if r and r:IsA("BasePart") then r else nil
end

local function sword(h: Handle): BasePart?
	local s = h.model:FindFirstChild("Sword")
	return if s and s:IsA("BasePart") then s else nil
end

-- The blade tip's world position (the sword's TrailEnd attachment), or a guess.
local function tip(h: Handle): Vector3
	local s = sword(h)
	local a = s and s:FindFirstChild("TrailEnd")
	if a and a:IsA("Attachment") then
		return a.WorldPosition
	end
	local r = root(h)
	return if r then r.Position + r.CFrame.LookVector * 4 else Vector3.zero
end

local function bladeMid(h: Handle): Vector3
	local s = sword(h)
	local a0 = s and s:FindFirstChild("TrailStart")
	if a0 and a0:IsA("Attachment") then
		return (a0.WorldPosition + tip(h)) / 2
	end
	return tip(h)
end

local function scaleOf(h: Handle): number
	local s = h.model:GetAttribute("BodyScale")
	return if typeof(s) == "number" and s > 0 then s else 1
end

local function feet(h: Handle): Vector3
	local r = root(h)
	if not r then
		return Vector3.zero
	end
	return r.Position - Vector3.new(0, 3 * scaleOf(h), 0)
end

-- A part's joint pivot (part.CFrame * joint.C1), the frame props are authored against.
local function pivot(h: Handle, partName: string, jointName: string): (BasePart?, CFrame)
	local p = h.model:FindFirstChild(partName)
	if not p or not p:IsA("BasePart") then
		return nil, CFrame.identity
	end
	local joint = p:FindFirstChild(jointName)
	if joint and joint:IsA("Motor6D") then
		return p, joint.C1
	end
	if joint and joint:IsA("AnimationConstraint") and joint.Attachment1 then
		return p, joint.Attachment1.CFrame
	end
	return p, CFrame.identity
end

-- Builds a prop (a main part plus dependents placed by their "Local" attribute) and welds it
-- to its body part at the authored offset (Shared/BakedIntros Props), turned by `turn`.
local function weldProp(h: Handle, name: string, build: (Model) -> BasePart, turn: CFrame?): BasePart?
	local spec = BakedIntros.Props[name]
	if not spec then
		return nil
	end
	local body, c1 = pivot(h, spec.part, spec.joint)
	if not body then
		return nil
	end
	local v = spec.cf
	local offset = CFrame.new(v[1], v[2], v[3], v[4], v[5], v[6], v[7])
	local s = scaleOf(h)
	if s ~= 1 then
		offset = offset.Rotation + offset.Position * s
	end
	local holder = Instance.new("Model")
	holder.Name = "Intro" .. name
	local main = build(holder)
	local c0 = c1 * offset * (turn or CFrame.identity)
	main.CFrame = body.CFrame * c0
	for _, d in holder:GetDescendants() do
		if d:IsA("BasePart") and d ~= main then
			local at = d:GetAttribute("Local")
			local cf = if typeof(at) == "CFrame" then at else CFrame.identity
			d.CFrame = main.CFrame * cf
			local w = Instance.new("Weld")
			w.Name = "PropWeld"
			w.Part0, w.Part1 = main, d
			w.C0 = cf
			w.Parent = d
		end
	end
	holder.Parent = h.folder
	local weld = Instance.new("Weld")
	weld.Name = "BodyWeld"
	weld.Part0 = body
	weld.Part1 = main
	weld.C0 = c0
	weld.Parent = main
	h.props[name] = main
	return main
end

local LACQUER = Color3.fromRGB(22, 18, 18)
local GOLD = Color3.fromRGB(212, 172, 92)
local STRAW = Color3.fromRGB(192, 156, 98)

local function local_(p: BasePart, cf: CFrame)
	p:SetAttribute("Local", cf)
end

local BUILD: { [string]: (Handle) -> () } = {
	Saya = function(h)
		weldProp(h, "Saya", function(holder)
			local s = scaleOf(h)
			local main = part({ Name = "Saya", Size = Vector3.new(0.3, 0.24, 3.3) * s, Color = LACQUER }, holder)
			local mouth = part({
				Name = "Koiguchi",
				Size = Vector3.new(0.36, 0.3, 0.14) * s,
				Color = GOLD,
				Material = Enum.Material.Metal,
			}, holder)
			local_(mouth, CFrame.new(0, 0, 1.6 * s)) -- the mouth end faces the hilt (+Z of a lookAt frame)
			local chape = part({
				Name = "Kojiri",
				Size = Vector3.new(0.33, 0.27, 0.16) * s,
				Color = GOLD,
				Material = Enum.Material.Metal,
			}, holder)
			local_(chape, CFrame.new(0, 0, -1.6 * s))
			return main
		end)
	end,
	Kasa = function(h)
		weldProp(h, "Kasa", function(holder)
			local s = scaleOf(h)
			local brim = part({
				Name = "Kasa",
				Shape = Enum.PartType.Cylinder,
				Size = Vector3.new(0.1, 2.7, 2.7) * s,
				Color = STRAW,
				Material = Enum.Material.Fabric,
			}, holder)
			local crown = part({
				Name = "Crown",
				Shape = Enum.PartType.Cylinder,
				Size = Vector3.new(0.34, 1.5, 1.5) * s,
				Color = STRAW:Lerp(Color3.new(), 0.12),
				Material = Enum.Material.Fabric,
			}, holder)
			local_(crown, CFrame.new(0.2 * s, 0, 0))
			local top = part({
				Name = "Top",
				Shape = Enum.PartType.Cylinder,
				Size = Vector3.new(0.22, 0.7, 0.7) * s,
				Color = STRAW:Lerp(Color3.new(), 0.2),
				Material = Enum.Material.Fabric,
			}, holder)
			local_(top, CFrame.new(0.42 * s, 0, 0))
			return brim
		end, CFrame.Angles(0, 0, math.pi / 2)) -- the cylinders' axis (X) points up
	end,
	Fan = function(h)
		weldProp(h, "Fan", function(holder)
			local s = scaleOf(h)
			local rivet = part({
				Name = "Fan",
				Size = Vector3.new(0.1, 0.1, 0.1) * s,
				Color = GOLD,
				Material = Enum.Material.Metal,
			}, holder)
			for i = 1, 9 do
				local slat = part({
					Name = `Slat{i}`,
					Size = Vector3.new(0.035, 0.95, 0.2) * s,
					Color = if i % 2 == 0 then Color3.fromRGB(150, 28, 30) else Color3.fromRGB(170, 36, 34),
					Material = Enum.Material.SmoothPlastic,
				}, holder)
				slat:SetAttribute("Slat", i)
				local_(slat, CFrame.new(0, -0.48 * s, 0))
			end
			return rivet
		end)
	end,
}

-- Fans the slats of the war fan open (true) or shut over `time` seconds.
local function setFan(h: Handle, open: boolean, time: number)
	local rivet = h.props.Fan
	if not rivet or not rivet.Parent then
		return
	end
	local s = scaleOf(h)
	local holder = rivet.Parent :: Instance
	local start = os.clock()
	local function place(alpha: number)
		for _, d in holder:GetChildren() do
			local i = d:GetAttribute("Slat")
			local w = d:FindFirstChild("PropWeld")
			if d:IsA("BasePart") and typeof(i) == "number" and w and w:IsA("Weld") then
				-- the fan opens in the plane of the palm: slats turn about the hand's X axis
				w.C0 = CFrame.Angles(math.rad((i - 5) * 15) * alpha, 0, 0) * CFrame.new(0, -0.48 * s, 0)
			end
		end
	end
	task.spawn(function()
		while h.alive and rivet.Parent do
			local t = math.clamp((os.clock() - start) / math.max(time, 1e-3), 0, 1)
			local e = 1 - (1 - t) ^ 3
			place(if open then e else 1 - e)
			if t >= 1 then
				break
			end
			task.wait()
		end
	end)
end

-- Throws the kasa off the head, spinning, and fades it.
local function tossKasa(h: Handle)
	local brim = h.props.Kasa
	local r = root(h)
	if not brim or not r then
		return
	end
	local holder = brim.Parent :: Instance
	local weld = brim:FindFirstChild("BodyWeld")
	if weld then
		weld:Destroy()
	end
	for _, d in holder:GetDescendants() do
		if d:IsA("BasePart") then
			d.Massless = false
		end
	end
	brim.AssemblyLinearVelocity = r.CFrame:VectorToWorldSpace(Vector3.new(-14, 16, -6))
	brim.AssemblyAngularVelocity = Vector3.new(0, 18, 6)
	task.delay(0.9, function()
		for _, d in holder:GetDescendants() do
			if d:IsA("BasePart") then
				TweenService:Create(d, TweenInfo.new(0.5), { Transparency = 1 }):Play()
			end
		end
	end)
	Debris:AddItem(holder, 1.6)
end

---------------------------------------------------------------------------------------
-- Each intro's beats, in clip seconds.

type Beat = { at: number, run: (Handle) -> () }

local function petalsAt(h: Handle, position: Vector3, n: number, wind: Vector3, color: Color3)
	local a = anchorAt(h, position, 5)
	burst(a, n, {
		Texture = C.Petal,
		Color = color,
		Size = seq(0.35, 0.3),
		Transparency = seq(0, 0, 1),
		Lifetime = NumberRange.new(1.4, 2.4),
		Speed = NumberRange.new(6, 16),
		SpreadAngle = Vector2.new(60, 60),
		Acceleration = wind + Vector3.new(0, -2.5, 0),
		Drag = 1.2,
		RotSpeed = NumberRange.new(-260, 260),
		LightInfluence = 0.4,
		LightEmission = 0.2,
	}, 5)
end

local function feathersAt(h: Handle, position: Vector3, n: number, up: number, color: Color3)
	local a = anchorAt(h, position, 5)
	burst(a, n, {
		Texture = C.Feather,
		Color = color,
		Size = seq(0.5, 0.4),
		Transparency = seq(0, 0, 1),
		Lifetime = NumberRange.new(1.2, 2.2),
		Speed = NumberRange.new(4, 10),
		Acceleration = Vector3.new(0, up, 0),
		Drag = 2.5,
		RotSpeed = NumberRange.new(-200, 200),
		LightInfluence = 1,
	}, 5)
end

-- The crow: a rounded black body and head, a grey beak, a wedge tail and two long wings that
-- beat while it flies and fold while it perches, flown along a path. (A box body read as a
-- phone in the hand.)
local CROW = Color3.fromRGB(18, 16, 24)

local function ellipsoid(name: string, size: Vector3, color: Color3, parent: Instance): BasePart
	local p = part({ Name = name, Size = size, Color = color, Anchored = true }, parent)
	local mesh = Instance.new("SpecialMesh")
	mesh.MeshType = Enum.MeshType.Sphere
	mesh.Parent = p
	return p
end

local function crow(h: Handle, from: Vector3, to: Vector3, time: number, scale: number): BasePart
	local s = scale * 1.45 -- about a real crow beside a 5-stud fighter
	local body = ellipsoid("Crow", Vector3.new(0.34, 0.34, 0.62) * s, CROW, h.folder)
	body.CFrame = CFrame.lookAt(from, to)
	-- -Z is forward (lookAt): head and beak in front, tail behind.
	local bits: { { p: BasePart, at: CFrame } } = {}
	local function attach(p: BasePart, at: CFrame)
		p.Parent = body
		table.insert(bits, { p = p, at = at })
	end
	attach(ellipsoid("Head", Vector3.new(0.24, 0.24, 0.26) * s, CROW, h.folder), CFrame.new(0, 0.12 * s, -0.36 * s))
	local beak =
		part({ Name = "Beak", Size = Vector3.new(0.07, 0.07, 0.2) * s, Color = Color3.fromRGB(60, 58, 64) }, h.folder)
	beak.Anchored = true
	attach(beak, CFrame.new(0, 0.1 * s, -0.54 * s))
	local tail = part({ Name = "Tail", Size = Vector3.new(0.26, 0.03, 0.36) * s, Color = CROW }, h.folder)
	tail.Anchored = true
	attach(tail, CFrame.new(0, 0.02 * s, 0.42 * s) * CFrame.Angles(math.rad(12), 0, 0))
	local wings = {}
	for side = -1, 1, 2 do
		local wing = part({ Name = "Wing", Size = Vector3.new(0.9, 0.03, 0.44) * s, Color = CROW }, h.folder)
		wing.Anchored = true
		wing.Parent = body
		table.insert(wings, { p = wing, side = side })
	end
	local t0 = os.clock()
	local function place()
		local cf = body.CFrame
		for _, b in bits do
			b.p.CFrame = cf * b.at
		end
		-- beating in flight (about 5 a second), folded back along the body while perched
		local perched = body:GetAttribute("Perched") == true
		local lift = if perched then math.rad(-12) else math.rad(-5 + 50 * math.sin((os.clock() - t0) * 30))
		for _, w in wings do
			local fold = if perched then CFrame.Angles(0, -w.side * math.rad(78), 0) else CFrame.identity
			w.p.CFrame = cf
				* CFrame.new(w.side * 0.14 * s, 0.08 * s, 0)
				* fold
				* CFrame.Angles(0, 0, w.side * lift)
				* CFrame.new(w.side * 0.45 * s, 0, 0)
		end
	end
	place()
	task.spawn(function()
		while body.Parent do
			place()
			task.wait()
		end
	end)
	local heading = Vector3.new(to.X - from.X, 0, to.Z - from.Z)
	heading = if heading.Magnitude > 1e-3 then heading.Unit else Vector3.zAxis
	TweenService:Create(body, TweenInfo.new(time, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		CFrame = CFrame.lookAt(to, to + heading), -- lands level
	}):Play()
	task.delay(time, function()
		if body.Parent then
			body:SetAttribute("Perched", true)
		end
	end)
	return body
end

local function inkTrail(h: Handle, color: Color3, life: number): Trail?
	local s = sword(h)
	local a0 = s and s:FindFirstChild("TrailStart")
	local a1 = s and s:FindFirstChild("TrailEnd")
	if not s or not a0 or not a1 or not a0:IsA("Attachment") or not a1:IsA("Attachment") then
		return nil
	end
	-- a thin band at the tip (the brush), not a sheet: a wide band swept past a close camera
	-- filled the frame with ink
	local mid = Instance.new("Attachment")
	mid.Position = a0.Position:Lerp(a1.Position, 0.86)
	mid.Parent = s
	local trail = Instance.new("Trail")
	trail.Name = "IntroInk"
	trail.Attachment0 = mid
	trail.Attachment1 = a1
	trail.Color = ColorSequence.new(color)
	trail.Transparency = seq(0.2, 0.45, 1)
	trail.WidthScale = seq(1, 0)
	trail.Lifetime = life
	trail.LightEmission = 0
	trail.LightInfluence = 0.6
	trail.MinLength = 0.05
	trail.FaceCamera = false -- in the plane of the cut, like a brush; facing the camera it read as dark sheets
	trail.MaxLength = 6
	trail.Texture = (Assets.UI :: any).Chrome and (Assets.UI :: any).Chrome.BrushSwipe or ""
	trail.TextureMode = Enum.TextureMode.Stretch
	trail.Parent = s
	Debris:AddItem(trail, life + 3)
	Debris:AddItem(mid, life + 3)
	return trail
end

local WHITE = Color3.new(1, 1, 1)
local INK = Color3.fromRGB(18, 16, 22)

local function swish(h: Handle, pitch: number, volume: number?)
	local r = root(h)
	if r then
		sound(Assets.Sounds.HeavySwing, r, volume or 0.7, pitch, 1)
	end
end

local BEATS: { [string]: { Beat } } = {
	Rei = {
		{
			at = 1.1,
			run = function(h)
				local r = root(h)
				if r then
					sound(C.Sounds.TempleBell, r, 0.45, 0.9, 3)
				end
				dust(h, feet(h), Color3.fromRGB(200, 196, 186), 6, 4)
			end,
		},
		{
			at = 1.78,
			run = function(h)
				flare(h, bladeMid(h), h.accent, 3, 0.35)
				swish(h, 1.1, 0.4)
			end,
		},
	},
	Chiburi = {
		{
			at = 0.5,
			run = function(h)
				swish(h, 1.05)
			end,
		},
		{
			at = 0.6,
			run = function(h)
				local a = anchorAt(h, tip(h), 3)
				burst(a, 16, {
					Color = h.accent:Lerp(WHITE, 0.4),
					Size = seq(0.18, 0.05),
					Lifetime = NumberRange.new(0.35, 0.7),
					Speed = NumberRange.new(10, 22),
					SpreadAngle = Vector2.new(30, 30),
					Acceleration = Vector3.new(0, -40, 0),
					LightEmission = 0.6,
				})
			end,
		},
		{
			at = 1.76,
			run = function(h)
				local saya = h.props.Saya
				local r = root(h)
				if r then
					sound(Assets.Sounds.DeflectAlt, r, 0.5, 1.9, 0.4)
				end
				if saya then
					flare(h, (saya.CFrame * CFrame.new(0, 0, 1.6)).Position, GOLD, 1.4, 0.25)
				end
			end,
		},
	},
	Iai = {
		{
			at = 0.2,
			run = function(h)
				dust(h, feet(h), Color3.fromRGB(190, 190, 196), 5, 3)
			end,
		},
		{
			at = 0.74,
			run = function(h)
				local r = root(h)
				if not r then
					return
				end
				sound(Assets.Sounds.HeavySwing, r, 0.9, 0.9, 1)
				sound(Assets.Sounds.PerfectDeflect, r, 0.45, 1.25, 2)
				-- the cut: a long white streak across the front, and a glint at the tip
				local s = scaleOf(h)
				local center = r.Position + r.CFrame.LookVector * 3.2 * s + Vector3.new(0, -0.2 * s, 0)
				local streak = part({
					Anchored = true,
					Material = Enum.Material.Neon,
					Color = h.accent,
					Size = Vector3.new(9 * s, 0.07, 0.07),
					Transparency = 0.1,
					CFrame = CFrame.lookAt(center, center + r.CFrame.LookVector) * CFrame.Angles(0, 0, math.rad(-6)),
				}, h.folder)
				TweenService
					:Create(streak, TweenInfo.new(0.45), { Transparency = 1, Size = Vector3.new(11 * s, 0.02, 0.02) })
					:Play()
				Debris:AddItem(streak, 0.5)
				task.delay(0.06, function()
					flare(h, tip(h), WHITE, 4, 0.3)
				end)
				light(r, h.accent, 18, 4, 0.4)
			end,
		},
	},
	Kasa = {
		{
			at = 1.12,
			run = function(h)
				tossKasa(h)
				swish(h, 1.3, 0.35)
			end,
		},
	},
	Plant = {
		{
			at = 0.58,
			run = function(h)
				swish(h, 0.8, 0.5)
			end,
		},
		{
			at = 0.66,
			run = function(h)
				local r = root(h)
				local at = feet(h) + (if r then r.CFrame.LookVector * 1.1 * scaleOf(h) else Vector3.zero)
				if r then
					sound(Assets.Sounds.PostureBreak, r, 0.8, 0.8, 2)
				end
				shockRing(h, at + Vector3.new(0, 0.1, 0), h.accent, 9 * scaleOf(h))
				dust(h, at, Color3.fromRGB(170, 160, 140), 14, 9)
				local a = anchorAt(h, at, 3)
				burst(a, 10, {
					Color = Color3.fromRGB(120, 112, 100),
					Size = seq(0.25, 0.2),
					Transparency = seq(0, 0, 1),
					Lifetime = NumberRange.new(0.5, 0.9),
					Speed = NumberRange.new(10, 18),
					SpreadAngle = Vector2.new(50, 50),
					Acceleration = Vector3.new(0, -50, 0),
					LightInfluence = 1,
				})
			end,
		},
	},
	Sakura = {
		{
			at = 0.42,
			run = function(h)
				swish(h, 1.0)
				local r = root(h)
				if r then
					sound(C.Sounds.Chimes, r, 0.5, 1, 3)
				end
			end,
		},
		{
			at = 0.52,
			run = function(h)
				local r = root(h)
				local wind = if r then r.CFrame:VectorToWorldSpace(Vector3.new(-10, 2, -6)) else Vector3.zero
				petalsAt(h, bladeMid(h), 40, wind, h.accent)
				task.delay(0.1, function()
					petalsAt(h, tip(h), 30, wind, h.accent)
				end)
			end,
		},
		{
			at = 1.05,
			run = function(h)
				flare(h, bladeMid(h), h.accent:Lerp(WHITE, 0.5), 3, 0.4)
				petalsAt(h, bladeMid(h) + Vector3.new(0, 2, 0), 18, Vector3.new(0, -1, 0), h.accent)
			end,
		},
	},
	Tessen = {
		{
			at = 0.5,
			run = function(h)
				setFan(h, true, 0.14)
				local fan = h.props.Fan
				if fan then
					sound(C.Sounds.InkSwish, fan, 0.7, 1.3, 1)
					task.delay(0.12, function()
						flare(h, fan.Position, GOLD, 2.4, 0.3)
					end)
				end
			end,
		},
		{
			at = 1.6,
			run = function(h)
				setFan(h, false, 0.1)
				local fan = h.props.Fan
				if fan then
					sound(Assets.Sounds.DeflectAlt, fan, 0.45, 1.8, 0.4)
				end
			end,
		},
	},
	Crow = {
		{
			at = 0.35,
			run = function(h)
				local r = root(h)
				local hand = h.model:FindFirstChild("LeftHand")
				if not r or not hand or not hand:IsA("BasePart") then
					return
				end
				local s = scaleOf(h)
				local perch = r.Position + r.CFrame:VectorToWorldSpace(Vector3.new(-1.9, 1.6, -0.5) * s)
				local from = perch + r.CFrame:VectorToWorldSpace(Vector3.new(-6, 12, -8) * s)
				local bird = crow(h, from, perch, 0.5, s)
				sound(C.Sounds.Wings, r, 0.5, 1.1, 1.5)
				task.delay(0.52, function()
					sound(C.Sounds.Caw, r, 0.6, 1, 2)
					feathersAt(h, perch, 8, -3, INK)
				end)
				task.delay(1.05, function()
					if not bird.Parent then
						return
					end
					local away = perch + r.CFrame:VectorToWorldSpace(Vector3.new(-3, 14, 10) * s)
					bird:SetAttribute("Perched", false)
					sound(C.Sounds.Wings, r, 0.6, 1.2, 1.5)
					feathersAt(h, perch, 14, 2, INK)
					TweenService:Create(bird, TweenInfo.new(0.7, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
						CFrame = CFrame.lookAt(away, away + (away - perch).Unit),
					}):Play()
					Debris:AddItem(bird, 0.8)
				end)
			end,
		},
	},
	Raiko = {
		{
			at = 0.68,
			run = function(h)
				local r = root(h)
				if not r then
					return
				end
				local t = tip(h)
				local sky = t + Vector3.new(math.random(-6, 6), 70, math.random(-6, 6))
				local mid = sky:Lerp(t, 0.55) + Vector3.new(math.random(-4, 4), 0, math.random(-4, 4))
				bolt(h, sky, mid, 2.2, h.accent, 0.35)
				bolt(h, mid, t, 1.8, h.accent, 0.35)
				flare(h, t, WHITE, 7, 0.35)
				light(r, h.accent, 30, 6, 0.6)
				sound(C.Sounds.Thunder, r, 0.8, 1, 3)
				shockRing(h, feet(h) + Vector3.new(0, 0.1, 0), h.accent, 7 * scaleOf(h))
			end,
		},
		{
			at = 0.8,
			run = function(h)
				local r = root(h)
				if r then
					sound(C.Sounds.Zap, r, 0.45, 1, 1.4)
				end
				for i = 0, (if reduced() then 2 else 6) do
					task.delay(i * 0.12, function()
						if not h.alive then
							return
						end
						local a, b = bladeMid(h), tip(h)
						local j = Vector3.new(math.random() - 0.5, math.random() - 0.5, math.random() - 0.5) * 0.8
						bolt(h, a + j, b - j, 0.5, h.accent, 0.12)
					end)
				end
			end,
		},
	},
	Shodo = {
		{
			at = 0.3,
			run = function(h)
				inkTrail(h, INK, 0.5)
				local r = root(h)
				if r then
					sound(C.Sounds.InkSwish, r, 0.6, 1, 1)
				end
			end,
		},
		{
			at = 0.88,
			run = function(h)
				local r = root(h)
				if r then
					sound(C.Sounds.InkSwish, r, 0.6, 1.15, 1)
				end
			end,
		},
		{
			at = 1.15,
			run = function(h)
				local s = sword(h)
				for _, d in (if s then s:GetChildren() else {}) do
					if d:IsA("Trail") and d.Name == "IntroInk" then
						d.Enabled = false -- the stroke is written
					end
				end
				local r = root(h)
				if not r then
					return
				end
				sound(C.Sounds.InkSplash, r, 0.55, 0.9, 1.5)
				-- behind the shoulder, like a scroll hung behind the fighter (in front, it sat
				-- between the hero shot's camera and the face)
				local sc = scaleOf(h)
				local at = r.Position + r.CFrame:VectorToWorldSpace(Vector3.new(2.6, 2.4, 2.2) * sc)
				kanjiBoard(h, at, C.Kanji.Ink, INK, 5 * sc, 1.0)
			end,
		},
	},
	Tsukimi = {
		{
			at = 0.05,
			run = function(h)
				local r = root(h)
				if not r then
					return
				end
				local s = scaleOf(h)
				local at = r.Position + r.CFrame:VectorToWorldSpace(Vector3.new(6, 16, 18) * s)
				kanjiBoard(h, at, C.Crescent, h.accent:Lerp(WHITE, 0.4), 14 * s, 2.0)
			end,
		},
		{
			at = 0.6,
			run = function(h)
				local r = root(h)
				if r then
					sound(C.Sounds.TempleBell, r, 0.45, 1.05, 3)
				end
			end,
		},
		{
			at = 1.5,
			run = function(h)
				flare(h, tip(h), h.accent, 3, 0.4)
				swish(h, 1.0, 0.5)
			end,
		},
	},
	Ryu = {
		{
			at = 0.3,
			run = function(h)
				local s = sword(h)
				if not s then
					return
				end
				local e = Instance.new("ParticleEmitter")
				e.Texture = GLOW
				e.Color = ColorSequence.new(h.accent, h.accent:Lerp(Color3.fromRGB(255, 240, 200), 0.5))
				e.LightEmission = 0.8
				e.Size = seq(0.35, 0)
				e.Transparency = seq(0, 1)
				e.Lifetime = NumberRange.new(0.5, 0.9)
				e.Speed = NumberRange.new(1, 3)
				e.SpreadAngle = Vector2.new(180, 180)
				e.Acceleration = Vector3.new(0, 4, 0)
				e.Rate = if reduced() then 30 else 90
				e.Parent = s
				task.delay(0.75, function()
					e.Enabled = false
				end)
				Debris:AddItem(e, 2)
				for i, at in { 0, 0.22, 0.38, 0.52 } do
					task.delay(at, function()
						swish(h, 0.85 + i * 0.12, 0.45)
					end)
				end
			end,
		},
		{
			at = 1.1,
			run = function(h)
				local r = root(h)
				if r then
					sound(Assets.Sounds.PostureBreak, r, 0.7, 0.9, 2)
				end
				shockRing(h, feet(h) + Vector3.new(0, 0.1, 0), h.accent, 10 * scaleOf(h))
				local a = anchorAt(h, feet(h), 3)
				burst(a, 26, {
					Color = h.accent,
					Size = seq(0.3, 0),
					Lifetime = NumberRange.new(0.5, 1.1),
					Speed = NumberRange.new(8, 18),
					SpreadAngle = Vector2.new(70, 70),
					Acceleration = Vector3.new(0, -8, 0),
					LightEmission = 0.8,
				})
				dust(h, feet(h), Color3.fromRGB(160, 150, 136), 10, 8)
			end,
		},
	},
}

---------------------------------------------------------------------------------------
-- A sheathed blade. The real sword stays welded to the hand, and with real avatars' arm
-- lengths it showed beside the saya instead of in it, so while an intro has the blade
-- sheathed the sword is hidden (locally) and a hilt sits in the saya's mouth instead.

-- Clip seconds at which the blade leaves the saya.
local SHEATHED: { [string]: number } = { Iai = 0.72 }

local function swordParts(h: Handle): { BasePart }
	local out = {}
	for _, name in { "Sword", "Sword2" } do
		local s = h.model:FindFirstChild(name)
		if s and s:IsA("BasePart") then
			table.insert(out, s)
			for _, d in s:GetDescendants() do
				if d:IsA("BasePart") then
					table.insert(out, d)
				end
			end
		end
	end
	return out
end

local function sheathe(h: Handle, sheathed: boolean)
	for _, p in swordParts(h) do
		p.LocalTransparencyModifier = if sheathed then 1 else 0
	end
	local hilt = h.props.Hilt
	if hilt and hilt.Parent then
		for _, d in (hilt.Parent :: Instance):GetChildren() do
			if d:IsA("BasePart") then
				d.Transparency = if sheathed then 0 else 1
			end
		end
	end
end

local function buildHilt(h: Handle)
	local saya = h.props.Saya
	if not saya then
		return
	end
	local s = scaleOf(h)
	local holder = Instance.new("Model")
	holder.Name = "IntroHilt"
	local function bit(name: string, size: Vector3, color: Color3, at: CFrame, shape: Enum.PartType?): BasePart
		local b = part({ Name = name, Size = size * s, Color = color, Shape = shape }, holder)
		b.CFrame = saya.CFrame * at
		local w = Instance.new("Weld")
		w.Part0, w.Part1, w.C0 = saya, b, at
		w.Parent = b
		return b
	end
	-- the tsuba (a guard disc) at the mouth, then the wrapped grip and a gold pommel
	bit(
		"Tsuba",
		Vector3.new(0.06, 0.5, 0.5),
		LACQUER,
		CFrame.new(0, 0, 1.7 * s) * CFrame.Angles(0, math.pi / 2, 0),
		Enum.PartType.Cylinder
	)
	local grip = bit("Tsuka", Vector3.new(0.17, 0.2, 1.05), Color3.fromRGB(34, 30, 36), CFrame.new(0, 0, 2.26 * s))
	bit("Kashira", Vector3.new(0.19, 0.22, 0.08), GOLD, CFrame.new(0, 0, 2.8 * s))
	holder.Parent = h.folder
	h.props.Hilt = grip
end

-- Dresses `model` with `clip`'s props and schedules its beats `offset` seconds from now (the
-- clip's time 0). Returns a handle for stop().
function IntroFX.start(model: Model, clip: string, accent: Color3, offset: number): Handle
	local folder = Instance.new("Folder")
	folder.Name = "IntroFX"
	folder.Parent = workspace
	local h: Handle = { model = model, folder = folder, props = {}, alive = true, accent = accent }
	local uses = (BakedIntros.Props.Uses :: any)[clip] :: { string }?
	for _, name in uses or {} do
		local build = BUILD[name]
		if build then
			local ok, err = pcall(build, h)
			if not ok then
				warn("[IntroFX] prop", name, err)
			end
		end
	end
	local drawAt = SHEATHED[clip]
	if drawAt and h.props.Saya then
		buildHilt(h)
		sheathe(h, true)
		h.sheathed = true
		task.delay(math.max(offset + drawAt, 0), function()
			if h.alive and h.sheathed then
				h.sheathed = false
				sheathe(h, false)
			end
		end)
	end
	for _, beat in BEATS[clip] or {} do
		task.delay(math.max(offset + beat.at, 0), function()
			if h.alive and model.Parent then
				local ok, err = pcall(beat.run, h)
				if not ok then
					warn("[IntroFX]", clip, err)
				end
			end
		end)
	end
	return h
end

-- Ends the intro's effects: props and anything still burning are cleared (after `delay`).
function IntroFX.stop(h: Handle, delay: number?)
	h.alive = false
	if h.sheathed then
		h.sheathed = false
		sheathe(h, false) -- cut short before the draw: the blade comes back at once
	end
	local folder = h.folder
	if delay and delay > 0 then
		task.delay(delay, function()
			folder:Destroy()
		end)
	else
		folder:Destroy()
	end
end

return IntroFX
