--!strict
-- Boss trials on screen: the shrine's boss picker, the boss's name banner and bars along the
-- bottom of the screen (vitality, posture growing from the centre, remaining lives), phase and
-- lesson banners, and the result. Driven by ReplicatedStorage.Remotes.Boss (server/
-- BossService) and the boss model's attributes.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Assets = require(ReplicatedStorage.Shared.Assets)
local Bosses = require(ReplicatedStorage.Shared.Bosses)
local BossVisuals = require(script.Parent.BossVisuals)
local CombatHUD = require(script.Parent.CombatHUD)
local LockOn = require(script.Parent.LockOn)
local Panels = require(script.Parent.Panels)
local Toasts = require(script.Parent.Toasts)
local UI = require(script.Parent.UI)

local player = Players.LocalPlayer

local BossHUD = {}

local remote: RemoteEvent
local screen: ScreenGui
local picker: Frame
local list: ScrollingFrame
local statusLabel: TextLabel
local cancelButton: TextButton
local pickerFit: UIScale
local pendingAt: number? = nil -- os.clock() of a pick still waiting for the server's answer
local inLine = false
local pickerCallbacks: { (open: boolean) -> () } = {}
local fightToken = 0
local bar: Frame
local nameLabel: TextLabel
local subLabel: TextLabel
local livesRow: Frame
local kanjiName: ImageLabel
local challengeButton: TextButton
local selectedId: string? = nil
local pickEntries: { [string]: { [string]: any } } = {}
local setStatus: (text: string?, color: Color3?) -> ()
local vitalityFill: Frame
local postureFill: Frame
local deathblowDot: ImageLabel
local banner: TextLabel
local lesson: TextLabel
local watched: Model? = nil
local connections: { RBXScriptConnection } = {}
local fightAt = 0
local counting = false
local bannerToken = 0

local PENDING_TIMEOUT = 5 -- seconds before an unanswered pick says so
local PICK_REACH = 10 -- studs off the pad edge before the picker closes (server allows 12)
local THEME = UI.Theme
local CHROME = (Assets.UI :: any).Chrome or {}
local VITALITY = Color3.fromRGB(176, 30, 28)
local POSTURE_LOW = Color3.fromRGB(255, 204, 96)
local POSTURE_HIGH = Color3.fromRGB(214, 44, 22)

local function now(): number
	return workspace:GetServerTimeNow()
end

-- Builder Sans has no star glyph: say it in words (the picker cards draw gold tomoe).
local function stars(count: number): string
	if count <= 0 then
		return "Tutorial"
	end
	return `Difficulty {count}/3`
end

-- A row of gold tomoe for a boss's difficulty, over a card's rarity caption.
local function tomoeRow(card: GuiObject, count: number)
	local caption = card:FindFirstChild("Rarity")
	if not caption or not caption:IsA("TextLabel") then
		return
	end
	caption.Text = ""
	local row = UI.new("Frame", {
		Name = "Tomoe",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, caption.Position.Y.Scale, caption.Position.Y.Offset),
		Size = UDim2.fromOffset(3 * 22, 18),
		BackgroundTransparency = 1,
		ZIndex = 5,
	}, card)
	UI.new("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
		Padding = UDim.new(0, 4),
	}, row)
	for i = 1, 3 do
		local img = UI.new("ImageLabel", {
			Size = UDim2.fromOffset(18, 18),
			BackgroundTransparency = 1,
			ImageTransparency = if i <= count then 0 else 0.7,
			ZIndex = 5,
		}, row)
		if not UI.art(img, "Tomoe") then
			img.BackgroundTransparency = if i <= count then 0 else 0.7
			img.BackgroundColor3 = THEME.GoldHi
			UI.new("UICorner", { CornerRadius = UDim.new(1, 0) }, img)
		end
	end
end

