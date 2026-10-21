--!strict
-- Phone controls: a thumb cluster in the bottom-right corner instead of Roblox's grey
-- ContextActionService circles. One big Deflect under the right thumb (tap to deflect,
-- hold to guard), Slash beside it, an arc of Dodge / Thrust / Sweep / Heal over them,
-- and Jump and Lock on the outside. The left half of the screen stays clear for the move
-- stick. On touch the camera locks on to the nearest enemy by itself; Lock turns that
-- off for free look. Keyboard and gamepad players never see any of this.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Assets = require(ReplicatedStorage.Shared.Assets)
local Config = require(ReplicatedStorage.Shared.Config)
local LockOn = require(script.Parent.LockOn)
local UI = require(script.Parent.UI)

local player = Players.LocalPlayer
local lockSettings = Config.LockOn

export type Handler = { began: () -> (), ended: (() -> ())? }

local TouchHUD = {}

-- Button centres as offsets from the cluster's bottom-right corner, and diameters, at
-- scale 1 (sized for an 844x390 phone in landscape). Hit boxes never overlap.
local LAYOUT: { [string]: { x: number, y: number, size: number } } = {
	Block = { x = -70, y = -68, size = 116 },
	Attack = { x = -190, y = -46, size = 84 },
	Dodge = { x = -228, y = -125, size = 60 },
	Perilous = { x = -185, y = -191, size = 60 },
	Sweep = { x = -116, y = -229, size = 60 },
	Heal = { x = -38, y = -233, size = 60 },
	Jump = { x = -292, y = -44, size = 64 },
	LockOn = { x = -306, y = -154, size = 60 },
}
-- On a portrait screen width is scarce, so Jump and Lock move from the left to the top.
local TALL: { [string]: { x: number, y: number, size: number } } = {
	Jump = { x = -200, y = -275, size = 64 },
	LockOn = { x = -40, y = -312, size = 60 },
}
local TITLES = {
	Block = "Deflect",
	Attack = "Slash",
	Dodge = "Dodge",
	Perilous = "Thrust",
	Sweep = "Sweep",
	Heal = "Heal",
	Jump = "Jump",
	LockOn = "Lock",
}
local CLUSTER = Vector2.new(336, 266)
local CLUSTER_TALL = Vector2.new(258, 342)
local MARGIN = 8
-- The smallest button stays at least 45 px across: comfortably over the 44 px minimum.
-- Never larger than designed: at 1.25 the cluster filled 85% of a phone's height and its arc
-- (Thrust, Dodge) sat over the opponent in the middle of the screen.
local MIN_SCALE = 0.75
local MAX_SCALE = 1
-- In landscape the cluster takes at most this share of the screen's height, so its arc
-- (Thrust, Dodge, Sweep) stays low and right, clear of the fighters in the middle: 0.85 on
-- an 844x390 phone (the 60 px discs stay 51 pt).
local MAX_HEIGHT_SHARE = 0.58
local TICK = 0.15

local screen: ScreenGui
local cluster: Frame
local strokes: { [string]: UIStroke } = {}
local glyphs: { [string]: GuiObject } = {}
local releases: { () -> () } = {}

local shown = false
local autoLock = true
local autoTarget: Model? = nil
local defaultJump: GuiObject? = nil
local defaultJumpWanted = true

-- Lays out `frame` (the cluster, or a copy of it in a layout test) for a screen of this
-- size: at most half the width (the move stick owns the left side) and the height below
-- the top bar, with Jump and Lock moved to the top on a portrait screen.
function TouchHUD.layout(frame: Frame, size: Vector2)
	local tall = size.Y > size.X
	local area = if tall then CLUSTER_TALL else CLUSTER
	local scale = math.min((size.X * 0.5 - MARGIN) / area.X, (size.Y - 40) / area.Y, MAX_SCALE)
	if not tall then
		scale = math.min(scale, size.Y * MAX_HEIGHT_SHARE / area.Y)
	end
	frame.Size = UDim2.fromOffset(area.X, area.Y)
	local fit = frame:FindFirstChildOfClass("UIScale")
	if fit then
		fit.Scale = math.max(scale, MIN_SCALE)
	end
	for _, child in frame:GetChildren() do
		local spec = LAYOUT[child.Name]
		if spec and child:IsA("GuiObject") then
			spec = (if tall then TALL[child.Name] else nil) or spec
			child.Position = UDim2.new(1, spec.x, 1, spec.y)
		end
	end
