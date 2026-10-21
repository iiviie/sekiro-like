--!strict
-- Builds the Ashina-style castle courtyard: terrain (raked-sand courtyard with a pale sand
-- duelling circle, grassy hills, rock outcrops on the horizon), the castle walls around the
-- fighting area, banners, braziers and drifting leaves.
-- Hand-placed props (torii, lanterns, trees, pagoda) live in Workspace.Props in the
-- place file and are restyled at runtime by EnvironmentProfile; lighting is LightingProfile.
--
-- Performance: terrain is one cheap voxel mesh; walls are a few large anchored parts
-- per segment, with shadows only on the big shapes and no queries or touches on trim.

local Config = require(game:GetService("ReplicatedStorage").Shared.Config)
local Palette = require(game:GetService("ReplicatedStorage").Shared.Palette)
local EnvironmentProfile = require(script.Parent.EnvironmentProfile)
local Torii = require(script.Parent.Torii)

local ARENA = Config.Arena
local WALL_HEIGHT = 9
local WALL_THICKNESS = 2.4
local SEGMENT_LENGTH = 24
local GATE_WIDTH = 22 -- opening in the south wall, framed by the torii outside

local PLASTER = Palette.Plaster
local TIMBER = Palette.Timber
local STONE = Palette.Stone
local ROOF = Palette.Roof
local DUEL_RADIUS = 19 -- pale sand circle in the middle of the courtyard
local FLOOR_Y = 2 -- where smooth terrain puts the walkable surface (see terrain())

local MapBuilder = {}

local function part(props: { [string]: any }, parent: Instance): Part
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanTouch = false
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	for key, value in props do
		(p :: any)[key] = value
	end
	p.Parent = parent
	return p
end

local function terrain()
	local t = workspace.Terrain
	t:Clear()

	EnvironmentProfile.applyTerrain() -- material colours and water for the daylight look

	local random = Random.new(7) -- fixed seed: the same map on every server

	-- Base land. Smooth terrain draws the surface half a voxel above the last full voxel,
	-- so the walkable ground ends up at y = FLOOR_Y. Repaint the top voxel layer with
	-- ReplaceMaterial on the 4-stud grid: thin fills can't change a full voxel's material.
	t:FillBlock(CFrame.new(0, -8, 0), Vector3.new(1024, 16, 1024), Enum.Material.Grass)
	local function paint(from: Vector3, to: Vector3, material: Enum.Material)
		local region = Region3.new(from:Min(to), from:Max(to)):ExpandToGrid(4)
		for _, source in { Enum.Material.Grass, Enum.Material.Ground, Enum.Material.Sand } do
			if source ~= material then
				t:ReplaceMaterial(region, 4, source, material)
			end
		end
	end
	local top, bottom = 0, -4
	-- Raked-sand courtyard inside the walls: a quiet, fine-grained floor in a mid value so
	-- the fighters read clearly against it (colour in EnvironmentProfile).
	local inner = ARENA.WallHalfExtent * 2 - 4
	paint(Vector3.new(-inner / 2, bottom, -inner / 2), Vector3.new(inner / 2, top, inner / 2), Enum.Material.Sand)
	-- Tufts of moss and grass breaking up the bare sand; terrain blending softens
	-- their square voxel edges.
	for _ = 1, 16 do
		local center = Vector3.new(random:NextNumber(-60, 60), 0, random:NextNumber(-60, 60))
		local half = Vector3.new(random:NextNumber(3, 7), 0, random:NextNumber(3, 7))
		if center.Magnitude > DUEL_RADIUS + 6 then
			paint(center - half + Vector3.new(0, bottom, 0), center + half, Enum.Material.LeafyGrass)
		end
	end
	-- Moss creeping along the foot of the walls hides the hard seam between floor and wall.
	local edge = inner / 2
	for _, axis in { Vector3.xAxis, Vector3.zAxis } do
		for _, sign in { -1, 1 } do
			local along = Vector3.new(1, 0, 1) - axis
			local inside = axis * sign * (edge - 8)
			local outside = axis * sign * edge
			paint(
				inside - along * edge + Vector3.new(0, bottom, 0),
				outside + along * edge + Vector3.new(0, top, 0),
				Enum.Material.LeafyGrass
			)
		end
	end
	-- Cobbled path from the torii, through the gate, to the duelling circle. (Not slate: slate
	-- terrain reads pale lilac in midday light whatever colour it is given.)
	paint(
		Vector3.new(-4, bottom, DUEL_RADIUS + 1),
		Vector3.new(4, top, ARENA.WallHalfExtent + 50),
		Enum.Material.Cobblestone
	)

	-- Gentle grassy hills rolling away from the walls; distant mountains are meshes in
	-- Workspace.Props, which are far cheaper than tall voxel peaks.
	for i = 1, 18 do
		local angle = (i / 18) * math.pi * 2 + random:NextNumber(-0.1, 0.1)
		local distance = random:NextNumber(180, 270)
		local radius = random:NextNumber(60, 110)
		local center =
			Vector3.new(math.cos(angle) * distance, -radius * random:NextNumber(0.7, 0.82), math.sin(angle) * distance)
		t:FillBall(center, radius, Enum.Material.Grass)
		if random:NextNumber() < 0.5 then
			-- An outcrop of bare rock breaking through some of them.
			t:FillBall(center + Vector3.new(0, radius * 0.95, 0), radius * 0.16, Enum.Material.Rock)
		end
	end
