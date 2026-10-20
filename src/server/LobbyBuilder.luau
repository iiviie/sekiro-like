--!strict
-- Builds the free-roam lobby: a sculpted floating island high above the castle, laid out
-- in tiers so it reads with depth from the moment you spawn.
--
--   Spawn plaza (lower tier)  ->  grand stair  ->  Torii terrace (upper tier, overlooking
--   the castle): the glowing Royale pad, a great torii and two towering stone lanterns.
--   Left wing: the dojo, with the deflect trainer under a pavilion.
--   Right wing: the hall of champions, with the leaderboards.
--   Two ponds spill off the rim as waterfalls; rope bridges lead to two small islets; more
--   islets drift at a distance over a sea of cloud.
--
-- The island is smooth terrain (organic cliffs for little memory); plazas and paths are
-- painted onto it. Architecture is parts, and props are cloned from Workspace.Props. The
-- layout's key points (spawn, pad, trainer) are published as attributes on Workspace.Lobby
-- for LobbyService.
--
-- Terrain note: a fill whose top is at height Y gives a walkable surface at Y + 2, and a
-- thin fill can't repaint existing voxels, so materials are painted with ReplaceMaterial.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Palette = require(ReplicatedStorage.Shared.Palette)

local LOBBY = Config.Lobby
local O = LOBBY.Origin -- fill top of the lower tier
local MAIN_RADIUS = LOBBY.Radius
local LOWER = O.Y + 2 -- walk heights of the three tiers
local WING = O.Y + 6
local UPPER = O.Y + 10

local LobbyBuilder = {}

local terrain = workspace.Terrain

---------------------------------------------------------------------------------------
-- Helpers

local function at(x: number, y: number, z: number): Vector3
	return Vector3.new(O.X + x, y, O.Z + z)
end

local function part(props: { [string]: any }, parent: Instance): BasePart
	local className = props.ClassName or "Part"
	props.ClassName = nil
	local p = Instance.new(className) :: BasePart
	p.Anchored = true
	p.CanTouch = false
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	for k, v in props do
		(p :: any)[k] = v
	end
	p.Parent = parent
	return p
end

local function decor(props: { [string]: any }): { [string]: any }
	props.CanCollide = false
	props.CanQuery = false
	if props.CastShadow == nil then
		props.CastShadow = false
	end
	return props
end

local function disc(
	radius: number,
	height: number,
	center: Vector3,
	props: { [string]: any },
	parent: Instance
): BasePart
	props.Shape = Enum.PartType.Cylinder
	props.Size = Vector3.new(height, radius * 2, radius * 2)
	props.CFrame = CFrame.new(center) * CFrame.Angles(0, 0, math.rad(90))
	return part(props, parent)
end

-- A flat-topped landmass: a grass cap over rock, top at `top` (walkable at top + 2).
local function plateau(center: Vector3, radius: number, top: number, depth: number)
	terrain:FillCylinder(CFrame.new(center.X, top - depth / 2, center.Z), depth, radius, Enum.Material.Rock)
	terrain:FillCylinder(CFrame.new(center.X, top - 3, center.Z), 6, radius, Enum.Material.Grass)
end

-- Repaint the top voxel layers inside a circle, row by row on the 4-stud voxel grid.
local function paint(center: Vector3, radius: number, top: number, material: Enum.Material, layers: number?)
	local bottom = top - 4 * (layers or 1)
	for z = -radius, radius, 4 do
		local half = math.sqrt(math.max(radius * radius - z * z, 0))
		if half >= 2 then
			local from = Vector3.new(center.X - half, bottom, center.Z + z - 2)
			local to = Vector3.new(center.X + half, top, center.Z + z + 2)
			local region = Region3.new(from, to):ExpandToGrid(4)
			for _, source in { Enum.Material.Grass, Enum.Material.Rock, Enum.Material.LeafyGrass, Enum.Material.Ground } do
				if source ~= material then
					terrain:ReplaceMaterial(region, 4, source, material)
				end
			end
		end
	end
end

-- A straight painted path between two points on one tier.
local function path(from: Vector3, to: Vector3, width: number, top: number, material: Enum.Material)
	local steps = math.ceil((to - from).Magnitude / 3)
	for i = 0, steps do
		paint(from:Lerp(to, i / steps), width / 2, top, material)
	end
end

