--!strict
-- Sekiro / Dark Souls style HUD: a thin crimson vitality bar bottom-left with a pale
-- trail showing recent damage, a posture bar bottom-centre that grows from the middle
-- and hides when empty, enemy bars only for whoever you're fighting, a red deathblow
-- marker on broken enemies, and the 死 / 忍殺 splashes.
--
-- Performance: nothing runs per frame. Bars update from attribute and health change
-- signals and animate with tweens; enemy bars exist only while relevant.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local LockOn = require(script.Parent.LockOn)
local Types = require(ReplicatedStorage.Shared.Types)

local combatEvent = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("CombatEvent") :: RemoteEvent
local player = Players.LocalPlayer

local FONT = Enum.Font.Garamond
local INK = Color3.fromRGB(12, 10, 9)
local BRONZE = Color3.fromRGB(150, 122, 82)
local PARCHMENT = Color3.fromRGB(232, 222, 200)
local CRIMSON_TOP = Color3.fromRGB(196, 38, 32)
local CRIMSON_BOTTOM = Color3.fromRGB(112, 12, 14)
local TRAIL = Color3.fromRGB(226, 208, 170)
local POSTURE_LOW = Color3.fromRGB(255, 196, 92)
local POSTURE_HIGH = Color3.fromRGB(232, 72, 30)
local DEATHBLOW_RED = Color3.fromRGB(255, 40, 40)

local ENEMY_BAR_LINGER = 4 -- seconds an enemy's bars stay up after you last traded blows
local CONTROLS_HINT_TIME = 14

local CombatHUD = {}

type Bar = { root: Frame, fill: Frame, trail: Frame?, centered: boolean }
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
local posture: Bar
local postureGroup: CanvasGroup
local ownGroup: CanvasGroup
local gourdLabel: TextLabel
local enemies: { [Model]: EnemyEntry } = {}