end

-- One stretch of castle wall: stone footing, white plaster, a dark timber band and a tiled cap.
local function wallSegment(parent: Instance, center: CFrame, length: number)
	local footing = 2.6
	part({
		Name = "Footing",
		Size = Vector3.new(length, footing, WALL_THICKNESS + 0.8),
		CFrame = center * CFrame.new(0, footing / 2, 0),
		Material = Enum.Material.Slate,
		Color = STONE,
	}, parent)
	part({
		Name = "Plaster",
		Size = Vector3.new(length, WALL_HEIGHT - footing, WALL_THICKNESS),
		CFrame = center * CFrame.new(0, footing + (WALL_HEIGHT - footing) / 2, 0),
		Material = Enum.Material.Plaster,
		Color = PLASTER,
	}, parent)
	part({
		Name = "Band",
		Size = Vector3.new(length, 0.7, WALL_THICKNESS + 0.3),
		CFrame = center * CFrame.new(0, WALL_HEIGHT - 1.2, 0),
		Material = Enum.Material.Wood,
		Color = TIMBER,
		CastShadow = false,
		CanQuery = false,
	}, parent)
	-- Tiled cap: two sloped slabs overhanging both faces, meeting at a ridge beam.
	for _, side in { -1, 1 } do
		part({
			Name = "Roof",
			Size = Vector3.new(length + 1.2, 0.6, WALL_THICKNESS + 1.6),
			CFrame = center
				* CFrame.new(0, WALL_HEIGHT + 0.7, side * (WALL_THICKNESS + 1.6) * 0.42)
				* CFrame.Angles(math.rad(side * 26), 0, 0), -- outer edge down
			Material = Enum.Material.ClayRoofTiles,
			Color = ROOF,
		}, parent)
	end
	part({
		Name = "Ridge",
		Size = Vector3.new(length + 1.2, 0.7, 0.9),
		CFrame = center * CFrame.new(0, WALL_HEIGHT + 1.35, 0),
		Material = Enum.Material.Slate,
		Color = ROOF,
		CastShadow = false,
		CanQuery = false,
	}, parent)
	-- Timber posts at the segment ends break up the long white run.
	for _, x in { -length / 2, length / 2 } do
		part({
			Name = "Post",
			Size = Vector3.new(0.8, WALL_HEIGHT - footing, WALL_THICKNESS + 0.25),
			CFrame = center * CFrame.new(x, footing + (WALL_HEIGHT - footing) / 2, 0),
			Material = Enum.Material.Wood,
			Color = TIMBER,
			CastShadow = false,
			CanQuery = false,
		}, parent)
	end
