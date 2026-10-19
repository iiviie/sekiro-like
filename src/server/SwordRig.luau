--!strict
-- Welds a greybox katana to a character's right hand. Clients animate it by tweening
-- the grip weld's C0 locally (see client/CombatVisuals), so the server only places it.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local SwordPoses = require(ReplicatedStorage.Shared.SwordPoses)

local BLADE_LENGTH = 4.2
local HANDLE_OFFSET = 0.4 -- how far the blade's base sits below the palm

local SwordRig = {}

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
	sword.Size = Vector3.new(0.18, BLADE_LENGTH, 0.32)
	sword.Material = Enum.Material.Metal
	sword.Color = Config.Visual.SwordColor
	sword.CanCollide = false
	sword.CanTouch = false
	sword.Massless = true

	local weld = Instance.new("Weld")
	weld.Name = "SwordGrip"
	weld.Part0 = hand
	weld.Part1 = sword
	weld.C0 = SwordPoses.Rest
	weld.C1 = CFrame.new(0, -BLADE_LENGTH / 2 + HANDLE_OFFSET, 0)
	weld.Parent = sword

	sword.Parent = model
	return sword
end

return SwordRig
