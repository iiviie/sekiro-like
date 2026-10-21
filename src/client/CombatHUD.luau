--!strict
-- Sekiro-style HUD built on the art in Shared/Assets.UI:
--   bottom-left   healing gourd, vitality (crimson, with a pale trail of recent damage)
--                 and stamina (muted gold) in soft lacquered frames
--   bottom-centre posture: grows from the ornament outwards, heats from amber to red
--                 with a bloom underneath, and fades away while empty
--   enemies       posture and vitality over the head of whoever you're fighting, and the
--                 red deathblow dot when they break
--   splashes      brush kanji on an ink band (死, 斬, round banners)
--   screen        a light cinematic vignette and a red edge flash for perilous attacks
--
-- Nothing runs per frame: bars update from attribute and health signals and animate with
-- tweens, and enemy bars exist only while relevant.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Assets = require(ReplicatedStorage.Shared.Assets)
local LockOn = require(script.Parent.LockOn)
local Types = require(ReplicatedStorage.Shared.Types)
local Kit = require(script.Parent.UI)

local combatEvent = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("CombatEvent") :: RemoteEvent
local player = Players.LocalPlayer
local UI = Assets.UI

local FONT = Enum.Font.Garamond
local PARCHMENT = Color3.fromRGB(232, 222, 200)
local CRIMSON = Color3.fromRGB(176, 22, 20)
local TRAIL = Color3.fromRGB(226, 206, 170)
local STAMINA = Color3.fromRGB(196, 168, 102)
local STAMINA_LOW = Color3.fromRGB(150, 110, 70)
local POSTURE_LOW = Color3.fromRGB(255, 204, 96)
local POSTURE_MID = Color3.fromRGB(246, 128, 40)
local POSTURE_HIGH = Color3.fromRGB(214, 44, 22)
local BROKEN_FLASH = Color3.fromRGB(255, 246, 222)
local DEATH_RED = Color3.fromRGB(190, 18, 18)

local FRAME_INSET = 10 -- transparent shadow margin baked into the frame art
local ENEMY_BAR_LINGER = 4
local CONTROLS_HINT_TIME = 14
local CONTROLS_HINT_FIGHTS = 3 -- the keycap reminder shows for your first few fights only (Played < 3)
-- The posture group's bottom edge above the screen's: its bar sits in the bottom ~15%, under
-- the fighters' feet. Coach prompts and the trainer readout sit just above it.
local POSTURE_BOTTOM = 70

local CombatHUD = {}

-- How far above the screen's bottom edge the posture group's top sits (scale 1).
CombatHUD.PostureTop = POSTURE_BOTTOM + 72

type Bar = { root: ImageLabel, fill: ImageLabel, trail: ImageLabel? }
type EnemyEntry = {
	gui: BillboardGui,
	posture: Bar,
	vitality: Bar,
	marker: BillboardGui,
	hideToken: number,
	connections: { RBXScriptConnection },
}

local screen: ScreenGui
local vitality: Bar
local stamina: Bar
local posture: Bar
local postureGlow: ImageLabel
local postureGroup: CanvasGroup
local ownGroup: CanvasGroup
local staminaGroup: CanvasGroup
local gourdIcon: ImageLabel
local gourdCount: TextLabel
local perilFlash: ImageLabel
local controlsHint: CanvasGroup
local enemies: { [Model]: EnemyEntry } = {}

