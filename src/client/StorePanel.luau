--!strict
-- The Store, in four calm tabs:
--   Featured  today's shop (2 coin + 2 gem items) and the week's featured set, with the
--             real rotation times from the server (items come back; nothing is gone for good)
--   Gems      the six gem packs: amount, a plain bonus and the Robux price
--   Offers    the Initiate's Bundle (only while its 72 h window is open and you don't own
--             it), the Path of the Blade premium track, and the cosmetic / convenience passes
--   Shrine    open earned Shrine Draws, the gem Shrine Capsule (only when the server says it
--             may be shown to you), the full odds table before any draw, pity counters, your
--             Shards and the shard shop where every pool item can be bought outright
-- No pop-ups, no fake timers, no paid refresh. Robux purchases go through the server's
-- Monetization.prompt (LobbyAction "Purchase"); shop and shrine requests through the
-- Shop RemoteFunction (server/ShopService). Everything shown is server-published state.

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Assets = require(ReplicatedStorage.Shared.Assets)
local Catalog = require(ReplicatedStorage.Shared.Catalog)
local Flair = require(ReplicatedStorage.Shared.Flair)
local Panels = require(script.Parent.Panels)
local StoreUI = require(script.Parent.StoreUI)
local Toasts = require(script.Parent.Toasts)
local UI = require(script.Parent.UI)

local player = Players.LocalPlayer
local ICONS = Assets.Icons :: any

local StorePanel = {}

type TabId = "Featured" | "Gems" | "Offers" | "Shrine"
local tab: TabId = "Featured"
local busy = false
local oddsSeen = false -- the first draw of a session goes through the odds sheet

function StorePanel.show(which: string?)
	if which == "Featured" or which == "Gems" or which == "Offers" or which == "Shrine" then
		tab = which
	end
	Panels.resetScroll()
	Panels.open("Store")
end

local function rsJson(name: string): { [string]: any }
	local raw = ReplicatedStorage:GetAttribute(name)
	if typeof(raw) ~= "string" or raw == "" then
		return {}
	end
	local ok, decoded = pcall(HttpService.JSONDecode, HttpService, raw)
	return if ok and typeof(decoded) == "table" then decoded else {}
end

local function capsule(): { [string]: any }?
	local raw = player:GetAttribute("Capsule")
	if typeof(raw) ~= "string" or raw == "" then
		return nil
	end
	local ok, decoded = pcall(HttpService.JSONDecode, HttpService, raw)
	return if ok and typeof(decoded) == "table" then decoded else nil
end

-- Calls the Shop RemoteFunction off the UI thread, one request at a time.
local function shop(action: string, arg: any, onResult: ((result: { [string]: any }) -> ())?)
	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
	local remote = remotes and remotes:FindFirstChild("Shop")
	if not remote or not remote:IsA("RemoteFunction") then
		Toasts.notice("The shrine keeper is away. Try again in a moment.", UI.Parchment)
		return
	end
	if busy then
		return
	end
	busy = true
	task.spawn(function()
		local ok, result = pcall(remote.InvokeServer, remote, action, arg)
		busy = false
		if not ok or typeof(result) ~= "table" then
			Toasts.notice("That didn't go through. Try again.", UI.Parchment)
			return
		end
		if result.ok ~= true then
			Toasts.notice(result.text or "That didn't go through.", UI.Parchment)
		end
		if onResult then
			onResult(result)
		end
	end)
end

local function header()
	local strip = Panels.header()
	UI.pill(strip, ICONS.Coin, StoreUI.attr("Coins", 0), UI.Gold, 1)
	UI.pill(strip, ICONS.Gem, StoreUI.attr("Gems", 0), UI.Jade, 2)
	if tab == "Shrine" then
		UI.pill(strip, ICONS.Shard or ICONS.Gem, StoreUI.attr("Shards", 0), UI.Parchment, 3)
	end
end

---------------------------------------------------------------------------------------
-- Featured: the daily shop and the weekly set