end

local function walls(parent: Instance)
	local half = ARENA.WallHalfExtent
	local sides = {
		{ CFrame.new(0, 0, -half), false }, -- north
		{ CFrame.new(half, 0, 0) * CFrame.Angles(0, math.rad(90), 0), false }, -- east
		{ CFrame.new(-half, 0, 0) * CFrame.Angles(0, math.rad(90), 0), false }, -- west
		{ CFrame.new(0, 0, half), true }, -- south, with the gate
	}
	for _, side in sides do
		local frame, hasGate = side[1] :: CFrame, side[2] :: boolean
		local span = half * 2 + WALL_THICKNESS
		local count = math.ceil(span / SEGMENT_LENGTH)
		local length = span / count
		for i = 1, count do
			local x = -span / 2 + (i - 0.5) * length
			if not (hasGate and math.abs(x) < GATE_WIDTH / 2 + length / 2 - 1) then
				wallSegment(parent, frame * CFrame.new(x, 0, 0), length)
			end
		end
		if hasGate then
			-- Gate posts either side of the opening.
			for _, x in { -GATE_WIDTH / 2 - 1, GATE_WIDTH / 2 + 1 } do
				part({
					Name = "GatePost",
					Size = Vector3.new(2.4, WALL_HEIGHT + 2, WALL_THICKNESS + 1.2),
					CFrame = frame * CFrame.new(x, (WALL_HEIGHT + 2) / 2, 0),
					Material = Enum.Material.Wood,
					Color = TIMBER,
				}, parent)
			end
		end
	end
end

