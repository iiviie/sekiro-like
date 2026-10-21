--!strict
-- Rewards you can see: every payout from the server's ProgressService pops up the moment
-- it happens. Small toasts stack on the right ("+15 coins  +30 XP  Cut down"), a level-up
-- gets a gold banner, a finished Trial a banner of its own, and every match ends with a
-- report card: your place, what you did, and what it earned.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local TextService = game:GetService("TextService")
local TweenService = game:GetService("TweenService")

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

local function icon(parent: Instance, image: string, size: number, position: UDim2, anchor: Vector2?): ImageLabel
	return UI.new("ImageLabel", {
		AnchorPoint = anchor or Vector2.zero,
		Position = position,
		Size = UDim2.fromOffset(size, size),
		BackgroundTransparency = 1,
		Image = image,
	}, parent)
end

-- "+15  +30 XP  Cut down", sliding in on the right and fading after a moment.
local function toast(xp: number, coins: number, reason: string)
	local row = UI.new("Frame", {
		Size = UDim2.fromOffset(360, 40),
		BackgroundTransparency = 1,
		LayoutOrder = -math.floor(os.clock() * 1000),
	}, stack)
	local inner = UI.new("Frame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = UI.Ink,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
	}, row)
	UI.new("UIGradient", {
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.35, 0.35),
			NumberSequenceKeypoint.new(1, 0.25),
		}),
	}, inner)
	local x = 348
	local labels: { TextLabel } = {}
	local images: { ImageLabel } = {}
	local function add(text: string, color: Color3, size: number, image: string?)
		local label = UI.text({
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(0, x, 0.5, 0),
			Size = UDim2.fromOffset(0, 30),
			AutomaticSize = Enum.AutomaticSize.X,
			Font = UI.Bold,
			TextSize = size,
			TextColor3 = color,
			TextStrokeTransparency = 0.4,
			TextTransparency = 1,
			Text = text,
		}, inner)
		table.insert(labels, label)
		x -= TextService:GetTextSize(text, size, UI.Bold, Vector2.new(1000, 100)).X + 6
		if image then
			local img = icon(inner, image, 34, UDim2.new(0, x, 0.5, 0), Vector2.new(1, 0.5))
			img.ImageTransparency = 1
			table.insert(images, img)
			x -= 34
		end
		x -= 10
	end
	add(reason, UI.Parchment, 18)
	if xp > 0 then
		add(`+{xp} XP`, Color3.fromRGB(150, 210, 255), 20)
	end
	if coins > 0 then
		add(`+{coins}`, UI.Gold, 22, ICONS.Coin)
	end
	inner.Position = UDim2.fromOffset(60, 0)
	UI.tween(inner, 0.25, { Position = UDim2.fromOffset(0, 0), BackgroundTransparency = 0 })
	for _, label in labels do
		UI.tween(label, 0.2, { TextTransparency = 0 })
	end
	for _, img in images do
		UI.tween(img, 0.2, { ImageTransparency = 0 })
	end
	task.delay(2.4, function()
		UI.tween(inner, 0.4, { BackgroundTransparency = 1 })
		for _, label in labels do
			UI.tween(label, 0.4, { TextTransparency = 1, TextStrokeTransparency = 1 })
		end
		for _, img in images do
			UI.tween(img, 0.4, { ImageTransparency = 1 })
		end
		task.wait(0.45)
		row:Destroy()
	end)
end