local function track(parent: Instance, position: UDim2, height: number, color: Color3, centered: boolean): Frame
	local frame = UI.new("Frame", {
		Size = UDim2.new(1, 0, 0, height),
		Position = position,
		BackgroundColor3 = THEME.Ink,
		BackgroundTransparency = 0.2,
		BorderSizePixel = 0,
	}, parent)
	UI.stroke(frame, UI.Bronze, 1.5, 0.25)
	local fill = UI.new("Frame", {
		Name = "Fill",
		AnchorPoint = if centered then Vector2.new(0.5, 0) else Vector2.zero,
		Position = if centered then UDim2.fromScale(0.5, 0) else UDim2.fromScale(0, 0),
		Size = UDim2.fromScale(if centered then 0 else 1, 1),
		BackgroundColor3 = color,
		BorderSizePixel = 0,
	}, frame)
	return fill
end

local function build()
	screen = UI.new("ScreenGui", {
		Name = "BossHUD",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		DisplayOrder = 6,
	}, player:WaitForChild("PlayerGui"))

	-- The picker: a lacquer window with the boss cards; pick one, then Challenge.
	picker = UI.panel({
		Name = "Picker",
		material = "lacquer",
		sliceScale = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(660, 520),
		Visible = false,
	}, screen)
	-- Small screens (a phone in landscape): shrink to fit, LEAVE always on screen.
	pickerFit = UI.new("UIScale", {}, picker)
	local camera = workspace.CurrentCamera
	local function refit()
		local size = camera.ViewportSize
		pickerFit.Scale = math.clamp(math.min((size.Y - 24) / 520, (size.X - 32) / 660), 0.5, 1)
	end
	camera:GetPropertyChangedSignal("ViewportSize"):Connect(refit)
	refit()
	local chrome = UI.windowChrome(picker, { title = "Boss Trials" })
	chrome.close.Activated:Connect(function()
		BossHUD.closePicker()
	end)
	UI.label("body", {
		Text = "Kannagi's nine. Two lives each: a deathblow starts phase 2, the second ends it.",
		TextSize = 16,
		TextColor3 = THEME.Dim,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextWrapped = true,
		Size = UDim2.new(1, -56, 0, 22),
		Position = UDim2.fromOffset(28, 70),
	}, picker)
	-- What's going on: the arena taken, your place in line, a pick on its way, a refusal.
	statusLabel = UI.label("label", {
		Name = "Status",
		Text = "",
		TextSize = 16,
		TextColor3 = THEME.GoldHi,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextWrapped = true,
		Size = UDim2.new(1, -56, 0, 36),
		Position = UDim2.fromOffset(28, 94),
		Visible = false,
	}, picker)
	list = UI.new("ScrollingFrame", {
		Name = "List",
		Size = UDim2.new(1, -40, 1, -186),
		Position = UDim2.fromOffset(20, 100),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 5,
		ScrollBarImageColor3 = THEME.Gold,
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(),
	}, picker)
	UI.new("UIGridLayout", {
		CellSize = UDim2.fromOffset(142, 186),
		CellPadding = UDim2.fromOffset(12, 12),
		SortOrder = Enum.SortOrder.LayoutOrder,
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
	}, list)
	UI.new("UIPadding", { PaddingTop = UDim.new(0, 6), PaddingBottom = UDim.new(0, 6) }, list)
	challengeButton = UI.button({
		Name = "Challenge",
		variant = "primary",
		Text = "Challenge",
		FontFace = UI.Fonts.Display,
		TextSize = 24,
		Size = UDim2.fromOffset(400, UI.Touch),
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -16),
	}, picker)
	challengeButton.Activated:Connect(function()
		local id = selectedId
		local entry = id and pickEntries[id]
		if not id or not entry or pendingAt then
			return -- one pick at a time
		end
		-- Stays open until the server answers with a Start (closes it) or a Notice (says why
		-- not), so a pick can never just vanish.
		pendingAt = os.clock()
		setStatus(`Opening the gate to the {entry.name}...`, UI.Parchment)
		BossVisuals.prepare(id)
		remote:FireServer("Choose", id)
	end)
	-- While you wait for the arena: give up your place.
	cancelButton = UI.button({
		Name = "LeaveLine",
		variant = "danger",
		Text = "Leave line",
		Size = UDim2.fromOffset(160, UI.Touch),
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0.5, 126, 1, -16),
		Visible = false,
	}, picker)
	cancelButton.Activated:Connect(function()
		remote:FireServer("Cancel")
	end)

	-- The boss bar, just above your own posture bar (CombatHUD's, 80 px tall at -100).
	bar = UI.new("Frame", {
		Name = "BossBar",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -188),
		Size = UDim2.new(0.5, 0, 0, 64),
		BackgroundTransparency = 1,
		Visible = false,
	}, screen)
	UI.new("UISizeConstraint", { MinSize = Vector2.new(320, 64), MaxSize = Vector2.new(720, 64) }, bar)
	-- The name sits on a horizontal ink band so it reads over any sky.
	UI.new("ImageLabel", {
		Name = "Band",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0, 18),
		Size = UDim2.new(1.25, 0, 0, 74),
		BackgroundTransparency = 1,
		Image = Assets.UI.InkBand,
		ImageTransparency = 0.15,
		ZIndex = 0,
	}, bar)
	nameLabel = UI.label("heading", {
		Name = "BossName",
		Text = "",
		TextSize = 26,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextStrokeColor3 = THEME.Ink,
		TextStrokeTransparency = 0.5,
		Position = UDim2.fromOffset(0, -6),
		Size = UDim2.new(1, -120, 0, 30),
	}, bar)
	-- The Japanese name as a brush image (art/ui/chrome.py), never as fallback-font text.
	kanjiName = UI.new("ImageLabel", {
		Name = "BossKanji",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromOffset(0, -8),
		Size = UDim2.fromOffset(260, 40),
		BackgroundTransparency = 1,
		ScaleType = Enum.ScaleType.Fit,
		ImageColor3 = THEME.Bone,
		Visible = false,
	}, bar)
	UI.new("UIAspectRatioConstraint", { AspectRatio = 4.3 }, kanjiName)
	subLabel = UI.label("body", {
		Text = "",
		TextSize = 16,
		TextColor3 = THEME.Dim,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextStrokeColor3 = THEME.Ink,
		TextStrokeTransparency = 0.5,
		Size = UDim2.new(1, -120, 0, 18),
		Position = UDim2.fromOffset(2, 24),
	}, bar)
	-- Lives: small gold-rimmed crimson diamonds.
	livesRow = UI.new("Frame", {
		Name = "Lives",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		Size = UDim2.fromOffset(140, 26),
		BackgroundTransparency = 1,
	}, bar)
	UI.new("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		HorizontalAlignment = Enum.HorizontalAlignment.Right,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		Padding = UDim.new(0, 4),
	}, livesRow)
	vitalityFill = track(bar, UDim2.fromOffset(0, 44), 9, VITALITY, false)
	postureFill = track(bar, UDim2.fromOffset(0, 56), 6, POSTURE_LOW, true)
	-- The deathblow marker, centred on the posture bar while the boss is broken (the
	-- floating bars don't show over a boss; its body carries the same red dot).
	deathblowDot = UI.new("ImageLabel", {
		Name = "Deathblow",
		Image = Assets.UI.DeathblowDot,
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0, 59),
		Size = UDim2.fromOffset(40, 40),
		ZIndex = 4,
		Visible = false,
	}, bar)
	TweenService:Create(
		deathblowDot,
		TweenInfo.new(0.5, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
		{ Size = UDim2.fromOffset(52, 52) }
	):Play()

	banner = UI.text({
		Name = "Banner",
		Text = "",
		Font = UI.Display,
		TextSize = 40,
		TextStrokeTransparency = 0.35,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 92),
		Size = UDim2.fromOffset(700, 48),
		Visible = false,
	}, screen)
	lesson = UI.text({
		Name = "Lesson",
		Text = "",
		TextSize = 20,
		TextColor3 = UI.Gold,
		TextStrokeTransparency = 0.4,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 140),
		Size = UDim2.fromOffset(700, 26),
		Visible = false,
	}, screen)