-- A shrine hall against the north wall: stone footing, a raised wooden deck with steps,
-- timber pillars, paper screens and a tiled roof. About sixty parts.
local function shrine(parent: Instance)
	local model = Instance.new("Model")
	model.Name = "ShrineHall"
	local depth, width = 14, 44
	local front = -ARENA.WallHalfExtent + WALL_THICKNESS / 2 + depth -- z of the deck's front edge
	local center = CFrame.new(0, 0, front - depth / 2)
	local deckTop = 3
	local pillarHeight = 9
	local DECK = Palette.Deck

	part({
		Name = "Footing",
		Size = Vector3.new(width + 2, deckTop - 0.6, depth + 2),
		CFrame = center * CFrame.new(0, (deckTop - 0.6) / 2, 0),
		Material = Enum.Material.Slate,
		Color = STONE,
	}, model)
	part({
		Name = "Deck",
		Size = Vector3.new(width, 0.6, depth),
		CFrame = center * CFrame.new(0, deckTop - 0.3, 0),
		Material = Enum.Material.WoodPlanks,
		Color = DECK,
	}, model)
	for i = 1, 3 do
		local h = deckTop * (i / 3)
		part({
			Name = "Step",
			Size = Vector3.new(12, h, 1.6),
			CFrame = CFrame.new(0, h / 2, front + 1.6 * (3 - i) + 0.8),
			Material = Enum.Material.WoodPlanks,
			Color = DECK,
		}, model)
	end

	-- Round lacquered pillars along the front and back of the deck, black-banded at the foot.
	for _, z in { front - 0.8, front - depth + 0.8 } do
		for x = -width / 2 + 1, width / 2 - 1, (width - 2) / 5 do
			EnvironmentProfile.post("Pillar", CFrame.new(x, deckTop, z), pillarHeight, 1.1, model, { band = 0.7 })
		end
	end

	-- Paper screens across the back, divided by dark timber.
	local back = front - depth + 1.4
	part({
		Name = "Shoji",
		Size = Vector3.new(width - 2, pillarHeight - 1, 0.3),
		CFrame = CFrame.new(0, deckTop + (pillarHeight - 1) / 2, back),
		Material = Enum.Material.SmoothPlastic,
		Color = Color3.fromRGB(236, 228, 210),
	}, model)
	for _, y in { 2.5, 5.5 } do
		part({
			Name = "ShojiRail",
			Size = Vector3.new(width - 2, 0.25, 0.4),
			CFrame = CFrame.new(0, deckTop + y, back + 0.05),
			Material = Enum.Material.Wood,
			Color = TIMBER,
			CastShadow = false,
			CanQuery = false,
		}, model)
	end
	for x = -width / 2 + 4, width / 2 - 4, 4 do
		part({
			Name = "ShojiStile",
			Size = Vector3.new(0.25, pillarHeight - 1, 0.4),
			CFrame = CFrame.new(x, deckTop + (pillarHeight - 1) / 2, back + 0.05),
			Material = Enum.Material.Wood,
			Color = TIMBER,
			CastShadow = false,
			CanQuery = false,
		}, model)
	end

	-- Roof: a lintel, two broad sloped slabs with deep eaves, and a ridge beam.
	local eave = deckTop + pillarHeight
	part({
		Name = "Lintel",
		Size = Vector3.new(width + 1, 1, depth),
		CFrame = center * CFrame.new(0, eave + 0.5, 0),
		Material = Enum.Material.Wood,
		Color = TIMBER,
	}, model)
	local slope = math.rad(28)
	local run = depth / 2 + 3
	for _, side in { -1, 1 } do
		part({
			Name = "Roof",
			Size = Vector3.new(width + 6, 0.9, run / math.cos(slope)),
			CFrame = center
				* CFrame.new(0, eave + 1 + math.tan(slope) * run / 2, side * run / 2)
				* CFrame.Angles(side * slope, 0, 0), -- outer edge down at the eave
			Material = Enum.Material.ClayRoofTiles,
			Color = ROOF,
		}, model)
	end
	part({
		Name = "Ridge",
		Size = Vector3.new(width + 6, 1.2, 1.4),
		CFrame = center * CFrame.new(0, eave + 1.4 + math.tan(slope) * run, 0),
		Material = Enum.Material.Slate,
		Color = ROOF,
	}, model)

	-- Plaster gable ends close the triangle under each end of the roof. Each is two
	-- wedges whose high edges meet under the ridge.
	local gableRise = math.tan(slope) * run - 0.3
	for _, x in { -width / 2 - 0.2, width / 2 + 0.2 } do
		for _, side in { -1, 1 } do
			local wedge = Instance.new("WedgePart")
			wedge.Name = "Gable"
			wedge.Anchored = true
			wedge.CanTouch = false
			wedge.CanQuery = false
			wedge.Material = Enum.Material.Plaster
			wedge.Color = PLASTER
			wedge.Size = Vector3.new(0.5, gableRise, run)
			-- A wedge's tall edge is at its +Z end, so face that end toward the ridge.
			wedge.CFrame = center
				* CFrame.new(x, eave + 1 + gableRise / 2, side * run / 2)
				* CFrame.Angles(0, if side > 0 then math.pi else 0, 0)
			wedge.Parent = model
		end
	end

	-- Two paper lanterns under the eaves, the only lights on the building.
	for _, x in { -10, 10 } do
		local lantern = part({
			Name = "PaperLantern",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(1.8, 1.4, 1.4),
			CFrame = CFrame.new(x, eave - 1.6, front + 0.2) * CFrame.Angles(0, 0, math.rad(90)),
			Material = Enum.Material.Neon,
			Color = Color3.fromRGB(214, 96, 52),
			CastShadow = false,
			CanCollide = false,
			CanQuery = false,
		}, model)
		local light = Instance.new("PointLight")
		light.Color = Color3.fromRGB(255, 160, 90)
		light.Range = 18
		light.Brightness = 1.2
		light.Shadows = false
		light.Parent = lantern
	end

	model.Parent = parent
end