local function shopCard(parent: Instance, id: string, order: number, have: { [string]: boolean })
	local item = Catalog.get(id)
	if not item then
		return
	end
	local owns = have[id] == true
	local card = UI.panel({ Name = StoreUI.key(id), LayoutOrder = order, BackgroundColor3 = UI.PanelLight }, parent)
	StoreUI.frame(card, item.rarity)
	local art = UI.new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 6),
		Size = UDim2.fromOffset(88, 88),
		BackgroundTransparency = 1,
	}, card)
	StoreUI.thumb(art, item)
	UI.text({
		Position = UDim2.fromOffset(8, 94),
		Size = UDim2.new(1, -16, 0, 22),
		Font = UI.Display,
		TextSize = 19,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Text = item.name,
	}, card)
	UI.text({
		Position = UDim2.fromOffset(8, 116),
		Size = UDim2.new(1, -16, 0, 16),
		TextSize = 13,
		TextColor3 = Flair.Rarity[item.rarity] or UI.Parchment,
		Text = `{StoreUI.rarityName(item.rarity)} {string.lower(
			item.category == "bladeSkin" and "blade" or item.category
		)}`,
	}, card)
	local price = item.price or {}
	local currency = if price.gems then "Gems" else "Coins"
	local cost = price.gems or price.coins or 0
	local afford = StoreUI.attr(currency, 0) >= cost
	local button = UI.actionButton(card, {
		Name = "Buy",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -8),
		Size = UDim2.new(1, -16, 0, UI.Touch - 4),
		Text = if owns then "Owned" else `{UI.number(cost)} {string.lower(currency)}`,
		BackgroundColor3 = if owns then UI.Panel else nil,
		TextColor3 = if owns then UI.Jade else nil,
	}, not owns and afford)
	button.Activated:Connect(function()
		if owns then
			return
		elseif not afford then
			if currency == "Gems" then
				StorePanel.show("Gems")
			else
				Toasts.notice(`{UI.number(cost - StoreUI.attr("Coins", 0))} more coins for {item.name}`, UI.Gold)
			end
			return
		end
		UI.confirm(
			Panels.window(),
			item.name,
			`Unlock {item.name} for {UI.number(cost)} {string.lower(currency)}?`,
			"Unlock",
			function()
				shop("BuyShop", id, function(result)
					if result.ok then
						Toasts.notice(`Unlocked  ·  {item.name}  ·  equip it in the Locker`, UI.Gold)
					end
				end)
			end
		)
	end)
end

