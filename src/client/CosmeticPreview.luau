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
--   CosmeticPreview.present(item, { back?, onBack? })  -- the Locker / Store preview: puts a
--        Catalog item on you, hides the lobby HUD, swings the camera round to your front
--        three-quarter (a side view for finishers), loops the blade's cuts, one Back button
--   CosmeticPreview.stop(reopen?)                    -- ends it (Back, a panel opening, respawn)
--
-- Meant for the lobby (out of combat): the swings play your character's clips locally.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")

local Animator = require(script.Parent.Animator)
local CombatVisuals = require(script.Parent.CombatVisuals)
local Panels = require(script.Parent.Panels)
local UI = require(script.Parent.UI)
local Catalog = require(ReplicatedStorage.Shared.Catalog)
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

---------------------------------------------------------------------------------------------
-- The full preview the Locker and the Store open (one at a time).

type Session = {
	token: number,
	gui: ScreenGui,
	connections: { RBXScriptConnection },
	cameraType: Enum.CameraType,
	onBack: (() -> ())?,
}
local session: Session? = nil
local sessionToken = 0
local CAMERA_STEP = "CosmeticPreviewCamera"

local function lobbyHud(): ScreenGui?
	local gui = player:FindFirstChild("PlayerGui")
	local hud = gui and gui:FindFirstChild("LobbyHUD")
	return if hud and hud:IsA("ScreenGui") then hud else nil
end

function CosmeticPreview.active(): boolean
	return session ~= nil
end

-- Ends the preview: your real look back, the camera and HUD as they were. `reopen` runs the
-- caller's Back (reopen the Locker / Store).
function CosmeticPreview.stop(reopen: boolean?)
	local s = session
	if not s then
		return
	end
	session = nil
	RunService:UnbindFromRenderStep(CAMERA_STEP)
	for _, connection in s.connections do
		connection:Disconnect()
	end
	s.gui:Destroy()
	CosmeticPreview.clear()
	local camera = workspace.CurrentCamera
	if camera.CameraType == Enum.CameraType.Scriptable then
		camera.CameraType = s.cameraType
	end
	local hud = lobbyHud()
	if hud then
		hud.Enabled = not Panels.isLarge()
	end
	if reopen and s.onBack then
		s.onBack()
	end
end

-- Front three-quarter of `root` (a side view of you and the rig for finishers), turning a
-- little either side so the blade catches the light.
local function cameraFor(root: BasePart, finisher: boolean, t: number): CFrame
	local flat = Vector3.new(root.CFrame.LookVector.X, 0, root.CFrame.LookVector.Z)
	flat = if flat.Magnitude > 1e-3 then flat.Unit else Vector3.zAxis
	local right = flat:Cross(Vector3.yAxis)
	if finisher then
		local mid = root.Position + flat * (RIG_DISTANCE / 2)
		local eye = mid + right * 12 + Vector3.yAxis * 2.5
		return CFrame.lookAt(eye, mid + Vector3.yAxis * 0.5)
	end
	local sway = math.sin(t * 0.45) * 0.35
	local angle = math.rad(32) + sway -- toward the sword hand
	local dir = (flat * math.cos(angle) + right * math.sin(angle)).Unit
	local focus = root.Position + Vector3.yAxis * 0.6 + right * 0.5
	return CFrame.lookAt(focus + dir * 7.5 + Vector3.yAxis * 1.4, focus)
end