-- The duelling circle: pale sand inside a flagstone kerb, a step lighter than the courtyard,
-- so dark-clad fighters read clearly against the ground where most fights happen. Parts, not terrain, because terrain
-- voxels are 4 studs and can't hold a crisp edge. About thirty parts.
local function duelCircle(parent: Instance)
	part({
		Name = "DuelSand",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.3, DUEL_RADIUS * 2, DUEL_RADIUS * 2),
		CFrame = CFrame.new(0, FLOOR_Y, 0) * CFrame.Angles(0, 0, math.rad(90)),
		Material = Enum.Material.Sand,
		Color = Palette.Sand,
		CastShadow = false,
	}, parent)
	local stones = 36
	local kerbRadius = DUEL_RADIUS + 0.7
	local stoneLength = 2 * math.pi * kerbRadius / stones + 0.15
	for i = 1, stones do
		local angle = (i / stones) * math.pi * 2
		local position = Vector3.new(math.cos(angle) * kerbRadius, FLOOR_Y + 0.1, math.sin(angle) * kerbRadius)
		part({
			Name = "Kerb",
			Size = Vector3.new(stoneLength, 0.45, 1.4),
			-- Each stone's long side runs along the circle; slight colour jitter between stones.
			CFrame = CFrame.lookAt(position, Vector3.new(0, position.Y, 0)),
			Material = Enum.Material.Slate,
			Color = Palette.Flagstone:Lerp(Palette.Stone, (i * 7 % 5) / 8),
			CastShadow = false,
		}, parent)
	end
end

-- Tall crimson nobori banners along the east and west walls, each with a brushed 刃.
-- One part for the pole, one for the cloth and one SurfaceGui each.
local function banners(parent: Instance)
	local inset = ARENA.WallHalfExtent - WALL_THICKNESS / 2 - 2.2
	for _, side in { -1, 1 } do
		for _, z in { -46, -15, 15, 46 } do
			local base = Vector3.new(side * inset, FLOOR_Y - 0.5, z)
			local inward = Vector3.new(-side, 0, 0)
			part({
				Name = "BannerPole",
				Shape = Enum.PartType.Cylinder,
				Size = Vector3.new(15, 0.35, 0.35),
				CFrame = CFrame.new(base + Vector3.new(0, 7.5, 0)) * CFrame.Angles(0, 0, math.rad(90)),
				Material = Enum.Material.Wood,
				Color = TIMBER,
				CanCollide = false,
				CanQuery = false,
			}, parent)
			part({
				Name = "BannerBar",
				Size = Vector3.new(0.2, 0.2, 2.6),
				CFrame = CFrame.new(base + Vector3.new(0, 14.2, 0) + inward * 0.25),
				Material = Enum.Material.Wood,
				Color = TIMBER,
				CastShadow = false,
				CanCollide = false,
				CanQuery = false,
			}, parent)
			local center = base + Vector3.new(0, 10, 0) + inward * 0.3
			local cloth = part({
				Name = "Banner",
				Size = Vector3.new(2.4, 8.4, 0.08),
				CFrame = CFrame.lookAt(center, center + inward), -- front face toward the courtyard
				Material = Enum.Material.Fabric,
				Color = Palette.Crimson,
				CanCollide = false,
				CanQuery = false,
			}, parent)
			local gui = Instance.new("SurfaceGui")
			gui.Face = Enum.NormalId.Front
			gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
			gui.PixelsPerStud = 40
			gui.LightInfluence = 1
			gui.Parent = cloth
			local mark = Instance.new("TextLabel")
			mark.BackgroundTransparency = 1
			mark.Size = UDim2.fromScale(1, 0.5)
			mark.Position = UDim2.fromScale(0, 0.12)
			mark.Text = "刃"
			mark.TextScaled = true
			mark.Font = Enum.Font.Garamond
			mark.TextColor3 = Palette.Parchment
			mark.Parent = gui
		end
	end
end

