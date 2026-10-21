--!strict
-- The lobby's menus, one centred panel at a time: Weapons (equip and unlock with coins),
-- Store, Profile (stats, most used weapons, ranked season), Rewards (daily streak) and
-- Settings. Every panel redraws from player attributes, so it is always current.

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Assets = require(ReplicatedStorage.Shared.Assets)
local Config = require(ReplicatedStorage.Shared.Config)
local Progression = require(ReplicatedStorage.Shared.Progression)
local Ranks = require(ReplicatedStorage.Shared.Ranks)
local Weapons = require(ReplicatedStorage.Shared.Weapons)
local Toasts = require(script.Parent.Toasts)
local UI = require(script.Parent.UI)

local player = Players.LocalPlayer

local Panels = {}

local screen: ScreenGui
local window: Frame
local titleLabel: TextLabel
local body: Frame
local current: string? = nil
local lobbyAction: RemoteEvent

local function today(): number
	return math.floor(os.time() / 86400)
end

local function attr(name: string, default: any): any
	local value = player:GetAttribute(name)
	return if value == nil then default else value
end

local function owned(): { [string]: boolean }
	local set = {}
	for id in string.gmatch(attr("OwnedWeapons", ""), "[^,]+") do
		set[id] = true
	end
	return set
end

local function clear()
	for _, child in body:GetChildren() do
		child:Destroy()
	end
end

local function sectionTitle(text: string, y: number)
	UI.text({
		Position = UDim2.fromOffset(0, y),
		Size = UDim2.new(1, 0, 0, 20),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = UI.Bronze,
		TextSize = 16,
		Text = text,
	}, body)
	UI.new("Frame", {
		Position = UDim2.fromOffset(0, y + 22),
		Size = UDim2.new(1, 0, 0, 1),
		BackgroundColor3 = UI.Bronze,
		BackgroundTransparency = 0.6,
		BorderSizePixel = 0,
	}, body)
end

local function statBox(parent: Instance, label: string, value: string, position: UDim2, size: UDim2)
	local box = UI.panel({ Position = position, Size = size, BackgroundColor3 = UI.PanelLight }, parent)
	UI.text({
		Position = UDim2.fromOffset(0, 6),
		Size = UDim2.new(1, 0, 0, 16),
		TextSize = 14,
		TextTransparency = 0.3,
		Text = label,
	}, box)
	UI.text({
		Position = UDim2.fromOffset(0, 22),
		Size = UDim2.new(1, -0, 1, -26),
		Font = UI.Bold,
		TextSize = 24,
		Text = value,
	}, box)
end

---------------------------------------------------------------------------------------

-- How to fight: the rules in the order a new player needs them.
local GUIDE = {
	{
		"Deflect  ·  F",
		"Tap F just before the enemy's blade lands. Watch for the white glint at their sword tip: press as it flashes. A deflect costs you nothing and fills THEIR posture; a perfect one (tighter timing) fills it more. Then click straight away for a fast Riposte.",
	},
	{
		"Guard  ·  hold F",
		"Holding F blocks damage but fills YOUR posture. Don't turtle: tap to deflect instead. Mashing F shrinks your deflect window.",
	},
	{
		"Posture",
		"The bar in the middle. When it's full you're Broken: open to a deathblow, which takes a big chunk of vitality and kills a wounded fighter. Posture drains back when you stop taking hits, slower when your vitality is low.",
	},
	{
		"Red 危 = perilous",
		"Can't be guarded. A thrust: deflect it, or dash INTO it with Q for a Mikiri Counter. A sweep: jump over it. Either way, reading it wrecks the attacker's posture.",
	},
	{
		"Attacking  ·  click",
		"Click on the beat for a three-hit string; it speeds up while it keeps landing. Pause before the third for a slow overhead that beats early deflects. E (thrust) or C (sweep) late in a string turns the ender perilous. Block mid-swing to feint.",
	},
	{
		"Survive",
		"Q dodges (dash into thrusts, away from sweeps). G sips your gourd (3 per life): only when you're safe. Outnumbered by two or more? You gain Resolve: faster posture and shorter stun.",
	},
}

