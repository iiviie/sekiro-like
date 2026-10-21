--!strict
-- Puts a fighter's weapon (Shared/Weapons) in its right hand. Meshes are built from code
-- with a SpecialMesh, so the place file doesn't need to carry them. Body motion comes from client/Animator, so the grip is fixed.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Players = game:GetService("Players")

local BladeLook = require(ReplicatedStorage.Shared.Cosmetics.BladeLook)
local Cosmetics = require(ReplicatedStorage.Shared.Cosmetics)
local Progression = require(ReplicatedStorage.Shared.Progression)
local Weapons = require(ReplicatedStorage.Shared.Weapons)

local SwordRig = {}

local function trail(sword: BasePart, look: Weapons.WeaponLook)
	local from = Instance.new("Attachment")
	from.Name = "TrailStart"
	from.Position = Vector3.new(0, 0, look.GuardZ + 0.15)
	from.Parent = sword

	local to = Instance.new("Attachment")
	to.Name = "TrailEnd"
	to.Position = Vector3.new(0, 0, look.TipZ)
	to.Parent = sword

	-- The cut itself is drawn by client/CombatVisuals as a crescent smear swept between these two
	-- attachments. This Trail stays invisible: client/Animator switches it on during strikes and
	-- tints it (steel, perilous red, the equipped skin), and the smear reads both from it.
	local swing = Instance.new("Trail")
	swing.Attachment0 = from
	swing.Attachment1 = to
	swing.Lifetime = 0.05
	swing.Color = ColorSequence.new(Color3.fromRGB(255, 255, 255), Color3.fromRGB(205, 220, 255))
	swing.Transparency = NumberSequence.new(1)
	swing.FaceCamera = false
	swing.Enabled = false
	swing.Parent = sword
end

-- A part welded to the sword (a fitting): no physics, no shadow, and it falls with the
-- blade when the dead let go of it.
local function fitting(sword: BasePart, name: string, size: Vector3, at: CFrame, color: Color3): BasePart
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.Color = color
	part.Material = Enum.Material.Metal
	part.CanCollide, part.CanQuery, part.CanTouch = false, false, false
	part.Massless = true
	part.CastShadow = false
	local weld = Instance.new("Weld")
	weld.Part0 = sword
	weld.Part1 = part
	weld.C0 = at
	weld.Parent = part
	part.Parent = sword
	return part
end

-- An oval disc (a cylinder mesh) facing along the blade.
local function disc(sword: BasePart, name: string, z: number, size: Vector3, color: Color3)
	local part = fitting(sword, name, Vector3.one, CFrame.new(0, 0, z) * CFrame.Angles(0, math.pi / 2, 0), color)
	local mesh = Instance.new("SpecialMesh")
	mesh.MeshType = Enum.MeshType.Cylinder
	mesh.Scale = Vector3.new(size.X, size.Z, size.Y) -- cylinder length, then its two diameters
	mesh.Parent = part
end

-- The mesh's own tsuba and handle are thin at Roblox scale; a bold iron tsuba with a gold rim,
-- a gold pommel cap and a bright line down the cutting edge (skin-coloured, see applySkin)
-- give the sword a silhouette and a glint at 30 studs.
local function fittings(sword: BasePart, look: Weapons.WeaponLook)
	local tsuba = look.Tsuba
	disc(sword, "Tsuba", look.TsubaZ, tsuba, Color3.fromRGB(34, 30, 30))
	disc(
		sword,
		"TsubaRim",
		look.TsubaZ,
		Vector3.new(tsuba.X * 0.5, tsuba.Y + 0.08, tsuba.Z + 0.08),
		Color3.fromRGB(200, 154, 64)
	)
	local cap = math.min(tsuba.Y, tsuba.Z) * 0.42
	disc(sword, "Kashira", look.PommelZ, Vector3.new(0.08, cap, cap * 1.3), Color3.fromRGB(200, 154, 64))

	local edge = look.Edge
	for i = 1, #edge - 1 do
		local a, b = edge[i], edge[i + 1]
		local line = fitting(
			sword,
			"Edge",
			Vector3.new(0.07, 0.06, (b - a).Magnitude + 0.03),
			CFrame.lookAt((a + b) / 2, b),
			Color3.new(1, 1, 1)
		)
		line.Material = Enum.Material.Neon
	end
end

function SwordRig.attach(model: Model, weaponId: string?): BasePart?
	local look = Weapons.get(weaponId).look
	local hand = model:FindFirstChild("RightHand") or model:FindFirstChild("Right Arm")
	if not hand or not hand:IsA("BasePart") then
		warn(`[SwordRig] {model.Name} has no right hand to hold a sword`)
		return nil
	end

	local existing = model:FindFirstChild("Sword")
	if existing then
		existing:Destroy()
	end

	local sword = Instance.new("Part")
	sword.Name = "Sword"
	sword.Size = look.Size
	sword.CanCollide = false
	sword.CanTouch = false
	sword.Massless = true
	sword.Reflectance = 0.2 -- catches the sky, so the steel reads bright in daylight

	local mesh = Instance.new("SpecialMesh")
	mesh.MeshType = Enum.MeshType.FileMesh
	mesh.MeshId = look.MeshId
	mesh.TextureId = look.TextureId
	mesh.Scale = look.Scale
	mesh.Parent = sword
	fittings(sword, look)

	trail(sword, look)

	-- A thin ink outline keeps the blade's silhouette the same width on screen at any
	-- distance or lighting. Each client draws it (client/BladeOutlines) on the few blades
	-- nearest its camera only: Highlights are capped at 31, and the perilous tell needs one.
	CollectionService:AddTag(sword, "BladeOutline")

	-- The fist closes around the handle with the blade pointing out of the front of the
	-- hand, edge down, so arm poses aim the blade.
	local weld = Instance.new("Weld")
	weld.Name = "SwordGrip"
	weld.Part0 = hand
	weld.Part1 = sword
	weld.C0 = CFrame.new(0, -0.15, 0) * CFrame.Angles(0, math.pi, 0)
	weld.C1 = CFrame.new(0, 0, look.GripZ)
	weld.Parent = sword

	sword.Parent = model
	SwordRig.applySkin(model)
	return sword
end

-- Dresses the blade in its look (Shared/Cosmetics: base skins, premium blade lines by level,
-- weapon Mastery evolutions). A player's comes from their Loadout / LineLevels / WeaponMastery;
-- a bot's from `skinId` or its "Skin" attribute (a Progression skin id). The look is published
-- on the model (BladeId, BladeLevel, BladeMastery, and Skin = its ref for older readers), which
-- is what client/CombatVisuals reads for the smear, deflect and finisher.
function SwordRig.applySkin(model: Model, skinId: string?)
	local sword = model:FindFirstChild("Sword")
	if not sword or not sword:IsA("BasePart") then
		return
	end
	local player = Players:GetPlayerFromCharacter(model)
	local id, level, mastery
	if player and not skinId then
		local weapon = model:GetAttribute("Weapon")
		id, level, mastery = Cosmetics.bladeOf(player, if typeof(weapon) == "string" then weapon else nil)
	else
		local chosen = skinId or model:GetAttribute("Skin")
		id, level, mastery = `skin.{Progression.skin(if typeof(chosen) == "string" then chosen else nil).id}`, 1, 0
	end
	local look = Cosmetics.Blades.look(id, level, mastery)
	model:SetAttribute("Skin", look.ref)
	model:SetAttribute("BladeId", look.id)
	model:SetAttribute("BladeLevel", look.level)
	model:SetAttribute("BladeMastery", mastery)
	BladeLook.apply(sword, look)
end

return SwordRig