end

-- Which fight a body is in: the royale, one duel terrace ("Duel1"), the boss arena, or
-- none (the lobby). The server publishes it as the Arena attribute (LobbyService.setArena).
local function arenaOf(model: Model): string?
	local arena = model:GetAttribute("Arena")
	if typeof(arena) == "string" then
		return arena
	elseif model:GetAttribute("InMatch") == true then
		return "Royale"
	elseif model:GetAttribute("InDuel") == true then
		return "Duel"
	end
	return nil
end

-- Mirrors the server's hit filter (LobbyService): fighters in the royale or a duel only
-- reach others in the same fight; in the lobby, the trainer, or another player who also
-- opted into sparring.
local function canFight(model: Model): boolean
	local mine = player.Character
	if not mine then
		return false
	end
	local myArena, theirArena = arenaOf(mine), arenaOf(model)
	if myArena or theirArena then
		return myArena == theirArena
	end
	if model:GetAttribute("Trainer") then
		return true
	end
	return mine:GetAttribute("Safe") == false and model:GetAttribute("Safe") == false
end

local function alive(): boolean
	local humanoid = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
	return humanoid ~= nil and humanoid.Health > 0
end

local function usingTouch(): boolean
	if workspace:GetAttribute("ForceTouchHUD") == true then
		return true -- test aid: try the phone controls with a mouse in Studio
	end
	if not UserInputService.TouchEnabled then
		return false
	end
	local last = UserInputService:GetLastInputType()
	if last == Enum.UserInputType.Touch then
		return true
	end
	-- Before the first input, a phone (no keyboard) counts as touch.
	local other = last == Enum.UserInputType.Keyboard
		or last.Name:match("^Mouse") ~= nil
		or last.Name:match("^Gamepad") ~= nil
	return not other and not UserInputService.KeyboardEnabled
end

local function refreshLockGlyph()
	local glyph = glyphs.LockOn
	if glyph then
		local dim = if autoLock then 0 else 0.55
		if glyph:IsA("ImageLabel") then
			glyph.ImageTransparency = dim
		elseif glyph:IsA("TextLabel") then
			glyph.TextTransparency = dim
		end
	end
	strokes.LockOn.Color = if autoLock then UI.Jade else UI.Theme.Ash
end

local function toggleAutoLock()
	autoLock = not autoLock
	autoTarget = nil
	if not autoLock then
		LockOn.set(nil) -- free look
	end
	refreshLockGlyph()
end

-- Humanoid.Jump would be overwritten by the control script on the next frame, so jump
-- directly, from the ground only, like the stock button.
local function jump()
	local humanoid = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
	if
		humanoid
		and humanoid.Health > 0
		and humanoid.FloorMaterial ~= Enum.Material.Air
		and humanoid:GetStateEnabled(Enum.HumanoidStateType.Jumping)
	then
		humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
	end
end

