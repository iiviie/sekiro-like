--!strict
-- The Locker: everything you can wear, by slot (weapon, blade, finisher, outfit, title,
-- banner, nameplate). Owned items equip; anything else says plainly how to get it (its
-- unlock rule with your progress, its price, or where it drops). Blade lines level up
-- here, L1 -> L4, with Whetstones (gems can cover up to half a level). Names, prices and
-- rules come from Shared/Catalog; ownership, loadout, levels and progress from the
-- server's attributes. Every change is a LobbyAction request the server checks.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Assets = require(ReplicatedStorage.Shared.Assets)
local Catalog = require(ReplicatedStorage.Shared.Catalog)
local EconomyConfig = require(ReplicatedStorage.Shared.EconomyConfig)
local Flair = require(ReplicatedStorage.Shared.Flair)
local Panels = require(script.Parent.Panels)
local StorePanel = require(script.Parent.StorePanel)
local StoreUI = require(script.Parent.StoreUI)
local Toasts = require(script.Parent.Toasts)
local UI = require(script.Parent.UI)

local player = Players.LocalPlayer
local ICONS = Assets.Icons :: any

local LockerPanel = {}

type Tab = { id: Catalog.Slot, label: string, categories: { Catalog.Category } }
local TABS: { Tab } = {
	{ id = "weapon", label = "Weapon", categories = { "weapon" } },
	{ id = "bladeSkin", label = "Blade", categories = { "bladeSkin", "bladeLine" } },
	{ id = "finisher", label = "Finisher", categories = { "finisher" } },
	{ id = "outfit", label = "Outfit", categories = { "outfit" } },
	{ id = "title", label = "Title", categories = { "title" } },
	{ id = "banner", label = "Banner", categories = { "banner" } },
	{ id = "nameplate", label = "Nameplate", categories = { "nameplate" } },
}

local NO_TITLE = "title." -- equipping this clears the title

local tab: Catalog.Slot = "bladeSkin"
local selected: { [string]: string } = {} -- slot -> the item shown in the preview