local function rimRocks(center: Vector3, radius: number, top: number, count: number, gaps: { number }, seed: number)
	local random = Random.new(seed)
	for i = 1, count do
		local angle = (i / count) * math.pi * 2 + random:NextNumber(-0.08, 0.08)
		local open = false
		for _, gap in gaps do
			local diff = math.abs((angle - gap + math.pi) % (math.pi * 2) - math.pi)
			if diff < 0.28 then
				open = true
			end
		end
		if not open then
			local r = radius - random:NextNumber(1, 4)
			local size = random:NextNumber(5, 9)
			terrain:FillBall(
				Vector3.new(
					center.X + math.cos(angle) * r,
					top - random:NextNumber(1, 4),
					center.Z + math.sin(angle) * r
				),
				size,
				Enum.Material.Rock
			)
		end
	end
end

-- The rough, tapering rock underside of an island: rings of boulders that shrink toward a
-- point `depth` studs below the island's `bottom`, like an inverted cone. Every boulder
-- stays inside or below the island's rock, never poking up through its walkable top.
local function underside(center: Vector3, radius: number, bottom: number, depth: number, seed: number)
	local random = Random.new(seed)
	-- No boulder may rise more than 4 studs into the island's rock, whatever its size.
	local cap = bottom + 4
	local function ball(position: Vector3, size: number, material: Enum.Material)
		local r = math.min(size, cap - position.Y)
		if r >= 2 then
			terrain:FillBall(position, r, material)
		end
	end
	local layers = math.clamp(math.floor(depth / 9), 2, 5)
	local step = depth / layers
	for k = 0, layers - 1 do
		local frac = k / layers
		local ring = radius * 0.85 * (1 - frac)
		local size = math.max(radius * 0.24 * (1 - frac * 0.55), 4)
		local y = bottom - step * (k + 0.5)
		-- A flat core disc per layer (discs, unlike balls, can't bulge up through the top).
		if ring > 3 then
			terrain:FillCylinder(CFrame.new(center.X, y, center.Z), step + 2, ring * 0.92, Enum.Material.Rock)
		end
		-- Boulders around its edge make the silhouette rough.
		local count = if ring < size then 1 else math.max(3, math.floor(2 * math.pi * ring / (size * 1.3)))
		for i = 1, count do
			local angle = (i / count) * math.pi * 2 + random:NextNumber(-0.25, 0.25)
			local r = if count == 1 then 0 else ring * random:NextNumber(0.85, 1.05)
			ball(
				Vector3.new(
					center.X + math.cos(angle) * r,
					y + random:NextNumber(-2, 2),
					center.Z + math.sin(angle) * r
				),
				size * random:NextNumber(0.85, 1.15),
				if k == layers - 1 and i % 2 == 0 then Enum.Material.Slate else Enum.Material.Rock
			)
		end
	end
	-- The tip.
	ball(Vector3.new(center.X, bottom - depth, center.Z), math.max(radius * 0.1, 3), Enum.Material.Slate)
end

-- Clone a prop from Workspace.Props, standing on height `ground`.
local function prop(name: string, cframe: CFrame, parent: Instance, scale: number?): Model?
	local props = workspace:FindFirstChild("Props")
	local source = props and props:FindFirstChild(name, true)
	if not source or not source:IsA("Model") then
		return nil
	end
	local copy = source:Clone()
	if scale then
		copy:ScaleTo(copy:GetScale() * scale)
	end
	copy:PivotTo(cframe)
	local boxCFrame, boxSize = copy:GetBoundingBox()
	local bottom = boxCFrame.Position.Y - boxSize.Y / 2
	copy:PivotTo(copy:GetPivot() + Vector3.new(0, cframe.Position.Y - bottom, 0))
	for _, d in copy:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = true
			d.CanTouch = false
		end
	end
	copy.Parent = parent
	return copy
end

local treeIndex = 0
local function tree(position: Vector3, parent: Instance, scale: number?)
	local trees = workspace:FindFirstChild("Props") and workspace.Props:FindFirstChild("Trees")
	if not trees then
		return
	end
	local list = trees:GetChildren()
	treeIndex = treeIndex % #list + 1
	local source = list[treeIndex]
	if not source:IsA("Model") then
		return
	end
	local copy = source:Clone()
	if scale then
		copy:ScaleTo(copy:GetScale() * scale)
	end
	local boxCFrame, boxSize = copy:GetBoundingBox()
	local pivotToBottom = copy:GetPivot().Position.Y - (boxCFrame.Position.Y - boxSize.Y / 2)
	copy:PivotTo(
		CFrame.new(position + Vector3.new(0, pivotToBottom - 0.5, 0)) * CFrame.Angles(0, math.rad(treeIndex * 47), 0)
	)
	copy.Parent = parent
end

local function lantern(position: Vector3, parent: Instance)
	local model = prop("Lantern", CFrame.new(position), parent)
	if model then
		local light = Instance.new("PointLight")
		light.Color = Palette.Ember
		light.Range = 14
		light.Brightness = 0.9
		light.Shadows = false
		local primary = model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart", true)
		if primary then
			light.Parent = primary
		end
	end
end

local function billboard(adornee: BasePart, title: string, height: number)
	local gui = Instance.new("BillboardGui")
	gui.Name = "Label"
	gui.Size = UDim2.fromOffset(280, 70)
	gui.StudsOffsetWorldSpace = Vector3.new(0, height, 0)
	gui.MaxDistance = 120
	gui.LightInfluence = 0
	gui.Parent = adornee
	local heading = Instance.new("TextLabel")
	heading.BackgroundTransparency = 1
	heading.Size = UDim2.fromScale(1, 0.6)
	heading.Font = Enum.Font.Garamond
	heading.TextScaled = true
	heading.TextColor3 = Palette.Parchment
	heading.TextStrokeTransparency = 0.5
	heading.Text = title
	heading.Parent = gui
end

---------------------------------------------------------------------------------------
-- Landforms

local BRIDGE_LEFT =
	{ from = Vector2.new(-62, 31), to = Vector2.new(-86, 40), islet = Vector2.new(-102, 46), radius = 18 }
local BRIDGE_BACK = { from = Vector2.new(16, 66), to = Vector2.new(23, 93), islet = Vector2.new(27, 109), radius = 17 }

local function landforms()
	-- Main island (lower tier) with a lumpy rock rim, open where bridges and falls leave.
	plateau(at(0, 0, 0), MAIN_RADIUS, O.Y, 26)
	local gaps = {
		math.atan2(BRIDGE_LEFT.from.Y, BRIDGE_LEFT.from.X),
		math.atan2(BRIDGE_BACK.from.Y, BRIDGE_BACK.from.X),
		math.atan2(-36, 60), -- right waterfall
		math.atan2(-42, -56), -- left waterfall
	}
	rimRocks(at(0, 0, 0), MAIN_RADIUS, O.Y + 2, 44, gaps, 3)
	underside(at(0, 0, 0), MAIN_RADIUS, O.Y - 26, 44, 5)

	-- Upper tier: the torii terrace, and two wings.
	plateau(at(0, 0, -40), 34, O.Y + 8, 14)
	rimRocks(at(0, 0, -40), 34, O.Y + 10, 26, { math.rad(90), math.rad(-90), math.rad(-60), math.rad(-120) }, 7)
	plateau(at(-48, 0, -2), 20, O.Y + 4, 10)
	plateau(at(48, 0, -2), 20, O.Y + 4, 10)

	-- Plazas and paths.
	paint(at(0, 0, 24), 24, O.Y, Enum.Material.Cobblestone)
	paint(at(0, 0, 24), 8, O.Y, Enum.Material.Slate)
	path(at(0, 0, 14), at(0, 0, 4), 12, O.Y, Enum.Material.Cobblestone)
	path(at(-16, 0, 16), at(-30, 0, 2), 6, O.Y, Enum.Material.Cobblestone)
	path(at(16, 0, 16), at(30, 0, 2), 6, O.Y, Enum.Material.Cobblestone)
	path(
		at(-14, 0, 32),
		Vector3.new(O.X + BRIDGE_LEFT.from.X, 0, O.Z + BRIDGE_LEFT.from.Y),
		5,
		O.Y,
		Enum.Material.Ground
	)
	path(at(6, 0, 44), Vector3.new(O.X + BRIDGE_BACK.from.X, 0, O.Z + BRIDGE_BACK.from.Y), 5, O.Y, Enum.Material.Ground)
	paint(at(0, 0, -44), 18, O.Y + 8, Enum.Material.Cobblestone)
	path(at(0, 0, -10), at(0, 0, -28), 10, O.Y + 8, Enum.Material.Cobblestone)
	path(at(0, 0, -58), at(0, 0, -70), 10, O.Y + 8, Enum.Material.Cobblestone)
	paint(at(-48, 0, -2), 12, O.Y + 4, Enum.Material.Sand)
	paint(at(48, 0, -2), 14, O.Y + 4, Enum.Material.Cobblestone)

	-- Ponds whose streams run to the rim, where the waterfalls take over. Water only
	-- replaces the top voxel layer and stops short of the cliff, so the rock face stays solid.
	for _, pond in { { at(44, 0, -36), Vector2.new(1, 0) }, { at(-44, 0, -42), Vector2.new(-1, 0) } } do
		local center = pond[1] :: Vector3
		paint(center, 7, O.Y, Enum.Material.Water)
		local dir = pond[2] :: Vector2
		path(center, center + Vector3.new(dir.X * 12, 0, dir.Y * 12), 4, O.Y, Enum.Material.Water)
	end

	-- The two islets the bridges reach.
	for i, bridge in { BRIDGE_LEFT, BRIDGE_BACK } do
		local center = Vector3.new(O.X + bridge.islet.X, 0, O.Z + bridge.islet.Y)
		plateau(center, bridge.radius, O.Y, 12)
		underside(center, bridge.radius, O.Y - 12, bridge.radius * 1.5, 20 + i)
		rimRocks(center, bridge.radius, O.Y + 2, 12, {
			math.atan2(bridge.to.Y - bridge.islet.Y, bridge.to.X - bridge.islet.X),
		}, 30 + i)
	end
end

-- Far islets drifting around the island: depth and scale without anything to load.
local function farIslets(parent: Instance)
	local random = Random.new(41)
	local placed = 0
	local attempts = 0
	while placed < 9 and attempts < 60 do
		attempts += 1
		local angle = random:NextNumber(0, math.pi * 2)
		-- Keep the view toward the castle (-Z from the island) clear.
		local towardCastle = math.abs((angle - math.rad(-90) + math.pi) % (math.pi * 2) - math.pi)
		if towardCastle > math.rad(40) then
			placed += 1
			local distance = random:NextNumber(130, 250)
			local radius = random:NextNumber(10, 26)
			local top = O.Y + random:NextNumber(-24, 46)
			local center = Vector3.new(O.X + math.cos(angle) * distance, 0, O.Z + math.sin(angle) * distance)
			local thickness = math.max(radius * 0.4, 8)
			plateau(center, radius, top, thickness)
			underside(center, radius, top - thickness, radius * 1.4, 100 + placed)
			if radius > 15 then
				tree(Vector3.new(center.X, top + 2, center.Z), parent, random:NextNumber(0.9, 1.3))
			end
		end
	end
end

---------------------------------------------------------------------------------------
-- Architecture

local function stairs(parent: Instance, from: Vector3, to: Vector3, width: number, steps: number)
	-- `from` is the foot (lower walk height), `to` the head; steps rise evenly.
	local run = Vector3.new(to.X - from.X, 0, to.Z - from.Z)
	local stepRun = run.Magnitude / steps
	local rise = (to.Y - from.Y) / steps
	local forward = run.Unit
	local look = CFrame.lookAt(Vector3.zero, forward)
	for i = 1, steps do
		local top = from.Y + rise * i
		local height = top - (from.Y - 3)
		local center = Vector3.new(from.X, 0, from.Z) + forward * (stepRun * (i - 0.5))
		part({
			Name = "Step",
			Size = Vector3.new(width, height, stepRun + 0.05),
			CFrame = CFrame.new(center.X, top - height / 2, center.Z) * look.Rotation,
			Material = Enum.Material.Slate,
			Color = Palette.Flagstone:Lerp(Palette.Stone, (i % 3) / 6),
			CastShadow = false,
		}, parent)
	end
	-- Low stone posts down both edges, one per step.
	for i = 1, steps, 2 do
		local top = from.Y + rise * i
		for _, side in { -1, 1 } do
			local position = Vector3.new(from.X, 0, from.Z)
				+ forward * (stepRun * (i - 0.5))
				+ look.RightVector * side * (width / 2 + 0.5)
			part({
				Name = "StairPost",
				Size = Vector3.new(1, 2.4, 1),
				CFrame = CFrame.new(position.X, top + 1.2, position.Z) * look.Rotation,
				Material = Enum.Material.Slate,
				Color = Palette.Stone,
				CastShadow = false,
			}, parent)
		end
	end
end

local function bridge(parent: Instance, data)
	local a = Vector3.new(O.X + data.from.X, LOWER, O.Z + data.from.Y)
	local b = Vector3.new(O.X + data.to.X, LOWER, O.Z + data.to.Y)
	local length = (b - a).Magnitude
	local look = CFrame.lookAt(a, b)
	local planks = math.floor(length / 1.2)
	for i = 0, planks do
		local t = i / planks
		local sag = math.sin(t * math.pi) * 1.2
		part({
			Name = "Plank",
			Size = Vector3.new(4.6, 0.3, 1),
			CFrame = look * CFrame.new(0, -0.15 - sag, -length * t),
			Material = Enum.Material.WoodPlanks,
			Color = Palette.Deck:Lerp(Palette.Timber, (i % 4) / 6),
		}, parent)
	end
	for _, side in { -1, 1 } do
		for i = 0, 4 do
			local t = i / 4
			local sag = math.sin(t * math.pi) * 1.2
			part(
				decor({
					Name = "RopePost",
					Size = Vector3.new(0.35, 3.2, 0.35),
					CFrame = look * CFrame.new(side * 2.4, 1.4 - sag, -length * t),
					Material = Enum.Material.Wood,
					Color = Palette.Timber,
				}),
				parent
			)
		end
		-- Rope rails: two attachments per side joined by a sagging beam.
		local holder =
			part(decor({ Name = "RopeHolder", Size = Vector3.one * 0.2, Transparency = 1, CFrame = look }), parent)
		local a0 = Instance.new("Attachment")
		a0.Position = Vector3.new(side * 2.4, 2.8, 0)
		a0.Parent = holder
		local a1 = Instance.new("Attachment")
		a1.Position = Vector3.new(side * 2.4, 2.8, -length)
		a1.Parent = holder
		local rope = Instance.new("Beam")
		rope.Attachment0 = a0
		rope.Attachment1 = a1
		rope.Width0 = 0.18
		rope.Width1 = 0.18
		rope.Color = ColorSequence.new(Color3.fromRGB(150, 122, 82))
		rope.CurveSize0 = -length * 0.25
		rope.CurveSize1 = length * 0.25
		rope.FaceCamera = true
		rope.Segments = 12
		rope.LightInfluence = 1
		rope.Parent = holder
	end
end

local function waterfall(parent: Instance, top: Vector3, outward: Vector3)
	local holder =
		part(decor({ Name = "Waterfall", Size = Vector3.one, Transparency = 1, CFrame = CFrame.new(top) }), parent)
	local a0 = Instance.new("Attachment")
	a0.Parent = holder
	local a1 = Instance.new("Attachment")
	a1.Position = outward * 6 + Vector3.new(0, -70, 0)
	a1.Parent = holder
	for i, width in { 7, 4.5 } do
		local fall = Instance.new("Beam")
		fall.Attachment0 = a0
		fall.Attachment1 = a1
		fall.Width0 = width
		fall.Width1 = width * 1.8
		fall.CurveSize0 = 8
		fall.FaceCamera = true
		fall.Segments = 16
		fall.Texture = "rbxasset://textures/particles/smoke_main.dds"
		fall.TextureMode = Enum.TextureMode.Wrap
		fall.TextureLength = 10
		fall.TextureSpeed = if i == 1 then -1.6 else -2.4
		fall.Color = ColorSequence.new(Color3.fromRGB(214, 232, 240), Color3.fromRGB(180, 200, 210))
		fall.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.25),
			NumberSequenceKeypoint.new(0.7, 0.45),
			NumberSequenceKeypoint.new(1, 1),
		})
		fall.LightEmission = 0.25
		fall.LightInfluence = 0.8
		fall.Parent = holder
	end
	-- Spray where the water leaves the rim.
	local spray = Instance.new("ParticleEmitter")
	spray.Texture = "rbxasset://textures/particles/smoke_main.dds"
	spray.Color = ColorSequence.new(Color3.fromRGB(235, 242, 246))
	spray.Size = NumberSequence.new(3, 9)
	spray.Transparency = NumberSequence.new(0.55, 1)
	spray.Lifetime = NumberRange.new(2, 3)
	spray.Rate = 6
	spray.Speed = NumberRange.new(6, 12)
	spray.EmissionDirection = Enum.NormalId.Bottom
	spray.SpreadAngle = Vector2.new(15, 15)
	spray.Acceleration = Vector3.new(0, -12, 0)
	spray.LightInfluence = 1
	spray.Parent = holder
	local sound = Instance.new("Sound")
	sound.Name = "Rush"
	sound.SoundId = "rbxassetid://9112854440"
	sound.Looped = true
	sound.Volume = 0.25
	sound.RollOffMinDistance = 10
	sound.RollOffMaxDistance = 70
	sound.Parent = holder
	sound:Play()