local function tween(instance: Instance, time: number, goal: { [string]: any }, style: Enum.EasingStyle?)
	local info = TweenInfo.new(time, style or Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local t = TweenService:Create(instance, info, goal)
	t:Play()
	return t
end

-- CanvasGroups that ran out of texture budget fall back to plain drawing and ignore
-- GroupTransparency, so a faded-out group is also hidden (never rely on the fade alone).
-- `lobbyHidden` groups stay hidden whatever their fade says.
local lobbyHidden: { [CanvasGroup]: boolean } = {}
local function fadeGroup(group: CanvasGroup, time: number, target: number)
	local token = (group:GetAttribute("FadeToken") or 0) + 1
	group:SetAttribute("FadeToken", token)
	if target < 1 then
		group.Visible = not lobbyHidden[group]
	end
	if time <= 0 then
		group.GroupTransparency = target
		if target >= 1 then
			group.Visible = false
		end
		return
	end
	local t = tween(group, time, { GroupTransparency = target })
	if target >= 1 then
		t.Completed:Once(function(state)
			if state == Enum.PlaybackState.Completed and group:GetAttribute("FadeToken") == token then
				group.Visible = false
			end
		end)
	end
end

local function image(parent: Instance, id: string, props: { [string]: any }?): ImageLabel
	local i = Instance.new("ImageLabel")
	i.BackgroundTransparency = 1
	i.Image = id
	if props then
		for key, value in props do
			(i :: any)[key] = value
		end
	end
	i.Parent = parent
	return i
end

-- A framed bar. `size` is the visible track; the frame art adds its shadow margin around
-- it. Centred bars (posture) grow from the middle outwards.
local function makeBar(
	parent: Instance,
	size: Vector2,
	position: UDim2,
	anchor: Vector2,
	centered: boolean,
	withTrail: boolean,
	tint: Color3
): Bar
	local root = image(parent, UI.BarFrame, {
		ScaleType = Enum.ScaleType.Slice,
		SliceCenter = Rect.new(14, 14, 242, 26),
		Size = UDim2.fromOffset(size.X + FRAME_INSET * 2, size.Y + FRAME_INSET * 2),
		Position = position,
		AnchorPoint = anchor,
	})

	local track = Instance.new("Frame")
	track.BackgroundTransparency = 1
	track.ClipsDescendants = true
	track.Position = UDim2.fromOffset(FRAME_INSET + 1, FRAME_INSET + 1)
	track.Size = UDim2.new(1, -(FRAME_INSET + 1) * 2, 1, -(FRAME_INSET + 1) * 2)
	track.Parent = root

	local function inner(color: Color3, z: number): ImageLabel
		return image(track, UI.BarFill, {
			ImageColor3 = color,
			ScaleType = Enum.ScaleType.Stretch,
			AnchorPoint = if centered then Vector2.new(0.5, 0) else Vector2.zero,
			Position = if centered then UDim2.fromScale(0.5, 0) else UDim2.fromScale(0, 0),
			Size = UDim2.fromScale(if centered then 0 else 1, 1),
			ZIndex = z,
		})
	end

	local trail = if withTrail then inner(TRAIL, 1) else nil
	return { root = root, fill = inner(tint, 2), trail = trail }
end

-- Sets a bar to `ratio`; a damage trail lingers, then drains to catch up.
local function setBar(bar: Bar, ratio: number, instant: boolean?)
	ratio = math.clamp(ratio, 0, 1)
	local goal = UDim2.fromScale(ratio, 1)
	if instant then
		bar.fill.Size = goal
		if bar.trail then
			bar.trail.Size = goal
		end
		return
	end
	tween(bar.fill, 0.12, { Size = goal })
	local trail = bar.trail
	if trail then
		if ratio >= trail.Size.X.Scale then
			trail.Size = goal
		else
			task.delay(0.5, function()
				if bar.fill.Size.X.Scale <= ratio + 1e-3 then
					tween(trail, 0.55, { Size = bar.fill.Size }, Enum.EasingStyle.Sine)
				end
			end)
		end
	end
end

local function postureColor(ratio: number): Color3
	if ratio < 0.5 then
		return POSTURE_LOW:Lerp(POSTURE_MID, ratio * 2)
	end
	return POSTURE_MID:Lerp(POSTURE_HIGH, (ratio - 0.5) * 2)
end

local function ratioOf(model: Model, value: string, max: string): number?
	local v, m = model:GetAttribute(value), model:GetAttribute(max)
	if typeof(v) == "number" and typeof(m) == "number" and m > 0 then
		return v / m
	end
	return nil
end

---------------------------------------------------------------------------------------
-- Own bars

local characterConnections: { RBXScriptConnection } = {}

local function refreshPosture(model: Model)
	local ratio = ratioOf(model, "Posture", "PostureMax")
	if not ratio then
		return
	end
	local broken = model:GetAttribute("CombatState") == "Broken"
	setBar(posture, ratio)
	local color = if broken then BROKEN_FLASH else postureColor(ratio)
	posture.fill.ImageColor3 = color
	postureGlow.ImageColor3 = color
	-- The bloom only shows as posture runs hot.
	local bloom = if broken then 0.1 else 1 - math.clamp((ratio - 0.4) * 1.4, 0, 0.75)
	tween(postureGlow, 0.2, { ImageTransparency = bloom })
	local visible = ratio > 0.01 or broken
	if visible or postureGroup.Visible then
		fadeGroup(postureGroup, 0.3, if visible then 0 else 1)
	end
end

local function refreshStamina(model: Model)
	local ratio = ratioOf(model, "Stamina", "StaminaMax")
	if not ratio then
		return
	end
	setBar(stamina, ratio)
	stamina.fill.ImageColor3 = if ratio < 0.2 then STAMINA_LOW else STAMINA
	-- Only dodges spend stamina now: hidden while full, shown while spent and recovering.
	local full = ratio >= 0.999
	if not full or staminaGroup.Visible then
		fadeGroup(staminaGroup, 0.3, if full then 1 else 0)
	end
end

local function trackCharacter(character: Model)
	for _, connection in characterConnections do
		connection:Disconnect()
	end
	table.clear(characterConnections)

	local humanoid = character:WaitForChild("Humanoid", 10) :: Humanoid?
	if not humanoid then
		return
	end
	local function onHealth()
		setBar(vitality, humanoid.Health / math.max(humanoid.MaxHealth, 1))
	end
	setBar(vitality, 1, true)
	setBar(stamina, 1, true)
	setBar(posture, 0, true)
	fadeGroup(postureGroup, 0, 1)
	fadeGroup(ownGroup, 0, 0)
	fadeGroup(staminaGroup, 0, 1)
	onHealth()
	table.insert(characterConnections, humanoid.HealthChanged:Connect(onHealth))
	table.insert(
		characterConnections,
		humanoid.Died:Connect(function()
			fadeGroup(ownGroup, 0.6, 1)
			fadeGroup(staminaGroup, 0.6, 1)
			fadeGroup(postureGroup, 0.6, 1)
		end)
	)

	local function bind(attribute: string, handler: () -> ())
		table.insert(characterConnections, character:GetAttributeChangedSignal(attribute):Connect(handler))
	end
	local function onPosture()
		refreshPosture(character)
	end
	local function onStamina()
		refreshStamina(character)
	end
	local function onGourds()
		local count = character:GetAttribute("Gourds")
		gourdCount.Text = tostring(if typeof(count) == "number" then count else 0)
		gourdIcon.ImageTransparency = if count == 0 then 0.6 else 0
	end
	bind("Posture", onPosture)
	bind("CombatState", onPosture)
	bind("Stamina", onStamina)
	bind("Gourds", onGourds)
	onPosture()
	onStamina()
	onGourds()
end

---------------------------------------------------------------------------------------
-- Splashes and screen effects

-- A brush-kanji banner on an ink band, with a small spaced-caps subtitle: top-centre, under
-- the round banner and over the fighters' heads, never across them. One at a time: a new
-- splash replaces the one showing.
local SPLASH = Vector2.new(520, 150)
local SPLASH_TOP = Kit.Hud.StageTop
local currentSplash: CanvasGroup? = nil
function CombatHUD.splash(kanjiImage: string, subtitle: string, color: Color3, hold: number)
	if currentSplash then
		currentSplash:Destroy()
	end
	local group = Instance.new("CanvasGroup")
	group.Name = "Splash"
	group.AnchorPoint = Vector2.new(0.5, 0)
	group.Position = UDim2.new(0.5, 0, 0, SPLASH_TOP)
	group.Size = UDim2.fromOffset(SPLASH.X, SPLASH.Y)
	group.BackgroundTransparency = 1
	group.GroupTransparency = 1
	group.ZIndex = 50
	group.Parent = screen
	currentSplash = group

	image(group, UI.InkBand, {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.48),
		Size = UDim2.fromOffset(SPLASH.X, 112),
		ImageTransparency = 0.18,
	})
	local glyph = image(group, kanjiImage, {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.4),
		Size = UDim2.fromScale(1, 0.62),
		ScaleType = Enum.ScaleType.Fit,
		ImageColor3 = color,
	})
	local caption = Instance.new("TextLabel")
	caption.AnchorPoint = Vector2.new(0.5, 0)
	caption.Position = UDim2.fromScale(0.5, 0.72)
	caption.Size = UDim2.new(1, 0, 0, 22)
	caption.BackgroundTransparency = 1
	caption.Font = FONT
	-- Letter-spaced, one UTF-8 character at a time (a byte-wise pattern splits "·").
	caption.Text = (string.upper(subtitle):gsub(utf8.charpattern, "%0 ")):sub(1, -2)
	caption.TextSize = 18
	caption.TextColor3 = PARCHMENT
	caption.TextTransparency = 0.1
	caption.TextStrokeColor3 = Kit.Theme.Ink
	caption.TextStrokeTransparency = 0.5
	caption.Parent = group

	tween(group, 0.3, { GroupTransparency = 0 })
	tween(glyph, 1.2, { Size = UDim2.fromScale(0.9, 0.56) }, Enum.EasingStyle.Sine)
	-- Brief: at most 2.4 s on screen before it fades.
	task.delay(math.min(hold, 2.4), function()
		if not group.Parent then
			return
		end
		tween(group, 0.6, { GroupTransparency = 1 })
		task.wait(0.65)
		if currentSplash == group then
			currentSplash = nil
		end
		group:Destroy()
	end)