end

local function showBanner(text: string, sub: string?, hold: number)
	bannerToken += 1
	local token = bannerToken
	banner.Text = text
	banner.Visible = true
	if sub then
		lesson.Text = sub
		lesson.Visible = true
	end
	task.delay(hold, function()
		if bannerToken == token then
			banner.Visible = false
		end
	end)
end

-- One pip per life left: the chrome art, or a rotated crimson square with a gold rim.
local function setLives(count: number)
	if #livesRow:GetChildren() - 1 == count then
		return
	end
	for _, child in livesRow:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
	for i = 1, count do
		local pip = UI.new("ImageLabel", {
			Name = `Life{i}`,
			LayoutOrder = i,
			Size = UDim2.fromOffset(22, 22),
			BackgroundTransparency = 1,
		}, livesRow)
		if not UI.art(pip, "LifePip") then
			pip.Size = UDim2.fromOffset(14, 14)
			pip.Rotation = 45
			pip.BackgroundTransparency = 0
			pip.BackgroundColor3 = THEME.CrimsonBtn
			UI.new("UIStroke", { Color = THEME.Gold, Thickness = 1.5 }, pip)
		end
	end
end

local function refresh()
	local model = watched
	if not model then
		return
	end
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid then
		vitalityFill.Size = UDim2.fromScale(math.clamp(humanoid.Health / math.max(humanoid.MaxHealth, 1), 0, 1), 1)
	end
	local postureMax = model:GetAttribute("PostureMax")
	local posture = model:GetAttribute("Posture")
	if typeof(postureMax) == "number" and typeof(posture) == "number" then
		local ratio = math.clamp(posture / math.max(postureMax, 1), 0, 1)
		postureFill.Size = UDim2.fromScale(ratio, 1)
		postureFill.BackgroundColor3 = POSTURE_LOW:Lerp(POSTURE_HIGH, ratio)
	end
	local broken = model:GetAttribute("CombatState") == "Broken"
	deathblowDot.Visible = broken
	if broken then
		postureFill.BackgroundColor3 = POSTURE_HIGH
	end
	local lives = model:GetAttribute("BossLives")
	if typeof(lives) == "number" then
		setLives(math.min(lives, 7))
	end