end

-- The glowing Royale pad: step on it (or press PLAY) to queue.
local function queuePad(parent: Instance, center: Vector3)
	local radius = LOBBY.QueuePadRadius
	local pad = disc(radius + 0.8, 0.6, center + Vector3.new(0, 0.2, 0), {
		Name = "QueuePad",
		Material = Enum.Material.Slate,
		Color = Palette.Ink,
	}, parent)
	disc(
		radius,
		0.14,
		center + Vector3.new(0, 0.52, 0),
		decor({
			Name = "PadGlow",
			Material = Enum.Material.Neon,
			Color = Palette.Crimson,
		}),
		parent
	)
	disc(
		radius - 0.8,
		0.16,
		center + Vector3.new(0, 0.54, 0),
		decor({
			Name = "PadInner",
			Material = Enum.Material.Sand,
			Color = Color3.fromRGB(186, 170, 144),
		}),
		parent
	)
	local beamRoot =
		part(decor({ Name = "PadBeam", Size = Vector3.one, Transparency = 1, CFrame = CFrame.new(center) }), parent)
	for i = 1, 28 do
		local angle = (i / 28) * math.pi * 2
		local base = Vector3.new(math.cos(angle) * radius, 0.6, math.sin(angle) * radius)
		local a0 = Instance.new("Attachment")
		a0.Position = base
		a0.Parent = beamRoot
		local a1 = Instance.new("Attachment")
		a1.Position = base + Vector3.new(0, 9, 0)
		a1.Parent = beamRoot
		local beam = Instance.new("Beam")
		beam.Attachment0 = a0
		beam.Attachment1 = a1
		beam.FaceCamera = true
		beam.Width0 = 2 * math.pi * radius / 28 + 0.3
		beam.Width1 = beam.Width0
		beam.Color = ColorSequence.new(Palette.Crimson)
		beam.Transparency = NumberSequence.new(0.5, 1)
		beam.LightEmission = 0.6
		beam.Segments = 1
		beam.Parent = beamRoot
	end
	local light = Instance.new("PointLight")
	light.Color = Palette.Crimson
	light.Range = 20
	light.Brightness = 1.6
	light.Parent = beamRoot
	billboard(pad, "ROYALE", 11)
