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

local T = UI.Theme
local PREMIUM_TINT = T.Lacquer:Lerp(T.Gold, 0.18) -- the premium row's plates (gold-brown lacquer)
local DONE_TINT = T.Lacquer:Lerp(T.Jade, 0.18) -- a finished mission's plate
local HEADER_H = 60
local ROW2_Y = 68 -- tabs, Claim all and the tier skips (60 px tall: >= 45 pt on a phone)
local CONTENT_Y = 136
local DETAIL_H = 24

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

-- An Assets.Icons.Tabs icon (Titles, Banners, ...), or `fallback` while it's missing.
local function tabIcon(key: string, fallback: string): string
	local tabsIcons = ICONS.Tabs
	local value = typeof(tabsIcons) == "table" and tabsIcons[key] or nil
	return if typeof(value) == "string" then value else fallback
end

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
		return tabIcon("Titles", ICONS.Guide), white, item.rarity
	elseif item.category == "banner" then
		return tabIcon("Banners", ICONS.Trophy), white, item.rarity
	elseif item.category == "nameplate" then
		return tabIcon("Titles", ICONS.Profile), white, item.rarity
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

-- A soft breathing glow on a stroke (claimable cells, Claim all).
local function pulse(stroke: UIStroke)
	if UI.reducedMotion() then
		return
	end
	local tween = UI.play(stroke, UI.Motion.Pulse, { Transparency = 0.65 })
	stroke.Destroying:Once(function()
		tween:Cancel()
	end)
end

--------------------------------------------------------------------------------------------
-- Header: the tier medallion, season, Pass XP bar and countdown, and premium.