-- Optional preview hooks (part C's CombatVisuals preview functions, wired in start()).
local previewers: { [string]: (item: Catalog.Item) -> () } = {}

function LockerPanel.show(slot: Catalog.Slot?)
	if slot then
		tab = slot
	end
	Panels.open("Locker")
end

-- Registers a preview function for a category (called with the item when Preview is
-- pressed).
function LockerPanel.setPreview(category: string, fn: (item: Catalog.Item) -> ())
	previewers[category] = fn
end

local function tabOf(slot: string): Tab
	for _, t in TABS do
		if t.id == slot then
			return t
		end
	end
	return TABS[1]
end

-- Items of the open slot worth listing: owned ones always; others when there is a way to
-- get them (a price, a rule, a season reward, the bundle while it's on offer).
local function itemsFor(t: Tab, have: { [string]: boolean }): { Catalog.Item }
	local out = {}
	for _, item in Catalog.Items do
		if not table.find(t.categories, item.category) then
			continue
		end
		local owns = have[item.id] == true or item.default == true
		if not owns then
			local source = item.sources[1]
			if source == "bundle" and not StoreUI.initiateOpen() then
				continue -- the bundle exclusive is gone once the offer is
			end
		end
		table.insert(out, item)
	end
	-- Owned first (equipped at the very top), then by catalogue order.
	local worn = StoreUI.loadout()
	table.sort(out, function(a, b)
		local ae, be = worn[t.id] == a.id, worn[t.id] == b.id
		if ae ~= be then
			return ae
		end
		local ao = have[a.id] == true or a.default == true
		local bo = have[b.id] == true or b.default == true
		if ao ~= bo then
			return ao
		end
		return a.order < b.order
	end)
	return out
end

-- The plain line for an item you don't own, with ranked rewards spelled out.
local function howToGet(item: Catalog.Item, progress: { [string]: any }): string
	local tier = string.match(item.ref, "^S%d(%a+)$")
	if item.sources[1] == "ranked" and tier then
		return `Finish Season {string.sub(item.season or "S1", 2)} ranked in {tier} or higher`
	end
	return StoreUI.howToGet(item, progress)
end

local function status(item: Catalog.Item, owns: boolean, equipped: boolean, progress: { [string]: any }): string
	if equipped then
		return "Equipped"
	elseif owns then
		return "Owned"
	end
	local entry = progress[item.id]
	if item.rule and typeof(entry) == "table" and entry[1] < entry[2] then
		return `{UI.number(entry[1])}/{UI.number(entry[2])}`
	end
	if item.price and not item.price.product then
		return if Catalog.isReady(item) then StoreUI.priceText(item) else "Coming soon"
	end
	return "Locked"
end

local function card(parent: Instance, item: Catalog.Item, order: number, state: { [string]: any })
	local owns = state.have[item.id] == true or item.default == true
	local equipped = state.worn == item.id
	local second = state.second == item.id
	local isSelected = state.selected == item.id
	local entry = state.progress[item.id]
	local price = item.price
	local ruleMet = not item.rule or not (typeof(entry) == "table" and entry[1] < entry[2])
	local priced = not owns
		and ruleMet
		and price ~= nil
		and not price.product
		and (price.coins ~= nil or price.gems ~= nil)
		and Catalog.isReady(item)
	local text = if second then "2nd title" else status(item, owns, equipped, state.progress)
	UI.card({
		Name = StoreUI.key(item.id),
		LayoutOrder = order,
		Size = UDim2.fromScale(1, 1),
		name = item.name,
		rarity = item.rarity,
		art = function(holder: Frame)
			StoreUI.thumb(holder, item, false)
		end,
		state = if equipped then "equipped" elseif owns then "owned" elseif priced then "buy" else "locked",
		selected = isSelected,
		price = if priced and price
			then { currency = if price.gems then "gems" else "coins", amount = price.gems or price.coins or 0 }
			else nil,
		status = if priced then nil else text,
		statusColor = if equipped or second then UI.Theme.GoldHi elseif owns then UI.Theme.JadeText else UI.Theme.Dim,
		onActivated = function()
			selected[tab] = item.id
			Panels.redraw()
		end,
	}, parent)
end

-- Blade line levels L1-L4 as gold diamonds (filled up to the current level).
local function levelPips(parent: Instance, item: Catalog.Item, level: number, y: number)
	local row = UI.new("Frame", {
		Name = "Levels",
		Position = UDim2.fromOffset(14, y),
		Size = UDim2.new(1, -28, 0, 20),
		BackgroundTransparency = 1,
	}, parent)
	UI.new("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		Padding = UDim.new(0, 12),
		VerticalAlignment = Enum.VerticalAlignment.Center,
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, row)
	for i = 1, #(item.levels or {}) do
		local pip = UI.new("Frame", {
			Name = `L{i}`,
			LayoutOrder = i,
			Size = UDim2.fromOffset(13, 13),
			Rotation = 45,
			BackgroundColor3 = if i <= level then UI.Theme.GoldHi else UI.Ink,
			BorderSizePixel = 0,
		}, row)
		UI.new("UIStroke", { Color = UI.Theme.Gold, Thickness = 1.5 }, pip)
	end
	UI.label("number", {
		LayoutOrder = 99,
		Size = UDim2.fromOffset(50, 20),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextSize = 16,
		TextColor3 = UI.Theme.GoldHi,
		Text = `L{level}`,
	}, row)
end

-- The big preview on the left: art, name, what it is, how to get it, and the one action.
local function preview(parent: Instance, item: Catalog.Item, state: { [string]: any })
	local window = Panels.window()
	local owns = state.have[item.id] == true or item.default == true
	local equipped = state.worn == item.id
	local isLine = item.category == "bladeLine"
	local upgradable = isLine and owns and item.levels ~= nil and item.levels[StoreUI.lineLevel(item.id) + 1] ~= nil
	-- An owned line with levels to go needs room for the pips and the Upgrade button.
	local artSize = if upgradable then 64 else 96
	local y = artSize + 6
	local box = UI.panel({
		Name = "Preview",
		Size = UDim2.new(0, 250, 1, 0),
		material = "inset",
	}, parent)
	UI.rarityGlow(box, item.rarity, 1)
	UI.rarityFrame(box, item.rarity, 4, 0.16)
	if item.rarity == "legendary" then
		UI.shine(box, 5)
	end
	-- The art sits left of centre so the Preview button (top right) never covers it.
	local art = UI.new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, -30, 0, 6),
		Size = UDim2.fromOffset(artSize, artSize),
		BackgroundTransparency = 1,
	}, box)
	StoreUI.thumb(art, item, false)
	UI.text({
		Position = UDim2.fromOffset(14, y),
		Size = UDim2.new(1, -28, 0, 28),
		FontFace = UI.Fonts.Display,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextSize = 22,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextColor3 = if item.category == "title" then Flair.Rarity[item.rarity] or UI.Parchment else UI.Parchment,
		Text = item.name,
	}, box)
	UI.label("caption", {
		Position = UDim2.fromOffset(14, y + 26),
		Size = UDim2.new(1, -28, 0, 18),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = UI.rarity(item.rarity).text,
		Text = item.rarity,
	}, box)
	local level = if isLine and owns then StoreUI.lineLevel(item.id) else 0
	local text: string
	if owns then
		text = item.blurb or (if item.category == "weapon" then "Never sold for Robux." else "Yours.")
		if isLine and item.levels then
			local nextLevel = item.levels[level + 1]
			text = if nextLevel then `Next: {nextLevel.text}` else "Fully upgraded: every level unlocked."
		end
	else
		text = howToGet(item, state.progress)
		if item.blurb then
			text = `{item.blurb}\n{text}`
		end
	end
	UI.text({
		Name = "Text",
		Position = UDim2.fromOffset(14, y + 46),
		Size = UDim2.new(1, -28, 0, if upgradable then 22 else 58),
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		TextSize = 15,
		TextColor3 = UI.Theme.Dim,
		Text = text,
	}, box)
	if isLine and owns then
		levelPips(box, item, level, y + 70)
	end

	-- The action button at the bottom.
	local touch = UI.Touch
	-- A title you own, with the second title slot: [Equip] and [As 2nd] side by side.
	local twoTitles = item.category == "title" and owns and StoreUI.attr("TitleSlots", 1) >= 2
	local split = upgradable or twoTitles
	-- Side by side with Upgrade for a line that can still level up.
	local action = UI.button({
		Name = "Action",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 12, 1, -12),
		Size = if split then UDim2.new(0.5, -15, 0, touch) else UDim2.new(1, -24, 0, touch),
		TextSize = 18,
		Text = "",
		ZIndex = 6,
	}, box)
	local coins, gems = StoreUI.attr("Coins", 0), StoreUI.attr("Gems", 0)
	local whetstones = StoreUI.attr("Whetstones", 0)
	local entry = state.progress[item.id]
	local ruleMet = not item.rule or not (typeof(entry) == "table" and entry[1] < entry[2])
	local price = item.price

	-- Lines: an Upgrade button beside the action once owned.
	if isLine and owns and item.levels and item.levels[level + 1] then
		local nextLevel = (item.levels :: { Catalog.LineLevel })[level + 1]
		local rules = EconomyConfig.LineUpgrade
		local cost = nextLevel.whetstones
		local maxGemStones = math.floor(cost * rules.GemShareMax)
		local shortBy = math.max(0, cost - whetstones)
		local viaGems = math.min(shortBy, maxGemStones)
		local gemCost = viaGems * rules.GemsPerWhetstone
		local canStones = whetstones >= cost
		local canMixed = not canStones and shortBy <= maxGemStones and gems >= gemCost
		local upgrade = UI.button({
			Name = "Upgrade",
			variant = if canStones or canMixed then "reward" else "disabled",
			AnchorPoint = Vector2.new(1, 1),
			Position = UDim2.new(1, -12, 1, -12),
			Size = UDim2.new(0.5, -15, 0, touch),
			TextSize = 18,
			FontFace = UI.Fonts.Number,
			Text = `To L{nextLevel.level}`,
			ZIndex = 6,
		}, box)
		upgrade:SetAttribute("Quiet", nil)
		-- The cost as a Whetstone pill over the buttons, the gem top-up as a line under it.
		UI.price({
			currency = "stones",
			amount = cost,
			AnchorPoint = Vector2.new(1, 1),
			Position = UDim2.new(1, -16, 1, -touch - 20),
			Size = UDim2.fromOffset(92, 28),
			height = 28,
			ZIndex = 6,
		}, box)
		UI.text({
			Name = "Cost",
			AnchorPoint = Vector2.new(0, 1),
			Position = UDim2.new(0, 14, 1, -touch - 22),
			Size = UDim2.new(1, -124, 0, 22),
			TextXAlignment = Enum.TextXAlignment.Left,
			TextSize = 14,
			TextColor3 = if canStones then UI.Theme.Dim elseif canMixed then UI.Theme.JadeText else UI.Theme.CrimsonText,
			Text = if canStones
				then `You have {whetstones}`
				elseif canMixed then `{cost - viaGems} + {gemCost} gems`
				else `You have {whetstones}`,
			ZIndex = 6,
		}, box)
		upgrade.Activated:Connect(function()
			if canStones then
				UI.sound("Claim")
				StoreUI.fire("UpgradeLine", item.id)
			elseif canMixed then
				UI.confirm(window, {
					title = `{item.name} to L{nextLevel.level}`,
					text = `Use {cost - viaGems} Whetstones and pay the other {viaGems} with gems.`,
					price = { currency = "gems", amount = gemCost },
					balance = gems,
					yes = "Upgrade",
					onYes = function()
						StoreUI.fire("UpgradeLine", { id = item.id, gems = viaGems })
					end,
				})
			else
				Toasts.notice(
					`Whetstones come from trials, wins and boss clears · gems can cover up to {maxGemStones} of these {cost}`,
					UI.Parchment
				)
			end
		end)
	end

	local function confirmUnlock(currency: string, cost: number)
		UI.confirm(window, {
			title = `Unlock {item.name}?`,
			art = function(holder: Frame)
				StoreUI.thumb(holder, item)
			end,
			rarity = item.rarity,
			price = { currency = currency, amount = cost },
			balance = if currency == "gems" then gems else coins,
			yes = "Unlock",
			shortLabel = if currency == "gems" then "Get gems" else "Not enough",
			onShort = if currency == "gems"
				then function()
					StorePanel.show("Gems")
				end
				else nil,
			onYes = function()
				StoreUI.fire("BuyItem", item.id)
			end,
		})
	end

	if equipped then
		action.Text = if item.category == "title" then "Take off" else "Equipped"
		UI.setVariant(action, if item.category == "title" then "secondary" else "disabled")
		action.TextColor3 = UI.Theme.GoldHi
		if item.category == "title" then
			action.Activated:Connect(function()
				StoreUI.fire("EquipItem", NO_TITLE)
			end)
		end
	elseif owns then
		action.Text = "Equip"
		UI.setVariant(action, "primary")
		action.Activated:Connect(function()
			UI.sound("Equip")
			StoreUI.fire("EquipItem", item.id)
		end)
	elseif price and not price.product and ruleMet and not Catalog.isReady(item) then
		action.Text = "Coming soon"
		UI.setVariant(action, "disabled")
	elseif price and price.coins and ruleMet then
		local afford = coins >= price.coins
		action.Text = if afford then "Unlock" else `{UI.number(price.coins - coins)} more coins`
		UI.setVariant(action, if afford then "primary" else "disabled")
		action:SetAttribute("Quiet", nil)
		action.Activated:Connect(function()
			if not afford then
				Toasts.notice("Coins come from every match, trials and the daily reward.", UI.Gold)
				return
			end
			confirmUnlock("coins", price.coins :: number)
		end)
	elseif price and price.gems and ruleMet then
		local afford = gems >= price.gems
		action.Text = if afford then "Unlock" else "Get gems"
		UI.setVariant(action, if afford then "primary" else "premium")
		action.Activated:Connect(function()
			if not afford then
				StorePanel.show("Gems")
				return
			end
			confirmUnlock("gems", price.gems :: number)
		end)
	elseif price and price.product then
		action.Text = "See it in the Store"
		UI.setVariant(action, "premium")
		action.Activated:Connect(function()
			StorePanel.show("Offers")
		end)
	else
		action.Text = "Locked"
		UI.setVariant(action, "disabled")
		action:SetAttribute("Quiet", nil)
		action.Activated:Connect(function()
			Toasts.notice(howToGet(item, state.progress), UI.Parchment)
		end)
	end
	-- A price line over the button for something you can unlock.
	if
		not owns
		and price
		and not price.product
		and ruleMet
		and Catalog.isReady(item)
		and (price.coins or price.gems)
	then
		UI.price({
			currency = if price.gems then "gems" else "coins",
			amount = price.gems or price.coins or 0,
			AnchorPoint = Vector2.new(0.5, 1),
			Position = UDim2.new(0.5, 0, 1, -touch - 20),
			Size = UDim2.fromOffset(130, 30),
			ZIndex = 6,
		}, box)
	end

	-- The second title slot (pass.TitleSlot): wear another owned title under the first.
	if twoTitles then
		local isSecond = state.second == item.id
		local second = UI.button({
			Name = "Second",
			variant = if equipped then "disabled" else "secondary",
			AnchorPoint = Vector2.new(1, 1),
			Position = UDim2.new(1, -12, 1, -12),
			Size = UDim2.new(0.5, -15, 0, touch),
			TextSize = 17,
			Text = if isSecond then "Off 2nd" else "As 2nd",
			ZIndex = 6,
		}, box)
		second.Activated:Connect(function()
			if equipped then
				return
			end
			UI.sound("Equip")
			StoreUI.fire("EquipTitle2", if isSecond then NO_TITLE else item.id)
		end)
	elseif item.category == "title" and owns and not StoreUI.passes()["pass.TitleSlot"] then
		local link = UI.tertiary({
			Name = "SecondSlot",
			AnchorPoint = Vector2.new(0.5, 1),
			Position = UDim2.new(0.5, 0, 1, -touch - 14),
			Size = UDim2.new(1, -24, 0, 30),
			Text = "Wear two titles: Second title slot",
			TextSize = 15,
			ZIndex = 6,
		}, box)
		link.Activated:Connect(function()
			StorePanel.show("Offers")
		end)
	end

	-- Preview (part C's hooks) for the categories that have one.
	local previewer = previewers[item.category]
	if previewer then
		local look = UI.button({
			Name = "Preview",
			variant = "secondary",
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -10, 0, 10),
			Size = UDim2.fromOffset(96, 54),
			TextSize = 16,
			Text = "Preview",
			ZIndex = 6,
		}, box)
		look.Activated:Connect(function()
			Panels.closeAll()
			previewer(item)
		end)
	end