end

local function boards(parent: Instance, spots: { Vector3 }, faceToward: Vector3)
	local titles = { "TOTAL WINS", "RANKED RATING" }
	for i, base in spots do
		local look = CFrame.lookAt(base, Vector3.new(faceToward.X, base.Y, faceToward.Z))
		for _, side in { -1, 1 } do
			part({
				Name = "BoardPost",
				Size = Vector3.new(0.7, 13, 0.7),
				CFrame = look * CFrame.new(side * 4.6, 6.5, 0),
				Material = Enum.Material.Wood,
				Color = Palette.Timber,
				CastShadow = false,
			}, parent)
		end
		local board = part({
			Name = "Leaderboard",
			Size = Vector3.new(8.6, 9.5, 0.4),
			CFrame = look * CFrame.new(0, 7.2, 0),
			Material = Enum.Material.SmoothPlastic,
			Color = Palette.Ink,
			CastShadow = false,
		}, parent)
		board:SetAttribute("Board", titles[i])
		part({
			Name = "BoardCap",
			Size = Vector3.new(10.4, 0.7, 1.4),
			CFrame = look * CFrame.new(0, 12.3, 0),
			Material = Enum.Material.ClayRoofTiles,
			Color = Palette.Roof,
			CastShadow = false,
		}, parent)
	end