-- One round button. `began` runs on touch-down; `ended` when that same finger lifts,
-- wherever it is by then, so a held guard survives the thumb sliding off.
local function makeButton(name: string, handler: Handler)
	local spec = LAYOUT[name]
	local primary = name == "Block" or name == "Attack"
	local button = UI.new("ImageButton", {
		Name = name,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(1, spec.x, 1, spec.y),
		Size = UDim2.fromOffset(spec.size, spec.size),
		BackgroundColor3 = UI.Ink,
		BackgroundTransparency = if primary then 0.25 else 0.35,
		AutoButtonColor = false,
		Selectable = false,
		Image = "",
	}, cluster)
	UI.corner(button, UDim.new(0.5, 0))
	-- A 2 px ink rim so the disc reads over dark ground, and an inner hairline ring in the
	-- button's colour (bone for Deflect, crimson for Slash, gold for the rest) that also
	-- shows state: gold while guarding, jade while auto lock-on is on.
	UI.new("UIStroke", { Name = "Rim", Color = UI.Theme.Ink, Thickness = 2, Transparency = 0.1 }, button)
	local ring = UI.new("Frame", {
		Name = "Ring",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(1, -6, 1, -6),
		BackgroundTransparency = 1,
		ZIndex = 2,
	}, button)
	UI.new("UICorner", { CornerRadius = UDim.new(0.5, 0) }, ring)
	strokes[name] = UI.new("UIStroke", {
		Color = if name == "Block" then UI.Parchment elseif name == "Attack" then UI.Crimson else UI.Theme.Gold,
		Thickness = if primary then 2 else 1,
		Transparency = 0.15,
	}, ring)
	local art = UI.new("ImageLabel", {
		Name = "RingArt",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(1.04, 1.04),
		BackgroundTransparency = 1,
		ZIndex = 3,
	}, button)
	if not UI.art(art, "TouchRing") then
		art:Destroy()
	end
	local press = UI.new("UIScale", {}, button)

	local glyph = Assets.Touch[name]
	if glyph and glyph ~= "" then
		glyphs[name] = UI.new("ImageLabel", {
			Name = "Glyph",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromScale(0.86, 0.86),
			BackgroundTransparency = 1,
			Image = glyph,
		}, button)
	else
		glyphs[name] = UI.text({
			Name = "Glyph",
			Size = UDim2.fromScale(1, 1),
			Font = UI.Display,
			TextSize = math.floor(spec.size * 0.3),
			Text = string.upper(TITLES[name]),
		}, button)
	end

	local held: InputObject? = nil
	local function release()
		if not held then
			return
		end
		held = nil
		UI.tween(press, 0.08, { Scale = 1 })
		button.BackgroundTransparency = if primary then 0.25 else 0.35
		if name == "Block" then
			strokes.Block.Color = UI.Parchment
		end
		if handler.ended then
			handler.ended()
		end
	end
	table.insert(releases, release)

	button.InputBegan:Connect(function(input: InputObject)
		local kind = input.UserInputType
		if held or (kind ~= Enum.UserInputType.Touch and kind ~= Enum.UserInputType.MouseButton1) then
			return
		end
		held = input
		press.Scale = 0.9
		button.BackgroundTransparency = 0.05
		if name == "Block" then
			strokes.Block.Color = UI.Gold -- guard up
		end
		handler.began()
	end)
	UserInputService.InputEnded:Connect(function(input: InputObject)
		local current = held
		if
			current
			and (
				input == current
				or (
					current.UserInputType == Enum.UserInputType.MouseButton1
					and input.UserInputType == Enum.UserInputType.MouseButton1
				)
			)
		then
			release()
		end
	end)
end

-- Roblox's own jump button sits exactly where Deflect does, so it hides while the
-- cluster (which has its own Jump) is up, and comes back as Roblox left it.
local function watchDefaultJump()
	local touchGui = player.PlayerGui:FindFirstChild("TouchGui")
	local frame = touchGui and touchGui:FindFirstChild("TouchControlFrame")
	local button = frame and frame:FindFirstChild("JumpButton")
	if not button or not button:IsA("GuiObject") or button == defaultJump then
		return
	end
	defaultJump = button
	defaultJumpWanted = button.Visible
	button:GetPropertyChangedSignal("Visible"):Connect(function()
		if shown and button.Visible then
			defaultJumpWanted = true
			button.Visible = false
		elseif not shown then
			defaultJumpWanted = button.Visible
		end
	end)
	if shown then
		button.Visible = false
	end
end

local function setShown(on: boolean)
	if shown == on then
		return
	end
	shown = on
	cluster.Visible = on
	if not on then
		for _, release in releases do
			release()
		end
	end
	local button = defaultJump
	if button and button.Parent then
		button.Visible = if on then false else defaultJumpWanted
	end
end