local function featuredTab(list: ScrollingFrame)
	local rotation = rsJson("ShopRotation")
	local have = StoreUI.owned()
	if not rotation.coin and not rotation.gem then
		UI.note(list, "Today's shop opens shortly.", 1)
		return
	end
	local line = UI.note(list, "", 1)
	if typeof(rotation.endsAt) == "number" then
		StoreUI.countdown(line, rotation.endsAt, function(left)
			return `Today's shop  ·  new items in {left}  ·  items come back within a few weeks`
		end)
	end
	local row = UI.new("Frame", {
		Name = "Daily",
		LayoutOrder = 2,
		Size = UDim2.new(1, 0, 0, 196),
		BackgroundTransparency = 1,
	}, list)
	UI.new("UIGridLayout", {
		CellSize = UDim2.new(0.25, -8, 1, 0),
		CellPadding = UDim2.fromOffset(8, 0),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, row)
	local n = 0
	for _, group in { rotation.coin or {}, rotation.gem or {} } do
		for _, id in group do
			n += 1
			shopCard(row, id, n, have)
		end
	end

	local featured = rotation.featured
	if typeof(featured) ~= "table" or typeof(featured.items) ~= "table" or #featured.items == 0 then
		return
	end
	UI.heading(list, "This week's set", 3)
	local box = UI.panel({
		Name = "Featured",
		LayoutOrder = 4,
		Size = UDim2.new(1, 0, 0, 150),
		BackgroundColor3 = UI.PanelLight,
	}, list)
	local strip = UI.new("Frame", {
		Position = UDim2.fromOffset(8, 8),
		Size = UDim2.new(0.55, 0, 1, -16),
		BackgroundTransparency = 1,
	}, box)
	UI.new("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		Padding = UDim.new(0, 8),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, strip)
	for i, id in featured.items do
		local item = Catalog.get(id)
		if not item then
			continue
		end
		local cell = UI.new("Frame", {
			LayoutOrder = i,
			Size = UDim2.new(1 / 3, -6, 1, 0),
			BackgroundColor3 = UI.Panel,
			BorderSizePixel = 0,
		}, strip)
		UI.corner(cell)
		StoreUI.frame(cell, item.rarity)
		local art = UI.new("Frame", {
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.new(0.5, 0, 0, 4),
			Size = UDim2.fromOffset(80, 80),
			BackgroundTransparency = 1,
		}, cell)
		StoreUI.thumb(art, item)
		UI.text({
			Position = UDim2.fromOffset(4, 86),
			Size = UDim2.new(1, -8, 0, 20),
			Font = UI.Display,
			TextSize = 16,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Text = item.name,
		}, cell)
		UI.text({
			Position = UDim2.fromOffset(4, 106),
			Size = UDim2.new(1, -8, 0, 16),
			TextSize = 13,
			TextColor3 = if have[id] then UI.Jade else Flair.Rarity[item.rarity] or UI.Parchment,
			Text = if have[id] then "Owned" else StoreUI.rarityName(item.rarity),
		}, cell)
	end
	local price = StoreUI.attr("ShopFeaturedPrice", featured.price or 0)
	local ownsAll = price == 0
	local info = UI.text({
		Position = UDim2.new(0.58, 0, 0, 10),
		Size = UDim2.new(0.42, -14, 0, 48),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		TextWrapped = true,
		TextSize = 15,
		Text = "",
	}, box)
	if typeof(featured.endsAt) == "number" then
		local discount = math.floor((featured.discount or 0) * 100 + 0.5)
		StoreUI.countdown(info, featured.endsAt, function(left)
			return `All {#featured.items} together{if discount > 0 then `, {discount}% less than one by one` else ""}. Changes in {left}.`
		end)
	end
	local afford = StoreUI.attr("Gems", 0) >= price
	local buy = UI.actionButton(box, {
		Name = "BuySet",
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -12, 1, -12),
		Size = UDim2.new(0.42, -14, 0, UI.Touch),
		Text = if ownsAll then "You own the set" else `Get the set  ·  {UI.number(price)} gems`,
		BackgroundColor3 = if ownsAll then UI.Panel else nil,
		TextColor3 = if ownsAll then UI.Jade else nil,
	}, not ownsAll and afford)
	buy.Activated:Connect(function()
		if ownsAll then
			return
		elseif not afford then
			StorePanel.show("Gems")
			return
		end
		UI.confirm(
			Panels.window(),
			"This week's set",
			`Spend {UI.number(price)} gems on every item in the set you don't own yet?`,
			"Spend gems",
			function()
				shop("BuyFeatured", nil, function(result)
					if result.ok then
						Toasts.notice("The set is yours  ·  equip it in the Locker", UI.Gold)
					end
				end)
			end
		)
	end)
end

---------------------------------------------------------------------------------------
-- Gems

local function gemsTab(list: ScrollingFrame)
	UI.note(list, "Gems buy cosmetics only: blades, finishers, outfits, banners. Never power.", 1)
	local grid = UI.new("Frame", {
		Name = "Packs",
		LayoutOrder = 2,
		Size = UDim2.new(1, 0, 0, 236),
		BackgroundTransparency = 1,
	}, list)
	UI.new("UIGridLayout", {
		CellSize = UDim2.new(1 / 3, -8, 0, 114),
		CellPadding = UDim2.fromOffset(8, 8),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, grid)
	local packs = Catalog.list("gemPack")
	-- The bonus is measured against the smallest pack's gems per Robux.
	local base: number? = nil
	for i, item in packs do
		local key = (item.price :: Catalog.Price).product :: string
		local gems = (item.contents :: Catalog.Contents).gems or 0
		local robux = StoreUI.robux(key)
		if i == 1 and robux then
			base = gems / robux
		end
		local bonus = if base and robux then math.floor((gems / (robux * base) - 1) * 100 + 0.5) else 0
		local card = UI.panel({ Name = StoreUI.key(item.id), LayoutOrder = i, BackgroundColor3 = UI.PanelLight }, grid)
		local art = UI.new("Frame", {
			Position = UDim2.fromOffset(4, 4),
			Size = UDim2.fromOffset(84, 84),
			BackgroundTransparency = 1,
		}, card)
		StoreUI.thumb(art, item)
		UI.text({
			Position = UDim2.fromOffset(92, 4),
			Size = UDim2.new(1, -100, 0, 32),
			TextXAlignment = Enum.TextXAlignment.Left,
			Font = UI.Bold,
			TextSize = 30,
			TextColor3 = UI.Jade,
			Text = UI.number(gems),
		}, card)
		UI.text({
			Position = UDim2.fromOffset(92, 36),
			Size = UDim2.new(1, -100, 0, 18),
			TextXAlignment = Enum.TextXAlignment.Left,
			TextSize = 15,
			TextTransparency = 0.2,
			Text = if bonus > 0 then `gems  ·  +{bonus}% bonus` else "gems",
		}, card)
		local button = UI.button({
			Name = "Buy",
			AnchorPoint = Vector2.new(1, 1),
			Position = UDim2.new(1, -8, 1, -8),
			Size = UDim2.new(1, -100, 0, 50),
			Text = if robux then `R$ {UI.number(robux)}` else "See price",
			TextSize = 20,
			BackgroundColor3 = UI.Crimson,
		}, card)
		button.Activated:Connect(function()
			StoreUI.purchase(key)
		end)
	end
end

---------------------------------------------------------------------------------------
-- Offers

local function offerCard(
	list: ScrollingFrame,
	item: Catalog.Item,
	order: number,
	lines: { string },
	owned: boolean,
	extra: ((TextLabel) -> ())?
)
	local key = (item.price :: Catalog.Price).product :: string
	local card = UI.panel({
		Name = StoreUI.key(item.id),
		LayoutOrder = order,
		Size = UDim2.new(1, 0, 0, 112),
		BackgroundColor3 = UI.PanelLight,
	}, list)
	StoreUI.frame(card, item.rarity)
	local art = UI.new("Frame", {
		Position = UDim2.fromOffset(6, 6),
		Size = UDim2.fromOffset(100, 100),
		BackgroundTransparency = 1,
	}, card)
	StoreUI.thumb(art, item)
	UI.text({
		Position = UDim2.fromOffset(116, 8),
		Size = UDim2.new(1, -310, 0, 28),
		TextXAlignment = Enum.TextXAlignment.Left,
		Font = UI.Display,
		TextSize = 24,
		Text = item.name,
	}, card)
	local text = UI.text({
		Position = UDim2.fromOffset(116, 38),
		Size = UDim2.new(1, -310, 0, 66),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		TextWrapped = true,
		TextSize = 15,
		TextTransparency = 0.1,
		Text = table.concat(lines, "\n"),
	}, card)
	local robux = StoreUI.robux(key)
	local button = UI.actionButton(card, {
		Name = "Buy",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -14, 0.5, if extra then 10 else 0),
		Size = UDim2.fromOffset(170, UI.Touch),
		Text = if owned then "Owned" elseif robux then `R$ {UI.number(robux)}` else "See price",
		TextSize = 20,
		BackgroundColor3 = if owned then UI.Panel else nil,
		TextColor3 = if owned then UI.Jade else nil,
	}, not owned)
	if extra then
		local sub = UI.text({
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -14, 0, 10),
			Size = UDim2.fromOffset(170, 18),
			TextSize = 14,
			TextColor3 = UI.Gold,
			Text = "",
		}, card)
		extra(sub)
	end
	button.Activated:Connect(function()
		if not owned then
			StoreUI.purchase(key)
		end
	end)
	return text