end

-- An open dojo pavilion: four lacquered posts and a tiled roof over a wooden deck.
local function pavilion(parent: Instance, center: Vector3, facing: Vector3)
	local look = CFrame.lookAt(center, center + facing)
	local w, d, h = 16, 10, 9
	part({
		Name = "DojoDeck",
		Size = Vector3.new(w, 0.6, d),
		CFrame = look * CFrame.new(0, 0.3, 0),
		Material = Enum.Material.WoodPlanks,
		Color = Palette.Deck,
	}, parent)
	for _, x in { -w / 2 + 0.6, w / 2 - 0.6 } do
		for _, z in { -d / 2 + 0.6, d / 2 - 0.6 } do
			part({
				Name = "DojoPost",
				Size = Vector3.new(0.9, h, 0.9),
				CFrame = look * CFrame.new(x, h / 2, z),
				Material = Enum.Material.SmoothPlastic,
				Color = Palette.Vermilion,
				CastShadow = false,
			}, parent)
		end
	end
	for _, side in { -1, 1 } do
		part({
			Name = "DojoRoof",
			Size = Vector3.new(w + 4, 0.7, d / 2 + 2.6),
			CFrame = look * CFrame.new(0, h + 1.2, side * (d / 4 + 1)) * CFrame.Angles(math.rad(side * 24), 0, 0),
			Material = Enum.Material.ClayRoofTiles,
			Color = Palette.Roof,
		}, parent)
	end
	part({
		Name = "DojoRidge",
		Size = Vector3.new(w + 4, 0.8, 1),
		CFrame = look * CFrame.new(0, h + 2.2, 0),
		Material = Enum.Material.Slate,
		Color = Palette.Roof,
		CastShadow = false,
	}, parent)
	local sign = part({
		Name = "DojoSign",
		Size = Vector3.new(6, 1.6, 0.3),
		CFrame = look * CFrame.new(0, h - 0.4, -d / 2 - 0.1),
		Material = Enum.Material.Wood,
		Color = Palette.Timber,
		CastShadow = false,
	}, parent)
	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 40
	gui.LightInfluence = 0.4
	gui.Parent = sign
	local text = Instance.new("TextLabel")
	text.BackgroundTransparency = 1
	text.Size = UDim2.fromScale(1, 1)
	text.Font = Enum.Font.Garamond
	text.TextScaled = true
	text.TextColor3 = Palette.Parchment
	text.Text = "道場  ·  DEFLECT TRAINER"
	text.Parent = gui