end

-- Red flash at the screen's edges: a perilous attack is coming at you.
function CombatHUD.flashPeril()
	perilFlash.ImageTransparency = 0.1
	tween(perilFlash, 0.9, { ImageTransparency = 1 }, Enum.EasingStyle.Sine)
end

-- The key-cap reminder is for keyboard players: not on a phone, not on a gamepad.
local function keyboardPlayer(): boolean
	if Kit.isTouch() or not UserInputService.KeyboardEnabled then
		return false
	end
	local last = UserInputService:GetLastInputType()
	return not (last.Name:find("Gamepad") ~= nil)
end

-- In the lobby: hide your own vitality and stamina (nothing there can hurt you unless you
-- opt into sparring); the posture bar stays where it is in a fight (bottom-centre, clear of
-- PLAY in the corner), where it still teaches the trainer's rhythm.
local lobbyMode: boolean? = nil
function CombatHUD.setLobbyMode(on: boolean)
	if not ownGroup then
		return
	end
	local entering = lobbyMode == true and not on -- lobby -> a fight (royale, duel or boss)
	lobbyMode = on
	lobbyHidden[ownGroup] = on
	lobbyHidden[staminaGroup] = on
	-- The keyboard reminder is for fights, and a phone has no keyboard.
	lobbyHidden[controlsHint] = on or not keyboardPlayer()
	ownGroup.Visible = not on and ownGroup.GroupTransparency < 0.99
	staminaGroup.Visible = not on and staminaGroup.GroupTransparency < 0.99
	controlsHint.Visible = not lobbyHidden[controlsHint] and controlsHint.GroupTransparency < 0.99
	if entering then
		CombatHUD.showControls()
	end
