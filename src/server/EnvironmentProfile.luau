--!strict
-- The daylight look of the world, applied in code at startup so it doesn't depend on the
-- place file: terrain material colours and water, a warm-stone / weathered-rock dressing for
-- the hand-placed props in Workspace.Props, and the round lacquered post used by the fences,
-- the dojo and the shrine hall. Only looks: nothing here moves, resizes or changes the
-- collision of anything that already exists.
--
-- MapBuilder applies it before anything is built (and before LobbyBuilder clones its
-- lanterns from Workspace.Props, so the clones inherit the dressing).

local Palette = require(game:GetService("ReplicatedStorage").Shared.Palette)

local EnvironmentProfile = {}

-- Terrain material colours. SetMaterialColor tints the material's own texture, so these
-- are mid values: calm ground for the fighting floors, fresh grass, warm rock.
EnvironmentProfile.Terrain = {
	[Enum.Material.Grass] = Palette.Grass,
	[Enum.Material.LeafyGrass] = Palette.Moss,
	[Enum.Material.Ground] = Palette.Earth,
	[Enum.Material.Rock] = Palette.Rock,
	[Enum.Material.Sandstone] = Palette.Rock, -- the courtyard's boulders
	[Enum.Material.Sand] = Palette.Paving, -- the fighting floors (LobbyBuilder FLOOR)
	[Enum.Material.Slate] = Palette.Flagstone,
	[Enum.Material.Cobblestone] = Palette.Flagstone,
}

EnvironmentProfile.Water = {
	WaterColor = Color3.fromRGB(58, 132, 140),
	WaterTransparency = 0.45,
	WaterReflectance = 0.6,
	WaterWaveSize = 0.08,
	WaterWaveSpeed = 6,
}

-- Hand-placed props, matched by model name: every part of the model takes this look.
local PROP_LOOKS: { [string]: { Material: Enum.Material, Color: Color3 } } = {
	Lantern = { Material = Enum.Material.Sandstone, Color = Palette.LanternStone },
	CornerLantern = { Material = Enum.Material.Sandstone, Color = Palette.LanternStone },
}
-- The backdrop mountains: warm weathered rock rather than flat dark grey.
local MOUNTAIN_COLOR = Color3.fromRGB(122, 114, 104)

function EnvironmentProfile.applyTerrain()
	local terrain = workspace.Terrain
	for material, color in EnvironmentProfile.Terrain do
		terrain:SetMaterialColor(material, color)
	end
	for key, value in EnvironmentProfile.Water do
		(terrain :: any)[key] = value
	end
end

local function dressModel(model: Instance, look: { Material: Enum.Material, Color: Color3 })
	for _, d in model:GetDescendants() do
		-- Invisible helpers (a lantern's light holder) stay as they are.
		if d:IsA("BasePart") and d.Transparency < 1 then
			if d:IsA("UnionOperation") then
				d.UsePartColor = true
			end
			d.Material = look.Material
			d.Color = look.Color
		end
	end
end

-- Restyle the hand-placed props in Workspace.Props (the place file stays untouched).
function EnvironmentProfile.dressProps()
	local props = workspace:FindFirstChild("Props")
	if not props then
		return
	end
	for _, d in props:GetDescendants() do
		local look = PROP_LOOKS[d.Name]
		if look and d:IsA("Model") then
			dressModel(d, look)
		end
	end
	local mountains = props:FindFirstChild("Mountains")
	if mountains then
		for _, mountain in mountains:GetChildren() do
			if mountain:IsA("BasePart") then
				mountain.Color = MOUNTAIN_COLOR
			end
		end
	end
end

-- A round lacquered post `height` tall and `width` across whose foot is at `foot`: a
-- vermilion cylinder with a black-lacquer cap and, if asked, a black band at the foot. The
-- post itself is a cylinder of the old square post's width and height, so it collides as
-- before; the trim is decoration (no collision, no queries, no shadow). Returns the post.
export type PostOptions = {
	castShadow: boolean?,
	band: number?, -- height of a black band above the foot (for posts on a deck)
}

local function trim(name: string, size: Vector3, at: CFrame, parent: Instance)
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Shape = Enum.PartType.Cylinder
	p.Size = size
	p.CFrame = at * CFrame.Angles(0, 0, math.rad(90))
	p.Material = Enum.Material.SmoothPlastic
	p.Reflectance = 0.04
	p.Color = Palette.Lacquer
	p.Parent = parent
end

function EnvironmentProfile.post(
	name: string,
	foot: CFrame,
	height: number,
	width: number,
	parent: Instance,
	options: PostOptions?
): Part
	local post = Instance.new("Part")
	post.Name = name
	post.Anchored = true
	post.CanTouch = false
	post.TopSurface = Enum.SurfaceType.Smooth
	post.BottomSurface = Enum.SurfaceType.Smooth
	post.Shape = Enum.PartType.Cylinder
	post.Size = Vector3.new(height, width, width)
	post.CFrame = foot * CFrame.new(0, height / 2, 0) * CFrame.Angles(0, 0, math.rad(90))
	post.Material = Enum.Material.SmoothPlastic
	post.Reflectance = 0.03
	post.Color = Palette.Vermilion
	if options and options.castShadow ~= nil then
		post.CastShadow = options.castShadow
	end
	local capHeight = math.max(width * 0.32, 0.25)
	trim(
		name .. "Cap",
		Vector3.new(capHeight, width * 1.3, width * 1.3),
		foot * CFrame.new(0, height + capHeight / 2 - 0.05, 0),
		parent
	)
	local band = options and options.band
	if band then
		trim(name .. "Band", Vector3.new(band, width * 1.12, width * 1.12), foot * CFrame.new(0, band / 2, 0), parent)
	end
	post.Parent = parent
	return post
end

return EnvironmentProfile
