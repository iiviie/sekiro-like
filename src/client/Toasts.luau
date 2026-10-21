--!strict
-- Rewards you can see: every payout from the server's ProgressService pops up the moment
-- it happens. Small toasts stack on the right ("+15 coins  +30 XP  Cut down"), a level-up
-- gets a gold banner, a finished mission or pass tier one of its own, and every match ends with a
-- report card: your place, what you did, and what it earned.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")

local Assets = require(ReplicatedStorage.Shared.Assets)
local Progression = require(ReplicatedStorage.Shared.Progression)
local Round = require(ReplicatedStorage.Shared.Round)
local UI = require(script.Parent.UI)

local player = Players.LocalPlayer
local ICONS = Assets.Icons

local Toasts = {}

local screen: ScreenGui
local stack: Frame
local REPORT_TIME = 9

-- The centre of the screen holds one announcement at a time. A match end used to fire the
-- level-up, a mission banner and the report card together, piled on top of each other: now
-- the banners play one after another, the report waits for them (a few seconds at most),
-- and anything that arrives while the report is open goes to the toast stack instead.
local STAGE_Y = 0.31 -- under the round banner and its sub-line (RoundHUD owns the top 20%)
local REPORT_DELAY = 2.4
local REPORT_MAX_DELAY = 6
local stageFreeAt = 0
local reportOpen = false
-- Plates that arrive while the report card is open wait for it to close: the stack sits under
-- the card's scrim and its right edge, where they'd be dimmed and cut off.
local deferred: { () -> () } = {}

local function deferWhileReport(show: () -> ()): boolean
	if reportOpen then
		table.insert(deferred, show)
		return true
	end
	return false
end

local function flushDeferred()
	local list = deferred
	deferred = {}
	for i, show in list do
		task.delay((i - 1) * 0.25, show)
	end
end

-- Plays `show` on the centre stage once it is free and returns true, or returns false (the
-- caller falls back to a toast) while a report card is open.
local function onStage(duration: number, show: () -> ()): boolean
	if reportOpen then
		return false
	end
	local now = os.clock()
	local wait = math.max(0, stageFreeAt - now)
	stageFreeAt = now + wait + duration
	if wait > 0 then
		task.delay(wait, show)
	else
		show()
	end
	return true
end

local function sound(id: string, volume: number, pitch: number)
	local s = Instance.new("Sound")
	s.SoundId = id
	s.Volume = volume
	s.PlaybackSpeed = pitch
	SoundService:PlayLocalSound(s)
	s.Ended:Once(function()
		s:Destroy()
	end)
end

local T = UI.Theme
local MAX_VISIBLE = 3

local function icon(parent: Instance, image: string, size: number, position: UDim2, anchor: Vector2?): ImageLabel
	return UI.new("ImageLabel", {
		AnchorPoint = anchor or Vector2.zero,
		Position = position,
		Size = UDim2.fromOffset(size, size),
		BackgroundTransparency = 1,
		Image = image,
	}, parent)
end

-- One plate in the stack: a CanvasGroup (so one tween fades everything) holding a lacquer
-- plate that slides in from the right. Only the newest MAX_VISIBLE stay; older ones fade.
local function plate(height: number?, autoHeight: boolean?): (CanvasGroup, Frame)
	local row = UI.new("CanvasGroup", {
		Size = UDim2.fromOffset(380, height or 64),
		AutomaticSize = if autoHeight then Enum.AutomaticSize.Y else Enum.AutomaticSize.None,
		BackgroundTransparency = 1,
		GroupTransparency = 1,
		LayoutOrder = -math.floor(os.clock() * 1000),
	}, stack)
	local inner = UI.panel({
		Name = "Plate",
		material = "plain",
		Size = UDim2.new(1, 0, 0, height or 64),
		AutomaticSize = if autoHeight then Enum.AutomaticSize.Y else Enum.AutomaticSize.None,
		Position = UDim2.fromOffset(if UI.reducedMotion() then 0 else 24, 0),
	}, row)
	-- Older plates beyond the limit fade out early.
	local rows = {}
	for _, child in stack:GetChildren() do
		if child:IsA("CanvasGroup") and child:GetAttribute("Leaving") ~= true then
			table.insert(rows, child)
		end
	end
	table.sort(rows, function(a, b)
		return a.LayoutOrder < b.LayoutOrder
	end)
	for i = MAX_VISIBLE + 1, #rows do
		local old = rows[i] :: CanvasGroup
		old:SetAttribute("Leaving", true)
		UI.play(old, UI.Motion.Close, { GroupTransparency = 1 })
		task.delay(0.15, function()
			old:Destroy()
		end)
	end
	UI.play(row, TweenInfo.new(0.25), { GroupTransparency = 0 })
	UI.play(inner, TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Position = UDim2.new() })
	return row, inner