local function guidePanel()
	local list = UI.new("ScrollingFrame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 4,
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(),
	}, body)
	UI.new("UIListLayout", { Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder }, list)
	for i, entry in GUIDE do
		local card = UI.panel({
			Size = UDim2.new(1, -10, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			LayoutOrder = i,
			BackgroundColor3 = UI.PanelLight,
		}, list)
		UI.new("UIPadding", {
			PaddingLeft = UDim.new(0, 12),
			PaddingRight = UDim.new(0, 12),
			PaddingTop = UDim.new(0, 8),
			PaddingBottom = UDim.new(0, 10),
		}, card)
		UI.new("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }, card)
		UI.text({
			Size = UDim2.new(1, 0, 0, 24),
			LayoutOrder = 1,
			TextXAlignment = Enum.TextXAlignment.Left,
			Font = UI.Display,
			TextSize = 24,
			TextColor3 = if i == 4 then Color3.fromRGB(230, 80, 70) else UI.Gold,
			Text = entry[1],
		}, card)
		UI.text({
			Size = UDim2.fromScale(1, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			LayoutOrder = 2,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextWrapped = true,
			TextSize = 16,
			Text = entry[2],
		}, card)
	end
	UI.text({
		Size = UDim2.new(1, -10, 0, 40),
		LayoutOrder = 99,
		TextWrapped = true,
		TextSize = 15,
		TextTransparency = 0.2,
		Text = "Practise on the Deflect Trainer in the dojo (left wing): it tells you how many milliseconds early you pressed.",
	}, list)
end

local function weaponsPanel()
	local have = owned()
	local equipped = attr("Weapon", Weapons.Default)
	local coins = attr("Coins", 0)
	local list = UI.new("ScrollingFrame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 4,
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(),
	}, body)
	UI.new("UIListLayout", { Padding = UDim.new(0, 10), SortOrder = Enum.SortOrder.LayoutOrder }, list)
	for i, id in Weapons.Order do
		local def = Weapons.get(id)
		local card =
			UI.panel({ Size = UDim2.new(1, -8, 0, 104), LayoutOrder = i, BackgroundColor3 = UI.PanelLight }, list)
		UI.new("ImageLabel", {
			Position = UDim2.fromOffset(4, 2),
			Size = UDim2.fromOffset(100, 100),
			BackgroundTransparency = 1,
			Image = (Assets.Icons :: any)[id] or Assets.Icons.Weapons,
		}, card)
		local textInset = UI.new("Frame", {
			Position = UDim2.fromOffset(100, 0),
			Size = UDim2.new(1, -100, 1, 0),
			BackgroundTransparency = 1,
		}, card)
		UI.text({
			Position = UDim2.fromOffset(14, 8),
			Size = UDim2.new(1, -170, 0, 30),
			TextXAlignment = Enum.TextXAlignment.Left,
			Font = UI.Display,
			TextSize = 28,
			Text = def.name,
		}, textInset)
		UI.text({
			Position = UDim2.fromOffset(14, 38),
			Size = UDim2.new(1, -170, 0, 18),
			TextXAlignment = Enum.TextXAlignment.Left,
			TextColor3 = UI.Bronze,
			TextSize = 15,
			Text = def.archetype,
		}, textInset)
		UI.text({
			Position = UDim2.fromOffset(14, 58),
			Size = UDim2.new(1, -170, 0, 40),
			TextXAlignment = Enum.TextXAlignment.Left,
			TextYAlignment = Enum.TextYAlignment.Top,
			TextWrapped = true,
			TextSize = 15,
			TextTransparency = 0.2,
			Text = def.description,
		}, textInset)
		local isOwned = have[id] == true
		local isEquipped = equipped == id
		local button = UI.button({
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -14, 0.5, 0),
			Size = UDim2.fromOffset(136, 44),
			Text = if isEquipped then "Equipped" elseif isOwned then "Equip" else `Unlock  {UI.number(def.price)} coins`,
			BackgroundColor3 = if isEquipped
				then UI.Panel
				elseif isOwned then UI.Crimson
				elseif coins >= def.price then UI.Crimson
				else UI.Panel,
			TextColor3 = if not isOwned and coins < def.price then Color3.fromRGB(140, 130, 120) else UI.Parchment,
		}, card)
		UI.stroke(button)
		button.Activated:Connect(function()
			if isOwned and not isEquipped then
				lobbyAction:FireServer("Equip", id)
			elseif not isOwned and coins >= def.price then
				lobbyAction:FireServer("Buy", id)
			elseif not isOwned then
				Toasts.notice(`{UI.number(def.price - coins)} more coins to unlock the {def.name}`, UI.Gold)
			end
		end)
	end
	UI.text({
		Size = UDim2.new(1, -8, 0, 36),
		LayoutOrder = 99,
		TextWrapped = true,
		TextSize = 14,
		TextTransparency = 0.35,
		Text = "Every weapon is earned with coins from matches, never sold for Robux. Each is a sidegrade: better at one thing, worse at another.",
	}, list)

	-- Blade skins: pure cosmetics, unlocked by playing, then bought with coins.
	UI.text({
		Size = UDim2.new(1, -8, 0, 30),
		LayoutOrder = 100,
		TextXAlignment = Enum.TextXAlignment.Left,
		Font = UI.Display,
		TextSize = 26,
		TextColor3 = UI.Gold,
		Text = "Blades",
	}, list)
	local grid = UI.new("Frame", {
		Size = UDim2.new(1, -8, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = 101,
		BackgroundTransparency = 1,
	}, list)
	UI.new("UIGridLayout", {
		CellSize = UDim2.new(1 / 3, -8, 0, 170),
		CellPadding = UDim2.fromOffset(10, 10),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, grid)
	local ownedSkins = {}
	for id in string.gmatch(attr("OwnedSkins", "Steel"), "[^,]+") do
		ownedSkins[id] = true
	end
	local equippedSkin = attr("Skin", "Steel")
	for i, skin in Progression.Skins do
		local isOwned = ownedSkins[skin.id] == true
		local isEquipped = equippedSkin == skin.id
		local rule = skin.unlock
		local unlocked = rule == nil or (attr(rule.stat, 0) :: number) >= rule.amount
		local card = UI.panel({
			LayoutOrder = i,
			BackgroundColor3 = if isEquipped then Color3.fromRGB(52, 40, 30) else UI.PanelLight,
		}, grid)
		if isEquipped then
			UI.stroke(card, UI.Gold, 2, 0)
		end
		local t = skin.tint
		UI.new("ImageLabel", {
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.new(0.5, 0, 0, 2),
			Size = UDim2.fromOffset(84, 84),
			BackgroundTransparency = 1,
			Image = Assets.Icons.Katana,
			ImageColor3 = Color3.new(math.min(t.X, 1), math.min(t.Y, 1), math.min(t.Z, 1)),
		}, card)
		if not unlocked then
			UI.new("ImageLabel", {
				AnchorPoint = Vector2.new(1, 0),
				Position = UDim2.new(1, -4, 0, 4),
				Size = UDim2.fromOffset(34, 34),
				BackgroundTransparency = 1,
				Image = Assets.Icons.Lock,
			}, card)
		end
		UI.text({
			Position = UDim2.fromOffset(4, 84),
			Size = UDim2.new(1, -8, 0, 22),
			Font = UI.Display,
			TextSize = 19,
			TextColor3 = skin.trail[2]:Lerp(Color3.new(1, 1, 1), 0.45),
			Text = skin.name,
		}, card)
		UI.text({
			Position = UDim2.fromOffset(4, 104),
			Size = UDim2.new(1, -8, 0, 18),
			TextSize = 13,
			TextTransparency = 0.3,
			TextWrapped = true,
			Text = if unlocked or not rule then skin.blurb else `{rule.text}  ({attr(rule.stat, 0)}/{rule.amount})`,
		}, card)
		local canBuy = not isOwned and unlocked and coins >= skin.price
		local button = UI.button({
			AnchorPoint = Vector2.new(0.5, 1),
			Position = UDim2.new(0.5, 0, 1, -8),
			Size = UDim2.new(1, -20, 0, 32),
			TextSize = 15,
			Text = if isEquipped
				then "Equipped"
				elseif isOwned then "Equip"
				elseif not unlocked then "Locked"
				else `{UI.number(skin.price)} coins`,
			BackgroundColor3 = if isEquipped then UI.Panel elseif isOwned or canBuy then UI.Crimson else UI.Panel,
			TextColor3 = if not isOwned and not canBuy then Color3.fromRGB(140, 130, 120) else UI.Parchment,
		}, card)
		button.Activated:Connect(function()
			if isOwned and not isEquipped then
				lobbyAction:FireServer("EquipSkin", skin.id)
			elseif canBuy then
				lobbyAction:FireServer("BuySkin", skin.id)
			elseif not isOwned and not unlocked and rule then
				Toasts.notice(`Locked  ·  {rule.text}`, UI.Parchment)
			elseif not isOwned then
				Toasts.notice(`{UI.number(skin.price - coins)} more coins for {skin.name}`, UI.Gold)
			end
		end)
	end
end

-- Daily Trials: three goals a day that pay out the moment they're done.
local function trialsPanel()
	local progress = {}
	local ok, decoded = pcall(HttpService.JSONDecode, HttpService, attr("TrialProgress", "{}"))
	if ok and typeof(decoded) == "table" then
		progress = decoded
	end
	local day = today()
	local fresh = attr("TrialDay", 0) == day
	for i, id in Progression.dailyTrials(player.UserId, day) do
		local trial = Progression.trial(id)
		if trial then
			local value = if fresh then math.min(progress[id] or 0, trial.goal) else 0
			local done = value >= trial.goal
			local card = UI.panel({
				Position = UDim2.fromOffset(0, (i - 1) * 88),
				Size = UDim2.new(1, -4, 0, 78),
				BackgroundColor3 = if done then Color3.fromRGB(34, 44, 36) else UI.PanelLight,
			}, body)
			UI.new("ImageLabel", {
				Position = UDim2.fromOffset(4, 2),
				Size = UDim2.fromOffset(74, 74),
				BackgroundTransparency = 1,
				Image = Assets.Icons.Trials,
				ImageTransparency = if done then 0 else 0.15,
			}, card)
			UI.text({
				Position = UDim2.fromOffset(90, 8),
				Size = UDim2.new(1, -250, 0, 26),
				TextXAlignment = Enum.TextXAlignment.Left,
				Font = UI.Display,
				TextSize = 24,
				Text = trial.text,
			}, card)
			local track = UI.new("Frame", {
				Position = UDim2.fromOffset(90, 44),
				Size = UDim2.new(1, -250, 0, 16),
				BackgroundColor3 = Color3.fromRGB(12, 10, 12),
				BorderSizePixel = 0,
			}, card)
			UI.corner(track, UDim.new(1, 0))
			local fill = UI.new("Frame", {
				Size = UDim2.fromScale(math.max(value / trial.goal, 0.02), 1),
				BackgroundColor3 = if done then UI.Jade else UI.Crimson,
				BorderSizePixel = 0,
			}, track)
			UI.corner(fill, UDim.new(1, 0))
			UI.text({
				Size = UDim2.fromScale(1, 1),
				Font = UI.Bold,
				TextSize = 13,
				TextStrokeTransparency = 0.3,
				Text = if done then "COMPLETE" else `{value} / {trial.goal}`,
			}, track)
			local reward = UI.new("Frame", {
				AnchorPoint = Vector2.new(1, 0.5),
				Position = UDim2.new(1, -12, 0.5, 0),
				Size = UDim2.fromOffset(140, 60),
				BackgroundTransparency = 1,
			}, card)
			UI.new("ImageLabel", {
				Position = UDim2.fromOffset(0, 0),
				Size = UDim2.fromOffset(34, 34),
				BackgroundTransparency = 1,
				Image = Assets.Icons.Coin,
			}, reward)
			UI.text({
				Position = UDim2.fromOffset(38, 2),
				Size = UDim2.new(1, -38, 0, 30),
				TextXAlignment = Enum.TextXAlignment.Left,
				Font = UI.Bold,
				TextSize = 22,
				TextColor3 = UI.Gold,
				Text = UI.number(trial.coins),
			}, reward)
			UI.text({
				Position = UDim2.fromOffset(38, 32),
				Size = UDim2.new(1, -38, 0, 22),
				TextXAlignment = Enum.TextXAlignment.Left,
				TextSize = 16,
				TextTransparency = 0.2,
				Text = `+{trial.xp} XP`,
			}, reward)
		end
	end
	local secondsLeft = 86400 - os.time() % 86400
	UI.text({
		Position = UDim2.fromOffset(0, 258),
		Size = UDim2.new(1, 0, 0, 20),
		TextSize = 15,
		TextTransparency = 0.35,
		Text = `New trials in {math.floor(secondsLeft / 3600)}h {math.floor(secondsLeft % 3600 / 60)}m  ·  rewards pay out the moment a trial is done`,
	}, body)
end

local function storePanel()
	sectionTitle("Gem packs", 0)
	UI.text({
		Position = UDim2.fromOffset(0, 34),
		Size = UDim2.new(1, 0, 0, 60),
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		TextSize = 16,
		TextTransparency = 0.2,
		Text = "Gems will buy cosmetic blade skins, trails and finishers. Packs go on sale once the game is published and its developer products are set up.",
	}, body)
	sectionTitle("Earn coins", 110)
	local rewards = Progression.Rewards
	local lines = {
		`Fight a royale  ·  {rewards.Played.Coins} coins`,
		`Cut someone down  ·  {rewards.Kill.Coins}   ·   deathblow bonus  ·  {rewards.Deathblow.Coins}`,
		`Win  ·  {rewards.Win.Coins}   ·   each Mastery level  ·  50+`,
		"Daily Trials and the login streak pay the most",
	}
	for i, line in lines do
		UI.text({
			Position = UDim2.fromOffset(0, 120 + i * 28),
			Size = UDim2.new(1, 0, 0, 24),
			TextXAlignment = Enum.TextXAlignment.Left,
			TextSize = 17,
			Text = line,
		}, body)
	end
end

local function profilePanel()
	local wins, losses = attr("Wins", 0), attr("Losses", 0)
	local played = attr("Played", 0)
	local ratio = if losses > 0 then wins / losses else wins
	sectionTitle(player.DisplayName, 0)
	local stats = {
		{ "Wins", tostring(wins) },
		{ "Losses", tostring(losses) },
		{ "W/L", string.format("%.2f", ratio) },
		{ "Kills", tostring(attr("Kills", 0)) },
		{ "Deathblows", tostring(attr("Deathblows", 0)) },
		{ "Played", tostring(played) },
	}
	for i, stat in stats do
		local column = (i - 1) % 3
		local row = (i - 1) // 3
		statBox(body, stat[1], stat[2], UDim2.new(column / 3, 4, 0, 34 + row * 70), UDim2.new(1 / 3, -8, 0, 62))
	end

	sectionTitle("Most used weapons", 184)
	local ok, uses = pcall(function()
		return HttpService:JSONDecode(attr("WeaponUses", "{}"))
	end)
	local sorted = {}
	for id, count in if ok and typeof(uses) == "table" then uses else {} do
		table.insert(sorted, { id = id, count = count })
	end
	table.sort(sorted, function(a, b)
		return a.count > b.count
	end)
	for i = 1, 3 do
		local entry = sorted[i]
		UI.text({
			Position = UDim2.fromOffset(0, 192 + i * 24),
			Size = UDim2.new(0.5, 0, 0, 22),
			TextXAlignment = Enum.TextXAlignment.Left,
			TextSize = 16,
			Text = if entry then `#{i}  {Weapons.get(entry.id).name}  ·  {entry.count} games` else `#{i}  —`,
		}, body)
	end

	-- Ranked season: tier, rating and progress through the division.
	local rating = attr("Rating", Config.Rating.Start)
	local rank = Ranks.of(rating)
	local season = UI.panel({
		Position = UDim2.new(0.5, 4, 0, 190),
		Size = UDim2.new(0.5, -4, 0, 88),
		BackgroundColor3 = UI.PanelLight,
	}, body)
	UI.text({
		Position = UDim2.fromOffset(12, 6),
		Size = UDim2.new(1, -24, 0, 18),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextSize = 14,
		TextTransparency = 0.3,
		Text = `Season 1  ·  peak {attr("PeakRating", rating)}`,
	}, season)
	UI.new("ImageLabel", {
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, 6, 0, 18),
		Size = UDim2.fromOffset(64, 64),
		BackgroundTransparency = 1,
		Image = Assets.RankCrests[rank.tier] or "",
		ZIndex = 2,
	}, season)
	UI.text({
		Position = UDim2.fromOffset(12, 24),
		Size = UDim2.new(1, -24, 0, 30),
		TextXAlignment = Enum.TextXAlignment.Left,
		Font = UI.Display,
		TextSize = 28,
		TextColor3 = rank.color,
		Text = rank.name,
	}, season)
	UI.text({
		Position = UDim2.fromOffset(12, 24),
		Size = UDim2.new(1, -84, 0, 30),
		TextXAlignment = Enum.TextXAlignment.Right,
		Font = UI.Bold,
		TextSize = 20,
		Text = `{rating}`,
	}, season)
	local bar = UI.new("Frame", {
		Position = UDim2.fromOffset(12, 58),
		Size = UDim2.new(1, -24, 0, 6),
		BackgroundColor3 = UI.Ink,
		BorderSizePixel = 0,
	}, season)
	UI.corner(bar, UDim.new(1, 0))
	local fill = UI.new("Frame", {
		Size = UDim2.fromScale(math.clamp((rating - rank.floor) / (rank.ceiling - rank.floor), 0, 1), 1),
		BackgroundColor3 = rank.color,
		BorderSizePixel = 0,
	}, bar)
	UI.corner(fill, UDim.new(1, 0))
	UI.text({
		Position = UDim2.fromOffset(12, 66),
		Size = UDim2.new(1, -24, 0, 16),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextSize = 13,
		TextTransparency = 0.4,
		Text = `{rank.floor}  →  {rank.ceiling}   ·   vs players only, not bots`,
		TextTruncate = Enum.TextTruncate.AtEnd,
	}, season)
end

local function rewardsPanel()
	local streak = attr("Streak", 0)
	local last = attr("LastDaily", 0)
	local claimedToday = last >= today()
	local continuing = last == today() - 1
	local nextDay = if claimedToday then streak elseif continuing then streak % #Config.Economy.Daily + 1 else 1
	sectionTitle("Daily reward  ·  come back each day to grow the streak", 0)
	for day, coins in Config.Economy.Daily do
		local done = day < nextDay or (claimedToday and day == nextDay)
		local isNext = day == nextDay and not claimedToday
		local card = UI.panel({
			Position = UDim2.new((day - 1) / 7, 3, 0, 36),
			Size = UDim2.new(1 / 7, -6, 0, 104),
			BackgroundColor3 = if isNext then UI.Crimson elseif done then UI.Panel else UI.PanelLight,
		}, body)
		UI.text({
			Position = UDim2.fromOffset(0, 6),
			Size = UDim2.new(1, 0, 0, 18),
			TextSize = 14,
			Text = `Day {day}`,
		}, card)
		UI.text({
			Position = UDim2.fromOffset(0, 34),
			Size = UDim2.new(1, 0, 0, 28),
			Font = UI.Bold,
			TextSize = 22,
			TextColor3 = UI.Gold,
			Text = `● {coins}`,
		}, card)
		if day == #Config.Economy.Daily then
			UI.text({
				Position = UDim2.fromOffset(0, 62),
				Size = UDim2.new(1, 0, 0, 20),
				TextSize = 15,
				TextColor3 = Color3.fromRGB(240, 110, 100),
				Text = `+ ◆ {Config.Economy.DailyGems}`,
			}, card)
		end
		if done then
			UI.text({
				Position = UDim2.new(0, 0, 1, -24),
				Size = UDim2.new(1, 0, 0, 20),
				TextSize = 14,
				TextColor3 = UI.Jade,
				Text = "Claimed",
			}, card)
		end
	end
	local claim = UI.button({
		Name = "Claim",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 160),
		Size = UDim2.fromOffset(220, 50),
		Font = UI.Display,
		TextSize = 26,
		Text = if claimedToday then "Come back tomorrow" else "Claim",
		BackgroundColor3 = if claimedToday then UI.Panel else UI.Crimson,
	}, body)
	UI.stroke(claim)
	claim.Activated:Connect(function()
		if not claimedToday then
			-- Say what it paid once the server has granted it.
			local nextCoins = Config.Economy.Daily[nextDay] or 0
			player:GetAttributeChangedSignal("LastDaily"):Once(function()
				Toasts.notice(`Day {nextDay} reward claimed  ·  +{nextCoins} coins`, UI.Gold)
			end)
			lobbyAction:FireServer("ClaimDaily")
		end
	end)
end

local function settingsPanel()
	-- `offByDefault`: the attribute reads as off until it's switched on (the rest read as on).
	local options: { { key: string, label: string, offByDefault: boolean? } } = {
		{ key = "SettingCameraShake", label = "Camera shake" },
		{ key = "SettingHitstop", label = "Hit freeze (hitstop)" },
		{ key = "SettingControlsHint", label = "Show controls reminder" },
		{ key = "SettingReducedEffects", label = "Reduced effects", offByDefault = true },
	}
	sectionTitle("Settings  ·  saved for this session", 0)
	for i, option in options do
		local value = player:GetAttribute(option.key)
		local on = if option.offByDefault then value == true else value ~= false
		UI.text({
			Position = UDim2.fromOffset(0, 10 + i * 52),
			Size = UDim2.new(1, -150, 0, 40),
			TextXAlignment = Enum.TextXAlignment.Left,
			TextSize = 19,
			Text = option.label,
		}, body)
		local toggle = UI.button({
			Name = option.key,
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, 0, 0, 10 + i * 52),
			Size = UDim2.fromOffset(110, 40),
			Text = if on then "On" else "Off",
			BackgroundColor3 = if on then UI.Crimson else UI.PanelLight,
		}, body)
		UI.stroke(toggle)
		toggle.Activated:Connect(function()
			player:SetAttribute(option.key, not on) -- local only; read by the effects code
			Panels.redraw()
		end)
	end