local function header(body: Frame, width: number)
	local seasonId = ReplicatedStorage:GetAttribute("SeasonId") or ""
	local def = Season.get(attr("PassSeason", "") ~= "" and attr("PassSeason", "") or seasonId)
	local xp = attr("PassXP", 0)
	local tier = attr("PassTier", Season.tierOf(xp))
	local premium = attr("PassPremium", false) == true
	local running = ReplicatedStorage:GetAttribute("SeasonState") == "live"

	-- The tier medallion: the season crest with your tier on an ink plate.
	local crest = UI.new("ImageLabel", {
		Name = "Crest",
		Size = UDim2.fromOffset(HEADER_H, HEADER_H),
		BackgroundTransparency = 1,
		Image = PassPanel.Icon,
	}, body)
	local plate = UI.new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.9),
		Size = UDim2.fromOffset(36, 22),
		BackgroundColor3 = T.Ink,
		BorderSizePixel = 0,
		ZIndex = 2,
	}, crest)
	UI.new("UICorner", { CornerRadius = UDim.new(1, 0) }, plate)
	UI.new("UIStroke", { Color = T.Gold, Thickness = 1.5 }, plate)
	UI.text({
		Size = UDim2.fromScale(1, 1),
		FontFace = UI.Fonts.Number,
		TextSize = 15,
		TextColor3 = T.GoldHi,
		Text = tostring(tier),
		ZIndex = 3,
	}, plate)
	UI.label("caption", {
		Position = UDim2.fromOffset(HEADER_H + 10, 0),
		Size = UDim2.fromOffset(130, 18),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Text = if def then def.subtitle else "Path of the Blade",
	}, body)
	UI.text({
		Name = "Tier",
		Position = UDim2.fromOffset(HEADER_H + 10, 18),
		Size = UDim2.fromOffset(130, 36),
		TextXAlignment = Enum.TextXAlignment.Left,
		FontFace = UI.Fonts.Display,
		TextSize = 28,
		TextColor3 = T.GoldHi,
		Text = `Tier {tier}`,
	}, body)

	-- Pass XP toward the next tier (value outside the bar), the countdown under it.
	local right = 232 -- the premium button
	local barX = HEADER_H + 146
	local barW = math.max(150, width - barX - right - 16)
	local maxed = tier >= Season.Tiers
	local into = xp - tier * Season.TierXP
	UI.progress({
		Name = "XPBar",
		Position = UDim2.fromOffset(barX, 4),
		Size = UDim2.fromOffset(barW, 22),
		height = 10,
		textWidth = 112,
		tone = "gold",
		value = if maxed then 1 else into,
		max = if maxed then 1 else Season.TierXP,
		format = function(v: number, m: number): string
			return if maxed then "Every tier" else `{UI.number(v)} / {UI.number(m)}`
		end,
	}, body)
	local clock = UI.text({
		Name = "Countdown",
		Position = UDim2.fromOffset(barX, 30),
		Size = UDim2.fromOffset(barW, 22),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		FontFace = UI.Fonts.Label,
		TextSize = 15,
		TextColor3 = T.Dim,
		Text = "",
	}, body)
	live(clock, function()
		local state = ReplicatedStorage:GetAttribute("SeasonState")
		local endsAt = ReplicatedStorage:GetAttribute("SeasonEndsAt") or 0
		local left = endsAt - Season.now()
		local double = (ReplicatedStorage:GetAttribute("SeasonMultiplier") or 1) > 1
		local next = if maxed then "" else `Pass XP to tier {tier + 1}  ·  `
		if state == "live" then
			local ends = DateTime.fromUnixTimestamp(endsAt):FormatUniversalTime("MMM D", "en-us")
			return `{next}ends in {duration(left)} ({ends}){if double then "  ·  DOUBLE PASS XP" else ""}`
		elseif state == "break" and endsAt > 0 then
			return `Season over  ·  claims stay open  ·  next season in {duration(left)}`
		end
		return "No season running"
	end)
	if (ReplicatedStorage:GetAttribute("SeasonMultiplier") or 1) > 1 then
		clock.TextColor3 = T.GoldHi
	end

	-- Premium: owned chip, or the upgrade (a Robux purchase: the premium variant).
	if premium then
		local chip = UI.panel({
			Name = "PremiumOwned",
			material = "inset",
			tint = PREMIUM_TINT,
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.fromScale(1, 0),
			Size = UDim2.fromOffset(right - 12, HEADER_H),
		}, body)
		UI.stroke(chip, T.Gold, 1.5, 0.05)
		UI.text({
			Size = UDim2.fromScale(1, 1),
			FontFace = UI.Fonts.Number,
			TextSize = 18,
			TextColor3 = T.GoldHi,
			Text = "PREMIUM  ✓",
		}, chip)
	else
		local upgrade = UI.button({
			Name = "BuyPremium",
			variant = if running then "premium" else "disabled",
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.fromScale(1, 0),
			Size = UDim2.fromOffset(right - 12, HEADER_H),
			FontFace = UI.Fonts.Number,
			TextSize = 17,
			Text = `Unlock Premium  ·  {price(Season.Products.Premium)}`,
		}, body)
		upgrade.Activated:Connect(function()
			action("Buy", Season.Products.Premium)
		end)
	end
end

--------------------------------------------------------------------------------------------
-- Tabs, Claim all and tier skips (one 60 px row), and the detail line along the bottom.