end

-- A brief white flash at the screen's edges: you landed a perfect deflect.
local perfectFlash: ImageLabel
function CombatHUD.flashPerfect()
	if not perfectFlash then
		return
	end
	perfectFlash.ImageTransparency = 0.25
	tween(perfectFlash, 0.35, { ImageTransparency = 1 }, Enum.EasingStyle.Quad)
end

-- Shows the controls reminder for a while, then fades it: at the start of every fight
-- (royale, duel, boss), unless Settings turned it off. A later call restarts the clock.
local hintToken = 0
local hintFights = 0
function CombatHUD.showControls()
	if not controlsHint or Players.LocalPlayer:GetAttribute("SettingControlsHint") == false then
		return
	end
	-- Only a newcomer's first fights (lifetime, and at most that many per session).
	local played = Players.LocalPlayer:GetAttribute("Played")
	if
		hintFights >= CONTROLS_HINT_FIGHTS
		or (typeof(played) == "number" and played >= CONTROLS_HINT_FIGHTS)
		or not keyboardPlayer()
	then
		return
	end
	hintFights += 1
	hintToken += 1
	local mine = hintToken
	fadeGroup(controlsHint, 0, 0.1)
	task.delay(CONTROLS_HINT_TIME, function()
		if hintToken == mine then
			fadeGroup(controlsHint, 2, 1)
		end
	end)