end

local function leave(row: CanvasGroup, after: number)
	task.delay(after, function()
		if not row.Parent or row:GetAttribute("Leaving") then
			return
		end
		row:SetAttribute("Leaving", true)
		UI.play(row, TweenInfo.new(0.3), { GroupTransparency = 1 })
		task.wait(0.32)
		row:Destroy()
	end)
end

-- "+15 coins  +30 XP" over "Cut down": the currency that just arrived and where from.
local function toast(xp: number, coins: number, reason: string)
	if deferWhileReport(function()
		toast(xp, coins, reason)
	end) then
		return
	end
	local row, inner = plate(64)
	local main = if coins > 0 then `+{UI.number(coins)}` else `+{UI.number(xp)}`
	icon(inner, if coins > 0 then ICONS.Coin else ICONS.Level, 46, UDim2.new(0, 10, 0.5, 0), Vector2.new(0, 0.5))
	local line = UI.new("Frame", {
		Position = UDim2.fromOffset(64, 8),
		Size = UDim2.new(1, -76, 0, 28),
		BackgroundTransparency = 1,
	}, inner)
	UI.new("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		VerticalAlignment = Enum.VerticalAlignment.Bottom,
		Padding = UDim.new(0, 8),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, line)
	UI.text({
		LayoutOrder = 1,
		Size = UDim2.fromOffset(0, 28),
		AutomaticSize = Enum.AutomaticSize.X,
		FontFace = UI.Fonts.Number,
		TextSize = 24,
		TextColor3 = if coins > 0 then T.GoldHi else T.Bone,
		Text = main,
	}, line)
	UI.text({
		LayoutOrder = 2,
		Size = UDim2.fromOffset(0, 26),
		AutomaticSize = Enum.AutomaticSize.X,
		FontFace = UI.Fonts.Label,
		TextSize = 18,
		Text = if coins > 0 then (if xp > 0 then `coins   +{UI.number(xp)} XP` else "coins") else "XP",
	}, line)
	UI.text({
		Position = UDim2.fromOffset(64, 36),
		Size = UDim2.new(1, -76, 0, 20),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		FontFace = UI.Fonts.Body,
		TextSize = 15,
		TextColor3 = T.Dim,
		Text = reason,
	}, inner)
	leave(row, 2.6)
end

-- A plain line of feedback in the same stack ("A trial is underway: you're next"), for
-- requests the server turned down or the client couldn't do. Wraps; lingers a little longer.
-- The plate's left edge says what kind: gold for good news, lacquer red for a refusal.
function Toasts.notice(text: string, color: Color3?)
	if not stack then
		return
	end
	if deferWhileReport(function()
		Toasts.notice(text, color)
	end) then
		return
	end
	local good = color == UI.Gold or color == UI.Jade or color == T.Gold
	local row, inner = plate(0, true)
	UI.new("UIPadding", {
		PaddingLeft = UDim.new(0, 20),
		PaddingRight = UDim.new(0, 14),
		PaddingTop = UDim.new(0, 12),
		PaddingBottom = UDim.new(0, 12),
	}, inner)
	UI.new("Frame", {
		Name = "Edge",
		Position = UDim2.fromOffset(-14, -6),
		Size = UDim2.new(0, 3, 1, 12),
		BackgroundColor3 = if good then T.Gold else T.LacquerRed,
		BorderSizePixel = 0,
	}, inner)
	UI.text({
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		FontFace = UI.Fonts.Label,
		TextSize = 17,
		TextColor3 = if color == UI.Jade then T.JadeText else T.Bone,
		Text = text,
	}, inner)
	leave(row, 3.6)
end

