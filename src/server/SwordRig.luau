--!strict
-- Puts a fighter's weapon (Shared/Weapons) in its right hand. Meshes are built from code
-- with a SpecialMesh, so the place file doesn't need to carry them. Body motion comes from client/Animator, so the grip is fixed.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Weapons = require(ReplicatedStorage.Shared.Weapons)

local SwordRig = {}

local function trail(sword: BasePart, look: Weapons.WeaponLook)
	local from = Instance.new("Attachment")
	from.Name = "TrailStart"
	from.Position = Vector3.new(0, 0, look.GuardZ + 0.3)
	from.Parent = sword

	local to = Instance.new("Attachment")
	to.Name = "TrailEnd"
	to.Position = Vector3.new(0, 0, look.TipZ)
	to.Parent = sword

	local swing = Instance.new("Trail")
	swing.Attachment0 = from
	swing.Attachment1 = to
	swing.Lifetime = 0.16
	swing.MinLength = 0.05
	swing.LightEmission = 0.8
	swing.LightInfluence = 0
	swing.Color = ColorSequence.new(Color3.fromRGB(255, 255, 255), Color3.fromRGB(170, 200, 255))
	swing.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.15),
		NumberSequenceKeypoint.new(1, 1),
	})
	-- Taper toward the tail so the arc reads as a cut, not a ribbon.
	swing.WidthScale = NumberSequence.new(1, 0.35)
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
	return sword
end

return SwordRig
