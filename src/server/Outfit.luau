--!strict
-- Dresses the ronin bots so they read as one faction and a clear silhouette across the
-- courtyard: a textured gi and hakama (classic Shirt and Pants from Shared/Clothing) in one
-- of several mid-tone colourways, a woven kasa and a welded obi. The extra parts are
-- welded, massless and invisible to queries. Bosses get their own set by id.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local Assets = require(ReplicatedStorage.Shared.Assets)
local Bosses = require(ReplicatedStorage.Shared.Bosses)
local Clothing = require(ReplicatedStorage.Shared.Clothing)
local Wear = require(ReplicatedStorage.Shared.Cosmetics.Wear)

local SKIN = Color3.fromRGB(226, 178, 140)
local KASA_WIDTH = 3.1
-- The rig keeps the description describe() filled in; this attribute on it names the set.
local SET_ATTRIBUTE = "ClothingSet"

local Outfit = {}

-- The arms take the skin colour: the shirt leaves the hands and wrists transparent.
local function colourBody(description: HumanoidDescription, skin: Color3, set: Clothing.Set)
	description.HeadColor = skin
	description.LeftArmColor = skin
	description.RightArmColor = skin
	description.TorsoColor = set.gi
	description.LeftLegColor = set.hakama
	description.RightLegColor = set.hakama
end

local function setOf(model: Model): Clothing.Set?
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	local description = humanoid and humanoid:FindFirstChildOfClass("HumanoidDescription")
	return Clothing.get(description and description:GetAttribute(SET_ATTRIBUTE) :: string?)
end

local function clothe(model: Model, set: Clothing.Set)
	local shirt = Instance.new("Shirt")
	shirt.Name = "Gi"
	shirt.ShirtTemplate = set.shirt
	shirt.Parent = model
	local pants = Instance.new("Pants")
	pants.Name = "Hakama"
	pants.PantsTemplate = set.pants
	pants.Parent = model
end

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

-- The obi: a slim band over the painted one at the top of the LowerTorso, so the waist
-- keeps a little depth in silhouette. The hakama's ties and knot stay visible below it.
local function obi(model: Model, colour: Color3)
	local lower = model:FindFirstChild("LowerTorso")
	if lower and lower:IsA("BasePart") then
		local height = lower.Size.Y * 0.5
		local size = Vector3.new(lower.Size.X + 0.06, height, lower.Size.Z + 0.06)
		local band = wear(model, "LowerTorso", {
			Name = "Sash",
			Size = size,
			Material = Enum.Material.Fabric,
			Color = colour,
			CastShadow = false,
		}, CFrame.new(0, lower.Size.Y / 2 - height / 2 + 0.02, 0))
		-- Parenting a scaled rig (bosses) rescales loose parts by ~1.3 but not the body: hold
		-- the band to the LowerTorso it was fitted to.
		if band then
			band:GetPropertyChangedSignal("Size"):Connect(function()
				if band.Size ~= size then
					band.Size = size
				end
			end)
		end
	end
end

-- Body colours and the set go on the description before the rig is built.
function Outfit.describe(description: HumanoidDescription, index: number)
	local name = Clothing.Bots[(index - 1) % #Clothing.Bots + 1]
	description:SetAttribute(SET_ATTRIBUTE, name)
	colourBody(description, SKIN, Clothing.Sets[name])
end

-- Clothes, hat and obi go on the built rig.
function Outfit.dress(model: Model)
	local set = setOf(model) or Clothing.Sets[Clothing.Bots[1]]
	clothe(model, set)
	obi(model, set.obi)

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

-- The boss's set (Clothing.Boss) found by its look: BossService hands Outfit the def's look.
local function bossSet(look: BossLook): Clothing.Set?
	for id, def in Bosses.Defs :: { [string]: Bosses.BossDef } do
		if (def.look :: any) == look then
			return Clothing.get(Clothing.Boss[id])
		end
	end
	return nil
end

function Outfit.describeBoss(description: HumanoidDescription, look: BossLook)
	local set = bossSet(look)
	if set then
		colourBody(description, look.skin, set)
	else -- no set: the flat look colours
		description.HeadColor = look.skin
		description.TorsoColor = look.gi
		description.LeftArmColor = look.gi
		description.RightArmColor = look.gi
		description.LeftLegColor = look.hakama
		description.RightLegColor = look.hakama
	end
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
	local set = bossSet(look)
	if set then
		clothe(model, set)
	end
	obi(model, if set then set.obi else look.sash)
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

---------------------------------------------------------------------------------------
-- Players: the outfit they equipped (a Clothing set name; "Avatar" or nil = their own
-- clothes), worn over the avatar in the lobby and in matches (Shared/Cosmetics/Wear).
-- server/CosmeticService calls this whenever the character or the loadout changes.

local stash: Folder? = nil
local function stashFolder(): Folder
	if not stash then
		local folder = Instance.new("Folder")
		folder.Name = "OutfitStash" -- layered clothing set aside while a gi is worn
		folder.Parent = ServerStorage
		stash = folder
	end
	return stash :: Folder
end

function Outfit.wearPlayer(character: Model, set: string?)
	local name = if set and Clothing.get(set) then set else ""
	if Wear.current(character) == name then
		return
	end
	Wear.apply(character, name, stashFolder())
end

-- A piece of avatar clothing that arrived while an outfit is on (see Wear.cover).
function Outfit.cover(character: Model, child: Instance)
	Wear.cover(character, child, stashFolder())
end

-- Layered clothing set aside for a character that's gone is dropped with it.
function Outfit.forget(character: Model)
	if stash then
		for _, child in stash:GetChildren() do
			if child:GetAttribute("OutfitStashedFrom") == character.Name then
				child:Destroy()
			end
		end
	end
end

return Outfit