end

local builders: { [string]: () -> () } = {
	Guide = guidePanel,
	Weapons = weaponsPanel,
	Store = storePanel,
	Trials = trialsPanel,
	Profile = profilePanel,
	Rewards = rewardsPanel,
	Settings = settingsPanel,
}

local drawn: string? = nil -- the panel body currently holds

function Panels.redraw()
	if not current then
		return
	end
	-- Panels redraw on every attribute change (coins, XP, queue...): keep a scrolled list
	-- (Arsenal's blades) where it was instead of jumping back to the top.
	local scroll = Vector2.zero
	local old = body:FindFirstChildOfClass("ScrollingFrame")
	if old and drawn == current then
		scroll = old.CanvasPosition
	end
	clear()
	drawn = current
	titleLabel.Text = if current == "Guide"
		then "How to fight"
		elseif current == "Weapons" then "Arsenal"
		elseif current == "Trials" then "Daily Trials"
		else current :: string
	builders[current :: string]()
	local list = body:FindFirstChildOfClass("ScrollingFrame")
	if list and scroll ~= Vector2.zero then
		task.defer(function()
			if list.Parent then
				list.CanvasPosition = scroll
			end
		end)
	end
end

local openedCallbacks: { () -> () } = {}

-- Runs `callback` whenever a panel opens (the boss picker closes itself so the two never
-- stack).
function Panels.onOpen(callback: () -> ())
	table.insert(openedCallbacks, callback)
end

function Panels.isOpen(): boolean
	return current ~= nil
end

function Panels.open(id: string)
	current = id
	window.Visible = true
	Panels.redraw()
	for _, callback in openedCallbacks do
		task.spawn(callback)
	end
end

function Panels.closeAll()
	current = nil
	if window then
		window.Visible = false
	end
end

function Panels.toggle(id: string)
	if current == id then
		Panels.closeAll()
	else
		Panels.open(id)
	end
end

function Panels.start(remote: RemoteEvent)
	lobbyAction = remote
	screen = UI.new("ScreenGui", {
		Name = "LobbyPanels",
		ResetOnSpawn = false,
		DisplayOrder = 6,
		ScreenInsets = Enum.ScreenInsets.CoreUISafeInsets,
	})
	-- Sits above the PLAY button and nav bar, never over them, and shrinks on short screens
	-- (a phone in landscape) so its top stays on screen.
	window = UI.panel({
		Name = "Window",
		Size = UDim2.fromOffset(660, 372),
		Visible = false,
	}, screen)
	UI.new("UISizeConstraint", { MaxSize = Vector2.new(660, 372) }, window)
	UI.fitAboveNav(window, 372)
	titleLabel = UI.text({
		Position = UDim2.fromOffset(24, 14),
		Size = UDim2.new(1, -90, 0, 36),
		TextXAlignment = Enum.TextXAlignment.Left,
		Font = UI.Display,
		TextSize = 32,
		Text = "",
	}, window)
	local close = UI.button({
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -16, 0, 14),
		Size = UDim2.fromOffset(38, 38),
		Text = "X",
		TextSize = 20,
		BackgroundColor3 = UI.Crimson,
	}, window)
	close.Activated:Connect(Panels.closeAll)
	UI.new("Frame", {
		Position = UDim2.fromOffset(24, 58),
		Size = UDim2.new(1, -48, 0, 1),
		BackgroundColor3 = UI.Bronze,
		BackgroundTransparency = 0.5,
		BorderSizePixel = 0,
	}, window)
	body = UI.new("Frame", {
		Position = UDim2.fromOffset(24, 72),
		Size = UDim2.new(1, -48, 1, -92),
		BackgroundTransparency = 1,
		ClipsDescendants = true,
	}, window)
	screen.Parent = player:WaitForChild("PlayerGui")

	player.AttributeChanged:Connect(function()
		if current then
			Panels.redraw()
		end
	end)
end

return Panels
