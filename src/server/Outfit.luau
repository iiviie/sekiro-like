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

---------------------------------------------------------------------------------------
-- Bosses (Shared/Bosses looks): their own colours, a taller frame and a headpiece that
-- reads at a distance (kasa, ears, horns or a mask).

type BossLook = {
	skin: Color3,
	gi: Color3,
	hakama: Color3,
	sash: Color3,
	headwear: string,
	ears: string?,
	earColor: Color3?,
	mask: Color3?,
	height: number,
}

function Outfit.describeBoss(description: HumanoidDescription, look: BossLook)
	description.HeadColor = look.skin
	description.TorsoColor = look.gi
	description.LeftArmColor = look.gi
	description.RightArmColor = look.gi
	description.LeftLegColor = look.hakama
	description.RightLegColor = look.hakama
	description.HeightScale = look.height
	description.WidthScale = 1 + (look.height - 1) * 0.8
	description.DepthScale = 1 + (look.height - 1) * 0.6
	description.HeadScale = 1 + (look.height - 1) * 0.5
end

local function ear(model: Model, head: BasePart, side: number, look: BossLook)
	local kind = look.ears or "Rabbit"
	local color = look.earColor or look.skin
	local size = if kind == "Rabbit" then Vector3.new(0.32, 1.5, 0.16) else Vector3.new(0.42, 0.5, 0.18)
	local tilt = if kind == "Rabbit" then math.rad(side * 12) else math.rad(side * 18)
	local piece = wear(
		model,
		"Head",
		{
			Name = "Ear",
			Size = size,
			Color = color,
			Material = Enum.Material.SmoothPlastic,
			CastShadow = false,
		},
		CFrame.new(side * head.Size.X * 0.28, head.Size.Y / 2 + size.Y * 0.42, 0)
			* CFrame.Angles(math.rad(-8), 0, -tilt)
	)
	if piece and kind ~= "Rabbit" then
		local mesh = Instance.new("SpecialMesh")
		mesh.MeshType = Enum.MeshType.Wedge
		mesh.Parent = piece
	end
end

function Outfit.dressBoss(model: Model, look: BossLook)
	local lower = model:FindFirstChild("LowerTorso")
	if lower and lower:IsA("BasePart") then
		wear(model, "LowerTorso", {
			Name = "Sash",
			Size = Vector3.new(lower.Size.X + 0.08, 0.34, lower.Size.Z + 0.1),
			Material = Enum.Material.Fabric,
			Color = look.sash,
			CastShadow = false,
		}, CFrame.new(0, lower.Size.Y / 2 - 0.12, 0))
	end
	local head = model:FindFirstChild("Head")
	if not head or not head:IsA("BasePart") then
		return
	end
	local headwear = look.headwear
	if headwear == "Kasa" then
		local kasa = Assets.Kasa
		local scale = KASA_WIDTH * look.height / kasa.NativeSize.X
		local hat = wear(model, "Head", {
			Name = "Kasa",
			Size = kasa.NativeSize * scale,
		}, CFrame.new(0, head.Size.Y / 2 + kasa.NativeSize.Y * scale * 0.32, 0) * CFrame.Angles(math.rad(-6), 0, 0))
		if hat then
			local mesh = Instance.new("SpecialMesh")
			mesh.MeshType = Enum.MeshType.FileMesh
			mesh.MeshId = kasa.MeshId
			mesh.TextureId = kasa.TextureId
			mesh.Scale = Vector3.one * scale
			mesh.VertexColor = Vector3.new(0.75, 0.72, 0.7)
			mesh.Parent = hat
		end
	elseif headwear == "Ears" then
		ear(model, head, -1, look)
		ear(model, head, 1, look)
	elseif headwear == "Horns" then
		for _, side in { -1, 1 } do
			local horn = wear(
				model,
				"Head",
				{
					Name = "Horn",
					Size = Vector3.new(0.22, 0.7, 0.22),
					Color = Color3.fromRGB(236, 224, 196),
					Material = Enum.Material.SmoothPlastic,
					CastShadow = false,
				},
				CFrame.new(side * head.Size.X * 0.25, head.Size.Y / 2 + 0.22, -0.1)
					* CFrame.Angles(math.rad(-15), 0, math.rad(-side * 20))
			)
			if horn then
				local mesh = Instance.new("SpecialMesh")
				mesh.MeshType = Enum.MeshType.FileMesh
				mesh.MeshId = "rbxassetid://1033714" -- Roblox's stock cone
				mesh.Scale = Vector3.new(0.22, 0.7, 0.22)
				mesh.Parent = horn
			end
		end
	elseif headwear == "Mask" then
		-- A noh mask over the face; BossService knocks it off in phase 2.
		wear(model, "Head", {
			Name = "Mask",
			Size = Vector3.new(head.Size.X * 0.82, head.Size.Y * 0.9, 0.16),
			Color = look.mask or Color3.fromRGB(246, 240, 232),
			Material = Enum.Material.SmoothPlastic,
			CastShadow = false,
		}, CFrame.new(0, 0, -head.Size.Z / 2 - 0.04))
	end
end

return Outfit
