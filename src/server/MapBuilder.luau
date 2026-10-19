--!strict
-- Builds the Ashina-style castle courtyard: terrain (packed-earth courtyard, autumn
-- grass, rock cliffs on the horizon) and the castle walls around the fighting area.
-- Hand-placed props (torii, lanterns, trees, pagoda) live in Workspace.Props in the
-- place file. Lighting and post-processing are set in default.project.json.
--
-- Performance: terrain is one cheap voxel mesh; walls are a few large anchored parts
-- per segment, with shadows only on the big shapes and no queries or touches on trim.

local Config = require(game:GetService("ReplicatedStorage").Shared.Config)

local ARENA = Config.Arena
local WALL_HEIGHT = 9
local WALL_THICKNESS = 2.4
local SEGMENT_LENGTH = 24
local GATE_WIDTH = 22 -- opening in the south wall, framed by the torii outside

local PLASTER = Color3.fromRGB(226, 220, 205)
local TIMBER = Color3.fromRGB(46, 34, 28)
local STONE = Color3.fromRGB(92, 88, 82)
local ROOF = Color3.fromRGB(52, 54, 58)

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

	t:SetMaterialColor(Enum.Material.Grass, Color3.fromRGB(118, 112, 62))
	t:SetMaterialColor(Enum.Material.Ground, Color3.fromRGB(104, 88, 70))
	t:SetMaterialColor(Enum.Material.Mud, Color3.fromRGB(84, 70, 58))
	t:SetMaterialColor(Enum.Material.Rock, Color3.fromRGB(88, 86, 84))
	t:SetMaterialColor(Enum.Material.Slate, Color3.fromRGB(120, 114, 104))

	local random = Random.new(7) -- fixed seed: the same map on every server

	-- Base land, top surface at y = 0.
	t:FillBlock(CFrame.new(0, -8, 0), Vector3.new(1024, 16, 1024), Enum.Material.Grass)
	-- Packed-earth courtyard inside the walls, scuffed with darker worn patches.
	local inner = ARENA.WallHalfExtent * 2 - 4
	t:FillBlock(CFrame.new(0, -1, 0), Vector3.new(inner, 2, inner), Enum.Material.Ground)
	for _ = 1, 14 do
		-- Flat discs that only replace the top layer, so the ground stays level.
		local spot = CFrame.new(random:NextNumber(-50, 50), -0.5, random:NextNumber(-50, 50))
		t:FillCylinder(spot, 1, random:NextNumber(5, 11), Enum.Material.Mud)
	end
	-- Flagstone path from the torii, through the gate, to the centre of the courtyard.
	t:FillBlock(
		CFrame.new(0, -0.9, ARENA.WallHalfExtent / 2 + 20),
		Vector3.new(9, 2, ARENA.WallHalfExtent + 60),
		Enum.Material.Slate
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
				* CFrame.Angles(math.rad(-side * 26), 0, 0),
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

function MapBuilder.build()
	terrain()

	-- Safe to re-run (e.g. once in edit mode for layout): replace any earlier build.
	local previous = workspace:FindFirstChild("Castle")
	if previous then
		previous:Destroy()
	end
	local map = Instance.new("Folder")
	map.Name = "Castle"
	walls(map)

	local spawn = Instance.new("SpawnLocation")
	spawn.Name = "PlayerSpawn"
	spawn.Anchored = true
	spawn.Neutral = true
	spawn.Duration = 0 -- a ForceField would block deathblows
	spawn.Size = Vector3.new(8, 0.2, 8)
	spawn.CFrame = CFrame.new(0, 0.1, ARENA.WallHalfExtent - 14)
	spawn.Transparency = 1
	spawn.CanCollide = false
	spawn.CanQuery = false
	spawn.Parent = map

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