local function tween(instance: Instance, time: number, goal: { [string]: any }, style: Enum.EasingStyle?)
	local info = TweenInfo.new(time, style or Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local t = TweenService:Create(instance, info, goal)
	t:Play()
	return t
end

local function stroke(parent: GuiObject, color: Color3, thickness: number, transparency: number)
	local s = Instance.new("UIStroke")
	s.Color = color
	s.Thickness = thickness
	s.Transparency = transparency
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.Parent = parent
end

-- A thin framed bar. Centred bars (posture) grow from the middle outwards.
local function makeBar(
	parent: Instance,
	size: UDim2,
	position: UDim2,
	anchor: Vector2,
	centered: boolean,
	withTrail: boolean
): Bar
	local root = Instance.new("Frame")
	root.BackgroundColor3 = INK
	root.BackgroundTransparency = 0.35
	root.BorderSizePixel = 0
	root.Size = size
	root.Position = position
	root.AnchorPoint = anchor
	stroke(root, BRONZE, 1, 0.45)
	root.Parent = parent

	local function inner(color: Color3, z: number): Frame
		local f = Instance.new("Frame")
		f.BorderSizePixel = 0
		f.BackgroundColor3 = color
		f.AnchorPoint = if centered then Vector2.new(0.5, 0) else Vector2.zero
		f.Position = if centered then UDim2.fromScale(0.5, 0) else UDim2.fromScale(0, 0)
		f.Size = UDim2.fromScale(if centered then 0 else 1, 1)
		f.ZIndex = z
		f.Parent = root
		return f
	end

	local trail = if withTrail then inner(TRAIL, 1) else nil
	local fill = inner(Color3.new(1, 1, 1), 2)
	return { root = root, fill = fill, trail = trail, centered = centered }
end

local function gradient(frame: Frame, top: Color3, bottom: Color3)
	local g = Instance.new("UIGradient")
	g.Color = ColorSequence.new(top, bottom)
	g.Rotation = 90
	g.Parent = frame
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
			task.delay(0.45, function()
				if bar.fill.Size.X.Scale <= ratio + 1e-3 then
					tween(trail, 0.5, { Size = bar.fill.Size }, Enum.EasingStyle.Sine)
				end
			end)
		end
	end
end

local function postureColor(ratio: number): Color3
	return POSTURE_LOW:Lerp(POSTURE_HIGH, ratio)
end

local function diamond(parent: Instance, size: number, position: UDim2, color: Color3): Frame
	local d = Instance.new("Frame")
	d.AnchorPoint = Vector2.new(0.5, 0.5)
	d.Position = position
	d.Size = UDim2.fromOffset(size, size)
	d.Rotation = 45
	d.BackgroundColor3 = color
	d.BorderSizePixel = 0
	d.ZIndex = 3
	stroke(d, BRONZE, 1, 0.2)
	d.Parent = parent
	return d
end

---------------------------------------------------------------------------------------
-- Own bars

local characterConnections: { RBXScriptConnection } = {}

local function refreshPosture(model: Model)
	local max = model:GetAttribute("PostureMax")
	local value = model:GetAttribute("Posture")
	if typeof(max) ~= "number" or typeof(value) ~= "number" or max <= 0 then
		return
	end
	local ratio = value / max
	local broken = model:GetAttribute("CombatState") == "Broken"
	setBar(posture, ratio)
	posture.fill.BackgroundColor3 = if broken then PARCHMENT else postureColor(ratio)
	-- Like Sekiro, the posture bar only shows while it has something to say.
	local visible = ratio > 0.01 or broken
	tween(postureGroup, 0.25, { GroupTransparency = if visible then 0 else 1 })
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
	setBar(posture, 0, true)
	postureGroup.GroupTransparency = 1
	onHealth()
	table.insert(characterConnections, humanoid.HealthChanged:Connect(onHealth))
	-- Your own bars fade out once you fall, and return with the next body.
	ownGroup.GroupTransparency = 0
	table.insert(
		characterConnections,
		humanoid.Died:Connect(function()
			tween(ownGroup, 0.6, { GroupTransparency = 1 })
			tween(postureGroup, 0.6, { GroupTransparency = 1 })
		end)
	)
	for _, attribute in { "Posture", "CombatState" } do
		table.insert(
			characterConnections,
			character:GetAttributeChangedSignal(attribute):Connect(function()
				refreshPosture(character)
			end)
		)
	end
	refreshPosture(character)
	local function refreshGourds()
		local count = character:GetAttribute("Gourds")
		gourdLabel.Text = `瓢 {if typeof(count) == "number" then count else 0}`
		gourdLabel.TextTransparency = if count == 0 then 0.6 else 0
	end
	table.insert(characterConnections, character:GetAttributeChangedSignal("Gourds"):Connect(refreshGourds))
	refreshGourds()
end

---------------------------------------------------------------------------------------
-- Splashes

-- A centred kanji banner with a subtitle, framed by a dark band (used for death,
-- executions, and round banners).
function CombatHUD.splash(kanji: string, subtitle: string, color: Color3, hold: number)
	local frame = Instance.new("CanvasGroup")
	frame.Size = UDim2.fromScale(1, 1)
	frame.BackgroundColor3 = Color3.new(0, 0, 0)
	frame.BackgroundTransparency = 1
	frame.GroupTransparency = 1
	frame.ZIndex = 50
	frame.Parent = screen

	-- A dark band across the middle of the screen, the way Souls games frame their banners.
	local band = Instance.new("Frame")
	band.AnchorPoint = Vector2.new(0.5, 0.5)
	band.Position = UDim2.fromScale(0.5, 0.5)
	band.Size = UDim2.new(1, 0, 0, 220)
	band.BackgroundColor3 = Color3.new(0, 0, 0)
	band.BackgroundTransparency = 0.25
	band.BorderSizePixel = 0
	local fade = Instance.new("UIGradient")
	fade.Rotation = 90
	fade.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.3, 0),
		NumberSequenceKeypoint.new(0.7, 0),
		NumberSequenceKeypoint.new(1, 1),
	})
	fade.Parent = band
	band.Parent = frame

	local glyph = Instance.new("TextLabel")
	glyph.AnchorPoint = Vector2.new(0.5, 0.5)
	glyph.Position = UDim2.fromScale(0.5, 0.47)
	glyph.Size = UDim2.fromOffset(600, 170)
	glyph.BackgroundTransparency = 1
	glyph.Font = FONT
	glyph.Text = kanji
	glyph.TextScaled = true
	glyph.TextColor3 = color
	glyph.TextStrokeColor3 = Color3.new(0, 0, 0)
	glyph.TextStrokeTransparency = 0.4
	glyph.Parent = frame

	local caption = Instance.new("TextLabel")
	caption.AnchorPoint = Vector2.new(0.5, 0)
	caption.Position = UDim2.new(0.5, 0, 0.47, 92)
	caption.Size = UDim2.fromOffset(600, 26)
	caption.BackgroundTransparency = 1
	caption.Font = FONT
	caption.Text = subtitle
	caption.TextSize = 24
	caption.TextColor3 = PARCHMENT
	caption.TextTransparency = 0.15
	caption.Parent = frame

	glyph.Size = UDim2.fromOffset(660, 190)
	tween(frame, 0.35, { GroupTransparency = 0 })
	tween(glyph, 1.2, { Size = UDim2.fromOffset(600, 170) }, Enum.EasingStyle.Sine)
	task.delay(hold, function()
		tween(frame, 0.8, { GroupTransparency = 1 })
		task.wait(0.85)
		frame:Destroy()
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
	local max = model:GetAttribute("PostureMax")
	local value = model:GetAttribute("Posture")
	local broken = model:GetAttribute("CombatState") == "Broken"
	if typeof(max) == "number" and typeof(value) == "number" and max > 0 then
		setBar(entry.posture, value / max)
		entry.posture.fill.BackgroundColor3 = if broken then PARCHMENT else postureColor(value / max)
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
	marker.Size = UDim2.fromOffset(46, 46)
	marker.LightInfluence = 0
	marker.Enabled = false

	-- Sekiro's red deathblow dot: a bright core inside a soft pulsing halo.
	local halo = Instance.new("Frame")
	halo.AnchorPoint = Vector2.new(0.5, 0.5)
	halo.Position = UDim2.fromScale(0.5, 0.5)
	halo.Size = UDim2.fromScale(1, 1)
	halo.BackgroundColor3 = DEATHBLOW_RED
	halo.BackgroundTransparency = 0.65
	local haloCorner = Instance.new("UICorner")
	haloCorner.CornerRadius = UDim.new(0.5, 0)
	haloCorner.Parent = halo
	halo.Parent = marker

	local core = Instance.new("Frame")
	core.AnchorPoint = Vector2.new(0.5, 0.5)
	core.Position = UDim2.fromScale(0.5, 0.5)
	core.Size = UDim2.fromScale(0.36, 0.36)
	core.BackgroundColor3 = Color3.fromRGB(255, 120, 110)
	local coreCorner = Instance.new("UICorner")
	coreCorner.CornerRadius = UDim.new(0.5, 0)
	coreCorner.Parent = core
	stroke(core, DEATHBLOW_RED, 2, 0)
	core.Parent = marker

	local pulse = TweenService:Create(
		halo,
		TweenInfo.new(0.45, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
		{ Size = UDim2.fromScale(0.6, 0.6), BackgroundTransparency = 0.35 }
	)
	pulse:Play()

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
		gui.Size = UDim2.fromOffset(150, 20)
		gui.StudsOffset = Vector3.new(0, 2.6, 0)
		gui.MaxDistance = 90

		local postureBar =
			makeBar(gui, UDim2.new(1, 0, 0, 6), UDim2.fromScale(0.5, 0), Vector2.new(0.5, 0), true, false)
		local vitalityBar =
			makeBar(gui, UDim2.new(0.72, 0, 0, 4), UDim2.new(0.5, 0, 0, 11), Vector2.new(0.5, 0), false, true)
		gradient(vitalityBar.fill, CRIMSON_TOP, CRIMSON_BOTTOM)
		diamond(postureBar.root, 6, UDim2.fromScale(0.5, 0.5), INK)
		gui.Parent = player:WaitForChild("PlayerGui")

		entry = {
			gui = gui,
			posture = postureBar,
			vitality = vitalityBar,
			marker = makeMarker(model),
			hideToken = 0,
			connections = {},
		}
		local created = entry :: EnemyEntry
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

	-- Vitality, bottom-left.
	-- (CanvasGroups render to a texture, so this one is only as big as the bar.)
	ownGroup = Instance.new("CanvasGroup")
	ownGroup.BackgroundTransparency = 1
	ownGroup.AnchorPoint = Vector2.new(0, 1)
	ownGroup.Position = UDim2.new(0, 40, 1, -48)
	ownGroup.Size = UDim2.fromOffset(420, 24)
	ownGroup.Parent = screen
	vitality = makeBar(ownGroup, UDim2.fromOffset(300, 9), UDim2.new(0, 24, 0.5, 0), Vector2.new(0, 0.5), false, true)
	gradient(vitality.fill, CRIMSON_TOP, CRIMSON_BOTTOM)
	diamond(ownGroup, 14, UDim2.new(0, 12, 0.5, 0), CRIMSON_BOTTOM)

	-- Healing gourd charges, right of the vitality bar.
	gourdLabel = Instance.new("TextLabel")
	gourdLabel.BackgroundTransparency = 1
	gourdLabel.AnchorPoint = Vector2.new(0, 0.5)
	gourdLabel.Position = UDim2.new(0, 334, 0.5, 0)
	gourdLabel.Size = UDim2.fromOffset(80, 22)
	gourdLabel.Font = FONT
	gourdLabel.TextSize = 19
	gourdLabel.TextXAlignment = Enum.TextXAlignment.Left
	gourdLabel.TextColor3 = PARCHMENT
	gourdLabel.TextStrokeTransparency = 0.6
	gourdLabel.Text = "瓢 3"
	gourdLabel.Parent = ownGroup

	-- Posture, bottom-centre, hidden while empty.
	postureGroup = Instance.new("CanvasGroup")
	postureGroup.BackgroundTransparency = 1
	postureGroup.AnchorPoint = Vector2.new(0.5, 1)
	postureGroup.Position = UDim2.new(0.5, 0, 1, -96)
	postureGroup.Size = UDim2.fromOffset(440, 18)
	postureGroup.GroupTransparency = 1
	postureGroup.Parent = screen
	posture =
		makeBar(postureGroup, UDim2.new(1, -20, 0, 7), UDim2.fromScale(0.5, 0.5), Vector2.new(0.5, 0.5), true, false)
	diamond(postureGroup, 10, UDim2.fromScale(0.5, 0.5), INK)

	-- A quiet controls reminder that fades away.
	local hint = Instance.new("TextLabel")
	hint.AnchorPoint = Vector2.new(1, 1)
	hint.Position = UDim2.new(1, -28, 1, -24)
	hint.Size = UDim2.fromOffset(460, 96)
	hint.BackgroundTransparency = 1
	hint.Font = FONT
	hint.TextSize = 17
	hint.TextXAlignment = Enum.TextXAlignment.Right
	hint.TextYAlignment = Enum.TextYAlignment.Bottom
	hint.TextColor3 = PARCHMENT
	hint.TextTransparency = 0.2
	hint.TextStrokeTransparency = 0.7
	hint.Text = "Slash  —  Left Mouse\nDeflect · Guard  —  F\nDodge  —  Q   (dash into a thrust: Mikiri)\n"
		.. "Perilous Thrust  —  E      Sweep  —  C\nHealing Gourd  —  G      Lock On  —  R"
	hint.Parent = screen
	task.delay(CONTROLS_HINT_TIME, function()
		tween(hint, 2, { TextTransparency = 1, TextStrokeTransparency = 1 })
	end)

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
		CombatHUD.splash("忍殺", "Shinobi Execution", DEATHBLOW_RED, 1.1)
		removeEnemy(defender)
	elseif kind == "Died" and data.model == character then
		CombatHUD.splash("死", "Death", DEATHBLOW_RED, 2.6)
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

	-- Enemies tagged later (respawns) just need cleanup on removal; bars are created on demand.
	CollectionService:GetInstanceRemovedSignal(Types.Tag):Connect(function(instance)
		if instance:IsA("Model") then
			removeEnemy(instance)
		end
	end)
end

return CombatHUD
