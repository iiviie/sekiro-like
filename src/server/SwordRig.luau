--!strict
-- Puts a fighter's weapon (Shared/Weapons) in its right hand. Meshes are built from code
-- with a SpecialMesh, so the place file doesn't need to carry them. Body motion comes from client/Animator, so the grip is fixed.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Players = game:GetService("Players")

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

	local swing = Instance.new("Trail")
	swing.Attachment0 = from
	swing.Attachment1 = to
	-- A soft white smear that fans out behind the cut (Dueling Grounds' look): it lingers a
	-- little and fades, so the eye reads the whole arc of a 70 ms strike.
	swing.Lifetime = 0.22
	swing.MinLength = 0.02
	swing.LightEmission = 0.6
	swing.LightInfluence = 0.15
	swing.Color = ColorSequence.new(Color3.fromRGB(255, 255, 255), Color3.fromRGB(205, 220, 255))
	swing.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.3),
		NumberSequenceKeypoint.new(0.4, 0.55),
		NumberSequenceKeypoint.new(1, 1),
	})
	swing.WidthScale = NumberSequence.new(1, 0.3)
	swing.FaceCamera = false
	swing.Enabled = false -- client/Animator switches it on during strikes
	swing.Parent = sword
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

	local mesh = Instance.new("SpecialMesh")
	mesh.MeshType = Enum.MeshType.FileMesh
	mesh.MeshId = look.MeshId
	mesh.TextureId = look.TextureId
	mesh.Scale = look.Scale
	mesh.Parent = sword

	trail(sword, look)

	-- A thin ink outline keeps the blade's silhouette the same width on screen at any
	-- distance or lighting, the cheapest way to make a sword read in third person.
	local outline = Instance.new("Highlight")
	outline.Name = "BladeOutline"
	outline.Adornee = sword
	outline.FillColor = Color3.fromRGB(235, 240, 255)
	outline.FillTransparency = 0.8
	outline.OutlineColor = Color3.fromRGB(20, 18, 22)
	outline.OutlineTransparency = 0.15
	outline.DepthMode = Enum.HighlightDepthMode.Occluded
	outline.Parent = sword

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

-- Dresses the blade in a skin (Shared/Progression.Skins): the model's "Skin" attribute,
-- else its player's equipped skin. The client reads the same attribute for trail colours.
function SwordRig.applySkin(model: Model, skinId: string?)
	local sword = model:FindFirstChild("Sword")
	if not sword or not sword:IsA("BasePart") then
		return
	end
	local player = Players:GetPlayerFromCharacter(model)
	local chosen = skinId or (player and player:GetAttribute("Skin")) or model:GetAttribute("Skin")
	local skin = Progression.skin(if typeof(chosen) == "string" then chosen else nil)
	model:SetAttribute("Skin", skin.id)

	local mesh = sword:FindFirstChildOfClass("SpecialMesh")
	if mesh then
		mesh.VertexColor = skin.tint
	end
	local outline = sword:FindFirstChild("BladeOutline")
	if outline and outline:IsA("Highlight") then
		outline.OutlineColor = skin.outline
		outline.FillColor = skin.fill
	end
	for _, name in { "SkinGlow", "SkinPetals" } do
		local old = sword:FindFirstChild(name)
		if old then
			old:Destroy()
		end
	end
	if skin.glow then
		local light = Instance.new("PointLight")
		light.Name = "SkinGlow"
		light.Color = skin.glow
		light.Range = 6
		light.Brightness = 1.2
		light.Shadows = false
		light.Parent = sword
	end
	local tip = sword:FindFirstChild("TrailEnd")
	if skin.petals and tip then
		local petals = Instance.new("ParticleEmitter")
		petals.Name = "SkinPetals"
		petals.Color = ColorSequence.new(skin.petals)
		petals.LightEmission = 0.3
		petals.Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.18),
			NumberSequenceKeypoint.new(1, 0.05),
		})
		petals.Transparency = NumberSequence.new(0.1, 1)
		petals.Lifetime = NumberRange.new(0.8, 1.4)
		petals.Rate = 6
		petals.Speed = NumberRange.new(0.5, 1.5)
		petals.SpreadAngle = Vector2.new(180, 180)
		petals.Acceleration = Vector3.new(0, -2, 0)
		petals.Rotation = NumberRange.new(0, 360)
		petals.RotSpeed = NumberRange.new(-120, 120)
		petals.Parent = tip
	end
end

return SwordRig