-- Two iron braziers at the foot of the shrine steps: warm firelight in the middle distance.
local function braziers(parent: Instance)
	local front = -ARENA.WallHalfExtent + WALL_THICKNESS / 2 + 14
	for _, x in { -9.5, 9.5 } do
		local base = Vector3.new(x, FLOOR_Y - 0.3, front + 6)
		part({
			Name = "BrazierStand",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(2.6, 1.2, 1.2),
			CFrame = CFrame.new(base + Vector3.new(0, 1.3, 0)) * CFrame.Angles(0, 0, math.rad(90)),
			Material = Enum.Material.Slate,
			Color = STONE,
		}, parent)
		local bowl = part({
			Name = "BrazierBowl",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(0.9, 3, 3),
			CFrame = CFrame.new(base + Vector3.new(0, 3, 0)) * CFrame.Angles(0, 0, math.rad(90)),
			Material = Enum.Material.CorrodedMetal,
			Color = Color3.fromRGB(46, 40, 38),
		}, parent)
		local coals = part({
			Name = "Coals",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(0.2, 2.5, 2.5),
			CFrame = CFrame.new(base + Vector3.new(0, 3.42, 0)) * CFrame.Angles(0, 0, math.rad(90)),
			Material = Enum.Material.Neon,
			Color = Color3.fromRGB(255, 96, 34),
			CastShadow = false,
			CanCollide = false,
			CanQuery = false,
		}, parent)
		local fire = Instance.new("Fire")
		fire.Size = 4
		fire.Heat = 7
		fire.Color = Palette.Ember
		fire.SecondaryColor = Color3.fromRGB(190, 40, 20)
		fire.Parent = coals
		local light = Instance.new("PointLight")
		light.Color = Palette.Ember
		light.Range = 16
		light.Brightness = 1.6
		light.Shadows = false
		light.Parent = bowl
	end
end

-- Maple leaves drifting down over the courtyard on the evening wind. One emitter; the
-- particles are simulated on each client.
local function fallingLeaves(parent: Instance)
	local sky = part({
		Name = "LeafEmitter",
		Size = Vector3.new(ARENA.WallHalfExtent * 2, 1, ARENA.WallHalfExtent * 2),
		CFrame = CFrame.new(-10, 34, -10),
		Transparency = 1,
		CanCollide = false,
		CanQuery = false,
		CastShadow = false,
	}, parent)
	local leaves = Instance.new("ParticleEmitter")
	leaves.Texture = "rbxassetid://241386641"
	leaves.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(196, 56, 30)),
		ColorSequenceKeypoint.new(0.5, Color3.fromRGB(214, 112, 40)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(150, 40, 28)),
	})
	leaves.Size = NumberSequence.new(0.35, 0.45)
	leaves.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.08, 0),
		NumberSequenceKeypoint.new(0.85, 0),
		NumberSequenceKeypoint.new(1, 1),
	})
	leaves.EmissionDirection = Enum.NormalId.Bottom
	leaves.Rate = 14
	leaves.Lifetime = NumberRange.new(9, 13)
	leaves.Speed = NumberRange.new(1.5, 3)
	leaves.SpreadAngle = Vector2.new(30, 30)
	leaves.Acceleration = Vector3.new(1.4, -0.9, 0.8)
	leaves.Drag = 0.4
	leaves.Rotation = NumberRange.new(0, 360)
	leaves.RotSpeed = NumberRange.new(-120, 120)
	leaves.LightInfluence = 1
	leaves.Parent = sky
end

