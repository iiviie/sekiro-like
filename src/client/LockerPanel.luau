--!strict
-- The Locker: everything you can wear, by slot (weapon, blade, finisher, outfit, title,
-- banner, nameplate, pre-fight intro). Owned items equip; anything else says plainly how to get it (its
-- unlock rule with your progress, its price, or where it drops). Blade lines level up
-- here, L1 -> L4, with Whetstones (gems can cover up to half a level). Names, prices and
-- rules come from Shared/Catalog; ownership, loadout, levels and progress from the
-- server's attributes. Every change is a LobbyAction request the server checks.
--
-- Also here: loadout presets (the Loadouts button in the title bar: 3 slots, 6 with the
-- pass; save what you wear, put a preset on in one tap, rename it), a 新 seal on things
-- you got this session and haven't looked at yet, a wishlist toggle for shop items (the
-- server says when one is in the daily shop), and Preview, which puts the item on you
-- (CosmeticPreview.present) with the camera in front.

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Assets = require(ReplicatedStorage.Shared.Assets)
local Catalog = require(ReplicatedStorage.Shared.Catalog)
local Text = require(ReplicatedStorage.Shared.Text)
local EconomyConfig = require(ReplicatedStorage.Shared.EconomyConfig)
local Flair = require(ReplicatedStorage.Shared.Flair)
local CosmeticPreview = require(script.Parent.CosmeticPreview)
local NewItems = require(script.Parent.NewItems)
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
	{ id = "intro", label = "Intro", categories = { "intro" } },
}

local NO_TITLE = "title." -- equipping this clears the title

local tab: Catalog.Slot = "bladeSkin"
local selected: { [string]: string } = {} -- slot -> the item shown in the preview

