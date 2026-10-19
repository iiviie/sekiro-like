--!strict
-- Puts the katana in a character's right hand. The mesh comes from the Creator Store
-- (see Shared/Assets) and is built from code with a SpecialMesh, so the place file
-- doesn't need to carry it. Body motion comes from client/Animator, so the grip is fixed.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Assets = require(ReplicatedStorage.Shared.Assets)

local KATANA = Assets.Katana

local SwordRig = {}

local function trail(sword: BasePart)
	local from = Instance.new("Attachment")
	from.Name = "TrailStart"
	from.Position = Vector3.new(0, 0, KATANA.GuardZ + 0.3)
	from.Parent = sword

	local to = Instance.new("Attachment")
	to.Name = "TrailEnd"
	to.Position = Vector3.new(0, 0, KATANA.TipZ)
	to.Parent = sword

	local swing = Instance.new("Trail")
	swing.Attachment0 = from
	swing.Attachment1 = to
	swing.Lifetime = 0.14
	swing.MinLength = 0.05
	swing.LightEmission = 0.7
	swing.LightInfluence = 0
	swing.Color = ColorSequence.new(Color3.fromRGB(255, 255, 255), Color3.fromRGB(170, 200, 255))
	swing.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.25),
		NumberSequenceKeypoint.new(1, 1),
	})
	swing.WidthScale = NumberSequence.new(1)
	swing.Enabled = false -- client/Animator switches it on during strikes
	swing.Parent = sword
end

function SwordRig.attach(model: Model): BasePart?
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
	sword.Size = KATANA.Size
	sword.CanCollide = false
	sword.CanTouch = false
	sword.Massless = true

	local mesh = Instance.new("SpecialMesh")
	mesh.MeshType = Enum.MeshType.FileMesh
	mesh.MeshId = KATANA.MeshId
	mesh.TextureId = KATANA.TextureId
	mesh.Scale = Vector3.one * KATANA.Scale
	mesh.Parent = sword

	trail(sword)

	-- The fist closes around the handle with the blade pointing out of the front of the
	-- hand, edge down, so arm poses aim the blade.
	local weld = Instance.new("Weld")
	weld.Name = "SwordGrip"
	weld.Part0 = hand
	weld.Part1 = sword
	weld.C0 = CFrame.new(0, -0.15, 0) * CFrame.Angles(0, math.pi, 0)
	weld.C1 = CFrame.new(0, 0, KATANA.GripZ)
	weld.Parent = sword

	sword.Parent = model
	return sword
end

return SwordRig