end

local function unwatch()
	for _, connection in connections do
		connection:Disconnect()
	end
	table.clear(connections)
	watched = nil
end

-- Takes the boss bar and its banners down (the fight is over, or broke off).
local function clearFight()
	fightToken += 1
	counting = false
	bar.Visible = false
	banner.Visible = false
	lesson.Visible = false
	unwatch()
end

local function watch(model: Model)
	unwatch()
	watched = model
	-- The server destroys the boss however the fight ends, so its body leaving is the last word:
	-- a missed or late End can't leave the bar up in the lobby or the next royale.
	table.insert(
		connections,
		model.AncestryChanged:Connect(function()
			if not model:IsDescendantOf(game) and watched == model then
				clearFight()
			end
		end)
	)
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid then
		table.insert(connections, humanoid.HealthChanged:Connect(refresh))
		table.insert(connections, humanoid:GetPropertyChangedSignal("MaxHealth"):Connect(refresh))
	end
	table.insert(connections, model.AttributeChanged:Connect(refresh))
	refresh()
end

function setStatus(text: string?, color: Color3?)
	statusLabel.Text = text or ""
	statusLabel.TextColor3 = color or UI.Gold
	statusLabel.Visible = text ~= nil and text ~= ""
	-- The list moves up into the status line's room while there's nothing to say.
	local gap = if statusLabel.Visible then 36 else 0
	list.Position = UDim2.fromOffset(20, 100 + gap)
	list.Size = UDim2.new(1, -40, 1, -186 - gap)
end

local function setLine(position: number?)
	inLine = position ~= nil
	cancelButton.Visible = inLine
end

local function setPickerVisible(open: boolean)
	if picker.Visible == open then
		return
	end
	picker.Visible = open
	if not open then
		pendingAt = nil
	end
	for _, callback in pickerCallbacks do
		task.spawn(callback, open)
	end