end

local function offersTab(list: ScrollingFrame)
	local passes = StoreUI.passes()
	local order = 0
	local function nextOrder(): number
		order += 1
		return order
	end
	UI.note(list, "Everything here is cosmetic or convenience. Nothing changes a fight.", nextOrder())

	local initiate = Catalog.get("bundle.Initiate")
	if initiate and StoreUI.initiateOpen() then
		local endsAt = StoreUI.attr("InitiateEndsAt", 0)
		offerCard(
			list,
			initiate,
			nextOrder(),
			{
				"The Initiate's Vow blade, the Initiate title, 300 gems and 1,500 coins.",
				"Once per account, for your first 72 hours.",
			},
			false,
			function(label)
				StoreUI.countdown(label, endsAt, function(left)
					return `Offer ends in {left}`
				end)
			end
		)
	end

	local premium = Catalog.get("pass.Premium")
	if premium then
		offerCard(list, premium, nextOrder(), {
			"This season's premium track: two blades, a finisher, a title, about 500 gems back.",
			"Tiers you've already reached pay out at once.",
		}, StoreUI.attr("PassPremium", false) == true or StoreUI.attr("SeasonPremium", false) == true)
	end

	UI.heading(list, "Passes", nextOrder())
	local PASS_LINES: { [string]: { string } } = {
		["pass.VIP"] = { "A Ronin nameplate frame and chat tag, an exclusive sheath. No boosts." },
		["pass.Loadouts"] = { "Save six loadout presets instead of three." },
		["pass.TitleSlot"] = { "Show a second title on your nameplate and duel card." },
		["pass.VictoryCry"] = { "A war cry when you win a royale or a duel." },
	}
	for _, key in { "pass.VIP", "pass.Loadouts", "pass.TitleSlot", "pass.VictoryCry" } do
		local item = Catalog.get(key)
		if item then
			offerCard(list, item, nextOrder(), PASS_LINES[key], passes[key] == true)
		end
	end
end

---------------------------------------------------------------------------------------
-- Shrine: earned draws, the gem capsule, odds, pity, shards

local function outcomeName(outcome: { [string]: any }): string
	if outcome.kind == "item" then
		local item = Catalog.get(outcome.id)
		return if item then item.name else tostring(outcome.id)
	end
	return outcome.label or `{UI.number(outcome.amount or 0)} {string.lower(tostring(outcome.kind))}`
end

local CURRENCY_ICON: { [string]: string } = {
	Coins = ICONS.Coin,
	Gems = ICONS.Gem,
	Whetstones = ICONS.Whetstone or ICONS.Skin,
	Shards = ICONS.Shard or ICONS.Gem,
}