-- Puts `item` (a blade, blade line, outfit or finisher) on you and shows it off. `opts.level`:
-- a line's level; `opts.back`: the button's text; `opts.onBack`: what Back does after.
function CosmeticPreview.present(item: Catalog.Item, opts: { level: number?, back: string?, onBack: (() -> ())? }?)
	local o = opts or {}
	CosmeticPreview.stop(false)
	local me = character()
	local root = me and me:FindFirstChild("HumanoidRootPart")
	if not me or not root or not root:IsA("BasePart") then
		return
	end
	sessionToken += 1
	local token = sessionToken
	local camera = workspace.CurrentCamera
	local gui = UI.new("ScreenGui", {
		Name = "CosmeticPreview",
		ResetOnSpawn = false,
		DisplayOrder = 7,
		ScreenInsets = Enum.ScreenInsets.CoreUISafeInsets,
	})
	-- One plate at the bottom: what you're wearing and the way back.
	local plate = UI.panel({
		Name = "Plate",
		material = "lacquer",
		sliceScale = 0.6,
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -16),
		Size = UDim2.fromOffset(340, 64 + UI.Touch),
	}, gui)
	UI.text({
		Name = "ItemName",
		Position = UDim2.fromOffset(12, 8),
		Size = UDim2.new(1, -24, 0, 26),
		FontFace = UI.Fonts.Display,
		TextSize = 20,
		TextColor3 = UI.rarity(item.rarity).text,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Text = item.name,
	}, plate)
	UI.label("caption", {
		Position = UDim2.fromOffset(12, 34),
		Size = UDim2.new(1, -24, 0, 18),
		TextColor3 = UI.Theme.Dim,
		Text = if item.category == "finisher" then "on a practice copy of you" else "on you  ·  only you see this",
	}, plate)
	local back = UI.button({
		Name = "Back",
		variant = "primary",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -8),
		Size = UDim2.new(1, -24, 0, UI.Touch),
		Text = o.back or "Back",
		TextSize = 19,
		sound = "Cancel",
	}, plate)
	gui.Parent = player:WaitForChild("PlayerGui")
	local s: Session = {
		token = token,
		gui = gui,
		connections = {},
		cameraType = if camera.CameraType == Enum.CameraType.Scriptable
			then Enum.CameraType.Custom
			else camera.CameraType,
		onBack = o.onBack,
	}
	session = s
	back.Activated:Connect(function()
		CosmeticPreview.stop(true)
	end)

	-- The lobby HUD steps aside (and stays aside if something tries to bring it back).
	local hud = lobbyHud()
	if hud then
		hud.Enabled = false
		table.insert(
			s.connections,
			hud:GetPropertyChangedSignal("Enabled"):Connect(function()
				if session == s and hud.Enabled then
					hud.Enabled = false
				end
			end)
		)
	end
	-- Any panel opening, a respawn or a fight ends it.
	table.insert(
		s.connections,
		player.CharacterAdded:Connect(function()
			CosmeticPreview.stop(false)
		end)
	)
	table.insert(
		s.connections,
		me:GetAttributeChangedSignal("InMatch"):Connect(function()
			CosmeticPreview.stop(false)
		end)
	)

	-- The look itself.
	local finisher = item.category == "finisher"
	local ok, err = pcall(function()
		if item.category == "bladeSkin" or item.category == "bladeLine" then
			CosmeticPreview.blade(item.id, if item.category == "bladeLine" then o.level or 1 else nil)
		elseif item.category == "outfit" then
			CosmeticPreview.outfit(item.ref)
		elseif finisher then
			CosmeticPreview.finisher(item.ref)
		end
	end)
	if not ok then
		warn("[CosmeticPreview] preview failed:", err)
	end

	-- The camera: front three-quarter, turning slowly.
	camera.CameraType = Enum.CameraType.Scriptable
	local t0 = os.clock()
	RunService:BindToRenderStep(CAMERA_STEP, Enum.RenderPriority.Camera.Value + 5, function()
		local body = character()
		local hrp = body and body:FindFirstChild("HumanoidRootPart")
		if session ~= s or not hrp or not hrp:IsA("BasePart") then
			return
		end
		camera.CameraType = Enum.CameraType.Scriptable
		local want = cameraFor(hrp, finisher, os.clock() - t0)
		camera.CFrame = camera.CFrame:Lerp(want, 0.12)
	end)

	-- Blades cut the air every few seconds; finishers replay.
	task.spawn(function()
		local first = true
		while session == s do
			if item.category == "bladeSkin" or item.category == "bladeLine" then
				task.wait(if first then 0.5 else 3.2)
				if session == s then
					CosmeticPreview.swing()
				end
			elseif finisher then
				task.wait(if first then 0 else 4)
				if session == s and not first then
					CosmeticPreview.finisher(item.ref)
				end
			else
				break
			end
			first = false
		end
	end)
end

return CosmeticPreview
