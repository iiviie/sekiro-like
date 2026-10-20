--!strict
-- Sekiro-style HUD built on the art in Shared/Assets.UI:
--   bottom-left   healing gourd, vitality (crimson, with a pale trail of recent damage)
--                 and stamina (muted gold) in soft lacquered frames
--   bottom-centre posture: grows from the ornament outwards, heats from amber to red
--                 with a bloom underneath, and fades away while empty
--   enemies       posture and vitality over the head of whoever you're fighting, and the
--                 red deathblow dot when they break
--   splashes      brush kanji on an ink band (死, 忍殺, round banners)
--   screen        a light cinematic vignette and a red edge flash for perilous attacks
--
-- Nothing runs per frame: bars update from attribute and health signals and animate with
-- tweens, and enemy bars exist only while relevant.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Assets = require(ReplicatedStorage.Shared.Assets)
local LockOn = require(script.Parent.LockOn)
local Types = require(ReplicatedStorage.Shared.Types)

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

local CombatHUD = {}

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
local controlsHint: TextLabel
local enemies: { [Model]: EnemyEntry } = {}

local function tween(instance: Instance, time: number, goal: { [string]: any }, style: Enum.EasingStyle?)
	local info = TweenInfo.new(time, style or Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local t = TweenService:Create(instance, info, goal)
	t:Play()
	return t
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
	tween(postureGroup, 0.3, { GroupTransparency = if visible then 0 else 1 })
end

local function refreshStamina(model: Model)
	local ratio = ratioOf(model, "Stamina", "StaminaMax")
	if not ratio then
		return
	end
	setBar(stamina, ratio)
	stamina.fill.ImageColor3 = if ratio < 0.2 then STAMINA_LOW else STAMINA
	-- Quiet while full, brighter while it's being spent and recovering.
	tween(staminaGroup, 0.3, { GroupTransparency = if ratio >= 0.999 then 0.45 else 0 })
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
	postureGroup.GroupTransparency = 1
	ownGroup.GroupTransparency = 0
	staminaGroup.GroupTransparency = 0.45
	onHealth()
	table.insert(characterConnections, humanoid.HealthChanged:Connect(onHealth))
	table.insert(
		characterConnections,
		humanoid.Died:Connect(function()
			tween(ownGroup, 0.6, { GroupTransparency = 1 })
			tween(staminaGroup, 0.6, { GroupTransparency = 1 })
			tween(postureGroup, 0.6, { GroupTransparency = 1 })
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

-- A brush-kanji banner on an ink band, with a small spaced-caps subtitle.
function CombatHUD.splash(kanjiImage: string, subtitle: string, color: Color3, hold: number)
	local group = Instance.new("CanvasGroup")
	group.AnchorPoint = Vector2.new(0.5, 0.5)
	group.Position = UDim2.fromScale(0.5, 0.46)
	group.Size = UDim2.fromOffset(1000, 380)
	group.BackgroundTransparency = 1
	group.GroupTransparency = 1
	group.ZIndex = 50
	group.Parent = screen

	image(group, UI.InkBand, {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(980, 250),
		ImageTransparency = 0.12,
	})
	local glyph = image(group, kanjiImage, {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.45),
		Size = UDim2.fromScale(1.02, 0.7),
		ScaleType = Enum.ScaleType.Fit,
		ImageColor3 = color,
	})
	local caption = Instance.new("TextLabel")
	caption.AnchorPoint = Vector2.new(0.5, 0)
	caption.Position = UDim2.fromScale(0.5, 0.76)
	caption.Size = UDim2.fromOffset(700, 26)
	caption.BackgroundTransparency = 1
	caption.Font = FONT
	caption.Text = (string.upper(subtitle):gsub("(.)", "%1 ")):sub(1, -2)
	caption.TextSize = 20
	caption.TextColor3 = PARCHMENT
	caption.TextTransparency = 0.1
	caption.Parent = group

	tween(group, 0.4, { GroupTransparency = 0 })
	tween(glyph, 1.4, { Size = UDim2.fromScale(0.9, 0.62) }, Enum.EasingStyle.Sine)
	task.delay(hold, function()
		tween(group, 0.9, { GroupTransparency = 1 })
		task.wait(0.95)
		group:Destroy()
	end)
end

-- Red flash at the screen's edges: a perilous attack is coming at you.
function CombatHUD.flashPeril()
	perilFlash.ImageTransparency = 0.1
	tween(perilFlash, 0.9, { ImageTransparency = 1 }, Enum.EasingStyle.Sine)
end

-- In the lobby the bottom of the screen belongs to PLAY and the nav bar: hide your own
-- vitality and stamina (nothing there can hurt you unless you opt into sparring) and lift
-- the posture bar above PLAY, where it still teaches the trainer's rhythm.
function CombatHUD.setLobbyMode(on: boolean)
	if not ownGroup then
		return
	end
	ownGroup.Visible = not on
	staminaGroup.Visible = not on
	postureGroup.Position = if on then UDim2.new(0.5, 0, 1, -260) else UDim2.new(0.5, 0, 1, -100)
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

-- Shows the controls reminder for a while, then fades it (called once you enter).
function CombatHUD.showControls()
	if Players.LocalPlayer:GetAttribute("SettingControlsHint") == false then
		return
	end
	controlsHint.TextTransparency = 0.25
	task.delay(CONTROLS_HINT_TIME, function()
		tween(controlsHint, 2, { TextTransparency = 1 })
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

local function makeMarker(model: Model): BillboardGui
	local torso = model:FindFirstChild("UpperTorso") or model:FindFirstChild("HumanoidRootPart")
	local marker = Instance.new("BillboardGui")
	marker.Name = "DeathblowMarker"
	marker.Adornee = torso :: BasePart?
	marker.AlwaysOnTop = true
	marker.LightInfluence = 0
	marker.Size = UDim2.fromOffset(64, 64)
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
		gui.Size = UDim2.fromOffset(200, 50)
		gui.StudsOffset = Vector3.new(0, 2.9, 0)
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
	task.delay(linger or ENEMY_BAR_LINGER, function()
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
	ownGroup.Position = UDim2.new(0, 36, 1, -60)
	ownGroup.Size = UDim2.fromOffset(470, 52)
	ownGroup.Parent = screen

	gourdIcon = image(ownGroup, UI.Gourd, {
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.fromScale(0, 0.5),
		Size = UDim2.fromOffset(42, 42),
	})
	gourdCount = Instance.new("TextLabel")
	gourdCount.BackgroundTransparency = 1
	gourdCount.AnchorPoint = Vector2.new(1, 1)
	gourdCount.Position = UDim2.new(1, 6, 1, 4)
	gourdCount.Size = UDim2.fromOffset(20, 20)
	gourdCount.Font = FONT
	gourdCount.TextSize = 20
	gourdCount.TextColor3 = PARCHMENT
	gourdCount.TextStrokeTransparency = 0.4
	gourdCount.Text = "3"
	gourdCount.Parent = gourdIcon

	vitality =
		makeBar(ownGroup, Vector2.new(380, 8), UDim2.new(0, 48, 0.5, 0), Vector2.new(0, 0.5), false, true, CRIMSON)

	staminaGroup = Instance.new("CanvasGroup")
	staminaGroup.BackgroundTransparency = 1
	staminaGroup.AnchorPoint = Vector2.new(0, 1)
	staminaGroup.Position = UDim2.new(0, 84, 1, -42)
	staminaGroup.Size = UDim2.fromOffset(330, 26)
	staminaGroup.GroupTransparency = 0.45
	staminaGroup.Parent = screen
	stamina =
		makeBar(staminaGroup, Vector2.new(300, 4), UDim2.fromScale(0, 0.5), Vector2.new(0, 0.5), false, false, STAMINA)

	-- Posture, bottom-centre: bloom, framed bar, and the ornament over its middle.
	postureGroup = Instance.new("CanvasGroup")
	postureGroup.BackgroundTransparency = 1
	postureGroup.AnchorPoint = Vector2.new(0.5, 1)
	postureGroup.Position = UDim2.new(0.5, 0, 1, -100)
	postureGroup.Size = UDim2.fromOffset(560, 80)
	postureGroup.GroupTransparency = 1
	postureGroup.Parent = screen
	postureGlow = image(postureGroup, UI.BarGlow, {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(560, 80),
		ImageTransparency = 1,
	})
	posture = makeBar(
		postureGroup,
		Vector2.new(440, 8),
		UDim2.fromScale(0.5, 0.5),
		Vector2.new(0.5, 0.5),
		true,
		false,
		POSTURE_LOW
	)
	image(postureGroup, UI.PostureOrnament, {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(140, 42),
		ZIndex = 3,
	})

	-- A quiet controls reminder that fades away.
	controlsHint = Instance.new("TextLabel")
	controlsHint.AnchorPoint = Vector2.new(1, 1)
	controlsHint.Position = UDim2.new(1, -30, 1, -26)
	controlsHint.Size = UDim2.fromOffset(470, 110)
	controlsHint.BackgroundTransparency = 1
	controlsHint.Font = FONT
	controlsHint.TextSize = 17
	controlsHint.LineHeight = 1.15
	controlsHint.TextXAlignment = Enum.TextXAlignment.Right
	controlsHint.TextYAlignment = Enum.TextYAlignment.Bottom
	controlsHint.TextColor3 = PARCHMENT
	controlsHint.TextTransparency = 1
	controlsHint.Text = "Slash   Left Mouse        Deflect · Guard   F\n"
		.. "Dodge   Q   — dash into a thrust to Mikiri\n"
		.. "Perilous Thrust   E        Sweep   C\n"
		.. "Healing Gourd   G        Lock On   R"
	controlsHint.Parent = screen

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
			CombatHUD.splash(UI.KanjiExecution, "Deathblow  ·  they still stand", DEATH_RED, 1.1)
			showEnemy(defender)
		else
			CombatHUD.splash(UI.KanjiExecution, "Shinobi Execution", DEATH_RED, 1.1)
			removeEnemy(defender)
		end
	elseif kind == "Died" and data.model == character then
		CombatHUD.splash(UI.KanjiDeath, "Death", DEATH_RED, 2.6)
	elseif kind == "Died" and data.model then
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

function CombatHUD.start()
	buildScreen()

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