local function tabs(body: Frame, size: Vector2, redraw: () -> ()): TextLabel?
	local width = size.X
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
	local x = 0
	for _, name in { "Rewards", "Missions" } do
		local selected = tab == name
		local w = if name == "Missions" then 168 else 128
		local button = UI.new("TextButton", {
			Name = `Tab{name}`,
			Position = UDim2.fromOffset(x, ROW2_Y),
			Size = UDim2.fromOffset(w, UI.Touch),
			BackgroundTransparency = 1,
			AutoButtonColor = false,
			FontFace = if selected then UI.Fonts.Number else UI.Fonts.Label,
			TextSize = 17,
			TextColor3 = if selected then T.Bone else T.Dim,
			Text = string.upper(if name == "Missions" then `Missions  {done}/{total}` else "Rewards"),
		}, body)
		if selected then
			UI.brush(button, "underline", {
				AnchorPoint = Vector2.new(0.5, 1),
				Position = UDim2.new(0.5, 0, 1, -2),
				Size = UDim2.new(1, -20, 0, 14),
				color = T.Crimson,
			})
		end
		button.MouseEnter:Connect(function()
			button.TextColor3 = T.Bone
		end)
		button.MouseLeave:Connect(function()
			button.TextColor3 = if selected then T.Bone else T.Dim
		end)
		button.Activated:Connect(function()
			if tab ~= name then
				UI.sound("Tab")
				tab = name :: any
				redraw()
			end
		end)
		UI.select(button)
		x += w + 4
	end
	UI.new("Frame", {
		Name = "TabRule",
		Position = UDim2.fromOffset(0, ROW2_Y + UI.Touch),
		Size = UDim2.new(1, 0, 0, 1),
		BackgroundColor3 = T.Gold,
		BackgroundTransparency = 0.75,
		BorderSizePixel = 0,
	}, body)

	-- Right side: Claim all (rewards tab), then the tier skips.
	local actions = UI.new("Frame", {
		Name = "Actions",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromOffset(width, ROW2_Y),
		Size = UDim2.fromOffset(width - x, UI.Touch),
		BackgroundTransparency = 1,
	}, body)
	UI.new("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		HorizontalAlignment = Enum.HorizontalAlignment.Right,
		Padding = UDim.new(0, 8),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, actions)
	local claimable = attr("PassClaimable", 0)
	if tab == "Rewards" and claimable > 0 then
		local all = UI.button({
			Name = "ClaimAll",
			variant = "reward",
			LayoutOrder = 1,
			Size = UDim2.fromOffset(164, UI.Touch),
			FontFace = UI.Fonts.Number,
			TextSize = 17,
			Text = `Claim all  ({claimable})`,
			sound = "Claim",
		}, actions)
		local glow = UI.new("UIStroke", {
			Color = T.JadeText,
			Thickness = 2,
			Transparency = 0,
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		}, all)
		pulse(glow)
		all.Activated:Connect(function()
			action("ClaimAll")
		end)
	end
	local running = ReplicatedStorage:GetAttribute("SeasonState") == "live"
	local tier = attr("PassTier", 0)
	local left = if running then Season.Tiers - tier - attr("PassTierSkips", 0) else 0
	for i, key in { Season.Products.TierSkip, Season.Products.Tiers10 } do
		local n = if i == 1 then 1 else 10
		local enabled = left >= n
		local skip = UI.button({
			Name = if i == 1 then "TierSkip" else "Tiers10",
			variant = if enabled then "premium" else "disabled",
			LayoutOrder = 1 + i,
			Size = UDim2.fromOffset(if i == 1 then 136 else 152, UI.Touch),
			TextSize = 16,
			Text = `+{n} tier{if n > 1 then "s" else ""}  ·  {price(key)}`,
		}, actions)
		skip.Activated:Connect(function()
			if enabled then
				action("Buy", key)
			end
		end)
	end

	if tab ~= "Rewards" then
		return nil
	end
	return UI.text({
		Name = "Detail",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromOffset(0, size.Y),
		Size = UDim2.new(1, 0, 0, DETAIL_H),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		FontFace = UI.Fonts.Label,
		TextSize = 15,
		TextColor3 = T.Dim,
		Text = detail or "Tap a reward to see it  ·  premium rewards stay claimable once you upgrade",
	}, body)
end

--------------------------------------------------------------------------------------------
-- The reward track: a free row and a premium row (gold trim), tier cells drawn like small
-- rarity cards, the path with your tier marked by a crimson brush stroke.