end

-- A "no title" card for the title slot.
local function noTitleCard(parent: Instance, state: { [string]: any })
	local isSelected = state.selected == NO_TITLE
	local equipped = state.worn == "" or state.worn == nil
	UI.card({
		Name = "NoTitle",
		LayoutOrder = 0,
		Size = UDim2.fromScale(1, 1),
		name = "No title",
		caption = "plain name",
		captionColor = UI.Theme.Dim,
		state = if equipped then "equipped" else "owned",
		selected = isSelected,
		status = if equipped then "Equipped" else "Owned",
		statusColor = if equipped then UI.Theme.GoldHi else UI.Theme.JadeText,
		onActivated = function()
			if not equipped then
				StoreUI.fire("EquipItem", NO_TITLE)
			end
			selected.title = NO_TITLE
			Panels.redraw()
		end,
	}, parent)
end

local TAB_ICONS: { [string]: string? } = {
	weapon = ICONS.Weapons,
	bladeSkin = ICONS.Katana,
	finisher = ICONS.Tabs and ICONS.Tabs.Finishers or ICONS.Deathblow,
	outfit = ICONS.Tabs and ICONS.Tabs.Outfits or ICONS.Profile,
	title = ICONS.Tabs and ICONS.Tabs.Titles or ICONS.Guide,
	banner = ICONS.Tabs and ICONS.Tabs.Banners or ICONS.Trophy,
	nameplate = ICONS.Profile,
}

