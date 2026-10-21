--!strict
-- "Path of the Blade", the season pass panel: the season and its countdown, your tier and
-- Pass XP, the premium upgrade and tier skips, the reward track (tiers scroll sideways, a
-- free row and a premium row, claim buttons) and the daily missions and weekly bounties.
-- Everything comes from Shared/Season (the track, the missions) and server attributes (tier,
-- claims, mission progress, the season clock); requests go to Remotes.PassAction and the
-- server checks every one (server/PassService).
--
--   PassPanel.build(body)   draw into `body` (Panels clears it before each redraw)
--   PassPanel.Title, PassPanel.Icon, PassPanel.badge() -> rewards ready to claim

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Assets = require(ReplicatedStorage.Shared.Assets)
local Catalog = require(ReplicatedStorage.Shared.Catalog)
local Progression = require(ReplicatedStorage.Shared.Progression)
local Season = require(ReplicatedStorage.Shared.Season)
local UI = require(script.Parent.UI)

local player = Players.LocalPlayer
local ICONS = Assets.Icons :: any

local PassPanel = {}

PassPanel.Title = Season.Name
PassPanel.Icon = ICONS.SeasonPass or Assets.RankCrests.Gold

-- Kept across redraws (Panels redraws on every attribute change).
local tab: "Rewards" | "Missions" = "Rewards"
local scrollX: number? = nil
local centeredOn: number? = nil
local detail: string? = nil

local PREMIUM_BG = Color3.fromRGB(48, 37, 24)
local DIM = Color3.fromRGB(140, 130, 120)
local PASS_BLUE = Color3.fromRGB(150, 210, 255)

local function attr(name: string, default: any): any
	local value = player:GetAttribute(name)
	return if value == nil then default else value
end

local function decode(name: string): any
	local ok, value = pcall(HttpService.JSONDecode, HttpService, attr(name, "{}"))
	return if ok and typeof(value) == "table" then value else {}
end

local function action(...: any)
	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
	local remote = remotes and remotes:FindFirstChild("PassAction")
	if remote and remote:IsA("RemoteEvent") then
		remote:FireServer(...)
	end
end

function PassPanel.badge(): number
	return attr("PassClaimable", 0)
end

local function duration(seconds: number): string
	seconds = math.max(0, seconds)
	local days = math.floor(seconds / 86400)
	local hours = math.floor(seconds % 86400 / 3600)
	local minutes = math.floor(seconds % 3600 / 60)
	if days > 0 then
		return `{days}d {hours}h`
	elseif hours > 0 then
		return `{hours}h {minutes}m`
	end
	return `{minutes}m {math.floor(seconds % 60)}s`
end

-- Re-runs `text` every second while `label` is on screen (countdowns).
local function live(label: TextLabel, text: () -> string)
	label.Text = text()
	task.spawn(function()
		while label.Parent do
			task.wait(1)
			if label.Parent then
				label.Text = text()
			end
		end
	end)
end

-- The body's size before any UIScale above it (the window shrinks on small screens).
local function logicalSize(body: GuiObject): Vector2
	local scale = 1
	local node: Instance? = body
	while node do
		local s = node:FindFirstChildOfClass("UIScale")
		if s then
			scale *= s.Scale
		end
		node = node.Parent
	end
	local size = body.AbsoluteSize / math.max(scale, 0.01)
	if size.X < 100 or size.Y < 100 then
		return Vector2.new(612, 280)
	end
	return size
end

local function price(key: string): string
	local product = Catalog.Products[key]
	return if product then `R$ {UI.number(product.robux)}` else ""
end

--------------------------------------------------------------------------------------------
-- Reward art.

local FRAME_OF = { common = "Common", uncommon = "Common", rare = "Rare", epic = "Epic", legendary = "Legendary" }