-- A centred banner on an ink band: finished missions, pass tiers, unlocks.
local function banner(image: string, title: string, subtitle: string, color: Color3, y: number)
	local frame = UI.new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, y),
		Size = UDim2.fromOffset(560, 120),
		BackgroundTransparency = 1,
		ZIndex = 20,
	}, screen)
	local band = UI.new("ImageLabel", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(1.35, 1.05),
		BackgroundTransparency = 1,
		Image = Assets.UI.InkBand,
		ImageColor3 = Color3.new(0, 0, 0),
		ImageTransparency = 1,
		ZIndex = 20,
	}, frame)
	local pic = icon(frame, image, 110, UDim2.new(0, 64, 0.5, 0), Vector2.new(0.5, 0.5))
	pic.ZIndex = 21
	pic.Size = UDim2.fromOffset(40, 40)
	local titleLabel = UI.text({
		Position = UDim2.fromOffset(132, 18),
		Size = UDim2.new(1, -132, 0, 48),
		TextXAlignment = Enum.TextXAlignment.Left,
		FontFace = UI.Fonts.Display,
		TextSize = 40,
		TextColor3 = color,
		TextStrokeColor3 = T.Ink,
		TextStrokeTransparency = 0.35,
		TextTransparency = 1,
		Text = title,
		ZIndex = 21,
	}, frame)
	local subLabel = UI.text({
		Position = UDim2.fromOffset(134, 66),
		Size = UDim2.new(1, -134, 0, 26),
		TextXAlignment = Enum.TextXAlignment.Left,
		FontFace = UI.Fonts.Label,
		TextSize = 19,
		TextStrokeColor3 = T.Ink,
		TextStrokeTransparency = 0.5,
		TextTransparency = 1,
		Text = subtitle,
		ZIndex = 21,
	}, frame)
	UI.play(pic, UI.Motion.Pop, { Size = UDim2.fromOffset(110, 110) })
	UI.tween(band, 0.3, { ImageTransparency = 0.2 })
	UI.tween(titleLabel, 0.3, { TextTransparency = 0 })
	UI.tween(subLabel, 0.4, { TextTransparency = 0 })
	task.delay(3, function()
		UI.tween(band, 0.5, { ImageTransparency = 1 })
		UI.tween(titleLabel, 0.5, { TextTransparency = 1, TextStrokeTransparency = 1 })
		UI.tween(subLabel, 0.5, { TextTransparency = 1, TextStrokeTransparency = 1 })
		UI.tween(pic, 0.5, { ImageTransparency = 1 })
		task.wait(0.55)
		frame:Destroy()
	end)
end