local function trackView(body: Frame, size: Vector2, info: TextLabel?)
	local def = Season.get(attr("PassSeason", "")) or Season.get(ReplicatedStorage:GetAttribute("SeasonId"))
	if not def then
		UI.text({
			Position = UDim2.fromOffset(0, CONTENT_Y + 20),
			Size = UDim2.new(1, 0, 0, 30),
			TextColor3 = T.Dim,
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

	local top = CONTENT_Y
	local height = size.Y - top - DETAIL_H
	local gutter = 86
	local pathH = 26
	local cell = math.clamp(math.floor((height - pathH - 6) / 2) - 4, 54, 110)
	local column = cell + 10

	-- Row labels.
	for row, name in { "FREE", "PREMIUM" } do
		local y = top + pathH + (row - 1) * (cell + 6)
		local isPremium = row == 2
		local label = UI.panel({
			Name = `{name}Label`,
			material = "inset",
			tint = if isPremium then PREMIUM_TINT else T.Lacquer,
			Position = UDim2.fromOffset(0, y),
			Size = UDim2.fromOffset(gutter - 8, cell),
		}, body)
		if isPremium then
			UI.stroke(label, T.Gold, 1.5, 0.05)
		end
		UI.text({
			Position = UDim2.fromOffset(0, if isPremium and not premium then 4 else 0),
			Size = UDim2.new(1, 0, 1, if isPremium and not premium then -28 else 0),
			FontFace = UI.Fonts.Number,
			TextSize = 14,
			TextColor3 = if isPremium then T.GoldHi else T.Bone,
			Text = name,
		}, label)
		if isPremium and not premium then
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
	local canvasW = Season.Tiers * column + 6
	local scroller = UI.new("ScrollingFrame", {
		Name = "Track",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 5,
		ScrollBarImageColor3 = T.Gold,
		ScrollBarImageTransparency = 0.3,
		ScrollingDirection = Enum.ScrollingDirection.X,
		VerticalScrollBarInset = Enum.ScrollBarInset.None,
		CanvasSize = UDim2.fromOffset(canvasW, 0),
	}, view)

	-- The premium row's gold trim, under its cells.
	local trim = UI.new("Frame", {
		Name = "PremiumTrim",
		Position = UDim2.fromOffset(0, pathH + cell + 6 - 3),
		Size = UDim2.fromOffset(canvasW - 2, cell + 6),
		BackgroundColor3 = PREMIUM_TINT,
		BackgroundTransparency = 0.55,
		BorderSizePixel = 0,
	}, scroller)
	UI.new("UICorner", { CornerRadius = UDim.new(0, 4) }, trim)
	UI.new("UIStroke", { Color = T.Gold, Thickness = 1, Transparency = 0.35 }, trim)

	-- The path: a line through every tier, gold up to yours.
	local path = UI.new("Frame", {
		Position = UDim2.fromOffset(column / 2, 11),
		Size = UDim2.fromOffset((Season.Tiers - 1) * column, 3),
		BackgroundColor3 = T.LacquerHi,
		BorderSizePixel = 0,
	}, scroller)
	UI.new("Frame", {
		Size = UDim2.fromScale(math.clamp((tier - 1) / (Season.Tiers - 1), 0, 1), 1),
		BackgroundColor3 = T.Gold,
		BorderSizePixel = 0,
	}, path)

	for t = 1, Season.Tiers do
		local entry = season.tiers[t]
		local x = (t - 1) * column + 3
		local reached = t <= tier
		if t == tier then
			-- Your tier: a crimson brush stroke under its number and a faint column.
			UI.new("Frame", {
				Position = UDim2.fromOffset(x - 3, pathH - 2),
				Size = UDim2.fromOffset(column - 4, cell * 2 + 12),
				BackgroundColor3 = T.GoldHi,
				BackgroundTransparency = 0.9,
				BorderSizePixel = 0,
			}, scroller)
			UI.brush(scroller, "underline", {
				Name = "YourTier",
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromOffset(x + cell / 2, 20),
				Size = UDim2.fromOffset(math.max(cell, 60), 14),
				color = T.Crimson,
				ZIndex = 1,
			})
		end
		local dotSize = if t % 5 == 0 or t == tier then 24 else 22
		local dot = UI.new("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromOffset(x + cell / 2, 12),
			Size = UDim2.fromOffset(dotSize, dotSize),
			BackgroundColor3 = if reached then T.Gold else T.Ink,
			BorderSizePixel = 0,
			ZIndex = 2,
		}, scroller)
		UI.new("UICorner", { CornerRadius = UDim.new(1, 0) }, dot)
		UI.new("UIStroke", {
			Color = if reached then T.GoldHi else T.Bronze,
			Thickness = 1,
			Transparency = 0.2,
		}, dot)
		UI.text({
			Size = UDim2.fromScale(1, 1),
			FontFace = UI.Fonts.Number,
			TextSize = 14,
			TextColor3 = if reached then T.Ink else T.Bone,
			Text = tostring(t),
			ZIndex = 3,
		}, dot)

		for row, track in { "free", "premium" } do
			local rewards: { Season.Reward }? = if track == "free" then entry.free else entry.premium
			local y = pathH + (row - 1) * (cell + 6)
			if not rewards then
				UI.new("Frame", {
					AnchorPoint = Vector2.new(0.5, 0.5),
					Position = UDim2.fromOffset(x + cell / 2, y + cell / 2),
					Size = UDim2.fromOffset(10, 2),
					BackgroundColor3 = T.Ash,
					BackgroundTransparency = 0.5,
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
				BackgroundTransparency = 1,
				AutoButtonColor = false,
				Text = "",
			}, scroller)
			local base = UI.panel({
				Name = "Base",
				material = "inset",
				tint = if isPremium then PREMIUM_TINT else T.Lacquer,
				Size = UDim2.fromScale(1, 1),
			}, card)
			if not reached then
				base.ImageTransparency = 0.3
				if base:GetAttribute("ArtMode") ~= true then
					base.BackgroundTransparency = 0.3
				end
			end
			if reached then
				UI.rarityGlow(base, rarity, 1)
			end
			UI.new("ImageLabel", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.42),
				Size = UDim2.fromScale(0.62, 0.62),
				BackgroundTransparency = 1,
				Image = image,
				ImageColor3 = tint,
				ImageTransparency = if done then 0.55 elseif reached then 0 else 0.3,
				ZIndex = 2,
			}, card)
			local frame = UI.rarityFrame(card, rarity, 3, if cell >= 80 then 0.12 else 0.1)
			if frame and not reached then
				frame.ImageTransparency = 0.4
			end
			local first = list[1]
			UI.text({
				AnchorPoint = Vector2.new(0.5, 1),
				Position = UDim2.new(0.5, 0, 1, -5),
				Size = UDim2.new(1, -12, 0, 17),
				FontFace = if first.kind == "item" then UI.Fonts.Label else UI.Fonts.Number,
				TextSize = 14,
				TextStrokeColor3 = T.Ink,
				TextStrokeTransparency = 0.25,
				TextTruncate = Enum.TextTruncate.AtEnd,
				TextColor3 = if first.kind == "gems"
					then T.JadeText
					elseif first.kind == "coins" then T.GoldHi
					elseif first.kind == "item" then UI.rarity(rarity).text
					else T.Bone,
				Text = shortText(first),
				ZIndex = 4,
			}, card)
			if #list > 1 then
				local more = UI.new("Frame", {
					Position = UDim2.fromOffset(5, 5),
					Size = UDim2.fromOffset(30, 18),
					BackgroundColor3 = T.Ink,
					BorderSizePixel = 0,
					ZIndex = 4,
				}, card)
				UI.new("UICorner", { CornerRadius = UDim.new(1, 0) }, more)
				UI.new("UIStroke", { Color = T.Gold, Thickness = 1, Transparency = 0.3 }, more)
				UI.text({
					Size = UDim2.fromScale(1, 1),
					FontFace = UI.Fonts.Number,
					TextSize = 14,
					TextColor3 = T.GoldHi,
					Text = `+{#list - 1}`,
					ZIndex = 5,
				}, more)
			end
			if done then
				local seal = UI.badge(card, "done", 22)
				seal.AnchorPoint = Vector2.new(1, 0)
				seal.Position = UDim2.new(1, -3, 0, 3)
			elseif isPremium and not premium then
				UI.new("ImageLabel", {
					AnchorPoint = Vector2.new(1, 0),
					Position = UDim2.new(1, -4, 0, 4),
					Size = UDim2.fromOffset(22, 22),
					BackgroundTransparency = 1,
					Image = ICONS.Lock,
					ZIndex = 5,
				}, card)
			end
			if ready then
				-- Claimable: the Reward look, a soft jade pulse and a CLAIM chip.
				local glow = UI.new("UIStroke", {
					Color = T.JadeText,
					Thickness = 2.5,
					Transparency = 0,
					ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
				}, card)
				pulse(glow)
				local chip = UI.new("Frame", {
					AnchorPoint = Vector2.new(0.5, 0.5),
					Position = UDim2.new(0.5, 0, 0, 13),
					Size = UDim2.fromOffset(math.min(cell - 8, 64), 20),
					BackgroundColor3 = T.JadeBtn,
					BorderSizePixel = 0,
					ZIndex = 5,
				}, card)
				UI.new("UICorner", { CornerRadius = UDim.new(1, 0) }, chip)
				UI.new("UIStroke", { Color = T.JadeText, Thickness = 1 }, chip)
				UI.text({
					Size = UDim2.fromScale(1, 1),
					FontFace = UI.Fonts.Number,
					TextSize = 14,
					Text = "CLAIM",
					ZIndex = 6,
				}, chip)
			end
			UI.juice(card, { hover = 1.05, press = 0.95 })
			local describe = `Tier {t}  ·  {if isPremium then "Premium" else "Free"}  ·  {fullText(list)}`
			card.Activated:Connect(function()
				detail = describe
				if info then
					info.Text = describe
				end
				if ready then
					UI.sound("Claim")
					action("Claim", track, t)
				end
			end)
		end
	end

	-- Keep the scroll where it was; jump to your tier when it changes (or on first open).
	local viewW = size.X - gutter
	if scrollX == nil or centeredOn ~= tier then
		centeredOn = tier
		scrollX = math.clamp(math.max(tier, 1) * column - viewW / 2, 0, math.max(0, canvasW - viewW))
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
-- Missions: inset plate rows with a bar (crimson, jade when done), the reward on the
-- right, a jade seal when done, and the free daily reroll.