function LockerPanel.build(body: Frame)
	local header = Panels.header()
	UI.pill(header, ICONS.Coin, StoreUI.attr("Coins", 0), UI.Gold, 1)
	UI.pill(header, ICONS.Gem, StoreUI.attr("Gems", 0), UI.Jade, 2)
	UI.pill(header, ICONS.Whetstone or ICONS.Skin, StoreUI.attr("Whetstones", 0), UI.Parchment, 3)

	local have = StoreUI.owned()
	local worn = StoreUI.loadout()
	local progress = StoreUI.json("UnlockProgress")
	local t = tabOf(tab)
	local items = itemsFor(t, have)

	local tabs = {}
	for _, entry in TABS do
		table.insert(tabs, { id = entry.id, label = entry.label, icon = TAB_ICONS[entry.id] })
	end
	UI.tabs(body, tabs, t.id, function(id)
		tab = id :: Catalog.Slot
		Panels.resetScroll()
		Panels.redraw()
	end, 54)

	local area = UI.new("Frame", {
		Name = "Area",
		Position = UDim2.fromOffset(0, 62),
		Size = UDim2.new(1, 0, 1, -62),
		BackgroundTransparency = 1,
	}, body)

	-- What the preview shows: the picked item, else what's equipped, else the first.
	local pick = selected[t.id]
	local pickItem = Catalog.get(pick)
	if pick == NO_TITLE and t.id == "title" then
		pickItem = nil
	elseif not pickItem or not table.find(items, pickItem) then
		pickItem = Catalog.get(worn[t.id]) or items[1]
		pick = pickItem and pickItem.id or nil
	end
	local state = {
		have = have,
		worn = worn[t.id],
		second = if t.id == "title" and StoreUI.attr("TitleSlots", 1) >= 2 then worn.title2 else nil,
		progress = progress,
		selected = pick,
	}
	if pickItem then
		preview(area, pickItem, state)
	else
		local box = UI.panel({ Name = "Preview", Size = UDim2.new(0, 250, 1, 0), material = "inset" }, area)
		UI.text({
			Position = UDim2.fromOffset(14, 40),
			Size = UDim2.new(1, -28, 0, 80),
			TextWrapped = true,
			FontFace = UI.Fonts.Display,
			TextSize = 22,
			Text = "No title shown over your head.",
		}, box)
	end

	local grid = UI.new("ScrollingFrame", {
		Name = "Grid",
		Position = UDim2.fromOffset(262, 0),
		Size = UDim2.new(1, -262, 1, 0),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 5,
		ScrollBarImageColor3 = UI.Theme.Gold,
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(),
		ScrollingDirection = Enum.ScrollingDirection.Y,
	}, area)
	UI.new("UIGridLayout", {
		CellSize = UDim2.fromOffset(118, 160),
		CellPadding = UDim2.fromOffset(6, 8),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, grid)
	UI.new("UIPadding", {
		PaddingTop = UDim.new(0, 2),
		PaddingLeft = UDim.new(0, 2),
		PaddingBottom = UDim.new(0, 8),
	}, grid)
	if t.id == "title" then
		noTitleCard(grid, state)
	end
	for i, item in items do
		card(grid, item, i, state)
	end
	if t.id == "weapon" then
		local note = UI.text({
			LayoutOrder = 999,
			TextWrapped = true,
			TextSize = 14,
			TextColor3 = UI.Theme.Dim,
			Text = "Weapons are earned with coins, never sold for Robux.",
		}, grid)
		note.Name = "Note"
	end
end

-- Part C's previews (client/CosmeticPreview): the look goes on your own character (and a
-- local practice rig for finishers), so the Locker steps aside while it plays and a "Back to
-- the Locker" button undoes it.
type CosmeticModule = {
	finisher: (string) -> (),
	blade: (string, number?, number?) -> (),
	swing: () -> (),
	outfit: (string) -> (),
	clear: () -> (),
}
local backGui: ScreenGui? = nil

