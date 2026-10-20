--!strict
-- Dresses the ronin bots so they read as one faction and a clear silhouette across the
-- courtyard: a woven kasa, a dark gi and hakama in one of a few muted colourways, and a
-- crimson sash. Three extra parts per bot, welded, massless and invisible to queries.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Assets = require(ReplicatedStorage.Shared.Assets)
local Palette = require(ReplicatedStorage.Shared.Palette)

local SKIN = Color3.fromRGB(226, 178, 140)
local KASA_WIDTH = 3.1

-- { gi (torso and sleeves), hakama (legs) }
local COLOURWAYS: { { Color3 } } = {
	{ Color3.fromRGB(44, 40, 42), Color3.fromRGB(28, 27, 32) }, -- charcoal
	{ Color3.fromRGB(40, 46, 68), Color3.fromRGB(26, 28, 38) }, -- indigo
	{ Color3.fromRGB(84, 66, 52), Color3.fromRGB(42, 36, 32) }, -- ash brown
	{ Color3.fromRGB(70, 30, 30), Color3.fromRGB(32, 26, 28) }, -- oxblood
}

local Outfit = {}

local function wear(model: Model, bodyPart: string, props: { [string]: any }, offset: CFrame): BasePart?
	local anchor = model:FindFirstChild(bodyPart)
	if not anchor or not anchor:IsA("BasePart") then
		return nil
	end
	local piece = Instance.new("Part")
	piece.CanCollide = false
	piece.CanQuery = false
	piece.CanTouch = false
	piece.Massless = true
	piece.TopSurface = Enum.SurfaceType.Smooth
	piece.BottomSurface = Enum.SurfaceType.Smooth
	for key, value in props do
		(piece :: any)[key] = value
	end
	piece.CFrame = anchor.CFrame * offset
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = anchor
	weld.Part1 = piece
	weld.Parent = piece
	piece.Parent = model
	return piece
end

-- Body colours go on the description before the rig is built.
function Outfit.describe(description: HumanoidDescription, index: number)
	local colours = COLOURWAYS[(index - 1) % #COLOURWAYS + 1]
	description.HeadColor = SKIN
	description.TorsoColor = colours[1]
	description.LeftArmColor = colours[1]
	description.RightArmColor = colours[1]
	description.LeftLegColor = colours[2]
	description.RightLegColor = colours[2]
end

-- Hat and sash go on the built rig.
function Outfit.dress(model: Model)
	local lower = model:FindFirstChild("LowerTorso")
	if lower and lower:IsA("BasePart") then
		wear(model, "LowerTorso", {
			Name = "Sash",
			Size = Vector3.new(lower.Size.X + 0.08, 0.34, lower.Size.Z + 0.1),
			Material = Enum.Material.Fabric,
			Color = Palette.Crimson,
			CastShadow = false,
		}, CFrame.new(0, lower.Size.Y / 2 - 0.12, 0))
	end

	local head = model:FindFirstChild("Head")
	if head and head:IsA("BasePart") then
		local kasa = Assets.Kasa
		local scale = KASA_WIDTH / kasa.NativeSize.X
		local hat = wear(model, "Head", {
			Name = "Kasa",
			Size = kasa.NativeSize * scale,
			Transparency = 0,
		}, CFrame.new(0, head.Size.Y / 2 + kasa.NativeSize.Y * scale * 0.32, 0) * CFrame.Angles(math.rad(-6), 0, 0))
		if hat then
			local mesh = Instance.new("SpecialMesh")
			mesh.MeshType = Enum.MeshType.FileMesh
			mesh.MeshId = kasa.MeshId
			mesh.TextureId = kasa.TextureId
			mesh.Scale = Vector3.one * scale
			mesh.VertexColor = Vector3.new(0.9, 0.82, 0.72) -- weathered, a little darker than the raw texture
			mesh.Parent = hat
		end
	end
end

return Outfit