end

function BossHUD.closePicker()
	setPickerVisible(false)
end

function BossHUD.pickerOpen(): boolean
	return picker ~= nil and picker.Visible
end

-- Runs `callback(open)` whenever the picker opens or closes (LobbyHUD hides PLAY and the nav
-- bar under it).
function BossHUD.onPicker(callback: (open: boolean) -> ())
	table.insert(pickerCallbacks, callback)
end

local function openPicker(bosses: { { [string]: any } }, busy: { [string]: any }?, line: number?)
	for _, child in list:GetChildren() do
		if child:IsA("GuiButton") then
			child:Destroy()
		end
	end
	table.clear(pickEntries)
	-- Keep the last pick if it's still offered; else the first boss not yet cleared.
	local stillThere = false
	for _, entry in bosses do
		if entry.id == selectedId then
			stillThere = true
		end
	end
	if not stillThere then
		selectedId = nil
		for _, entry in bosses do
			if not entry.cleared and not entry.tutorial then
				selectedId = entry.id
				break
			end
		end
		selectedId = selectedId or (bosses[1] and bosses[1].id)
	end
	local function draw()
		for _, child in list:GetChildren() do
			if child:IsA("GuiButton") then
				child:Destroy()
			end
		end
		for i, entry in bosses do
			local id = entry.id :: string
			pickEntries[id] = entry
			local count = entry.stars or 0
			local rarity = if entry.tutorial
				then "common"
				elseif count >= 3 then "epic"
				elseif count == 2 then "rare"
				else "uncommon"
			local card = UI.card({
				Name = `Boss_{id}`,
				LayoutOrder = i,
				name = entry.name,
				rarity = rarity,
				caption = if count <= 0 then "Tutorial" else stars(count),
				captionColor = THEME.GoldHi,
				image = if entry.tutorial
					then Assets.Icons.Guide
					elseif entry.cleared then Assets.Icons.Trophy
					else Assets.Icons.Deathblow,
				state = if entry.cleared then "equipped" else nil,
				status = if entry.cleared then "Cleared" else "Not yet cleared",
				statusColor = if entry.cleared then THEME.JadeText else THEME.Dim,
				selected = id == selectedId,
				onActivated = function()
					if selectedId ~= id then
						selectedId = id
						draw()
					end
				end,
			}, list)
			if count > 0 and not entry.tutorial then
				tomoeRow(card, count)
			end
		end
		local entry = selectedId and pickEntries[selectedId]
		challengeButton.Text = if entry then `Challenge  ·  {entry.name}` else "Challenge"
	end
	draw()
	setLine(line)
	if line then
		setStatus(
			`{if busy then `{busy.player} is facing the {busy.boss}. ` else ""}You're {if line == 1
				then "next"
				else `#{line}`} in line: your trial starts by itself.`
		)
	elseif busy then
		setStatus(`The arena is taken: {busy.player} is facing the {busy.boss}. Pick a boss to wait your turn.`)
	else
		setStatus(nil)
	end
	Panels.closeAll()
	setPickerVisible(true)
end