local MISSION_ROW = 56 -- daily rows hold the 54 px Reroll button (>= 45 pt on a phone)

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
		material = "inset",
		tint = if done then DONE_TINT else T.Lacquer,
		Size = UDim2.new(1, -6, 0, height),
		LayoutOrder = order,
	}, parent)
	if done then
		UI.stroke(row, T.Jade, 1.5, 0.2)
	end
	local rewardW = 98
	local rerollW = if canReroll and not done then 82 else 0
	local textX = if done then 34 else 10
	UI.text({
		Position = UDim2.fromOffset(textX, 4),
		Size = UDim2.new(1, -(rewardW + rerollW + textX + 10), 0, 22),
		TextXAlignment = Enum.TextXAlignment.Left,
		FontFace = UI.Fonts.Label,
		TextSize = 16,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextColor3 = if done then T.JadeText else T.Bone,
		Text = m.text,
	}, row)
	if done then
		local seal = UI.badge(row, "done", 22)
		seal.AnchorPoint = Vector2.new(0, 0)
		seal.Position = UDim2.fromOffset(7, 4)
	end
	UI.progress({
		Name = "Bar",
		Position = UDim2.new(0, 10, 1, -26),
		Size = UDim2.new(1, -(rewardW + rerollW + 22), 0, 20),
		height = 8,
		textWidth = 66,
		tone = "crimson",
		doneTone = "jade",
		value = have,
		max = m.goal,
		format = function(v: number, goal: number): string
			return if v >= goal then "DONE" else `{v} / {goal}`
		end,
	}, row)
	-- Reward: Pass XP over coins and a Whetstone.
	local reward = UI.new("Frame", {
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -6, 0.5, 0),
		Size = UDim2.fromOffset(rewardW, 44),
		BackgroundTransparency = 1,
	}, row)
	UI.new("ImageLabel", {
		Size = UDim2.fromOffset(22, 22),
		BackgroundTransparency = 1,
		Image = ICONS.PassXP or ICONS.Level,
	}, reward)
	local multiplier = ReplicatedStorage:GetAttribute("SeasonMultiplier") or 1
	UI.text({
		Position = UDim2.fromOffset(25, 0),
		Size = UDim2.new(1, -25, 0, 22),
		TextXAlignment = Enum.TextXAlignment.Left,
		FontFace = UI.Fonts.Number,
		TextSize = 15,
		TextColor3 = T.GoldHi,
		Text = `+{math.floor(m.pass * math.max(multiplier, 1))} XP`,
	}, reward)
	UI.new("ImageLabel", {
		Position = UDim2.fromOffset(2, 24),
		Size = UDim2.fromOffset(18, 18),
		BackgroundTransparency = 1,
		Image = ICONS.Coin,
	}, reward)
	UI.text({
		Position = UDim2.fromOffset(25, 23),
		Size = UDim2.fromOffset(40, 20),
		TextXAlignment = Enum.TextXAlignment.Left,
		FontFace = UI.Fonts.Number,
		TextSize = 14,
		TextColor3 = T.GoldHi,
		Text = UI.number(m.coins),
	}, reward)
	UI.new("ImageLabel", {
		Position = UDim2.fromOffset(62, 24),
		Size = UDim2.fromOffset(18, 18),
		BackgroundTransparency = 1,
		Image = ICONS.Whetstone or ICONS.Skin,
	}, reward)
	UI.text({
		Position = UDim2.fromOffset(80, 23),
		Size = UDim2.fromOffset(20, 20),
		TextXAlignment = Enum.TextXAlignment.Left,
		FontFace = UI.Fonts.Number,
		TextSize = 14,
		TextColor3 = T.Steel,
		Text = `{m.whetstones}`,
	}, reward)
	if rerollW > 0 then
		local reroll = UI.button({
			Name = "Reroll",
			variant = "secondary",
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -(rewardW + 10), 0.5, 0),
			Size = UDim2.fromOffset(rerollW - 6, math.min(54, height - 2)),
			TextSize = 16,
			Text = "Reroll",
		}, row)
		reroll.Activated:Connect(function()
			action("Reroll", m.id)
		end)
	end