local function endPreview(cosmetic: CosmeticModule, reopen: boolean)
	if backGui then
		backGui:Destroy()
		backGui = nil
	end
	pcall(cosmetic.clear)
	if reopen then
		LockerPanel.show()
	end
end

local function startPreview(cosmetic: CosmeticModule, run: () -> ())
	if backGui then
		backGui:Destroy()
	end
	local gui = UI.new("ScreenGui", {
		Name = "LockerPreview",
		ResetOnSpawn = false,
		DisplayOrder = 7,
		ScreenInsets = Enum.ScreenInsets.CoreUISafeInsets,
	})
	local back = UI.button({
		Name = "Back",
		variant = "primary",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 132),
		Size = UDim2.fromOffset(260, UI.Touch),
		Text = "Back to the Locker",
		TextSize = 20,
		sound = "Cancel",
	}, gui)
	back.Activated:Connect(function()
		endPreview(cosmetic, true)
	end)
	gui.Parent = player:WaitForChild("PlayerGui")
	backGui = gui
	local ok, err = pcall(run)
	if not ok then
		warn("[LockerPanel] preview failed:", err)
	end
end

function LockerPanel.start()
	Panels.register("Locker", { title = "Locker", build = LockerPanel.build, large = true })
	local module = script.Parent:FindFirstChild("CosmeticPreview")
	if module and module:IsA("ModuleScript") then
		local ok, loaded = pcall(require, module)
		if ok and typeof(loaded) == "table" then
			local cosmetic = loaded :: CosmeticModule
			LockerPanel.setPreview("finisher", function(item)
				startPreview(cosmetic, function()
					cosmetic.finisher(item.ref)
				end)
			end)
			local function blade(item: Catalog.Item)
				local level = if StoreUI.owned()[item.id] then StoreUI.lineLevel(item.id) else 1
				startPreview(cosmetic, function()
					cosmetic.blade(item.id, if item.category == "bladeLine" then level else nil)
					cosmetic.swing()
				end)
			end
			LockerPanel.setPreview("bladeSkin", blade)
			LockerPanel.setPreview("bladeLine", blade)
			LockerPanel.setPreview("outfit", function(item)
				startPreview(cosmetic, function()
					cosmetic.outfit(item.ref)
				end)
			end)
			-- Opening any panel, or leaving the lobby, ends a preview.
			Panels.onChange(function(id)
				if id and backGui then
					endPreview(cosmetic, false)
				end
			end)
			player.CharacterAdded:Connect(function()
				if backGui then
					endPreview(cosmetic, false)
				end
			end)
		end
	end
end

return LockerPanel