-- A few weathered boulders in the courtyard: cover to break line-of-sight in the ring.
-- Low and wide (about chest high, 8 studs across), so the camera sees over them instead of
-- pulling in behind a wall. Stone balls sunk into the sand, a big one and a smaller one leaning
-- on it: a small terrain ball comes out of the 4-stud voxels as a cone, not a rounded stone.
-- Sandstone tinted Palette.Rock (terrain rock reads lilac and mossy on the pale sand).
local BOULDERS = {
	-- centre on the floor, diameter of the main stone, bearing of the smaller one (degrees)
	{ Vector3.new(-34, FLOOR_Y, 22), 8.4, 30 },
	{ Vector3.new(38, FLOOR_Y, -18), 8.6, 200 },
	{ Vector3.new(12, FLOOR_Y, 40), 7.6, 110 },
	{ Vector3.new(-26, FLOOR_Y, -38), 8, 290 },
}
local function boulders(parent: Instance)
	for i, spec in BOULDERS do
		local base, size, bearing = spec[1], spec[2], math.rad(spec[3])
		local side = Vector3.new(math.cos(bearing), 0, math.sin(bearing))
		-- (offset from the main stone's foot, diameter, depth sunk below the floor as a share of it)
		for j, stone in { { Vector3.zero, size, 0.53 }, { side * size * 0.5, size * 0.62, 0.55 } } do
			local d = stone[2]
			part({
				Name = "Boulder",
				Shape = Enum.PartType.Ball,
				Size = Vector3.one * d,
				CFrame = CFrame.new(base + stone[1] + Vector3.new(0, d * (0.5 - stone[3]), 0))
					* CFrame.Angles(0, math.rad(i * 71 + j * 23), math.rad(j * 17)),
				Material = Enum.Material.Sandstone,
				Color = Palette.Rock,
			}, parent)
		end
	end
end

-- The hand-placed props in Workspace.Props were laid out on the old flat baseplate (top at
-- y = 0), but the terrain's walkable surface is at FLOOR_Y, so they stood 2 studs deep.
-- Stand each courtyard prop on the terrain actually under it. Distant set dressing (the
-- pagoda on its hill, the mountains) is left where it was placed.
local function seatProps()
	local props = workspace:FindFirstChild("Props")
	if not props then
		return
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { workspace.Terrain }
	for _, model in props:GetDescendants() do
		-- Whole props only: a model nested inside another moves with its parent.
		local whole = model:IsA("Model") and (model.Parent == props or (model.Parent :: Instance):IsA("Folder"))
		if not whole or model.Name == "Pagoda" or model:FindFirstAncestor("Mountains") then
			continue
		end
		local pivot = model:GetPivot().Position
		if math.max(math.abs(pivot.X), math.abs(pivot.Z)) > ARENA.WallHalfExtent + 60 then
			continue
		end
		local box, size = model:GetBoundingBox()
		local hit = workspace:Raycast(
			Vector3.new(box.Position.X, box.Position.Y + size.Y / 2 + 4, box.Position.Z),
			Vector3.new(0, -(size.Y + 20), 0),
			params
		)
		if hit then
			-- Trees sink half a stud so a trunk never shows a seam at its foot.
			local sink = if model:FindFirstAncestor("Trees") then 0.5 else 0.05
			local bottom = box.Position.Y - size.Y / 2
			model:PivotTo(model:GetPivot() + Vector3.new(0, hit.Position.Y - sink - bottom, 0))
		end
		if model.Name == "Torii" then
			Torii.openGate(model) -- the flagstone path runs through it to the gate
		end
	end
end

function MapBuilder.build()
	terrain()
	EnvironmentProfile.dressProps()
	task.wait() -- terrain filled this frame isn't hit by raycasts until the next
	seatProps()

	-- Safe to re-run (e.g. once in edit mode for layout): replace any earlier build.
	local previous = workspace:FindFirstChild("Castle")
	if previous then
		previous:Destroy()
	end
	local map = Instance.new("Folder")
	map.Name = "Castle"
	walls(map)
	boulders(map)
	shrine(map)
	duelCircle(map)
	banners(map)
	braziers(map)
	fallingLeaves(map)

	-- Players spawn in the lobby (LobbyBuilder) and are placed into the arena for a match.
	map.Parent = workspace

	-- Disable spawn protection on any spawn that came with the place template too.
	for _, descendant in workspace:GetDescendants() do
		if descendant:IsA("SpawnLocation") then
			descendant.Duration = 0
		end
	end
	local baseplate = workspace:FindFirstChild("Baseplate")
	if baseplate then
		baseplate:Destroy()
	end
end

return MapBuilder