end

local function missionsView(body: Frame, size: Vector2)
	local missions = decode("Missions")
	local top = CONTENT_Y
	local height = size.Y - top
	local split = math.floor(size.X * 0.5)
	for col, spec in
		{
			{ title = "Today", list = missions.daily or {}, x = 0, w = split - 8 },
			{ title = "This week", list = missions.weekly or {}, x = split + 4, w = size.X - split - 4 },
		}
	do
		UI.text({
			Position = UDim2.fromOffset(spec.x, top),
			Size = UDim2.fromOffset(spec.w, 24),
			TextXAlignment = Enum.TextXAlignment.Left,
			FontFace = UI.Fonts.Display,
			TextSize = 20,
			TextColor3 = T.GoldHi,
			Text = spec.title,
		}, body)
		local clock = UI.text({
			Position = UDim2.fromOffset(spec.x, top + 2),
			Size = UDim2.fromOffset(spec.w - 8, 20),
			TextXAlignment = Enum.TextXAlignment.Right,
			FontFace = UI.Fonts.Label,
			TextSize = 14,
			TextColor3 = T.Dim,
			Text = "",
		}, body)
		if col == 1 then
			live(clock, function()
				local endsAt = ReplicatedStorage:GetAttribute("DayEndsAt") or 0
				local free = if missions.reroll == true then "1 free reroll  ·  " else ""
				return `{free}new in {duration(endsAt - workspace:GetServerTimeNow())}`
			end)
		else
			live(clock, function()
				return `New bounties in {duration((missions.weekEndsAt or 0) - workspace:GetServerTimeNow())}`
			end)
		end
		local list = UI.new("ScrollingFrame", {
			Position = UDim2.fromOffset(spec.x, top + 26),
			Size = UDim2.fromOffset(spec.w, height - 26),
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			ScrollBarThickness = 4,
			ScrollBarImageColor3 = T.Gold,
			ScrollingDirection = Enum.ScrollingDirection.Y,
			AutomaticCanvasSize = Enum.AutomaticSize.Y,
			CanvasSize = UDim2.new(),
		}, body)
		UI.new("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }, list)
		local rowH = if col == 1 then MISSION_ROW else math.clamp(math.floor((height - 26) / 4) - 4, 48, 56)
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
	local info = tabs(body, size, redraw)
	if tab == "Rewards" then
		trackView(body, size, info)
	else
		missionsView(body, size)
	end
end

return PassPanel