local handlers: { [string]: (data: { [string]: any }) -> () } = {
	Pick = function(data)
		openPicker(data.bosses or {}, data.busy, data.line)
	end,
	Notice = function(data)
		pendingAt = nil
		local text = data.text or ""
		local kind = data.kind
		if kind == "Line" then
			setLine(data.line)
		elseif kind == "Turn" then
			setLine(nil)
		end
		if kind == "Failed" then
			-- The trial broke off mid-fight: take its HUD down with it.
			clearFight()
		end
		local color = if kind == "Refused" or kind == "Failed" then THEME.CrimsonText else UI.Gold
		if picker.Visible then
			setStatus(text, color)
		else
			Toasts.notice(text, color)
		end
	end,
	Start = function(data)
		fightToken += 1
		setLine(nil)
		setPickerVisible(false)
		BossVisuals.prepare(data.boss)
		local def = Bosses.def(data.boss)
		nameLabel.Text = data.name or ""
		local names = CHROME.BossNames
		local jp = typeof(names) == "table" and names[data.boss] or nil
		kanjiName.Visible = typeof(jp) == "string"
		if typeof(jp) == "string" then
			kanjiName.Image = jp
		end
		subLabel.Text = stars(data.stars or 0) .. (if def and def.blurb then "   ·   " .. def.blurb else "")
		bar.Visible = true
		lesson.Visible = false
		fightAt = data.fightAt or now()
		counting = true
		if typeof(data.model) == "Instance" and data.model:IsA("Model") then
			watch(data.model)
			LockOn.engage(data.model)
		end
		if data.tutorial then
			lesson.Text = "Lesson: move in, then attack"
			lesson.Visible = true
		end
	end,
	Phase = function(data)
		if data.lesson then
			showBanner(if data.stage == "2" then "The real fight" else "Next lesson", `Lesson: {data.lesson}`, 3)
		elseif data.phase == 2 then
			showBanner("Phase 2", "One life left", 2.5)
		end
	end,
	End = function(data)
		lesson.Visible = false
		if data.left then
			clearFight() -- stopped or abandoned: no result to show
			return
		end
		local minutes = math.floor((data.time or 0) / 60)
		local seconds = math.floor((data.time or 0) % 60)
		if data.won then
			CombatHUD.splash(
				Assets.UI.KanjiVictory,
				`{data.name} defeated  {string.format("%d:%02d", minutes, seconds)}{if data.firstClear
					then "  ·  first clear"
					else ""}`,
				UI.Gold,
				3.5
			)
		else
			CombatHUD.splash(Assets.UI.KanjiEnd, `{data.name} stands`, UI.Parchment, 3)
		end
		local token = fightToken
		task.delay(4, function()
			if fightToken == token then
				bar.Visible = false
				unwatch()
			end
		end)
	end,
}

function BossHUD.start()
	build()
	BossVisuals.start()
	remote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("Boss") :: RemoteEvent
	remote.OnClientEvent:Connect(function(kind: string, data: { [string]: any })
		local handler = handlers[kind]
		if handler then
			handler(data)
		end
	end)
	-- The countdown, and closing the picker if you walk away from the shrine (or the royale
	-- or a duel takes you), or saying so if a pick goes unanswered.
	local function walkedAway(): boolean
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if not character or not root or not root:IsA("BasePart") then
			return true
		end
		if character:GetAttribute("InMatch") == true or character:GetAttribute("InDuel") == true then
			return true
		end
		local lobby = workspace:FindFirstChild("Lobby")
		local shrine = lobby and lobby:FindFirstChild("BossShrine")
		local pad = shrine and shrine:GetAttribute("Pad")
		if not shrine or typeof(pad) ~= "Vector3" then
			return false
		end
		local radius = shrine:GetAttribute("PadRadius")
		local offset = root.Position - pad
		local flat = Vector3.new(offset.X, 0, offset.Z).Magnitude
		return flat > (if typeof(radius) == "number" then radius else 4) + PICK_REACH or math.abs(offset.Y) > 10
	end
	RunService.Heartbeat:Connect(function()
		if picker.Visible then
			if walkedAway() then
				setPickerVisible(false)
			elseif pendingAt and os.clock() - pendingAt > PENDING_TIMEOUT then
				pendingAt = nil
				setStatus("The shrine didn't answer. Pick again.", THEME.CrimsonText)
			end
		end
		if counting then
			if now() < fightAt then
				banner.Visible = true
				banner.Text = `Fight in {math.ceil(fightAt - now())}`
			else
				counting = false
				showBanner("Begin", nil, 0.8)
			end
		end
	end)
	player.CharacterAdded:Connect(function()
		setPickerVisible(false)
	end)
	-- One window at a time: a lobby panel opening closes the picker.
	Panels.onOpen(function()
		setPickerVisible(false)
	end)
end

return BossHUD
