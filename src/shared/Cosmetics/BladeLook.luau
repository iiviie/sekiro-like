--!strict
-- Dresses a sword part (built by server/SwordRig) in a blade look (Cosmetics/Blades): the
-- mesh tint, the edge line, the ink outline, a glow, the motes it sheds, and the weapon
-- Mastery evolutions (a sageo ribbon at M10, an engraved line along the edge at M25, an aura at
-- M50). The server calls it for everyone; the client calls it on its own sword for Locker
-- previews (a local change, nobody else sees it). Re-applying replaces what it added before.

local Assets = require(script.Parent.Parent.Assets)
local Blades = require(script.Parent.Blades)

local BladeLook = {}

-- Everything this module adds is named here, so a re-apply can clear it.
local ADDED = { "SkinGlow", "SkinPetals", "SkinMotes", "MoteSpan", "Sageo", "Engraving", "MasteryAura" }

local GLOW = Assets.UI.Glow
local C = Assets.Cosmetics

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

-- Glowing kinds stay only half additive: fully additive pale motes vanish against the daylit
-- sand, so they keep some of their own colour (seen in Studio, phase 3).
-- A mote emitter of `kind` (also used by client/CosmeticFX for line smears and deflects, so a
-- line's petals are the same petals everywhere).
function BladeLook.emitter(kind: string, color: Color3): ParticleEmitter
	local e = Instance.new("ParticleEmitter")
	e.Name = "SkinMotes"
	e.Color = ColorSequence.new(color)
	e.LightInfluence = 0
	e.Rate = 0
	e.Rotation = NumberRange.new(0, 360)
	if kind == "petals" or kind == "paper" then
		e.Texture = C.Petal
		e.Size = seq(0.24, 0.2, 0.12)
		e.Transparency = seq(0.05, 0.1, 1)
		e.Lifetime = NumberRange.new(1, 1.8)
		e.Speed = NumberRange.new(0.4, 1.3)
		e.SpreadAngle = Vector2.new(180, 180)
		e.Acceleration = Vector3.new(0.6, -1.4, 0.3)
		e.RotSpeed = NumberRange.new(-180, 180)
		e.LightEmission = 0.08 -- additive light turns pale pink white in daylight
		e.LightInfluence = 0.3
		if kind == "paper" then
			e.Squash = NumberSequence.new(-0.5) -- wide strips of paper
			e.LightEmission = 0.1
		end
	elseif kind == "feathers" then
		e.Texture = C.Feather
		e.Size = seq(0.42, 0.36, 0.3)
		e.Transparency = seq(0, 0, 1)
		e.Lifetime = NumberRange.new(1.2, 2)
		e.Speed = NumberRange.new(0.3, 1)
		e.SpreadAngle = Vector2.new(180, 180)
		e.Acceleration = Vector3.new(0.3, -1.1, 0)
		e.RotSpeed = NumberRange.new(-90, 90)
		e.Drag = 1
		e.LightEmission = 0
		e.LightInfluence = 1
	elseif kind == "sparks" then
		e.Texture = GLOW
		e.Size = seq(0.14, 0)
		e.Lifetime = NumberRange.new(0.08, 0.2)
		e.Speed = NumberRange.new(4, 9)
		e.SpreadAngle = Vector2.new(180, 180)
		e.Orientation = Enum.ParticleOrientation.VelocityParallel
		e.Squash = NumberSequence.new(2.5)
		e.LightEmission = 0.6
		e.Brightness = 3
	elseif kind == "embers" then
		e.Texture = GLOW
		e.Size = seq(0.18, 0.12, 0)
		e.Lifetime = NumberRange.new(0.6, 1.2)
		e.Speed = NumberRange.new(0.3, 1.2)
		e.SpreadAngle = Vector2.new(180, 180)
		e.Acceleration = Vector3.new(0, 2.5, 0)
		e.LightEmission = 0.4
		e.Brightness = 2
	elseif kind == "mist" then
		e.Texture = GLOW
		e.Size = seq(0.5, 1.2, 1.6)
		e.Transparency = seq(1, 0.55, 1)
		e.Lifetime = NumberRange.new(0.8, 1.4)
		e.Speed = NumberRange.new(0.1, 0.4)
		e.SpreadAngle = Vector2.new(180, 180)
		e.LightEmission = 0.2
	elseif kind == "snow" then
		e.Texture = GLOW
		e.Size = seq(0.16, 0.1)
		e.Transparency = seq(0, 1)
		e.Lifetime = NumberRange.new(1, 2)
		e.Speed = NumberRange.new(0.2, 0.6)
		e.SpreadAngle = Vector2.new(180, 180)
		e.Acceleration = Vector3.new(0.2, -1, 0)
		e.LightEmission = 0.2
	elseif kind == "foxfire" then
		e.Texture = GLOW
		e.Color = ColorSequence.new(color:Lerp(Color3.new(1, 1, 1), 0.5), color)
		e.Size = seq(0.42, 0.3, 0)
		e.Transparency = seq(0.05, 0.25, 1)
		e.Lifetime = NumberRange.new(0.4, 0.8)
		e.Speed = NumberRange.new(0.2, 0.8)
		e.SpreadAngle = Vector2.new(30, 30)
		e.Acceleration = Vector3.new(0, 4, 0)
		e.LightEmission = 0.5
		e.Brightness = 2
	else -- glints: twinkles that bloom and vanish in place along the blade
		e.Texture = GLOW
		e.Size = seq(0, 0.3, 0)
		e.Lifetime = NumberRange.new(0.35, 0.7)
		e.Speed = NumberRange.new(0, 0.1)
		e.LightEmission = 0.6
		e.Brightness = 4
	end
	return e
end

-- Blade-space points along the blade, guard to tip.
local function bladePoints(sword: BasePart): (Vector3, Vector3)
	local from = sword:FindFirstChild("TrailStart")
	local to = sword:FindFirstChild("TrailEnd")
	local guard = if from and from:IsA("Attachment") then from.Position else Vector3.new(0, 0, 0)
	local tip = if to and to:IsA("Attachment") then to.Position else Vector3.new(0, 0, sword.Size.Z / 2)
	return guard, tip
end

-- Emitters spread along the blade (an emitter on an attachment emits from a point).
local function motesAlong(sword: BasePart, guard: Vector3, tip: Vector3, kind: string, color: Color3, rate: number)
	-- `rate` is per blade at rest; seen in Studio, that left one or two short-lived motes on
	-- the whole blade at a time, so the blade sheds twice its listed rate.
	local each = rate * 2 / 3
	for _, at in { 0.35, 0.65, 0.95 } do
		local attachment = Instance.new("Attachment")
		attachment.Name = "MoteSpan"
		attachment.Position = guard:Lerp(tip, at)
		attachment.Parent = sword
		local e = BladeLook.emitter(kind, color)
		e.Rate = each
		e:SetAttribute("BaseRate", each) -- client/CombatVisuals scales it for reduced effects
		e.Parent = attachment
	end
end

local function weld(sword: BasePart, part: BasePart, at: CFrame)
	local w = Instance.new("Weld")
	w.Part0 = sword
	w.Part1 = part
	w.C0 = at
	w.Parent = part
end

-- M10: a silk sageo ribbon tied at the pommel, trailing back and down in two tails.
local function sageo(sword: BasePart, color: Color3)
	local pommel = Vector3.new(0, 0, -sword.Size.Z / 2 + 0.05)
	local knot = Instance.new("Attachment")
	knot.Name = "Sageo"
	knot.Position = pommel
	knot.Parent = sword
	for i, tail in { Vector3.new(0.12, -0.75, -0.9), Vector3.new(-0.1, -0.95, -0.55) } do
		local finish = Instance.new("Attachment")
		finish.Name = "Sageo"
		finish.Position = pommel + tail
		finish.Parent = sword
		local beam = Instance.new("Beam")
		beam.Name = "Sageo"
		beam.Attachment0 = knot
		beam.Attachment1 = finish
		beam.Color = ColorSequence.new(color, color:Lerp(Color3.new(0, 0, 0), 0.25))
		beam.Width0 = 0.2
		beam.Width1 = if i == 1 then 0.14 else 0.1
		beam.CurveSize0 = 0.25
		beam.CurveSize1 = -0.35
		beam.Segments = 12
		beam.FaceCamera = true
		beam.LightInfluence = 1
		beam.Transparency = NumberSequence.new(0)
		beam.Parent = sword
	end
end

-- M25: a gold line engraved along the blade just inside the edge.
local function engrave(sword: BasePart, color: Color3)
	for _, line in sword:GetChildren() do
		if line.Name == "Edge" and line:IsA("BasePart") then
			local weldOf = line:FindFirstChildOfClass("Weld")
			if weldOf then
				local copy = Instance.new("Part")
				copy.Name = "Engraving"
				copy.Size = Vector3.new(line.Size.X + 0.01, 0.035, line.Size.Z)
				copy.Color = color
				copy.Material = Enum.Material.Neon
				copy.CanCollide, copy.CanQuery, copy.CanTouch = false, false, false
				copy.Massless = true
				copy.CastShadow = false
				weld(sword, copy, CFrame.new(0, 0.11, 0) * weldOf.C0)
				copy.Parent = sword
			end
		end
	end
end

-- M50: a slow aura of light rising off the blade, and a stronger glow.
local function aura(sword: BasePart, guard: Vector3, tip: Vector3, color: Color3)
	for _, at in { 0.25, 0.55, 0.85 } do
		local span = Instance.new("Attachment")
		span.Name = "MasteryAura"
		span.Position = guard:Lerp(tip, at)
		span.Parent = sword
		local e = Instance.new("ParticleEmitter")
		e.Name = "MasteryAura"
		e.Texture = GLOW
		e.Color = ColorSequence.new(color:Lerp(Color3.new(1, 1, 1), 0.4), color)
		e.Size = seq(0.7, 0.5, 0)
		-- Half-additive and fairly opaque: a fully additive pale glow vanishes in daylight.
		e.Transparency = seq(0.3, 0.5, 1)
		e.Lifetime = NumberRange.new(0.45, 0.8)
		e.Speed = NumberRange.new(0.2, 0.6)
		e.SpreadAngle = Vector2.new(180, 180)
		e.Acceleration = Vector3.new(0, 1.6, 0)
		e.LightEmission = 0.5
		e.LightInfluence = 0
		e.Rate = 6
		e:SetAttribute("BaseRate", 6)
		e.Parent = span
	end
end

function BladeLook.apply(sword: BasePart, look: Blades.Look)
	local mesh = sword:FindFirstChildOfClass("SpecialMesh")
	if mesh then
		mesh.VertexColor = look.tint
	end
	for _, line in sword:GetChildren() do
		if line.Name == "Edge" and line:IsA("BasePart") then
			line.Color = look.edge
		end
	end
	local outline = sword:FindFirstChild("BladeOutline")
	if outline and outline:IsA("Highlight") then
		outline.OutlineColor = look.outline
		outline.FillColor = look.fill
	end
	for _, child in sword:GetChildren() do
		if table.find(ADDED, child.Name) then
			child:Destroy()
		end
	end
	local tip = sword:FindFirstChild("TrailEnd")
	if tip then
		for _, child in tip:GetChildren() do
			if table.find(ADDED, child.Name) then
				child:Destroy()
			end
		end
	end

	local glow = look.glow
	if look.evolution >= 3 then
		glow = glow or look.ribbon
	end
	if glow then
		local light = Instance.new("PointLight")
		light.Name = "SkinGlow"
		light.Color = glow
		light.Range = if look.evolution >= 3 then 9 else 6
		light.Brightness = if look.evolution >= 3 then 1.8 else 1.2
		light.Shadows = false
		light.Parent = sword
	end

	local guard, tipAt = bladePoints(sword)
	local motes = look.motes
	if motes then
		motesAlong(sword, guard, tipAt, motes.kind, motes.color, motes.rate)
	end
	if look.evolution >= 1 then
		sageo(sword, look.ribbon)
	end
	if look.evolution >= 2 then
		engrave(sword, Color3.fromRGB(255, 214, 120))
	end
	if look.evolution >= 3 then
		aura(sword, guard, tipAt, look.glow or look.ribbon)
	end
	sword:SetAttribute("Look", look.id)
end

return BladeLook