function LockerPanel.show(slot: Catalog.Slot?)
	if slot then
		tab = slot
	end
	Panels.open("Locker")
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
	-- Owned first, then by catalogue order: equipping something never moves its card.
	table.sort(out, function(a, b)
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
	local made = UI.card({
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
		isNew = owns and NewItems.isNew(item.id),
		onActivated = function()
			selected[tab] = item.id
			NewItems.seen(item.id)
			Panels.redraw()
		end,
	}, parent)
	-- Long names wrap onto two lines and shrink a little, instead of trailing off
	-- ("Crimson Lacquer"); never under 14 px.
	local label = made:FindFirstChild("ItemName")
	if label and label:IsA("TextLabel") then
		label.TextWrapped = true
		label.TextTruncate = Enum.TextTruncate.None
		label.TextScaled = true
		label.LineHeight = 0.9
		label.Position -= UDim2.fromOffset(0, 4)
		label.Size += UDim2.fromOffset(0, 6)
		UI.new("UITextSizeConstraint", { MaxTextSize = label.TextSize, MinTextSize = 14 }, label)
	end
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

local inShopToday: (id: string) -> boolean

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
		local entry = state.progress[item.id]
		local ruleMet = not item.rule or not (typeof(entry) == "table" and entry[1] < entry[2])
		local pricePill = item.price ~= nil
			and not item.price.product
			and ruleMet
			and Catalog.isReady(item)
			and (item.price.coins ~= nil or item.price.gems ~= nil)
		-- The price pill over the button says the price; the text says what it is.
		text = if pricePill
			then (item.blurb or "Unlock it once, wear it whenever you like.")
			else howToGet(item, state.progress)
		if item.blurb and not pricePill then
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
			Text = `To level {nextLevel.level}`,
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
			TextSize = 16,
			TextColor3 = if canStones then UI.Theme.Dim elseif canMixed then UI.Theme.JadeText else UI.Theme.CrimsonText,
			Text = if canStones
				then `You have {Text.currency(whetstones, "Whetstones")}`
				elseif canMixed then `{Text.currency(cost - viaGems, "Whetstones")} + {Text.currency(
					gemCost,
					"gems"
				)}`
				else `You have {Text.currency(whetstones, "Whetstones")}`,
			ZIndex = 6,
		}, box)
		upgrade.Activated:Connect(function()
			if canStones then
				UI.sound("Claim")
				StoreUI.fire("UpgradeLine", item.id)
			elseif canMixed then
				UI.confirm(window, {
					title = `{item.name} to L{nextLevel.level}`,
					text = `Use your {Text.currency(cost - viaGems, "Whetstones")}; {Text.currency(gemCost, "gems")} cover the other {viaGems}.`,
					price = { currency = "gems", amount = gemCost },
					balance = gems,
					yes = "Upgrade",
					onYes = function()
						StoreUI.fire("UpgradeLine", { id = item.id, gems = viaGems })
					end,
				})
			else
				Toasts.notice(
					`Whetstones come from missions, wins and boss clears. Gems can cover up to {maxGemStones} of the {cost}.`,
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
				Toasts.notice("Coins come from every fight, missions and the daily reward.", UI.Gold)
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
			Text = if isSecond then "Remove 2nd" else "Wear as 2nd",
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

	-- Preview: the item on you, the camera in front (part C's CosmeticPreview).
	local topY = 10
	if StoreUI.previewable(item) then
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
			if item.category == "intro" then
				-- Your pre-fight intro on your own character (client/IntroCinematic).
				local intro = require(script.Parent.IntroCinematic) :: any
				intro.preview(item.ref, function()
					LockerPanel.show("intro" :: Catalog.Slot)
				end)
				return
			end
			CosmeticPreview.present(item, {
				level = math.max(level, 1),
				back = "Back to the Locker",
				onBack = function()
					LockerPanel.show()
				end,
			})
		end)
		topY = 66
	end

	-- A shop item you don't own: in today's shop (a link there), or a wishlist toggle (the
	-- server tells you the day it rotates in).
	if not owns and StoreUI.wishable(item) and Catalog.isReady(item) then
		local today = inShopToday(item.id)
		local wished = StoreUI.wished()[item.id] == true
		local link = UI.tertiary({
			Name = "Wishlist",
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -10, 0, topY),
			Size = UDim2.fromOffset(110, 32),
			Text = if today then "In the Store today" elseif wished then "On your wishlist" else "Add to wishlist",
			TextColor3 = if today or wished then UI.Theme.GoldHi else nil,
			TextSize = 14,
			TextWrapped = true,
			ZIndex = 6,
		}, box)
		link.Activated:Connect(function()
			if today then
				StorePanel.show("Featured")
				return
			end
			UI.sound("Press")
			StoreUI.fire("Wish", item.id)
			if not wished then
				Toasts.notice(`{item.name} is on your wishlist: you'll hear when it's in the Store`, UI.Gold)
			end
		end)
	end
end

-- Whether `id` is in today's shop (the daily slots or the week's set).
function inShopToday(id: string): boolean
	local raw = ReplicatedStorage:GetAttribute("ShopRotation")
	if typeof(raw) ~= "string" then
		return false
	end
	local ok, rotation = pcall(HttpService.JSONDecode, HttpService, raw)
	if not ok or typeof(rotation) ~= "table" then
		return false
	end
	for _, list in { rotation.coin or {}, rotation.gem or {}, (rotation.featured or {}).items or {} } do
		if table.find(list, id) then
			return true
		end
	end
	return false
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
	intro = Assets.Cosmetics.Kanji.Path,
}

