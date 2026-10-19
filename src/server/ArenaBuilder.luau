--!strict
-- Builds the greybox dueling ground at runtime so the place file stays empty.
-- Replace with a real map once the combat loop passes its playtest gate.

local Lighting = game:GetService("Lighting")

local FLOOR_SIZE = 260
local PILLAR_RING_RADIUS = 70
local PILLAR_COUNT = 12

local ArenaBuilder = {}

local function part(props: { [string]: any }): Part
	local p = Instance.new("Part")
	p.Anchored = true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	for key, value in props do
		(p :: any)[key] = value
	end
	return p
end

function ArenaBuilder.build()
	local arena = Instance.new("Folder")
	arena.Name = "Arena"

	part({
		Name = "Floor",
		Size = Vector3.new(FLOOR_SIZE, 4, FLOOR_SIZE),
		CFrame = CFrame.new(0, -1.5, 0), -- top surface at y = 0.5, clear of a template Baseplate
		Material = Enum.Material.Slate,
		Color = Color3.fromRGB(86, 80, 72),
		Parent = arena,
	})

	for i = 1, PILLAR_COUNT do
		local angle = (i / PILLAR_COUNT) * math.pi * 2
		local position = Vector3.new(math.cos(angle) * PILLAR_RING_RADIUS, 8.5, math.sin(angle) * PILLAR_RING_RADIUS)
		part({
			Name = "Pillar",
			Size = Vector3.new(3, 16, 3),
			CFrame = CFrame.new(position),
			Material = Enum.Material.Wood,
			Color = Color3.fromRGB(150, 38, 30),
			Parent = arena,
		})
	end

	local spawn = Instance.new("SpawnLocation")
	spawn.Name = "PlayerSpawn"
	spawn.Anchored = true
	spawn.Neutral = true
	spawn.Size = Vector3.new(10, 0.2, 10)
	spawn.CFrame = CFrame.new(0, 0.6, 38) -- a flat stone plate just above the floor
	spawn.Material = Enum.Material.Slate
	spawn.Color = Color3.fromRGB(64, 58, 52)
	local decal = spawn:FindFirstChildOfClass("Decal")
	if decal then
		decal:Destroy()
	end
	spawn.Parent = arena

	arena.Parent = workspace

	-- A ForceField blocks Humanoid:TakeDamage, so spawn protection would make fresh
	-- spawns invulnerable to deathblows. Turn it off on every spawn, including any
	-- that came with the place template.
	for _, descendant in workspace:GetDescendants() do
		if descendant:IsA("SpawnLocation") then
			descendant.Duration = 0
		end
	end

	Lighting.ClockTime = 17.3
	Lighting.Brightness = 2
	if not Lighting:FindFirstChildOfClass("Atmosphere") then
		local atmosphere = Instance.new("Atmosphere")
		atmosphere.Density = 0.35
		atmosphere.Color = Color3.fromRGB(230, 190, 150)
		atmosphere.Decay = Color3.fromRGB(120, 80, 70)
		atmosphere.Parent = Lighting
	end
end

return ArenaBuilder