end

-- A sea of cloud beneath the island, parting toward the castle valley.
local function cloudSea(parent: Instance)
	local layer = part(
		decor({
			Name = "CloudSea",
			Size = Vector3.new(620, 1, 400),
			CFrame = CFrame.new(O.X, O.Y - 34, O.Z + 90),
			Transparency = 1,
		}),
		parent
	)
	local clouds = Instance.new("ParticleEmitter")
	clouds.Texture = "rbxasset://textures/particles/smoke_main.dds"
	clouds.Color = ColorSequence.new(Color3.fromRGB(250, 238, 232), Color3.fromRGB(214, 196, 204))
	clouds.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 55),
		NumberSequenceKeypoint.new(1, 85),
	})
	clouds.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.25, 0.45),
		NumberSequenceKeypoint.new(0.75, 0.5),
		NumberSequenceKeypoint.new(1, 1),
	})
	clouds.Lifetime = NumberRange.new(40, 55)
	clouds.Rate = 9
	clouds.Speed = NumberRange.new(0.4, 1.2)
	clouds.SpreadAngle = Vector2.new(80, 80)
	clouds.Rotation = NumberRange.new(0, 360)
	clouds.RotSpeed = NumberRange.new(-2, 2)
	clouds.LightInfluence = 1
	clouds.Parent = layer
	-- Warm the sea up from the start instead of letting it fill in over a minute.
	clouds:Emit(300)