function LockerPanel.build(body: Frame)
	local header = Panels.header()
	local presetsButton = UI.button({
		Name = "Loadouts",
		variant = "secondary",
		LayoutOrder = 0,
		Size = UDim2.fromOffset(128, 44),
		TextSize = 16,
		Text = "Loadouts",
	}, header)
	presetsButton.Activated:Connect(function()
		LockerPanel.presets()
	end)
	UI.pill(header, ICONS.Coin, StoreUI.attr("Coins", 0), UI.Gold, 1)
	UI.pill(header, ICONS.Gem, StoreUI.attr("Gems", 0), UI.Jade, 2)
	UI.pill(header, ICONS.Whetstone or ICONS.Skin, StoreUI.attr("Whetstones", 0), UI.Parchment, 3)

	local have = StoreUI.owned()
	local worn = StoreUI.loadout()
	local progress = StoreUI.json("UnlockProgress")
	local t = tabOf(tab)
	local items = itemsFor(t, have)

	-- Icon tabs, the open one with its name (so every tab fits across the window), with a 新
	-- seal where something new waits.
	local tabs = {}
	for _, entry in TABS do
		local fresh = false
		for _, item in Catalog.Items do
			if table.find(entry.categories, item.category) and have[item.id] and NewItems.isNew(item.id) then
				fresh = true
				break
			end
		end
		table.insert(tabs, {
			id = entry.id,
			label = if entry.id == t.id then entry.label else "",
			icon = TAB_ICONS[entry.id],
			dot = fresh and entry.id ~= t.id,
		})
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
		NewItems.seen(pickItem.id)
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

---------------------------------------------------------------------------------------
-- Loadout presets: a sheet over the Locker, one row per slot (3, or 6 with the pass).

type Preset = { slot: number, name: string, slots: { [string]: string } }
local presetSheet: Frame? = nil
local renaming: number? = nil

local function presetList(): { [number]: Preset }
	local out = {}
	local raw = player:GetAttribute("LoadoutPresets")
	if typeof(raw) == "string" and raw ~= "" then
		local ok, list = pcall(HttpService.JSONDecode, HttpService, raw)
		if ok and typeof(list) == "table" then
			for _, entry in list do
				if typeof(entry) == "table" and typeof(entry.slot) == "number" then
					out[entry.slot] = entry
				end
			end
		end
	end
	return out
end

local function nameOf(id: string?, fallback: string): string
	local item = Catalog.get(id)
	return if item then item.name else fallback
end

-- "Crimson Lacquer · Slate Gi · Novice": the blade, the outfit and the title.
local function summary(slots: { [string]: string }): string
	local title = slots.title
	return `{nameOf(slots.bladeSkin, "Tamahagane")}  ·  {nameOf(slots.outfit, "Your avatar")}  ·  {if title
			and title ~= ""
		then nameOf(title, "no title")
		else "no title"}`
end