-- Image, tint and rarity of a reward.
local function art(reward: Season.Reward): (string, Color3, string)
	local white = Color3.new(1, 1, 1)
	if reward.kind == "coins" then
		return ICONS.Coin, white, "common"
	elseif reward.kind == "gems" then
		return ICONS.Gem, white, "rare"
	elseif reward.kind == "whetstones" then
		return ICONS.Whetstone or ICONS.Skin, white, "common"
	elseif reward.kind == "draws" then
		return ICONS.ShrineDraw or ICONS.Rewards, white, "rare"
	end
	local item = Catalog.get(reward.id)
	if not item then
		return ICONS.Rewards, white, "common"
	end
	if item.category == "bladeSkin" then
		local t = Progression.skin(item.ref).tint
		return ICONS.Katana, Color3.new(math.min(t.X, 1), math.min(t.Y, 1), math.min(t.Z, 1)), item.rarity
	elseif item.category == "finisher" then
		return (ICONS.Finishers and ICONS.Finishers[item.ref]) or ICONS.Deathblow, white, item.rarity
	elseif item.category == "title" then
		return ICONS.Guide, white, item.rarity
	elseif item.category == "banner" then
		return ICONS.Trophy, white, item.rarity
	elseif item.category == "nameplate" then
		return ICONS.Profile, white, item.rarity
	end
	return (item.icon and ICONS[item.icon]) or ICONS.Rewards, white, item.rarity
end

local function shortText(reward: Season.Reward): string
	if reward.kind == "item" then
		local item = Catalog.get(reward.id)
		return if item then item.name else "?"
	end
	return UI.number(reward.amount or 0)
end

local function fullText(rewards: { Season.Reward }): string
	local parts = {}
	for _, reward in rewards do
		local item = reward.kind == "item" and Catalog.get(reward.id)
		if item then
			local category = if item.category == "bladeSkin"
				then "blade"
				elseif item.category == "nameplate" then "nameplate"
				else item.category
			table.insert(parts, `{item.name} ({category})`)
		else
			table.insert(parts, Season.rewardText(reward))
		end
	end
	return table.concat(parts, "  +  ")
end

