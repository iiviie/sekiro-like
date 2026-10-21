--!strict
-- Locker / Store previews of the combat cosmetics, played for real but only on this client:
-- on your own character in the lobby, against a local practice rig (a copy of you) that
-- nobody else sees. Nothing is sent to the server and no gameplay state changes. Previews
-- override what Shared/Cosmetics reads with Preview* attributes on your character (local
-- attributes never replicate), and clear() puts back what you really own and wear.
--
--   CosmeticPreview.finisher("InkBrush")            -- you deathblow a rig with that finisher
--   CosmeticPreview.blade("line.Raijin", 3)          -- your sword wears it (level 1-4, opt. Mastery)
--   CosmeticPreview.swing()                          -- a three-cut string (shows the L2 smear)
--   CosmeticPreview.deflect(true)                    -- a rig cuts at you, you deflect (L3 spark)
--   CosmeticPreview.outfit("miko")                   -- wear a Clothing set ("Avatar" = your own)
--   CosmeticPreview.clear()                          -- back to your real loadout
--
-- Meant for the lobby (out of combat): the swings play your character's clips locally.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")

local Animator = require(script.Parent.Animator)
local CombatVisuals = require(script.Parent.CombatVisuals)
local BladeLook = require(ReplicatedStorage.Shared.Cosmetics.BladeLook)
local Blades = require(ReplicatedStorage.Shared.Cosmetics.Blades)
local Cosmetics = require(ReplicatedStorage.Shared.Cosmetics)
local Wear = require(ReplicatedStorage.Shared.Cosmetics.Wear)

local player = Players.LocalPlayer

local CosmeticPreview = {}

local RIG_DISTANCE = 6.5
local stash: Folder? = nil
local rig: Model? = nil

local function character(): Model?
	local model = player.Character
	if model and model:FindFirstChild("HumanoidRootPart") then
		return model
	end
	return nil
end

local function localStash(): Folder
	if not stash then
		local folder = Instance.new("Folder")
		folder.Name = "PreviewOutfitStash"
		folder.Parent = ReplicatedStorage
		stash = folder
	end
	return stash :: Folder
end

-- A local copy of your character standing `RIG_DISTANCE` studs in front of you, facing you.
function CosmeticPreview.rig(): Model?
	if rig and rig.Parent then
		return rig
	end
	local me = character()
	if not me then
		return nil
	end
	local archivable = me.Archivable
	me.Archivable = true
	local copy = me:Clone()
	me.Archivable = archivable
	if not copy then
		return nil
	end
	for _, d in copy:GetDescendants() do
		if d:IsA("LuaSourceContainer") or d:IsA("ForceField") then
			d:Destroy()
		end
	end
	for _, tag in CollectionService:GetTags(copy) do
		CollectionService:RemoveTag(copy, tag) -- not a fighter: no HUD bars, no lock-on
	end
	for _, name in { "PreviewBlade", "PreviewBladeLevel", "PreviewMastery", "PreviewFinisher" } do
		copy:SetAttribute(name, nil)
	end
	copy.Name = "PreviewRig"
	local humanoid = copy:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	end
	local root = copy:FindFirstChild("HumanoidRootPart") :: BasePart
	local mine = me:FindFirstChild("HumanoidRootPart") :: BasePart
	local flat = Vector3.new(mine.CFrame.LookVector.X, 0, mine.CFrame.LookVector.Z)
	flat = if flat.Magnitude > 1e-3 then flat.Unit else Vector3.zAxis
	local at = mine.Position + flat * RIG_DISTANCE
	root.Anchored = true
	copy:PivotTo(CFrame.lookAt(at, at - flat))
	copy.Parent = workspace
	CombatVisuals.watchPreview(copy)
	rig = copy
	return copy
end

-- Removes the practice rig.
function CosmeticPreview.dismiss()
	if rig then
		rig:Destroy()
		rig = nil
	end
end

-- You deathblow the practice rig with finisher `ref` (any Shared/Cosmetics.Finishers key).
-- The same clips, hitstop, shake, grade and camera punch as a real one.
function CosmeticPreview.finisher(ref: string)
	local me = character()
	local target = CosmeticPreview.rig()
	if not me or not target then
		return
	end
	task.delay(0.1, function()
		if target.Parent then
			CombatVisuals.previewDeathblow(me, target, ref)
		end
	end)
	task.delay(3, function()
		if rig == target then
			CosmeticPreview.dismiss()
		end
	end)
end

-- Dresses your sword in blade `id` ("skin.Jade", "line.Raijin") at line `level` and weapon
-- Mastery `mastery` (evolutions at 10 / 25 / 50), until clear().
function CosmeticPreview.blade(id: string, level: number?, mastery: number?)
	local me = character()
	local sword = me and me:FindFirstChild("Sword")
	if not me or not sword or not sword:IsA("BasePart") then
		return
	end
	me:SetAttribute("PreviewBlade", id)
	me:SetAttribute("PreviewBladeLevel", level or 1)
	me:SetAttribute("PreviewMastery", mastery or 0)
	BladeLook.apply(sword, Blades.look(id, level, mastery))
end

-- A three-cut string with whatever blade you hold (the smear, and a line's L2 extras).
function CosmeticPreview.swing()
	local me = character()
	if not me then
		return
	end
	task.spawn(function()
		for _, clip in { "Light1", "Light2", "Light3" } do
			Animator.play(me, clip, 0.28)
			task.wait(0.62)
		end
	end)
end

-- The practice rig cuts at you and you deflect it (a perfect deflect if `perfect`), showing
-- your blade's deflect spark and sound (a line's L3).
function CosmeticPreview.deflect(perfect: boolean?)
	local me = character()
	local target = CosmeticPreview.rig()
	if not me or not target then
		return
	end
	local windup = 0.35
	Animator.play(target, "Light1", windup)
	task.delay(windup, function()
		if target.Parent and me.Parent then
			CombatVisuals.previewDeflect(target, me, perfect == true)
		end
	end)
end

-- Wears Clothing set `ref` over your avatar ("Avatar" or "" = your own clothes), until clear().
function CosmeticPreview.outfit(ref: string)
	local me = character()
	if me then
		Wear.apply(me, ref, localStash())
	end
end

-- Puts back your real blade, finisher and outfit and removes the practice rig.
function CosmeticPreview.clear()
	CosmeticPreview.dismiss()
	local me = character()
	if not me then
		return
	end
	for _, name in { "PreviewBlade", "PreviewBladeLevel", "PreviewMastery", "PreviewFinisher" } do
		me:SetAttribute(name, nil)
	end
	local sword = me:FindFirstChild("Sword")
	if sword and sword:IsA("BasePart") then
		BladeLook.apply(sword, Cosmetics.blade(me))
	end
	if stash then
		local real = Cosmetics.equippedRef(player, "outfit")
		Wear.apply(me, real, stash)
	end
end

return CosmeticPreview