end

---------------------------------------------------------------------------------------
-- Enemy bars and the deathblow marker

local function removeEnemy(model: Model)
	local entry = enemies[model]
	if not entry then
		return
	end
	for _, connection in entry.connections do
		connection:Disconnect()
	end
	entry.gui:Destroy()
	entry.marker:Destroy()
	enemies[model] = nil
end

local function refreshEnemy(model: Model, entry: EnemyEntry)
	local ratio = ratioOf(model, "Posture", "PostureMax")
	local broken = model:GetAttribute("CombatState") == "Broken"
	if ratio then
		setBar(entry.posture, ratio)
		entry.posture.fill.ImageColor3 = if broken then BROKEN_FLASH else postureColor(ratio)
	end
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid then
		setBar(entry.vitality, humanoid.Health / math.max(humanoid.MaxHealth, 1))
	end
	entry.marker.Enabled = broken
end

-- The deathblow marker on a broken body: 96 px at scale 1 (a 64 px dot read as a speck on a
-- kneeling fighter), at the HUD's scale on phones.
local MARKER_SIZE = 96

local function makeMarker(model: Model): BillboardGui
	local torso = model:FindFirstChild("UpperTorso") or model:FindFirstChild("HumanoidRootPart")
	local marker = Instance.new("BillboardGui")
	marker.Name = "DeathblowMarker"
	marker.Adornee = torso :: BasePart?
	marker.AlwaysOnTop = true
	marker.LightInfluence = 0
	local size = math.floor(MARKER_SIZE * Kit.hudScale())
	marker.Size = UDim2.fromOffset(size, size)
	marker.Enabled = false
	local dot = image(marker, UI.DeathblowDot, {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.8, 0.8),
	})
	TweenService:Create(
		dot,
		TweenInfo.new(0.5, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
		{ Size = UDim2.fromScale(1, 1) }
	):Play()
	marker.Parent = player:WaitForChild("PlayerGui")
	return marker
end

local function showEnemy(model: Model, linger: number?)
	if model == player.Character or not model.Parent or model:GetAttribute("CombatState") == "Dead" then
		return
	end
	local entry = enemies[model]
	if not entry then
		local head = model:FindFirstChild("Head")
		if not head or not head:IsA("BasePart") then
			return
		end
		local gui = Instance.new("BillboardGui")
		gui.Name = "EnemyBars"
		gui.Adornee = head
		gui.AlwaysOnTop = true
		gui.LightInfluence = 0
		-- A bot carries no Roblox nameplate (BotService), so its name is the last line here: it
		-- shows only while its bars do. Players keep Roblox's own name over their heads.
		local named = Players:GetPlayerFromCharacter(model) == nil
		gui.Size = UDim2.fromOffset(200, if named then 62 else 50)
		gui.StudsOffset = Vector3.new(0, if named then 3.1 else 2.9, 0)
		gui.MaxDistance = 90

		local postureBar =
			makeBar(gui, Vector2.new(170, 6), UDim2.fromScale(0.5, 0), Vector2.new(0.5, 0), true, false, POSTURE_LOW)
		image(gui, UI.PostureOrnament, {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromOffset(100, 13),
			Size = UDim2.fromOffset(80, 24),
			ZIndex = 3,
		})
		local vitalityBar =
			makeBar(gui, Vector2.new(120, 4), UDim2.fromOffset(100, 22), Vector2.new(0.5, 0), false, true, CRIMSON)
		if named then
			Kit.label("label", {
				Name = "FighterName",
				AnchorPoint = Vector2.new(0.5, 0),
				Position = UDim2.fromOffset(100, 44),
				Size = UDim2.fromOffset(200, 17),
				TextSize = 15,
				TextColor3 = Kit.Theme.Bone,
				TextStrokeColor3 = Kit.Theme.Ink,
				TextStrokeTransparency = 0.35,
				TextTruncate = Enum.TextTruncate.AtEnd,
				Text = model.Name,
			}, gui)
		end
		-- A boss has its own bar at the bottom of the screen (BossHUD): no floating bars over
		-- it, but the deathblow marker on its body still shows.
		gui.Enabled = model:GetAttribute("Boss") == nil
		gui.Parent = player:WaitForChild("PlayerGui")

		local created: EnemyEntry = {
			gui = gui,
			posture = postureBar,
			vitality = vitalityBar,
			marker = makeMarker(model),
			hideToken = 0,
			connections = {},
		}
		enemies[model] = created
		local function refresh()
			refreshEnemy(model, created)
		end
		for _, attribute in { "Posture", "CombatState" } do
			table.insert(created.connections, model:GetAttributeChangedSignal(attribute):Connect(refresh))
		end
		local humanoid = model:FindFirstChildOfClass("Humanoid")
		if humanoid then
			table.insert(created.connections, humanoid.HealthChanged:Connect(refresh))
		end
		table.insert(
			created.connections,
			model.AncestryChanged:Connect(function()
				if not model:IsDescendantOf(workspace) then
					removeEnemy(model)
				end
			end)
		)
		refreshEnemy(model, created)
		entry = created
	end

	local current = entry :: EnemyEntry
	current.hideToken += 1
	local token = current.hideToken
	local hold = linger or ENEMY_BAR_LINGER
	if hold == math.huge then
		return -- the lock-on target: shown until the lock moves on (task.delay can't take inf)
	end
	task.delay(hold, function()
		if enemies[model] == current and current.hideToken == token and LockOn.target() ~= model then
			if model:GetAttribute("CombatState") ~= "Broken" then
				removeEnemy(model)
			end
		end
	end)
end

---------------------------------------------------------------------------------------

local function buildScreen()
	screen = Instance.new("ScreenGui")
	screen.Name = "CombatHUD"
	screen.ResetOnSpawn = false
	screen.IgnoreGuiInset = true
	screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	-- Phones get the HUD at their own scale (UI.hudScale); full-screen pieces still fill.
	local fit = Instance.new("UIScale")
	fit.Name = "Fit"
	fit.Parent = screen
	local function refit()
		fit.Scale = Kit.hudScale()
	end
	workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(refit)
	player:GetAttributeChangedSignal("UIViewport"):Connect(refit)
	refit()

	-- A light cinematic vignette over the whole frame, and a red one for perilous flashes.
	image(screen, UI.Vignette, { Size = UDim2.fromScale(1, 1), ImageTransparency = 0.45, ZIndex = 0 })
	perilFlash = image(screen, UI.Vignette, {
		Size = UDim2.fromScale(1, 1),
		ImageColor3 = Color3.fromRGB(150, 0, 0),
		ImageTransparency = 1,
		ZIndex = 0,
	})
	perfectFlash = image(screen, UI.Vignette, {
		Size = UDim2.fromScale(1, 1),
		ImageColor3 = Color3.fromRGB(255, 244, 220),
		ImageTransparency = 1,
		ZIndex = 0,
	})

	-- Bottom-left: gourd, vitality, stamina. (CanvasGroups render to textures, so each is
	-- only as big as what it holds.)
	ownGroup = Instance.new("CanvasGroup")
	ownGroup.BackgroundTransparency = 1
	ownGroup.AnchorPoint = Vector2.new(0, 1)
	ownGroup.Position = UDim2.new(0, 28, 1, -44)
	ownGroup.Size = UDim2.fromOffset(390, 52)
	ownGroup.Parent = screen

	gourdIcon = image(ownGroup, UI.Gourd, {
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.fromScale(0, 0.5),
		Size = UDim2.fromOffset(42, 42),
	})
	-- The count sits at the gourd's foot in the number face, stroked so it reads on sand.
	gourdCount = Kit.label("number", {
		Name = "GourdCount",
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, 8, 1, 6),
		Size = UDim2.fromOffset(22, 22),
		TextSize = 18,
		TextColor3 = Kit.Theme.Bone,
		TextStrokeColor3 = Kit.Theme.Ink,
		TextStrokeTransparency = 0.2,
		Text = "3",
		ZIndex = 2,
	}, gourdIcon)

	vitality =
		makeBar(ownGroup, Vector2.new(320, 8), UDim2.new(0, 48, 0.5, 0), Vector2.new(0, 0.5), false, true, CRIMSON)

	staminaGroup = Instance.new("CanvasGroup")
	staminaGroup.BackgroundTransparency = 1
	staminaGroup.AnchorPoint = Vector2.new(0, 1)
	staminaGroup.Position = UDim2.new(0, 76, 1, -26)
	staminaGroup.Size = UDim2.fromOffset(290, 26)
	staminaGroup.GroupTransparency = 1
	staminaGroup.Visible = false
	staminaGroup.Parent = screen
	stamina =
		makeBar(staminaGroup, Vector2.new(260, 4), UDim2.fromScale(0, 0.5), Vector2.new(0, 0.5), false, false, STAMINA)

	-- Posture, bottom-centre: bloom, framed bar, and the ornament over its middle.
	postureGroup = Instance.new("CanvasGroup")
	postureGroup.BackgroundTransparency = 1
	postureGroup.AnchorPoint = Vector2.new(0.5, 1)
	postureGroup.Position = UDim2.new(0.5, 0, 1, -POSTURE_BOTTOM)
	postureGroup.Size = UDim2.fromOffset(520, 72)
	postureGroup.GroupTransparency = 1
	postureGroup.Visible = false
	postureGroup.Parent = screen
	postureGlow = image(postureGroup, UI.BarGlow, {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(520, 72),
		ImageTransparency = 1,
	})
	posture = makeBar(
		postureGroup,
		Vector2.new(400, 8),
		UDim2.fromScale(0.5, 0.5),
		Vector2.new(0.5, 0.5),
		true,
		false,
		POSTURE_LOW
	)
	image(postureGroup, UI.PostureOrnament, {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(124, 38),
		ZIndex = 3,
	})

	-- A quiet controls reminder: key-cap chips (keyboard only) that fade away.
	controlsHint = Instance.new("CanvasGroup")
	controlsHint.Name = "ControlsHint"
	controlsHint.AnchorPoint = Vector2.new(1, 1)
	controlsHint.Position = UDim2.new(1, -20, 1, -20)
	controlsHint.Size = UDim2.fromOffset(420, 4 * 32)
	controlsHint.BackgroundTransparency = 1
	controlsHint.GroupTransparency = 1
	controlsHint.Visible = false
	controlsHint.Parent = screen
	Kit.new("UIListLayout", {
		Padding = UDim.new(0, 6),
		HorizontalAlignment = Enum.HorizontalAlignment.Right,
		VerticalAlignment = Enum.VerticalAlignment.Bottom,
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, controlsHint)
	local rows = {
		{ { "Mouse", "Slash" }, { "F", "Deflect · hold to guard" } },
		{ { "Q", "Dodge · into a thrust: Mikiri" } },
		{ { "E", "Perilous thrust" }, { "C", "Sweep" } },
		{ { "G", "Gourd" }, { "R", "Lock on" } },
	}
	for i, row in rows do
		local line = Kit.new("Frame", {
			Name = `Row{i}`,
			LayoutOrder = i,
			Size = UDim2.new(1, 0, 0, 26),
			BackgroundTransparency = 1,
		}, controlsHint)
		Kit.new("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			HorizontalAlignment = Enum.HorizontalAlignment.Right,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			Padding = UDim.new(0, 6),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}, line)
		for j, pair in row do
			Kit.keycap(line, pair[1], { LayoutOrder = j * 2 - 1 })
			Kit.label("label", {
				LayoutOrder = j * 2,
				Size = UDim2.fromOffset(0, 26),
				AutomaticSize = Enum.AutomaticSize.X,
				TextSize = 14,
				TextStrokeColor3 = Kit.Theme.Ink,
				TextStrokeTransparency = 0.35,
				Text = pair[2] .. (if j < #row then "   " else ""),
			}, line)
		end
	end

	screen.Parent = player:WaitForChild("PlayerGui")
end

local function onCombatEvent(kind: string, data: { [string]: any })
	local character = player.Character
	if not character then
		return
	end
	local attacker: Model? = data.attacker
	local defender: Model? = data.defender
	if kind == "Deathblow" and attacker == character and defender then
		if data.lethal == false then
			CombatHUD.splash(UI.KanjiSlay, "Deathblow  ·  they still stand", DEATH_RED, 1.1)
			showEnemy(defender)
		else
			CombatHUD.splash(UI.KanjiSlay, "Deathblow", DEATH_RED, 1.1)
			removeEnemy(defender)
		end
	elseif kind == "CutDown" and data.model == character then
		CombatHUD.splash(UI.KanjiDeath, "Cut down  ·  you will rise", DEATH_RED, 1.8)
	elseif kind == "Resurrected" and data.model == character then
		CombatHUD.splash(UI.KanjiResurrect, "Resurrection", Color3.fromRGB(235, 70, 60), 1.6)
	elseif kind == "Died" and data.model == character then
		CombatHUD.splash(UI.KanjiDeath, "Death", DEATH_RED, 2.6)
	elseif (kind == "Died" or kind == "CutDown") and data.model then
		removeEnemy(data.model)
	elseif attacker and defender then
		-- Any exchange involving you brings up the other fighter's bars.
		if attacker == character then
			showEnemy(defender)
		elseif defender == character then
			showEnemy(attacker)
		end
	end
	if kind == "PostureBroken" and data.model and data.model ~= character then
		showEnemy(data.model, 2)
	end
end

-- Roblox's own health bar (top-right, green to red) only repeats our vitality bar, and stayed
-- up over the match report: off for good. SetCoreGuiEnabled can fail while the CoreGui loads.
local function hideCoreHealth()
	task.spawn(function()
		for _ = 1, 10 do
			if pcall(StarterGui.SetCoreGuiEnabled, StarterGui, Enum.CoreGuiType.Health, false) then
				return
			end
			task.wait(0.5)
		end
	end)
end

function CombatHUD.start()
	hideCoreHealth()
	buildScreen()
	-- Settings: turning the reminder off hides it at once.
	player:GetAttributeChangedSignal("SettingControlsHint"):Connect(function()
		if player:GetAttribute("SettingControlsHint") == false then
			hintToken += 1
			fadeGroup(controlsHint, 0, 1)
		end
	end)

	player.CharacterAdded:Connect(trackCharacter)
	if player.Character then
		task.spawn(trackCharacter, player.Character)
	end

	combatEvent.OnClientEvent:Connect(onCombatEvent)
	LockOn.changed(function(target: Model?)
		if target then
			showEnemy(target, math.huge)
		end
		for model, entry in enemies do
			if model ~= target then
				entry.hideToken += 1
				local token = entry.hideToken
				task.delay(ENEMY_BAR_LINGER, function()
					if enemies[model] == entry and entry.hideToken == token and LockOn.target() ~= model then
						removeEnemy(model)
					end
				end)
			end
		end
	end)

	CollectionService:GetInstanceRemovedSignal(Types.Tag):Connect(function(instance)
		if instance:IsA("Model") then
			removeEnemy(instance)
		end
	end)
end

return CombatHUD