local function pulse(stroke: UIStroke)
	local tween = TweenService:Create(
		stroke,
		TweenInfo.new(0.7, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
		{ Transparency = 0.6 }
	)
	tween:Play()
	stroke.Destroying:Once(function()
		tween:Cancel()
	end)
end

--------------------------------------------------------------------------------------------
-- Header: season, countdown, tier and XP bar, premium and tier skips.

local function header(body: Frame, width: number)
	local seasonId = ReplicatedStorage:GetAttribute("SeasonId") or ""
	local def = Season.get(attr("PassSeason", "") ~= "" and attr("PassSeason", "") or seasonId)
	local xp = attr("PassXP", 0)
	local tier = attr("PassTier", Season.tierOf(xp))
	local premium = attr("PassPremium", false) == true
	local pending = attr("PassTierSkips", 0)
	local running = ReplicatedStorage:GetAttribute("SeasonState") == "live"

	UI.new("ImageLabel", {
		Name = "Crest",
		Position = UDim2.fromOffset(-4, -4),
		Size = UDim2.fromOffset(64, 64),
		BackgroundTransparency = 1,
		Image = PassPanel.Icon,
	}, body)
	UI.text({
		Position = UDim2.fromOffset(64, 0),
		Size = UDim2.fromOffset(260, 16),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextSize = 14,
		TextColor3 = UI.Bronze,
		Text = if def then def.subtitle else "Path of the Blade",
	}, body)
	UI.text({
		Name = "Tier",
		Position = UDim2.fromOffset(64, 14),
		Size = UDim2.fromOffset(110, 32),
		TextXAlignment = Enum.TextXAlignment.Left,
		Font = UI.Display,
		TextSize = 32,
		TextColor3 = UI.Gold,
		Text = `Tier {tier}`,
	}, body)

	-- Pass XP toward the next tier.
	local right = 196 -- room for the premium column
	local barX = 176
	local barW = math.max(120, width - barX - right)
	local track = UI.new("Frame", {
		Name = "XPBar",
		Position = UDim2.fromOffset(barX, 22),
		Size = UDim2.fromOffset(barW, 16),
		BackgroundColor3 = Color3.fromRGB(12, 10, 12),
		BorderSizePixel = 0,
	}, body)
	UI.corner(track, UDim.new(1, 0))
	UI.stroke(track, UI.Bronze, 1, 0.5)
	local maxed = tier >= Season.Tiers
	local into = xp - tier * Season.TierXP
	local fill = UI.new("Frame", {
		Size = UDim2.fromScale(if maxed then 1 else math.clamp(into / Season.TierXP, 0.02, 1), 1),
		BackgroundColor3 = UI.Gold,
		BorderSizePixel = 0,
	}, track)
	UI.corner(fill, UDim.new(1, 0))
	UI.new("UIGradient", {
		Color = ColorSequence.new(Color3.fromRGB(255, 226, 150), Color3.fromRGB(200, 130, 40)),
	}, fill)
	UI.text({
		Size = UDim2.fromScale(1, 1),
		Font = UI.Bold,
		TextSize = 13,
		TextStrokeTransparency = 0.3,
		Text = if maxed
			then "Every tier reached"
			else `{UI.number(into)} / {UI.number(Season.TierXP)} Pass XP to tier {tier + 1}`,
	}, track)

	-- Countdown (the real end, from the server's season clock) and double XP.
	local clock = UI.text({
		Name = "Countdown",
		Position = UDim2.fromOffset(barX, 40),
		Size = UDim2.fromOffset(barW, 18),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextSize = 14,
		TextTransparency = 0.15,
		Text = "",
	}, body)
	live(clock, function()
		local state = ReplicatedStorage:GetAttribute("SeasonState")
		local endsAt = ReplicatedStorage:GetAttribute("SeasonEndsAt") or 0
		local left = endsAt - Season.now()
		local double = (ReplicatedStorage:GetAttribute("SeasonMultiplier") or 1) > 1
		if state == "live" then
			local ends = DateTime.fromUnixTimestamp(endsAt):FormatUniversalTime("MMM D", "en-us")
			return `Ends in {duration(left)}  ·  {ends}{if double then "  ·  DOUBLE PASS XP" else ""}`
		elseif state == "break" and endsAt > 0 then
			return `Season over  ·  claims stay open  ·  next season in {duration(left)}`
		end
		return "No season running"
	end)
	if (ReplicatedStorage:GetAttribute("SeasonMultiplier") or 1) > 1 then
		clock.TextColor3 = UI.Gold
	end

	-- Premium and tier skips.
	local column = UI.new("Frame", {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		Size = UDim2.fromOffset(right - 12, 62),
		BackgroundTransparency = 1,
	}, body)
	if premium then
		local chip = UI.panel({
			Name = "PremiumOwned",
			Size = UDim2.new(1, 0, 0, 30),
			BackgroundColor3 = PREMIUM_BG,
		}, column)
		UI.stroke(chip, UI.Gold, 1.5, 0.1)
		UI.text({
			Size = UDim2.fromScale(1, 1),
			Font = UI.Bold,
			TextSize = 16,
			TextColor3 = UI.Gold,
			Text = "PREMIUM  ✓",
		}, chip)
	else
		local upgrade = UI.button({
			Name = "BuyPremium",
			Size = UDim2.new(1, 0, 0, 30),
			BackgroundColor3 = if running then UI.Crimson else UI.PanelLight,
			Font = UI.Bold,
			TextSize = 16,
			Text = `Unlock Premium  ·  {price(Season.Products.Premium)}`,
		}, column)
		UI.stroke(upgrade, UI.Gold, 1.5, 0.1)
		upgrade.Activated:Connect(function()
			action("Buy", Season.Products.Premium)
		end)
	end
	local left = if running then Season.Tiers - tier - pending else 0
	for i, key in { Season.Products.TierSkip, Season.Products.Tiers10 } do
		local n = if i == 1 then 1 else 10
		local enabled = left >= n
		local skip = UI.button({
			Name = if i == 1 then "TierSkip" else "Tiers10",
			Position = UDim2.new((i - 1) / 2, if i == 1 then 0 else 3, 0, 34),
			Size = UDim2.new(0.5, -3, 0, 26),
			BackgroundColor3 = UI.PanelLight,
			TextColor3 = if enabled then UI.Parchment else DIM,
			TextSize = 13,
			Text = `+{n} tier{if n > 1 then "s" else ""}  ·  {price(key)}`,
		}, column)
		UI.stroke(skip, UI.Bronze, 1, 0.4)
		skip.Activated:Connect(function()
			if enabled then
				action("Buy", key)
			end
		end)
	end
end

--------------------------------------------------------------------------------------------
-- Tabs.

local function tabs(body: Frame, width: number, redraw: () -> ())
	local missions = decode("Missions")
	local done, total = 0, 0
	for _, list in { missions.daily or {}, missions.weekly or {} } do
		for _, entry in list do
			local mission = Season.mission(entry.id)
			if mission then
				total += 1
				if (entry.have or 0) >= mission.goal then
					done += 1
				end
			end
		end
	end
	for i, name in { "Rewards", "Missions" } do
		local selected = tab == name
		local button = UI.button({
			Name = `Tab{name}`,
			Position = UDim2.fromOffset((i - 1) * 124, 68),
			Size = UDim2.fromOffset(118, 28),
			BackgroundColor3 = if selected then UI.Crimson else UI.PanelLight,
			TextColor3 = if selected then UI.Parchment else Color3.fromRGB(200, 190, 175),
			TextSize = 16,
			Text = if name == "Missions" then `Missions  {done}/{total}` else "Rewards",
		}, body)
		if selected then
			UI.stroke(button, UI.Gold, 1, 0.3)
		end
		button.Activated:Connect(function()
			if tab ~= name then
				tab = name :: any
				redraw()
			end
		end)
	end
	local claimable = attr("PassClaimable", 0)
	if tab == "Rewards" and claimable > 0 then
		local all = UI.button({
			Name = "ClaimAll",
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, 0, 0, 68),
			Size = UDim2.fromOffset(150, 28),
			BackgroundColor3 = Color3.fromRGB(40, 110, 80),
			TextSize = 16,
			Text = `Claim all  ({claimable})`,
		}, body)
		local stroke = UI.new("UIStroke", {
			Color = UI.Gold,
			Thickness = 1.5,
			Transparency = 0,
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		}, all)
		pulse(stroke)
		all.Activated:Connect(function()
			action("ClaimAll")
		end)
	end
	local info = UI.text({
		Name = "Detail",
		Position = UDim2.fromOffset(256, 68),
		Size = UDim2.fromOffset(math.max(80, width - 256 - (if claimable > 0 then 160 else 0)), 28),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextSize = 14,
		TextTransparency = 0.15,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Text = if tab == "Rewards"
			then (detail or "Tap a reward to see it  ·  premium rewards stay claimable once you upgrade")
			else "Missions never cost gems  ·  one free reroll a day",
	}, body)
	return info
end

--------------------------------------------------------------------------------------------
-- The reward track.

local function trackView(body: Frame, size: Vector2, info: TextLabel)
	local def = Season.get(attr("PassSeason", "")) or Season.get(ReplicatedStorage:GetAttribute("SeasonId"))
	if not def then
		UI.text({
			Position = UDim2.fromOffset(0, 110),
			Size = UDim2.new(1, 0, 0, 30),
			Text = "No season is running.",
		}, body)
		return
	end
	local season = def :: Season.Def
	local tier = attr("PassTier", 0)
	local premium = attr("PassPremium", false) == true
	local claimed = decode("PassClaimed")
	local freeClaimed, premiumClaimed = {}, {}
	for _, n in claimed.free or {} do
		freeClaimed[n] = true
	end
	for _, n in claimed.premium or {} do
		premiumClaimed[n] = true
	end

	local top = 104
	local height = size.Y - top
	local gutter = 70
	local cell = math.clamp(math.floor((height - 24) / 2) - 6, 54, 110)
	local column = cell + 10

	-- Row labels.
	for row, name in { "FREE", "PREMIUM" } do
		local y = top + 22 + (row - 1) * (cell + 6)
		local label = UI.panel({
			Position = UDim2.fromOffset(0, y),
			Size = UDim2.fromOffset(gutter - 8, cell),
			BackgroundColor3 = if row == 2 then PREMIUM_BG else UI.PanelLight,
		}, body)
		if row == 2 then
			UI.stroke(label, UI.Gold, 1, 0.35)
		end
		UI.text({
			Position = UDim2.fromOffset(0, if row == 2 and not premium then 6 else 0),
			Size = UDim2.new(1, 0, 1, if row == 2 and not premium then -26 else 0),
			Font = UI.Bold,
			TextSize = 13,
			TextColor3 = if row == 2 then UI.Gold else UI.Parchment,
			Text = name,
		}, label)
		if row == 2 and not premium then
			UI.new("ImageLabel", {
				AnchorPoint = Vector2.new(0.5, 1),
				Position = UDim2.new(0.5, 0, 1, -6),
				Size = UDim2.fromOffset(24, 24),
				BackgroundTransparency = 1,
				Image = ICONS.Lock,
			}, label)
		end
	end

	-- In a container so Panels' own scroll keeping (first ScrollingFrame in the body) leaves
	-- the track alone: it keeps its scroll itself and recentres when the tier changes.
	local view = UI.new("Frame", {
		Name = "TrackView",
		Position = UDim2.fromOffset(gutter, top),
		Size = UDim2.new(1, -gutter, 0, height),
		BackgroundTransparency = 1,
	}, body)
	local scroller = UI.new("ScrollingFrame", {
		Name = "Track",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 5,
		ScrollBarImageColor3 = UI.Bronze,
		ScrollingDirection = Enum.ScrollingDirection.X,
		VerticalScrollBarInset = Enum.ScrollBarInset.None,
		CanvasSize = UDim2.fromOffset(Season.Tiers * column + 6, 0),
	}, view)

	-- The path: a line through every tier, gold up to yours.
	local path = UI.new("Frame", {
		Position = UDim2.fromOffset(column / 2, 10),
		Size = UDim2.fromOffset((Season.Tiers - 1) * column, 3),
		BackgroundColor3 = Color3.fromRGB(70, 60, 55),
		BorderSizePixel = 0,
	}, scroller)
	UI.new("Frame", {
		Size = UDim2.fromScale(math.clamp((tier - 1) / (Season.Tiers - 1), 0, 1), 1),
		BackgroundColor3 = UI.Gold,
		BorderSizePixel = 0,
	}, path)

	for t = 1, Season.Tiers do
		local entry = season.tiers[t]
		local x = (t - 1) * column + 3
		local reached = t <= tier
		local isNext = t == tier + 1
		if isNext or t == tier then
			UI.new("Frame", {
				Position = UDim2.fromOffset(x - 3, 20),
				Size = UDim2.fromOffset(column - 4, cell * 2 + 10),
				BackgroundColor3 = UI.Gold,
				BackgroundTransparency = if t == tier then 0.86 else 0.93,
				BorderSizePixel = 0,
			}, scroller)
		end
		local dotSize = if t % 5 == 0 or t == tier then 20 else 16
		local dot = UI.new("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromOffset(x + cell / 2, 11),
			Size = UDim2.fromOffset(dotSize, dotSize),
			BackgroundColor3 = if reached then UI.Gold else Color3.fromRGB(46, 40, 40),
			BorderSizePixel = 0,
			ZIndex = 2,
		}, scroller)
		UI.corner(dot, UDim.new(1, 0))
		UI.stroke(dot, if reached then Color3.fromRGB(255, 240, 200) else UI.Bronze, 1, 0.3)
		UI.text({
			Size = UDim2.fromScale(1, 1),
			Font = UI.Bold,
			TextSize = 11,
			TextColor3 = if reached then UI.Ink else UI.Parchment,
			Text = tostring(t),
			ZIndex = 3,
		}, dot)

		for row, track in { "free", "premium" } do
			local rewards: { Season.Reward }? = if track == "free" then entry.free else entry.premium
			local y = 22 + (row - 1) * (cell + 6)
			if not rewards then
				UI.new("Frame", {
					AnchorPoint = Vector2.new(0.5, 0.5),
					Position = UDim2.fromOffset(x + cell / 2, y + cell / 2),
					Size = UDim2.fromOffset(10, 2),
					BackgroundColor3 = Color3.fromRGB(80, 70, 66),
					BorderSizePixel = 0,
				}, scroller)
				continue
			end
			local list = rewards :: { Season.Reward }
			local isPremium = track == "premium"
			local done = if isPremium then premiumClaimed[t] == true else freeClaimed[t] == true
			local ready = reached and not done and (not isPremium or premium)
			local image, tint, rarity = art(list[1])
			if t == Season.Tiers and isPremium then
				rarity = "legendary"
			end
			local card = UI.new("TextButton", {
				Name = `{track}{t}`,
				Position = UDim2.fromOffset(x, y),
				Size = UDim2.fromOffset(cell, cell),
				BackgroundColor3 = if isPremium then PREMIUM_BG else UI.PanelLight,
				BackgroundTransparency = if reached then 0 else 0.25,
				BorderSizePixel = 0,
				AutoButtonColor = false,
				Text = "",
			}, scroller)
			UI.corner(card)
			UI.new("ImageLabel", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.44),
				Size = UDim2.fromScale(0.66, 0.66),
				BackgroundTransparency = 1,
				Image = image,
				ImageColor3 = tint,
				ImageTransparency = if done then 0.55 elseif reached then 0 else 0.3,
			}, card)
			UI.new("ImageLabel", {
				Size = UDim2.fromScale(1, 1),
				BackgroundTransparency = 1,
				Image = Assets.Icons.RarityFrames[FRAME_OF[rarity] or "Common"] or "",
				ImageTransparency = if reached then 0.05 else 0.4,
			}, card)
			UI.text({
				AnchorPoint = Vector2.new(0.5, 1),
				Position = UDim2.new(0.5, 0, 1, -3),
				Size = UDim2.new(1, -8, 0, 14),
				Font = UI.Bold,
				TextSize = if list[1].kind == "item" then 11 else 14,
				TextStrokeTransparency = 0.25,
				TextTruncate = Enum.TextTruncate.AtEnd,
				TextColor3 = if list[1].kind == "gems"
					then Color3.fromRGB(150, 235, 190)
					elseif list[1].kind == "coins" then UI.Gold
					else UI.Parchment,
				Text = shortText(list[1]),
			}, card)
			if #list > 1 then
				local more = UI.new("Frame", {
					AnchorPoint = Vector2.new(0, 0),
					Position = UDim2.fromOffset(4, 4),
					Size = UDim2.fromOffset(26, 16),
					BackgroundColor3 = UI.Crimson,
					BorderSizePixel = 0,
				}, card)
				UI.corner(more, UDim.new(1, 0))
				UI.text({ Size = UDim2.fromScale(1, 1), Font = UI.Bold, TextSize = 11, Text = `+{#list - 1}` }, more)
			end
			if done then
				local check = UI.new("Frame", {
					AnchorPoint = Vector2.new(1, 0),
					Position = UDim2.new(1, -4, 0, 4),
					Size = UDim2.fromOffset(20, 20),
					BackgroundColor3 = UI.Jade,
					BorderSizePixel = 0,
				}, card)
				UI.corner(check, UDim.new(1, 0))
				UI.text({ Size = UDim2.fromScale(1, 1), Font = UI.Bold, TextSize = 13, Text = "✓" }, check)
			elseif isPremium and not premium then
				UI.new("ImageLabel", {
					AnchorPoint = Vector2.new(1, 0),
					Position = UDim2.new(1, -3, 0, 3),
					Size = UDim2.fromOffset(18, 18),
					BackgroundTransparency = 1,
					Image = ICONS.Lock,
				}, card)
			end
			if ready then
				local stroke = UI.new("UIStroke", {
					Color = UI.Gold,
					Thickness = 2.5,
					Transparency = 0,
					ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
				}, card)
				pulse(stroke)
				local pill = UI.new("Frame", {
					AnchorPoint = Vector2.new(0.5, 0.5),
					Position = UDim2.new(0.5, 0, 0, 12),
					Size = UDim2.fromOffset(math.min(cell - 6, 56), 16),
					BackgroundColor3 = Color3.fromRGB(40, 120, 84),
					BorderSizePixel = 0,
					ZIndex = 3,
				}, card)
				UI.corner(pill, UDim.new(1, 0))
				UI.text({
					Size = UDim2.fromScale(1, 1),
					Font = UI.Bold,
					TextSize = 11,
					Text = "CLAIM",
					ZIndex = 4,
				}, pill)
			end
			local describe = `Tier {t}  ·  {if isPremium then "Premium" else "Free"}  ·  {fullText(list)}`
			card.Activated:Connect(function()
				detail = describe
				info.Text = describe
				if ready then
					action("Claim", track, t)
				end
			end)
		end
	end

	-- Keep the scroll where it was; jump to your tier when it changes (or on first open).
	local viewW = size.X - gutter
	if scrollX == nil or centeredOn ~= tier then
		centeredOn = tier
		scrollX = math.clamp(math.max(tier, 1) * column - viewW / 2, 0, math.max(0, Season.Tiers * column + 6 - viewW))
	end
	scroller.CanvasPosition = Vector2.new(scrollX :: number, 0)
	task.defer(function()
		if scroller.Parent then
			scroller.CanvasPosition = Vector2.new(scrollX :: number, 0)
			scroller:GetPropertyChangedSignal("CanvasPosition"):Connect(function()
				scrollX = scroller.CanvasPosition.X
			end)
		end
	end)