-- Level-up (guide 11.2): an ink band sweeps across the middle, the new level stamps down in
-- heavy gold, "MASTERY" in tracked caps above it and what it paid below; then it sweeps out.
local function levelUp(level: number, coins: number, gems: number?)
	local reduced = UI.reducedMotion()
	local frame = UI.new("Frame", {
		Name = "LevelUp",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, STAGE_Y),
		Size = UDim2.fromOffset(600, 170),
		BackgroundTransparency = 1,
		ZIndex = 20,
	}, screen)
	local band = UI.new("ImageLabel", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(if reduced then 0.5 else -1, 0.5),
		Size = UDim2.fromScale(1.5, 1.3), -- tall enough that the reward row sits on ink
		BackgroundTransparency = 1,
		Image = Assets.UI.InkBand,
		ImageColor3 = Color3.new(0, 0, 0),
		ImageTransparency = 0.12,
		ZIndex = 20,
	}, frame)
	UI.play(band, UI.Motion.Slide, { Position = UDim2.fromScale(0.5, 0.5) })
	local caps = UI.text({
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 0.02),
		Size = UDim2.new(1, 0, 0, 30),
		FontFace = UI.Fonts.Banner,
		TextSize = 26,
		TextColor3 = T.Bone,
		TextStrokeColor3 = T.Ink,
		TextStrokeTransparency = 0.4,
		TextTransparency = 1,
		Text = UI.tracked("Mastery"),
		ZIndex = 21,
	}, frame)
	local number = UI.text({
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(300, 84),
		FontFace = UI.Fonts.DisplayHeavy,
		TextSize = 72,
		TextColor3 = T.GoldHi,
		TextStrokeColor3 = T.Ink,
		TextStrokeTransparency = 0.2,
		TextTransparency = 1,
		Text = tostring(level),
		ZIndex = 22,
	}, frame)
	local rewards = UI.new("Frame", {
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.fromScale(0.5, 0.98),
		Size = UDim2.fromOffset(0, 32),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundTransparency = 1,
		ZIndex = 21,
	}, frame)
	UI.new("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		Padding = UDim.new(0, 6),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, rewards)
	local parts: { { any } } = { { ICONS.Coin, `+{UI.number(coins)}`, T.GoldHi } }
	if gems and gems > 0 then
		table.insert(parts, { ICONS.Gem, `+{UI.number(gems)}`, T.JadeText })
	end
	local fades: { GuiObject } = {}
	for i, part in parts do
		local img = UI.new("ImageLabel", {
			LayoutOrder = i * 2,
			Size = UDim2.fromOffset(32, 32),
			BackgroundTransparency = 1,
			Image = part[1],
			ImageTransparency = 1,
			ZIndex = 21,
		}, rewards)
		local amount = UI.text({
			LayoutOrder = i * 2 + 1,
			Size = UDim2.fromOffset(0, 30),
			AutomaticSize = Enum.AutomaticSize.X,
			FontFace = UI.Fonts.Number,
			TextSize = 22,
			TextColor3 = part[3],
			TextStrokeColor3 = T.Ink,
			TextStrokeTransparency = 0.4,
			TextTransparency = 1,
			Text = part[2] .. "  ",
			ZIndex = 21,
		}, rewards)
		table.insert(fades, img)
		table.insert(fades, amount)
	end
	task.delay(if reduced then 0 else 0.25, function()
		number.TextTransparency = 0
		UI.stamp(number, 0)
		UI.sound("Stamp")
		UI.tween(caps, 0.25, { TextTransparency = 0 })
		for _, obj in fades do
			UI.tween(obj, 0.3, if obj:IsA("ImageLabel") then { ImageTransparency = 0 } else { TextTransparency = 0 })
		end
	end)
	task.delay(2.35, function()
		if not frame.Parent then
			return
		end
		local out = if reduced then UDim2.fromScale(0.5, 0.5) else UDim2.fromScale(2, 0.5)
		UI.play(
			band,
			TweenInfo.new(0.3, Enum.EasingStyle.Quint, Enum.EasingDirection.In),
			{ Position = out, ImageTransparency = 1 }
		)
		UI.tween(number, 0.25, { TextTransparency = 1, TextStrokeTransparency = 1 })
		UI.tween(caps, 0.25, { TextTransparency = 1, TextStrokeTransparency = 1 })
		for _, obj in fades do
			UI.tween(
				obj,
				0.25,
				if obj:IsA("ImageLabel")
					then { ImageTransparency = 1 }
					else { TextTransparency = 1, TextStrokeTransparency = 1 }
			)
		end
		task.wait(0.35)
		frame:Destroy()
	end)
end

local function ordinal(n: number): string
	local suffix = if n % 100 >= 11 and n % 100 <= 13
		then "th"
		elseif n % 10 == 1 then "st"
		elseif n % 10 == 2 then "nd"
		elseif n % 10 == 3 then "rd"
		else "th"
	return `{n}{suffix}`
end

-- End of match (guide 11.2): a washi card. Place and a line, then the stats count up one
-- row after another, then coins and XP, the Mastery bar, and the way back into a fight.
local function report(data: { [string]: any })
	for _, name in { "Report", "ReportScrim" } do
		local old = screen:FindFirstChild(name)
		if old then
			old:Destroy()
		end
	end
	-- A soft scrim so the lobby HUD and tips behind the card don't read through its edges; a
	-- tap on it closes the card like Lobby does.
	local scrim = UI.scrim(screen, 0.55, 9)
	scrim.Name = "ReportScrim"
	local won = data.won == true
	local duel = data.duel -- { score, opponent, rating? } for a duel
	local card = UI.panel({
		Name = "Report",
		material = "washi",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.47),
		Size = UDim2.fromOffset(480, 410), -- room for the hint line above the buttons
		ZIndex = 10,
		Active = true,
	}, screen)
	UI.grain(card, 0.88)
	local open = UI.new("UIScale", { Scale = if UI.reducedMotion() then 1 else 0.92 }, card)
	UI.play(open, UI.Motion.Open, { Scale = 1 })
	icon(card, if won then ICONS.Trophy else ICONS.Kill, 92, UDim2.fromOffset(22, 14)).ZIndex = 11
	UI.text({
		Position = UDim2.fromOffset(124, 22),
		Size = UDim2.new(1, -150, 0, 48),
		TextXAlignment = Enum.TextXAlignment.Left,
		FontFace = UI.Fonts.Display,
		TextSize = 38,
		TextColor3 = if won then T.LacquerRed else T.Ink,
		Text = if data.boss
			then (if won then "Trial cleared" else "Trial failed")
			elseif duel then (if won then "Duel won" else "Duel lost")
			elseif won then "Last Blade"
			else `{ordinal(data.placement)} of {data.fighters}`,
		ZIndex = 11,
	}, card)
	UI.text({
		Position = UDim2.fromOffset(126, 70),
		Size = UDim2.new(1, -150, 0, 22),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		FontFace = UI.Fonts.Body,
		TextSize = 17,
		TextColor3 = T.Ink,
		TextTransparency = 0.2,
		Text = if duel
			then `{duel.score} against {duel.opponent}{if typeof(duel.rating) == "number"
				then `  ·  rating {if duel.rating >= 0 then "+" else ""}{duel.rating}`
				else ""}`
			elseif won then "You were the last one standing."
			elseif data.placement <= 3 then "So close. One more."
			else "Every death is a lesson. Next fight starts soon.",
		ZIndex = 11,
	}, card)
	UI.divider(card, {
		Position = UDim2.fromOffset(24, 104),
		Size = UDim2.new(1, -48, 0, 10),
		color = T.Bronze,
	})

	local stats = {
		{ "Cut down", data.kills },
		{ "Deathblows", data.deathblows },
		{ "Deflects", data.deflects },
		{ "Perfect deflects", data.perfects },
	}
	for i, stat in stats do
		local col = (i - 1) % 2
		local row = (i - 1) // 2
		local cell = UI.new("Frame", {
			Position = UDim2.fromOffset(24 + col * 222, 122 + row * 40),
			Size = UDim2.fromOffset(210, 34),
			BackgroundTransparency = 1,
			ZIndex = 11,
		}, card)
		UI.text({
			Size = UDim2.new(1, -70, 1, 0),
			TextXAlignment = Enum.TextXAlignment.Left,
			FontFace = UI.Fonts.Label,
			TextSize = 17,
			TextColor3 = T.Ink,
			TextTransparency = 0.15,
			Text = stat[1],
			ZIndex = 12,
		}, cell)
		local value = UI.text({
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.fromScale(1, 0),
			Size = UDim2.new(0, 70, 1, 0),
			TextXAlignment = Enum.TextXAlignment.Right,
			FontFace = UI.Fonts.Number,
			TextSize = 26,
			TextColor3 = T.Ink,
			Text = "0",
			ZIndex = 12,
		}, cell)
		UI.new("Frame", {
			AnchorPoint = Vector2.new(0, 1),
			Position = UDim2.fromScale(0, 1),
			Size = UDim2.new(1, 0, 0, 1),
			BackgroundColor3 = T.Bronze,
			BackgroundTransparency = 0.6,
			BorderSizePixel = 0,
			ZIndex = 11,
		}, cell)
		-- Count up, one row after another: the numbers land like hits.
		task.delay(0.25 + i * 0.12, function()
			if value.Parent then
				UI.countUp(value, 0, stat[2] :: number, tostring, 0.35)
			end
		end)
	end

	local earned = UI.new("Frame", {
		Position = UDim2.fromOffset(24, 212),
		Size = UDim2.new(1, -48, 0, 40),
		BackgroundTransparency = 1,
		ZIndex = 11,
	}, card)
	icon(earned, ICONS.Coin, 40, UDim2.fromOffset(0, 0)).ZIndex = 12
	local coinsLabel = UI.text({
		Position = UDim2.fromOffset(46, 0),
		Size = UDim2.fromOffset(130, 40),
		TextXAlignment = Enum.TextXAlignment.Left,
		FontFace = UI.Fonts.Number,
		TextSize = 28,
		TextColor3 = T.GoldDeep,
		Text = "+0",
		ZIndex = 12,
	}, earned)
	icon(earned, ICONS.Level, 40, UDim2.fromOffset(190, 0)).ZIndex = 12
	local xpLabel = UI.text({
		Position = UDim2.fromOffset(236, 0),
		Size = UDim2.fromOffset(190, 40),
		TextXAlignment = Enum.TextXAlignment.Left,
		FontFace = UI.Fonts.Number,
		TextSize = 28,
		TextColor3 = T.Ink,
		Text = "+0 XP",
		ZIndex = 12,
	}, earned)
	task.delay(0.25 + #stats * 0.12 + 0.12, function()
		if coinsLabel.Parent then
			UI.countUp(coinsLabel, 0, data.coins or 0, function(n)
				return `+{UI.number(n)}`
			end)
			UI.countUp(xpLabel, 0, data.xp or 0, function(n)
				return `+{UI.number(n)} XP`
			end)
		end
	end)

	-- Mastery bar (value text outside the bar, Number 15).
	local level = player:GetAttribute("Level") or 1
	local xp = player:GetAttribute("XP") or 0
	local need = Progression.xpToNext(level)
	UI.text({
		Position = UDim2.fromOffset(24, 258),
		Size = UDim2.new(1, -48, 0, 20),
		TextXAlignment = Enum.TextXAlignment.Left,
		FontFace = UI.Fonts.Label,
		TextSize = 15,
		TextColor3 = T.Bronze,
		Text = `MASTERY {level}`,
		ZIndex = 11,
	}, card)
	local bar = UI.progress({
		Name = "Mastery",
		Position = UDim2.fromOffset(24, 278),
		Size = UDim2.new(1, -48, 0, 20),
		value = 0,
		max = need,
		tone = "gold",
		height = 12,
		textWidth = 120,
		format = function(v: number, m: number): string
			return `{UI.number(v)} / {UI.number(m)} XP`
		end,
	}, card)
	if bar.text then
		bar.text.TextColor3 = T.Ink
	end
	for _, d in bar.frame:GetDescendants() do
		if d:IsA("GuiObject") then
			d.ZIndex = 12
		end
	end
	task.delay(0.9, function()
		if bar.frame.Parent then
			bar.set(xp, need, true)
		end
	end)
	local next = UI.text({
		Position = UDim2.fromOffset(24, 300),
		Size = UDim2.new(1, -48, 0, 20),
		FontFace = UI.Fonts.Body,
		TextSize = 15,
		TextColor3 = T.Ink,
		TextTransparency = 0.3,
		Text = "",
		ZIndex = 11,
	}, card)

	reportOpen = true
	local function close()
		if reportOpen then
			reportOpen = false
			flushDeferred()
		end
		scrim:Destroy()
		if card.Parent then
			card:Destroy()
		end
	end
	scrim.Activated:Connect(close)
	-- The way back into a fight: a royale queues you (the same request as PLAY); trials and
	-- duels start from the shrine / a duel pad, so they only close.
	local royale = not data.boss and not duel
	local done = UI.button({
		Name = "Lobby",
		variant = "washi",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 24, 1, -20),
		Size = UDim2.new(if royale then 0.5 else 1, if royale then -30 else -48, 0, UI.Touch),
		Text = if royale then "Lobby" else "Close",
		sound = "Cancel",
		ZIndex = 12,
	}, card)
	done.Activated:Connect(close)
	if royale then
		local again = UI.button({
			Name = "FightAgain",
			variant = "primary",
			AnchorPoint = Vector2.new(1, 1),
			Position = UDim2.new(1, -24, 1, -20),
			Size = UDim2.new(0.5, -30, 0, UI.Touch),
			FontFace = UI.Fonts.Display,
			TextSize = 22,
			Text = "Fight again",
			ZIndex = 12,
		}, card)
		again.Activated:Connect(function()
			local remotes = ReplicatedStorage:FindFirstChild("Remotes")
			local lobby = remotes and remotes:FindFirstChild("LobbyAction")
			if lobby and lobby:IsA("RemoteEvent") and player:GetAttribute("Queued") ~= true then
				lobby:FireServer("Queue", true)
			end
			UI.sound("Confirm")
			close()
		end)
	end

	local closeAt = os.clock() + REPORT_TIME
	task.spawn(function()
		while card.Parent and os.clock() < closeAt do
			local queued = player:GetAttribute("Queued") == true
			next.Text = if data.boss
				then "Step on the shrine for another trial"
				elseif duel then "Step on a duel pad for a rematch"
				elseif queued then "You're queued for the next royale"
				else "Press PLAY to fight again"
			task.wait(0.25)
		end
		if card.Parent then
			UI.play(open, UI.Motion.Close, { Scale = 0.94 })
			task.wait(0.15)
			close()
		end
	end)
	-- A fresh match closes it early.
	local connection
	connection = Round.state():GetAttributeChangedSignal("Phase"):Connect(function()
		if Round.phase() == "Match" then
			connection:Disconnect()
			close()
		end
	end)