-- The full odds table: every outcome with its percent, owned items marked with what a
-- duplicate pays, the tier totals and (capsule) the pity rules.
local function showOdds(odds: { [string]: any }, title: string, confirm: { label: string, run: () -> () }?)
	local have = StoreUI.owned()
	UI.sheet(Panels.window(), title, function(content)
		local list = UI.scroll(content, 2)
		if confirm then
			list.Size = UDim2.new(1, 0, 1, -UI.Touch - 10)
			local go = UI.button({
				Name = "Confirm",
				AnchorPoint = Vector2.new(0.5, 1),
				Position = UDim2.fromScale(0.5, 1),
				Size = UDim2.new(0.6, 0, 0, UI.Touch),
				Text = confirm.label,
				BackgroundColor3 = UI.Crimson,
			}, content)
			go.Activated:Connect(function()
				UI.closeSheet()
				confirm.run()
			end)
		end
		local tiers = {}
		for _, t in odds.tiers or {} do
			local pct = string.format("%.1f%%", t.pct or 0)
			if t.effective then
				pct ..= string.format(" (%.1f%% with pity)", t.effective)
			end
			table.insert(tiers, `{StoreUI.rarityName(tostring(t.tier))} {pct}`)
		end
		UI.note(list, table.concat(tiers, "   ·   "), 1, 34)
		if odds.pity and odds.pity.text then
			UI.note(list, odds.pity.text, 2, 34)
		end
		local dup = odds.dupShards or {}
		for i, outcome in odds.outcomes or {} do
			local owns = outcome.kind == "item" and have[outcome.id] == true
			local row = UI.new("Frame", {
				LayoutOrder = 10 + i,
				Size = UDim2.new(1, 0, 0, 26),
				BackgroundColor3 = if i % 2 == 0 then UI.PanelLight else UI.Panel,
				BorderSizePixel = 0,
			}, list)
			UI.text({
				Position = UDim2.fromOffset(8, 0),
				Size = UDim2.new(0.6, -8, 1, 0),
				TextXAlignment = Enum.TextXAlignment.Left,
				TextSize = 15,
				TextTruncate = Enum.TextTruncate.AtEnd,
				TextColor3 = Flair.Rarity[outcome.rarity] or UI.Parchment,
				Text = outcomeName(outcome),
			}, row)
			UI.text({
				Position = UDim2.fromScale(0.6, 0),
				Size = UDim2.fromScale(0.25, 1),
				TextXAlignment = Enum.TextXAlignment.Left,
				TextSize = 13,
				TextColor3 = UI.Jade,
				Text = if owns then `owned → {dup[outcome.rarity] or 0} shards` else "",
			}, row)
			UI.text({
				AnchorPoint = Vector2.new(1, 0),
				Position = UDim2.new(1, -8, 0, 0),
				Size = UDim2.fromScale(0.15, 1),
				TextXAlignment = Enum.TextXAlignment.Right,
				Font = UI.Bold,
				TextSize = 15,
				Text = string.format("%.2f%%", outcome.pct or 0),
			}, row)
		end
	end, Vector2.new(640, 340))
end

-- What a draw (or ten) gave.
local function showResults(results: { { [string]: any } }, title: string)
	UI.sheet(Panels.window(), title, function(content)
		local grid = UI.new("ScrollingFrame", {
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			ScrollBarThickness = 6,
			AutomaticCanvasSize = Enum.AutomaticSize.Y,
			CanvasSize = UDim2.new(),
		}, content)
		UI.new("UIGridLayout", {
			CellSize = UDim2.fromOffset(112, 128),
			CellPadding = UDim2.fromOffset(8, 8),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}, grid)
		for i, outcome in results do
			local cell = UI.new("Frame", {
				LayoutOrder = i,
				BackgroundColor3 = UI.PanelLight,
				BorderSizePixel = 0,
			}, grid)
			UI.corner(cell)
			StoreUI.frame(cell, outcome.rarity or "common")
			local art = UI.new("Frame", {
				AnchorPoint = Vector2.new(0.5, 0),
				Position = UDim2.new(0.5, 0, 0, 4),
				Size = UDim2.fromOffset(72, 72),
				BackgroundTransparency = 1,
			}, cell)
			local item = outcome.kind == "item" and Catalog.get(outcome.id) or nil
			if item then
				StoreUI.thumb(art, item)
			else
				UI.new("ImageLabel", {
					Size = UDim2.fromScale(1, 1),
					BackgroundTransparency = 1,
					Image = CURRENCY_ICON[outcome.kind] or ICONS.Rewards,
				}, art)
			end
			UI.text({
				Position = UDim2.fromOffset(4, 78),
				Size = UDim2.new(1, -8, 0, 20),
				TextSize = 15,
				Font = UI.Bold,
				TextTruncate = Enum.TextTruncate.AtEnd,
				TextColor3 = Flair.Rarity[outcome.rarity or "common"] or UI.Parchment,
				Text = if item then item.name else `+{UI.number(outcome.amount or 0)} {string.lower(outcome.kind)}`,
			}, cell)
			UI.text({
				Position = UDim2.fromOffset(4, 100),
				Size = UDim2.new(1, -8, 0, 18),
				TextSize = 13,
				TextColor3 = UI.Jade,
				Text = if outcome.dup
					then `owned → +{outcome.shards or 0} shards`
					elseif outcome.pity then "pity"
					elseif item then "New!"
					else "",
			}, cell)
		end
	end, Vector2.new(640, 330))
end

local function drawNow(count: number)
	shop("Draw", count, function(result)
		if result.ok and typeof(result.results) == "table" then
			showResults(result.results, if count == 1 then "Shrine Draw" else `{count} Shrine Draws`)
		end
	end)
end

local function capsuleNow(count: number, cost: number)
	shop("Capsule", count, function(result)
		if result.ok and typeof(result.results) == "table" then
			showResults(result.results, `Shrine Capsule  ·  -{UI.number(cost)} gems`)
		end
	end)
end

local function history()
	shop("History", nil, function(result)
		if not result.ok or typeof(result.data) ~= "table" then
			return
		end
		UI.sheet(Panels.window(), "Your last draws", function(content)
			local list = UI.scroll(content, 2)
			if #result.data == 0 then
				UI.note(list, "No draws yet.", 1)
			end
			for i, entry in result.data do
				local when = os.date("!%d %b %H:%M", math.floor(entry.t or 0))
				local what = if entry.kind == "item"
					then ((Catalog.get(entry.id) or {} :: any).name or entry.id)
					else `{UI.number(entry.amount or 0)} {string.lower(tostring(entry.kind))}`
				local tail = if entry.dup then `  (owned → {entry.shards or 0} shards)` else ""
				UI.note(list, `{when}   {if entry.pool == "capsule" then "Capsule" else "Draw"}   {what}{tail}`, i, 24)
			end
		end, Vector2.new(560, 320))
	end)