end

--------------------------------------------------------------------------------------------
-- Missions.

local function missionRow(parent: Instance, entry: any, height: number, order: number, canReroll: boolean)
	local mission = Season.mission(entry.id)
	if not mission then
		return
	end
	local m = mission :: Season.Mission
	local have = math.min(entry.have or 0, m.goal)
	local done = have >= m.goal
	local row = UI.panel({
		Name = m.id,
		Size = UDim2.new(1, -6, 0, height),
		LayoutOrder = order,
		BackgroundColor3 = if done then Color3.fromRGB(32, 46, 38) else UI.PanelLight,
	}, parent)
	if done then
		UI.stroke(row, UI.Jade, 1.5, 0.3)
	end
	local rewardW = 116
	UI.text({
		Position = UDim2.fromOffset(10, 3),
		Size = UDim2.new(1, -(rewardW + 16), 0, 18),
		TextXAlignment = Enum.TextXAlignment.Left,
		Font = UI.Bold,
		TextSize = 15,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Text = m.text,
	}, row)
	local bar = UI.new("Frame", {
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 10, 1, -6),
		Size = UDim2.new(1, -(rewardW + 16 + (if canReroll and not done then 58 else 0)), 0, 12),
		BackgroundColor3 = Color3.fromRGB(12, 10, 12),
		BorderSizePixel = 0,
	}, row)
	UI.corner(bar, UDim.new(1, 0))
	local fill = UI.new("Frame", {
		Size = UDim2.fromScale(math.max(have / m.goal, 0.03), 1),
		BackgroundColor3 = if done then UI.Jade else UI.Crimson,
		BorderSizePixel = 0,
	}, bar)
	UI.corner(fill, UDim.new(1, 0))
	UI.text({
		Size = UDim2.fromScale(1, 1),
		Font = UI.Bold,
		TextSize = 11,
		TextStrokeTransparency = 0.3,
		Text = if done then "DONE" else `{have} / {m.goal}`,
	}, bar)
	-- Reward: Pass XP and coins.
	local reward = UI.new("Frame", {
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -6, 0.5, 0),
		Size = UDim2.fromOffset(rewardW, height - 6),
		BackgroundTransparency = 1,
	}, row)
	UI.new("ImageLabel", {
		Position = UDim2.fromOffset(0, 0),
		Size = UDim2.fromOffset(20, 20),
		BackgroundTransparency = 1,
		Image = ICONS.PassXP or ICONS.Level,
	}, reward)
	local multiplier = ReplicatedStorage:GetAttribute("SeasonMultiplier") or 1
	UI.text({
		Position = UDim2.fromOffset(22, 0),
		Size = UDim2.new(1, -22, 0, 20),
		TextXAlignment = Enum.TextXAlignment.Left,
		Font = UI.Bold,
		TextSize = 15,
		TextColor3 = PASS_BLUE,
		Text = `+{math.floor(m.pass * math.max(multiplier, 1))} Pass XP`,
	}, reward)
	UI.new("ImageLabel", {
		Position = UDim2.fromOffset(2, 20),
		Size = UDim2.fromOffset(16, 16),
		BackgroundTransparency = 1,
		Image = ICONS.Coin,
	}, reward)
	UI.text({
		Position = UDim2.fromOffset(22, 19),
		Size = UDim2.new(1, -22, 0, 18),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextSize = 13,
		TextColor3 = UI.Gold,
		Text = `{m.coins}  ·  +{m.whetstones}`,
	}, reward)
	UI.new("ImageLabel", {
		Position = UDim2.new(1, -16, 0, 20),
		Size = UDim2.fromOffset(16, 16),
		BackgroundTransparency = 1,
		Image = ICONS.Whetstone or ICONS.Skin,
	}, reward)
	if canReroll and not done then
		local reroll = UI.button({
			Name = "Reroll",
			AnchorPoint = Vector2.new(1, 1),
			Position = UDim2.new(1, -(rewardW + 10), 1, -3),
			Size = UDim2.fromOffset(52, 18),
			BackgroundColor3 = UI.Panel,
			TextSize = 12,
			Text = "Reroll",
		}, row)
		UI.stroke(reroll, UI.Bronze, 1, 0.3)
		reroll.Activated:Connect(function()
			action("Reroll", m.id)
		end)
	end