-- Auto lock-on: keep the camera on the nearest enemy we can actually fight; let an
-- automatic lock go once they're far away, and move it when someone much closer appears.
local function updateAutoLock(touch: boolean)
	local current = LockOn.target()
	if current ~= autoTarget then
		autoTarget = nil -- released (death, range) or picked by hand
	end
	if not touch or not autoLock or not alive() then
		return
	end
	local nearest, distance = LockOn.nearest(lockSettings.AutoRange, canFight)
	if autoTarget then
		local held = LockOn.distanceTo(autoTarget)
		if held > lockSettings.AutoBreakRange or not canFight(autoTarget) then
			LockOn.set(nil)
			autoTarget = nil
		elseif nearest and nearest ~= autoTarget and distance + lockSettings.AutoSwitchGap < held then
			LockOn.set(nearest)
			autoTarget = nearest
		end
		return
	end
	if not current and nearest then
		LockOn.set(nearest)
		autoTarget = nearest
	end
end

local function panelOpen(): boolean
	-- The boss picker counts as a panel: the cluster never covers its list or CLOSE.
	local boss = player.PlayerGui:FindFirstChild("BossHUD")
	local picker = boss and boss:FindFirstChild("Picker")
	if picker and picker:IsA("GuiObject") and picker.Visible then
		return true
	end
	local panels = player.PlayerGui:FindFirstChild("LobbyPanels")
	if not panels or not panels:IsA("ScreenGui") or not panels.Enabled then
		return false
	end
	for _, child in panels:GetChildren() do
		if child:IsA("GuiObject") and child.Visible then
			return true
		end
	end
	return false
end

-- Heal is out of gourds: its disc fades (disabled look); it still answers a press.
local function refreshDisabled()
	local glyph = glyphs.Heal
	local character = player.Character
	local gourds = character and character:GetAttribute("Gourds")
	local empty = typeof(gourds) == "number" and gourds <= 0
	if glyph and glyph:IsA("ImageLabel") then
		glyph.ImageTransparency = if empty then 0.6 else 0
	elseif glyph and glyph:IsA("TextLabel") then
		glyph.TextTransparency = if empty then 0.6 else 0
	end
end

local function tick()
	watchDefaultJump()
	refreshDisabled()
	local touch = usingTouch()
	updateAutoLock(touch)
	-- In a match or a duel the cluster is always up. In the lobby the bottom belongs to PLAY
	-- and the nav bar, so it only comes up (over them) with someone to fight close by, the
	-- trainer or a sparring partner, and never over an open lobby panel.
	local character = player.Character
	local fighting = character ~= nil and arenaOf(character) ~= nil
	local engaged = fighting or LockOn.nearest(lockSettings.AutoRange, canFight) ~= nil
	setShown(touch and alive() and engaged and not panelOpen())
end

local function refit()
	TouchHUD.layout(cluster, screen.AbsoluteSize)
end

-- Builds the cluster. `handlers` maps the combat actions (Attack, Block, Dodge, Perilous,
-- Sweep, Heal, and optionally Jump) to what a press does; Lock (and Jump by default) are
-- handled here.
function TouchHUD.start(handlers: { [string]: Handler })
	screen = UI.new("ScreenGui", {
		Name = "TouchHUD",
		ResetOnSpawn = false,
		IgnoreGuiInset = false,
		ScreenInsets = Enum.ScreenInsets.CoreUISafeInsets,
		DisplayOrder = 7, -- over the lobby HUD (5) and its panels (6); see tick()
	})
	cluster = UI.new("Frame", {
		Name = "Cluster",
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -MARGIN, 1, -MARGIN),
		Size = UDim2.fromOffset(CLUSTER.X, CLUSTER.Y),
		BackgroundTransparency = 1,
		Visible = false,
	}, screen)
	UI.new("UIScale", {}, cluster)

	for name, handler in handlers do
		if name ~= "Jump" then
			makeButton(name, handler)
		end
	end
	-- CombatInput may take over the jump (to buffer it during swings and stomp in the air).
	makeButton("Jump", handlers.Jump or { began = jump })
	makeButton("LockOn", { began = toggleAutoLock })
	refreshLockGlyph()

	screen.Parent = player:WaitForChild("PlayerGui")
	screen:GetPropertyChangedSignal("AbsoluteSize"):Connect(refit)
	refit()

	local last = 0
	RunService.Heartbeat:Connect(function()
		local now = os.clock()
		if now - last >= TICK then
			last = now
			tick()
		end
	end)
	UserInputService.LastInputTypeChanged:Connect(tick)
end

return TouchHUD