end

function Toasts.start()
	screen = UI.new("ScreenGui", {
		Name = "Toasts",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		DisplayOrder = 12,
	}, player:WaitForChild("PlayerGui"))
	-- Top right, under the lobby's currency pills (the toasts explain where coins came from).
	stack = UI.new("Frame", {
		Name = "Stack",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -20, 0, 136),
		Size = UDim2.fromOffset(380, 300),
		BackgroundTransparency = 1,
	}, screen)
	UI.new("UIListLayout", {
		VerticalAlignment = Enum.VerticalAlignment.Top,
		HorizontalAlignment = Enum.HorizontalAlignment.Right,
		Padding = UDim.new(0, 6),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, stack)

	local remote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("Progress") :: RemoteEvent
	remote.OnClientEvent:Connect(function(kind: string, data: { [string]: any })
		if kind == "Reward" then
			toast(data.xp or 0, data.coins or 0, data.reason or "")
		elseif kind == "LevelUp" then
			local level, coins = data.level or 1, data.coins or 0
			local shown = onStage(2.75, function()
				levelUp(level, coins, data.gems)
				UI.sound("LevelUp")
				sound(Assets.Sounds.PerfectDeflect, 0.45, 1.2)
			end)
			if not shown then
				Toasts.notice(`Mastery {level}  ·  +{UI.number(coins)} coins`, UI.Gold)
				UI.sound("LevelUp")
			end
		elseif kind == "Trial" then
			local text = `{data.text}  ·  +{data.coins} coins`
			if
				not onStage(3.6, function()
					banner(ICONS.Trials, "Trial complete", text, UI.Jade, STAGE_Y)
					sound(Assets.Sounds.PerfectDeflect, 0.5, 1.2)
				end)
			then
				Toasts.notice(`Trial complete  ·  {text}`, UI.Jade)
			end
		elseif kind == "Report" then
			-- After the banners already queued, but never long after the match ended.
			local delay = math.clamp(stageFreeAt - os.clock(), REPORT_DELAY, REPORT_MAX_DELAY)
			task.delay(delay, report, data)
		elseif kind == "Unlock" then
			local name = data.name or ""
			if
				not onStage(3.6, function()
					banner(ICONS.Trophy, "Unlocked", name, UI.Gold, STAGE_Y)
					sound(Assets.Sounds.PerfectDeflect, 0.5, 1.1)
				end)
			then
				Toasts.notice(`Unlocked  ·  {name}`, UI.Gold)
			end
		elseif kind == "Notice" then
			Toasts.notice(data.text or "", UI.Parchment)
		elseif kind == "Mission" then
			-- Season pass missions (server/PassService): a daily mission or a weekly bounty.
			local pass = if (data.pass or 0) > 0 then `+{data.pass} Pass XP  ·  ` else ""
			local title = if data.weekly then "Bounty complete" else "Mission complete"
			local text = `{data.text}  ·  {pass}+{data.coins} coins`
			if
				not onStage(3.6, function()
					banner(ICONS.Trials, title, text, UI.Jade, STAGE_Y)
					sound(Assets.Sounds.PerfectDeflect, 0.5, 1.2)
				end)
			then
				Toasts.notice(`{title}  ·  {text}`, UI.Jade)
			end
		elseif kind == "PassTier" then
			local crest = (ICONS :: any).SeasonPass or Assets.RankCrests.Gold
			local ready = if (data.claimable or 0) > 0 then `  ·  {data.claimable} to claim` else ""
			local tier = data.tier
			if
				not onStage(3.6, function()
					banner(crest, `Tier {tier}`, `Path of the Blade{ready}`, UI.Gold, STAGE_Y)
					sound(Assets.Sounds.PerfectDeflect, 0.6, 0.85)
				end)
			then
				Toasts.notice(`Path of the Blade  ·  Tier {tier}{ready}`, UI.Gold)
			end
		elseif kind == "PassPremium" then
			local crest = (ICONS :: any).SeasonPass or Assets.RankCrests.Gold
			local text = `{data.claimable or 0} rewards ready to claim`
			if not onStage(3.6, function()
				banner(crest, "Premium unlocked", text, UI.Gold, STAGE_Y)
			end) then
				Toasts.notice(`Premium unlocked  ·  {text}`, UI.Gold)
			end
			UI.sound("Robux")
		elseif kind == "PassClaim" then
			Toasts.notice(`Claimed  ·  {data.text or ""}`, UI.Gold)
			UI.sound("Claim")
		end
	end)
end

return Toasts