end

local function missionsView(body: Frame, size: Vector2)
	local missions = decode("Missions")
	local top = 104
	local height = size.Y - top
	local split = math.floor(size.X * 0.47)
	for col, spec in
		{
			{ title = "Today", list = missions.daily or {}, x = 0, w = split - 8 },
			{ title = "This week", list = missions.weekly or {}, x = split + 4, w = size.X - split - 4 },
		}
	do
		UI.text({
			Position = UDim2.fromOffset(spec.x, top),
			Size = UDim2.fromOffset(spec.w, 20),
			TextXAlignment = Enum.TextXAlignment.Left,
			Font = UI.Display,
			TextSize = 20,
			TextColor3 = UI.Gold,
			Text = spec.title,
		}, body)
		local clock = UI.text({
			Position = UDim2.fromOffset(spec.x, top + 2),
			Size = UDim2.fromOffset(spec.w - 8, 18),
			TextXAlignment = Enum.TextXAlignment.Right,
			TextSize = 13,
			TextTransparency = 0.25,
			Text = "",
		}, body)
		if col == 1 then
			live(clock, function()
				local endsAt = ReplicatedStorage:GetAttribute("DayEndsAt") or 0
				return `New missions in {duration(endsAt - workspace:GetServerTimeNow())}`
			end)
		else
			live(clock, function()
				return `New bounties in {duration((missions.weekEndsAt or 0) - workspace:GetServerTimeNow())}`
			end)
		end
		local list = UI.new("ScrollingFrame", {
			Position = UDim2.fromOffset(spec.x, top + 24),
			Size = UDim2.fromOffset(spec.w, height - 24),
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			ScrollBarThickness = 4,
			ScrollBarImageColor3 = UI.Bronze,
			ScrollingDirection = Enum.ScrollingDirection.Y,
			AutomaticCanvasSize = Enum.AutomaticSize.Y,
			CanvasSize = UDim2.new(),
		}, body)
		UI.new("UIListLayout", { Padding = UDim.new(0, 5), SortOrder = Enum.SortOrder.LayoutOrder }, list)
		local rowH = if col == 1
			then math.clamp(math.floor((height - 24) / 3) - 6, 42, 64)
			else math.clamp(math.floor((height - 24) / 4) - 6, 42, 52)
		for i, entry in spec.list do
			missionRow(list, entry, rowH, i, col == 1 and missions.reroll == true)
		end
	end
end

--------------------------------------------------------------------------------------------

function PassPanel.build(body: Frame)
	local size = logicalSize(body)
	local function redraw()
		for _, child in body:GetChildren() do
			child:Destroy()
		end
		PassPanel.build(body)
	end
	header(body, size.X)
	local info = tabs(body, size.X, redraw)
	if tab == "Rewards" then
		trackView(body, size, info)
	else
		missionsView(body, size)
	end
end

return PassPanel