local function presetRow(list: ScrollingFrame, n: number, entry: Preset?, locked: boolean)
	local row = UI.panel({
		Name = `Preset{n}`,
		LayoutOrder = n,
		Size = UDim2.new(1, 0, 0, 66),
		material = "inset",
	}, list)
	local textW = UDim2.new(1, -330, 0, 26)
	if renaming == n and entry then
		local box = UI.new("TextBox", {
			Name = "NameBox",
			Position = UDim2.fromOffset(12, 6),
			Size = textW,
			BackgroundColor3 = UI.Theme.Ink,
			BackgroundTransparency = 0.3,
			ClearTextOnFocus = false,
			FontFace = UI.Fonts.Display,
			TextSize = 18,
			TextColor3 = UI.Theme.Bone,
			TextXAlignment = Enum.TextXAlignment.Left,
			PlaceholderText = "Name this loadout",
			Text = entry.name,
		}, row)
		UI.new("UISizeConstraint", { MaxSize = Vector2.new(400, 26) }, box)
		task.defer(function()
			if box.Parent then
				box:CaptureFocus()
			end
		end)
		box.FocusLost:Connect(function(enter)
			renaming = nil
			if enter and box.Text ~= "" and box.Text ~= entry.name then
				StoreUI.fire("Preset", { op = "rename", slot = n, name = string.sub(box.Text, 1, 40) })
			end
			LockerPanel.refreshPresets()
		end)
	else
		UI.text({
			Name = "PresetName",
			Position = UDim2.fromOffset(12, 6),
			Size = textW,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			FontFace = UI.Fonts.Display,
			TextSize = 18,
			TextColor3 = if entry then UI.Theme.Bone else UI.Theme.Dim,
			Text = if entry then entry.name elseif locked then `Slot {n}` else `Slot {n}  ·  empty`,
		}, row)
	end
	UI.text({
		Name = "Summary",
		Position = UDim2.fromOffset(12, 34),
		Size = UDim2.new(1, -330, 0, 22),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextSize = 14,
		TextColor3 = UI.Theme.Dim,
		Text = if locked
			then "With the Loadout presets pass"
			elseif entry then summary(entry.slots)
			else "Save what you're wearing now",
	}, row)
	local buttons = UI.new("Frame", {
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -8, 0.5, 0),
		Size = UDim2.fromOffset(312, 52),
		BackgroundTransparency = 1,
	}, row)
	UI.new("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		HorizontalAlignment = Enum.HorizontalAlignment.Right,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		Padding = UDim.new(0, 6),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, buttons)
	if locked then
		local see = UI.button({
			Name = "SeePass",
			variant = "premium",
			LayoutOrder = 1,
			Size = UDim2.fromOffset(160, 50),
			TextSize = 15,
			Text = "See it in the Store",
		}, buttons)
		see.Activated:Connect(function()
			UI.closeSheet()
			StorePanel.show("Offers")
		end)
		return
	end
	if entry then
		local rename = UI.tertiary({
			Name = "Rename",
			LayoutOrder = 1,
			Size = UDim2.fromOffset(78, 50),
			Text = "Rename",
			TextSize = 15,
		}, buttons)
		rename.Activated:Connect(function()
			renaming = n
			LockerPanel.refreshPresets()
		end)
	end
	local save = UI.button({
		Name = "Save",
		variant = "secondary",
		LayoutOrder = 2,
		Size = UDim2.fromOffset(110, 50),
		TextSize = 15,
		Text = if entry then "Save over" else "Save here",
	}, buttons)
	save.Activated:Connect(function()
		UI.sound("Confirm")
		StoreUI.fire("Preset", { op = "save", slot = n })
	end)
	if entry then
		local wear = UI.button({
			Name = "Wear",
			variant = "primary",
			LayoutOrder = 3,
			Size = UDim2.fromOffset(110, 50),
			TextSize = 16,
			Text = "Wear",
		}, buttons)
		wear.Activated:Connect(function()
			UI.sound("Equip")
			StoreUI.fire("Preset", { op = "wear", slot = n })
		end)
	end
end

local function fillPresets(content: Frame)
	for _, child in content:GetChildren() do
		child:Destroy()
	end
	local list = UI.scroll(content, 6)
	local max = StoreUI.attr("LoadoutSlots", 3)
	local presets = presetList()
	for n = 1, 6 do
		presetRow(list, n, presets[n], n > max)
	end
end

-- Rebuilds the open presets sheet (after a save, a rename, a new pass).
function LockerPanel.refreshPresets()
	local content = presetSheet
	if content and content.Parent then
		fillPresets(content)
		for _, child in content:GetDescendants() do
			if child:IsA("GuiObject") then
				child.ZIndex = math.max(child.ZIndex, 22)
			end
		end
	end
end

-- Opens the presets sheet over the Locker.
function LockerPanel.presets()
	renaming = nil
	presetSheet = UI.sheet(Panels.window(), "Loadouts", function(content)
		fillPresets(content)
	end, Vector2.new(680, 400), { material = "lacquer" })
end

function LockerPanel.start()
	Panels.register("Locker", { title = "Locker", build = LockerPanel.build, large = true })
	NewItems.start(function(slot, id)
		if slot and id then
			selected[slot] = id
		end
		LockerPanel.show(slot :: Catalog.Slot?)
	end)
	for _, name in { "LoadoutPresets", "LoadoutSlots", "Loadout", "Inventory" } do
		player:GetAttributeChangedSignal(name):Connect(function()
			if renaming == nil then
				LockerPanel.refreshPresets()
			end
		end)
	end
	-- Opening any panel ends a preview.
	Panels.onChange(function(id)
		if id and CosmeticPreview.active() then
			CosmeticPreview.stop(false)
		end
	end)
end

return LockerPanel