end

local function shrinePanel(parent: Instance, order: number, width: UDim): Frame
	local box = UI.panel({
		LayoutOrder = order,
		Size = UDim2.new(width.Scale, width.Offset, 1, 0),
		BackgroundColor3 = UI.PanelLight,
	}, parent)
	return box
end

local function shrineTab(list: ScrollingFrame)
	local draws = StoreUI.attr("Draws", 0)
	local cap = capsule()
	local drawOdds = rsJson("ShrineOdds")

	local top = UI.new("Frame", {
		Name = "Shrine",
		LayoutOrder = 1,
		Size = UDim2.new(1, 0, 0, 186),
		BackgroundTransparency = 1,
	}, list)
	UI.new("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		Padding = UDim.new(0, 8),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, top)

	-- Earned Shrine Draws.
	local drawBox = shrinePanel(top, 1, if cap then UDim.new(0.5, -4) else UDim.new(1, 0))
	drawBox.Name = "Draws"
	UI.new("ImageLabel", {
		Position = UDim2.fromOffset(6, 4),
		Size = UDim2.fromOffset(78, 78),
		BackgroundTransparency = 1,
		Image = ICONS.ShrineDraw or ICONS.Rewards,
	}, drawBox)
	UI.text({
		Position = UDim2.fromOffset(92, 8),
		Size = UDim2.new(1, -100, 0, 28),
		TextXAlignment = Enum.TextXAlignment.Left,
		Font = UI.Display,
		TextSize = 24,
		Text = "Shrine Draw",
	}, drawBox)
	UI.text({
		Name = "Info",
		Position = UDim2.fromOffset(92, 40),
		Size = UDim2.new(1, -100, 0, 66),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		TextWrapped = true,
		TextSize = 15,
		Text = if draws > 0
			then `You have {draws} {if draws == 1 then "draw" else "draws"} to open. Earned in play, never sold.`
			else "Earn draws by winning royales, your first duel win each day and pass tiers. Never sold.",
	}, drawBox)
	local half = UDim2.new(1 / 3, -8, 0, UI.Touch)
	local quarter = UDim2.new(1 / 4, -8, 0, UI.Touch)
	local buttons = UI.new("Frame", {
		Name = "Buttons",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 8, 1, -8),
		Size = UDim2.new(1, -16, 0, UI.Touch),
		BackgroundTransparency = 1,
	}, drawBox)
	UI.new("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		Padding = UDim.new(0, 8),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, buttons)
	local odds = UI.button({ Name = "Odds", LayoutOrder = 1, Size = quarter, Text = "Odds", TextSize = 18 }, buttons)
	UI.stroke(odds)
	odds.Activated:Connect(function()
		oddsSeen = true
		showOdds(drawOdds, "Shrine Draw odds")
	end)
	local function open(count: number)
		if draws < 1 then
			Toasts.notice("No draws yet: win a royale or your first duel of the day.", UI.Parchment)
			return
		end
		if not oddsSeen then
			oddsSeen = true
			showOdds(drawOdds, "Shrine Draw odds", {
				label = if count == 1 then "Open 1 draw" else `Open {count} draws`,
				run = function()
					drawNow(count)
				end,
			})
			return
		end
		drawNow(count)
	end
	local one =
		UI.actionButton(buttons, { Name = "Open1", LayoutOrder = 2, Size = quarter, Text = "Open 1" }, draws > 0)
	one.Activated:Connect(function()
		open(1)
	end)
	local many = math.min(draws, 10)
	local all = UI.actionButton(buttons, {
		Name = "OpenAll",
		LayoutOrder = 3,
		Size = quarter,
		Text = if many > 1 then `Open {many}` else "Open all",
	}, many > 1)
	all.Activated:Connect(function()
		if many > 1 then
			open(many)
		else
			open(1)
		end
	end)
	local historyButton = UI.button({
		Name = "History",
		LayoutOrder = 4,
		Size = quarter,
		Text = "History",
		TextSize = 16,
		BackgroundColor3 = UI.Panel,
	}, buttons)
	UI.stroke(historyButton, UI.Bronze, 1, 0.5)
	historyButton.Activated:Connect(history)

	-- The gem Shrine Capsule: only when the server says it may be shown to this player.
	if cap then
		local capBox = shrinePanel(top, 2, UDim.new(0.5, -4))
		capBox.Name = "Capsule"
		local featured = Catalog.get(cap.featured)
		local art = UI.new("Frame", {
			Position = UDim2.fromOffset(6, 4),
			Size = UDim2.fromOffset(78, 78),
			BackgroundTransparency = 1,
		}, capBox)
		if featured then
			StoreUI.thumb(art, featured)
		else
			UI.new("ImageLabel", {
				Size = UDim2.fromScale(1, 1),
				BackgroundTransparency = 1,
				Image = ICONS.ShrineCapsule or ICONS.Rewards,
			}, art)
		end
		UI.text({
			Position = UDim2.fromOffset(92, 8),
			Size = UDim2.new(1, -100, 0, 28),
			TextXAlignment = Enum.TextXAlignment.Left,
			Font = UI.Display,
			TextSize = 24,
			Text = "Shrine Capsule",
		}, capBox)
		local info = UI.text({
			Name = "Info",
			Position = UDim2.fromOffset(92, 36),
			Size = UDim2.new(1, -100, 0, 44),
			TextXAlignment = Enum.TextXAlignment.Left,
			TextYAlignment = Enum.TextYAlignment.Top,
			TextWrapped = true,
			TextSize = 14,
			Text = "",
		}, capBox)
		local featuredName = if featured then featured.name else "the featured blade"
		local epicLeft = math.max(1, (cap.epicAt or 10) - (cap.epicSince or 0))
		local legLeft = math.max(1, (cap.legendaryAt or 40) - (cap.legendarySince or 0))
		local pityText = `Epic or better within {epicLeft} · {featuredName} within {legLeft}`
		if typeof(cap.bannerEndsAt) == "number" and cap.bannerEndsAt > 0 then
			StoreUI.countdown(info, cap.bannerEndsAt, function(left)
				return `{pityText}\nFeatured item changes in {left}`
			end)
		else
			info.Text = pityText
		end
		local row = UI.new("Frame", {
			Name = "Buttons",
			AnchorPoint = Vector2.new(0, 1),
			Position = UDim2.new(0, 8, 1, -8),
			Size = UDim2.new(1, -16, 0, UI.Touch),
			BackgroundTransparency = 1,
		}, capBox)
		UI.new("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			Padding = UDim.new(0, 8),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}, row)
		local capOdds = UI.button({ Name = "Odds", LayoutOrder = 1, Size = half, Text = "Odds", TextSize = 18 }, row)
		UI.stroke(capOdds)
		capOdds.Activated:Connect(function()
			showOdds(cap.odds or {}, "Shrine Capsule odds")
		end)
		local gems = StoreUI.attr("Gems", 0)
		for i, count in { 1, 10 } do
			local cost = if count == 1 then cap.price1 or 100 else cap.price10 or 900
			local button = UI.actionButton(row, {
				Name = `Capsule{count}`,
				LayoutOrder = 1 + i,
				Size = half,
				TextSize = 15,
				Text = `{count} × {UI.number(cost)} gems`,
			}, gems >= cost)
			button.Activated:Connect(function()
				if gems < cost then
					StorePanel.show("Gems")
					return
				end
				-- Paid draws always show the odds first, with the price on the button.
				showOdds(cap.odds or {}, `Shrine Capsule  ·  {count} for {UI.number(cost)} gems`, {
					label = `Spend {UI.number(cost)} gems`,
					run = function()
						capsuleNow(count, cost)
					end,
				})
			end)
		end
	end

	-- The shard shop: every pool item, for Shards or bought outright.
	local shardPrices = rsJson("ShardPrices")
	local direct = rsJson("DirectPrices")
	local ids = {}
	for id in shardPrices do
		if Catalog.get(id) then
			table.insert(ids, id)
		end
	end
	if #ids == 0 then
		return
	end
	local rank = { common = 1, uncommon = 2, rare = 3, epic = 4, legendary = 5 }
	table.sort(ids, function(a, b)
		local ia, ib = Catalog.get(a) :: Catalog.Item, Catalog.get(b) :: Catalog.Item
		if ia.rarity ~= ib.rarity then
			return (rank[ia.rarity] or 0) > (rank[ib.rarity] or 0)
		end
		return ia.order < ib.order
	end)
	UI.heading(list, `Shard shop  ·  you have {UI.number(StoreUI.attr("Shards", 0))} shards`, 2)
	UI.note(
		list,
		"Duplicates from draws turn into Shards. Every item a draw can give is also here to buy outright.",
		3,
		36
	)
	local have = StoreUI.owned()
	local shards, gems, coins = StoreUI.attr("Shards", 0), StoreUI.attr("Gems", 0), StoreUI.attr("Coins", 0)
	for i, id in ids do
		local item = Catalog.get(id) :: Catalog.Item
		local owns = have[id] == true
		local row = UI.panel({
			Name = StoreUI.key(id),
			LayoutOrder = 10 + i,
			Size = UDim2.new(1, 0, 0, 72),
			BackgroundColor3 = UI.PanelLight,
		}, list)
		local art = UI.new("Frame", {
			Position = UDim2.fromOffset(6, 4),
			Size = UDim2.fromOffset(60, 60),
			BackgroundTransparency = 1,
		}, row)
		StoreUI.thumb(art, item)
		UI.text({
			Position = UDim2.fromOffset(74, 8),
			Size = UDim2.new(1, -420, 0, 26),
			TextXAlignment = Enum.TextXAlignment.Left,
			Font = UI.Display,
			TextSize = 20,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Text = item.name,
		}, row)
		UI.text({
			Position = UDim2.fromOffset(74, 36),
			Size = UDim2.new(1, -420, 0, 18),
			TextXAlignment = Enum.TextXAlignment.Left,
			TextSize = 14,
			TextColor3 = if owns then UI.Jade else Flair.Rarity[item.rarity] or UI.Parchment,
			Text = if owns then "Owned" else StoreUI.rarityName(item.rarity),
		}, row)
		if owns then
			continue
		end
		local shardCost = tonumber(shardPrices[id]) or 0
		local shardButton = UI.actionButton(row, {
			Name = "Shards",
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -184, 0.5, 0),
			Size = UDim2.fromOffset(160, 58),
			TextSize = 16,
			Text = `{UI.number(shardCost)} shards`,
		}, shards >= shardCost)
		shardButton.Activated:Connect(function()
			if shards < shardCost then
				Toasts.notice(`{UI.number(shardCost - shards)} more shards for {item.name}`, UI.Parchment)
				return
			end
			UI.confirm(
				Panels.window(),
				item.name,
				`Trade {UI.number(shardCost)} shards for {item.name}?`,
				"Trade",
				function()
					shop("ShardBuy", id, function(result)
						if result.ok then
							Toasts.notice(`Unlocked  ·  {item.name}`, UI.Gold)
						end
					end)
				end
			)
		end)
		local price = direct[id]
		if typeof(price) == "table" and (price.gems or price.coins) then
			local currency = if price.gems then "Gems" else "Coins"
			local cost = price.gems or price.coins
			local afford = (if currency == "Gems" then gems else coins) >= cost
			local buy = UI.actionButton(row, {
				Name = "Direct",
				AnchorPoint = Vector2.new(1, 0.5),
				Position = UDim2.new(1, -14, 0.5, 0),
				Size = UDim2.fromOffset(160, 58),
				TextSize = 16,
				Text = `{UI.number(cost)} {string.lower(currency)}`,
				BackgroundColor3 = if afford then UI.PanelLight else nil,
			}, afford)
			if afford then
				UI.stroke(buy, UI.Jade, 1.5, 0.2)
			end
			buy.Activated:Connect(function()
				if not afford then
					if currency == "Gems" then
						StorePanel.show("Gems")
					end
					return
				end
				UI.confirm(
					Panels.window(),
					item.name,
					`Unlock {item.name} for {UI.number(cost)} {string.lower(currency)}?`,
					"Unlock",
					function()
						shop("DirectBuy", id, function(result)
							if result.ok then
								Toasts.notice(`Unlocked  ·  {item.name}`, UI.Gold)
							end
						end)
					end
				)
			end)
		end
	end
end

---------------------------------------------------------------------------------------

local BUILDERS: { [TabId]: (ScrollingFrame) -> () } = {
	Featured = featuredTab,
	Gems = gemsTab,
	Offers = offersTab,
	Shrine = shrineTab,
}

function StorePanel.build(body: Frame)
	header()
	local failed = StoreUI.attr("DataFailed", false) == true or StoreUI.attr("CanTransact", true) == false
	UI.tabs(
		body,
		{
			{ id = "Featured", label = "Featured" },
			{ id = "Gems", label = "Gems" },
			{ id = "Offers", label = "Offers" },
			{ id = "Shrine", label = "Shrine", dot = StoreUI.attr("Draws", 0) > 0 },
		},
		tab,
		function(id)
			tab = id :: TabId
			Panels.resetScroll()
			Panels.redraw()
		end,
		54
	)
	local area = UI.new("Frame", {
		Name = "Area",
		Position = UDim2.fromOffset(0, 62),
		Size = UDim2.new(1, 0, 1, -62),
		BackgroundTransparency = 1,
	}, body)
	if failed then
		area.Position = UDim2.fromOffset(0, 88)
		area.Size = UDim2.new(1, 0, 1, -88)
		UI.text({
			Name = "Blocked",
			Position = UDim2.fromOffset(0, 60),
			Size = UDim2.new(1, 0, 0, 24),
			TextXAlignment = Enum.TextXAlignment.Left,
			TextSize = 15,
			TextColor3 = UI.Danger,
			Text = "Your progress couldn't load, so purchases are off this session. Rejoin to try again.",
		}, body)
	end
	local list = UI.scroll(area, 8)
	BUILDERS[tab](list)
end

-- Whether the Store has something waiting (a Shrine Draw to open).
function StorePanel.badge(): boolean
	return StoreUI.attr("Draws", 0) > 0
end

function StorePanel.start()
	Panels.register("Store", { title = "Store", build = StorePanel.build, large = true })
	-- The shop rotation and odds live on ReplicatedStorage.
	ReplicatedStorage.AttributeChanged:Connect(function(name)
		if
			Panels.current() == "Store" and (name == "ShopRotation" or name == "ShrineOdds" or name == "ShardPrices")
		then
			Panels.redraw()
		end
	end)
end

return StorePanel