end

---------------------------------------------------------------------------------------

function LobbyBuilder.build(): Folder
	local previous = workspace:FindFirstChild("Lobby")
	if previous then
		previous:Destroy()
	end
	local lobby = Instance.new("Folder")
	lobby.Name = "Lobby"
	lobby.Parent = workspace

	landforms()

	-- Spawn plaza.
	local spawnPoint = at(0, LOWER, 30)
	local terraceCenter = at(0, UPPER, -44)
	for _, x in { -11, 11 } do
		lantern(at(x, LOWER, 12), lobby)
		lantern(at(x * 1.7, LOWER, 36), lobby)
	end
	tree(at(-30, LOWER, 46), lobby, 1.2)
	tree(at(34, LOWER, 44), lobby, 1.1)
	tree(at(-58, LOWER, 18), lobby)
	tree(at(62, LOWER, 16), lobby)
	tree(at(-8, LOWER, 60), lobby, 0.9)

	-- The grand stair up to the torii terrace, and the wing stairs.
	stairs(lobby, at(0, LOWER, 8), at(0, UPPER, -8), 18, 10)
	stairs(lobby, at(-20, LOWER, -2), at(-29, WING, -2), 10, 5)
	stairs(lobby, at(20, LOWER, -2), at(29, WING, -2), 10, 5)

	-- Torii terrace: the queue pad, a great torii framing the castle, two guardians.
	queuePad(lobby, terraceCenter)
	prop("Torii", CFrame.lookAt(at(0, UPPER, -68), at(0, UPPER, -200)), lobby, 1.55)
	for _, x in { -9, 9 } do
		lantern(at(x, UPPER, -12), lobby)
		lantern(at(x * 1.3, UPPER, -62), lobby)
	end
	-- Two towering stone lanterns flank the torii.
	for _, x in { -18, 18 } do
		prop("Lantern", CFrame.new(at(x, UPPER, -64)), lobby, 2.4)
	end
	tree(at(-24, UPPER, -30), lobby, 0.9)
	tree(at(26, UPPER, -28), lobby, 0.9)

	-- Left wing: the dojo.
	local trainerHome = at(-48, WING, -2)
	pavilion(lobby, at(-56, WING - 0.2, -2), Vector3.new(1, 0, 0))
	disc(
		9,
		0.1,
		trainerHome + Vector3.new(0, 0.05, 0),
		decor({
			Name = "TrainerKerb",
			Material = Enum.Material.Slate,
			Color = Palette.Stone,
		}),
		lobby
	)
	disc(
		8.4,
		0.12,
		trainerHome + Vector3.new(0, 0.07, 0),
		decor({
			Name = "TrainerSand",
			Material = Enum.Material.Sand,
			Color = Color3.fromRGB(186, 170, 144),
		}),
		lobby
	)

	-- Right wing: the hall of champions.
	boards(lobby, { at(42, WING, -16), at(56, WING, 4) }, at(30, WING, 10))
	for _, z in { -14, 10 } do
		lantern(at(34, WING, z), lobby)
	end

	-- Bridges and their islets.
	bridge(lobby, BRIDGE_LEFT)
	bridge(lobby, BRIDGE_BACK)
	local leftIslet = Vector3.new(O.X + BRIDGE_LEFT.islet.X, LOWER, O.Z + BRIDGE_LEFT.islet.Y)
	tree(leftIslet + Vector3.new(-4, 0, 4), lobby, 1.2)
	lantern(leftIslet + Vector3.new(6, 0, -4), lobby)
	local backIslet = Vector3.new(O.X + BRIDGE_BACK.islet.X, LOWER, O.Z + BRIDGE_BACK.islet.Y)
	prop("CornerLantern", CFrame.new(backIslet), lobby, 1.3)
	tree(backIslet + Vector3.new(6, 0, 6), lobby)

	-- Waterfalls leave the rim where the streams end (the rim is at MAIN_RADIUS).
	waterfall(lobby, at(math.sqrt(MAIN_RADIUS ^ 2 - 36 ^ 2) - 1, LOWER - 1.5, -36), Vector3.new(1, 0, 0))
	waterfall(lobby, at(-math.sqrt(MAIN_RADIUS ^ 2 - 42 ^ 2) + 1, LOWER - 1.5, -42), Vector3.new(-1, 0, 0))
	farIslets(lobby)
	cloudSea(lobby)

	local spawn = Instance.new("SpawnLocation")
	spawn.Name = "LobbySpawn"
	spawn.Anchored = true
	spawn.Neutral = true
	spawn.Duration = 0
	spawn.Size = Vector3.new(10, 0.2, 10)
	spawn.CFrame = CFrame.lookAt(spawnPoint + Vector3.new(0, 0.1, 0), terraceCenter)
	spawn.Transparency = 1
	spawn.CanCollide = false
	spawn.CanQuery = false
	spawn.Parent = lobby

	-- Key points for LobbyService.
	lobby:SetAttribute("SpawnPoint", spawnPoint)
	lobby:SetAttribute("QueuePad", terraceCenter)
	lobby:SetAttribute("TrainerHome", trainerHome)
	return lobby
end

return LobbyBuilder