-- A plain line of feedback in the same stack ("A trial is underway: you're next"), for
-- requests the server turned down or the client couldn't do. Wraps; lingers a little longer.
function Toasts.notice(text: string, color: Color3?)
	if not stack then
		return
	end
	local row = UI.new("Frame", {
		Size = UDim2.fromOffset(360, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = UI.Ink,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		LayoutOrder = -math.floor(os.clock() * 1000),
	}, stack)
	UI.corner(row)
	UI.new("UIPadding", {
		PaddingLeft = UDim.new(0, 12),
		PaddingRight = UDim.new(0, 12),
		PaddingTop = UDim.new(0, 6),
		PaddingBottom = UDim.new(0, 6),
	}, row)
	local label = UI.text({
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Right,
		Font = UI.Bold,
		TextSize = 18,
		TextColor3 = color or UI.Parchment,
		TextStrokeTransparency = 0.4,
		TextTransparency = 1,
		Text = text,
	}, row)
	UI.tween(row, 0.2, { BackgroundTransparency = 0.25 })
	UI.tween(label, 0.2, { TextTransparency = 0 })
	task.delay(3.6, function()
		UI.tween(row, 0.4, { BackgroundTransparency = 1 })
		UI.tween(label, 0.4, { TextTransparency = 1, TextStrokeTransparency = 1 })
		task.wait(0.45)
		row:Destroy()
	end)
end

-- A centred banner with an icon: level-ups and finished trials.
local function banner(image: string, title: string, subtitle: string, color: Color3, y: number)
	local frame = UI.new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, y),
		Size = UDim2.fromOffset(520, 110),
		BackgroundTransparency = 1,
		ZIndex = 20,
	}, screen)
	local band = UI.new("ImageLabel", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(1.3, 1),
		BackgroundTransparency = 1,
		Image = Assets.UI.InkBand,
		ImageColor3 = Color3.new(0, 0, 0),
		ImageTransparency = 1,
		ZIndex = 20,
	}, frame)
	local pic = icon(frame, image, 120, UDim2.new(0, 60, 0.5, 0), Vector2.new(0.5, 0.5))
	pic.ZIndex = 21
	pic.Size = UDim2.fromOffset(40, 40)
	local titleLabel = UI.text({
		Position = UDim2.fromOffset(130, 16),
		Size = UDim2.new(1, -130, 0, 46),
		TextXAlignment = Enum.TextXAlignment.Left,
		Font = UI.Display,
		TextSize = 42,
		TextColor3 = color,
		TextStrokeTransparency = 0.3,
		TextTransparency = 1,
		Text = title,
		ZIndex = 21,
	}, frame)
	local subLabel = UI.text({
		Position = UDim2.fromOffset(132, 62),
		Size = UDim2.new(1, -132, 0, 26),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextSize = 20,
		TextStrokeTransparency = 0.5,
		TextTransparency = 1,
		Text = subtitle,
		ZIndex = 21,
	}, frame)
	TweenService:Create(
		pic,
		TweenInfo.new(0.45, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Size = UDim2.fromOffset(120, 120) }
	):Play()
	UI.tween(band, 0.3, { ImageTransparency = 0.25 })
	UI.tween(titleLabel, 0.3, { TextTransparency = 0 })
	UI.tween(subLabel, 0.4, { TextTransparency = 0.1 })
	task.delay(3, function()
		UI.tween(band, 0.5, { ImageTransparency = 1 })
		UI.tween(titleLabel, 0.5, { TextTransparency = 1, TextStrokeTransparency = 1 })
		UI.tween(subLabel, 0.5, { TextTransparency = 1, TextStrokeTransparency = 1 })
		UI.tween(pic, 0.5, { ImageTransparency = 1 })
		task.wait(0.55)
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

-- End of match: place, what you did, what it earned, and the Mastery bar.
local function report(data: { [string]: any })
	local old = screen:FindFirstChild("Report")
	if old then
		old:Destroy()
	end
	local card = UI.panel({
		Name = "Report",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.47),
		Size = UDim2.fromOffset(460, 330),
		BackgroundColor3 = UI.Ink,
		BackgroundTransparency = 0.06,
		ZIndex = 10,
	}, screen)
	UI.stroke(card, if data.won then UI.Gold else UI.Bronze, 2, 0.1)
	local won = data.won == true
	local duel = data.duel -- { score, opponent, rating? } for a duel
	icon(card, if won then ICONS.Trophy else ICONS.Kill, 96, UDim2.fromOffset(18, 8)).ZIndex = 11
	UI.text({
		Position = UDim2.fromOffset(124, 14),
		Size = UDim2.new(1, -140, 0, 50),
		TextXAlignment = Enum.TextXAlignment.Left,
		Font = UI.Display,
		TextSize = 46,
		TextColor3 = if won then UI.Gold else UI.Parchment,
		Text = if data.boss
			then (if won then "Trial cleared" else "Trial failed")
			elseif duel then (if won then "Duel won" else "Duel lost")
			elseif won then "Last Blade"
			else `{ordinal(data.placement)} of {data.fighters}`,
		ZIndex = 11,
	}, card)
	UI.text({
		Position = UDim2.fromOffset(126, 62),
		Size = UDim2.new(1, -140, 0, 22),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextSize = 17,
		TextTransparency = 0.25,
		Text = if duel
			then `{duel.score} against {duel.opponent}{if typeof(duel.rating) == "number"
				then `  ·  rating {if duel.rating >= 0 then "+" else ""}{duel.rating}`
				else ""}`
			elseif won then "You were the last one standing."
			elseif data.placement <= 3 then "So close. One more."
			else "Every death is a lesson. Next fight starts soon.",
		ZIndex = 11,
	}, card)

	local stats = {
		{ "Cut down", data.kills },
		{ "Deathblows", data.deathblows },
		{ "Deflects", data.deflects },
		{ "Perfect deflects", data.perfects },
	}
	for i, stat in stats do
		local col = (i - 1) % 2
		local row = (i - 1) // 2
		local box = UI.panel({
			Position = UDim2.fromOffset(18 + col * 216, 112 + row * 58),
			Size = UDim2.fromOffset(206, 50),
			BackgroundColor3 = UI.PanelLight,
			ZIndex = 11,
		}, card)
		UI.text({
			Position = UDim2.fromOffset(12, 0),
			Size = UDim2.new(1, -70, 1, 0),
			TextXAlignment = Enum.TextXAlignment.Left,
			TextSize = 17,
			TextTransparency = 0.2,
			Text = stat[1],
			ZIndex = 12,
		}, box)
		local value = UI.text({
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -12, 0, 0),
			Size = UDim2.new(0, 60, 1, 0),
			TextXAlignment = Enum.TextXAlignment.Right,
			Font = UI.Bold,
			TextSize = 26,
			Text = "0",
			ZIndex = 12,
		}, box)
		-- Count up, one after another: the numbers land like hits.
		task.delay(0.25 + i * 0.18, function()
			local target = stat[2] :: number
			for n = 0, target do
				value.Text = tostring(n)
				task.wait(math.min(0.06, 0.5 / math.max(target, 1)))
			end
		end)
	end

	local earned = UI.new("Frame", {
		Position = UDim2.fromOffset(18, 232),
		Size = UDim2.new(1, -36, 0, 36),
		BackgroundTransparency = 1,
		ZIndex = 11,
	}, card)
	icon(earned, ICONS.Coin, 38, UDim2.fromOffset(0, -1)).ZIndex = 12
	UI.text({
		Position = UDim2.fromOffset(42, 0),
		Size = UDim2.fromOffset(120, 36),
		TextXAlignment = Enum.TextXAlignment.Left,
		Font = UI.Bold,
		TextSize = 26,
		TextColor3 = UI.Gold,
		Text = `+{UI.number(data.coins)}`,
		ZIndex = 12,
	}, earned)
	icon(earned, ICONS.Level, 38, UDim2.fromOffset(170, -1)).ZIndex = 12
	UI.text({
		Position = UDim2.fromOffset(212, 0),
		Size = UDim2.fromOffset(200, 36),
		TextXAlignment = Enum.TextXAlignment.Left,
		Font = UI.Bold,
		TextSize = 26,
		TextColor3 = Color3.fromRGB(150, 210, 255),
		Text = `+{UI.number(data.xp)} XP`,
		ZIndex = 12,
	}, earned)

	-- Mastery bar.
	local level = player:GetAttribute("Level") or 1
	local xp = player:GetAttribute("XP") or 0
	local need = Progression.xpToNext(level)
	local track = UI.new("Frame", {
		Position = UDim2.fromOffset(18, 280),
		Size = UDim2.new(1, -36, 0, 18),
		BackgroundColor3 = Color3.fromRGB(12, 10, 12),
		BorderSizePixel = 0,
		ZIndex = 11,
	}, card)
	UI.corner(track, UDim.new(1, 0))
	local fill = UI.new("Frame", {
		Size = UDim2.fromScale(0, 1),
		BackgroundColor3 = UI.Gold,
		BorderSizePixel = 0,
		ZIndex = 12,
	}, track)
	UI.corner(fill, UDim.new(1, 0))
	UI.text({
		Size = UDim2.fromScale(1, 1),
		Font = UI.Bold,
		TextSize = 13,
		TextStrokeTransparency = 0.3,
		Text = `Mastery {level}   ·   {xp} / {need} XP`,
		ZIndex = 13,
	}, track)
	task.delay(0.9, function()
		TweenService:Create(
			fill,
			TweenInfo.new(0.8, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
			{ Size = UDim2.fromScale(math.clamp(xp / need, 0.02, 1), 1) }
		):Play()
	end)
	local next = UI.text({
		Position = UDim2.fromOffset(18, 302),
		Size = UDim2.new(1, -36, 0, 22),
		TextSize = 15,
		TextTransparency = 0.35,
		Text = "",
		ZIndex = 11,
	}, card)

	card.Size = UDim2.fromOffset(420, 300)
	TweenService:Create(
		card,
		TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Size = UDim2.fromOffset(460, 330) }
	):Play()
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
			UI.tween(card, 0.3, { BackgroundTransparency = 1 })
			task.wait(0.3)
			card:Destroy()
		end
	end)
	-- A fresh match closes it early.
	local connection
	connection = Round.state():GetAttributeChangedSignal("Phase"):Connect(function()
		if Round.phase() == "Match" then
			connection:Disconnect()
			card:Destroy()
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
	stack = UI.new("Frame", {
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -20, 0.42, 0),
		Size = UDim2.fromOffset(360, 260),
		BackgroundTransparency = 1,
	}, screen)
	UI.new("UIListLayout", {
		VerticalAlignment = Enum.VerticalAlignment.Bottom,
		HorizontalAlignment = Enum.HorizontalAlignment.Right,
		Padding = UDim.new(0, 4),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, stack)

	local remote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("Progress") :: RemoteEvent
	remote.OnClientEvent:Connect(function(kind: string, data: { [string]: any })
		if kind == "Reward" then
			toast(data.xp or 0, data.coins or 0, data.reason or "")
		elseif kind == "LevelUp" then
			local gems = if data.gems then `  ·  +{data.gems} gems` else ""
			banner(ICONS.Level, `Mastery {data.level}`, `Level up  ·  +{data.coins} coins{gems}`, UI.Gold, 0.16)
			sound(Assets.Sounds.PerfectDeflect, 0.6, 0.7)
		elseif kind == "Trial" then
			banner(ICONS.Trials, "Trial complete", `{data.text}  ·  +{data.coins} coins`, UI.Jade, 0.16)
			sound(Assets.Sounds.PerfectDeflect, 0.5, 1.2)
		elseif kind == "Report" then
			task.delay(2.4, report, data)
		elseif kind == "Unlock" then
			banner(ICONS.Trophy, "Unlocked", data.name or "", UI.Gold, 0.16)
			sound(Assets.Sounds.PerfectDeflect, 0.5, 1.1)
		elseif kind == "Notice" then
			Toasts.notice(data.text or "", UI.Parchment)
		end
	end)
end

return Toasts
