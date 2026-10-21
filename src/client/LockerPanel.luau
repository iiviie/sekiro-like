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
	local isSelected = state.selected == item.id
	local entry = state.progress[item.id]
	local locked = not owns and (item.rule ~= nil and typeof(entry) == "table" and entry[1] < entry[2])
	local button = UI.button({
		Name = StoreUI.key(item.id),
		LayoutOrder = order,
		Text = "",
		BackgroundColor3 = if isSelected then UI.Selected elseif owns then UI.PanelLight else UI.Muted,
	}, parent)
	StoreUI.frame(button, item.rarity)
	if isSelected then
		UI.stroke(button, UI.Gold, 2.5, 0)
	end
	local art = UI.new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 8),
		Size = UDim2.fromOffset(76, 76),
		BackgroundTransparency = 1,
	}, button)
	StoreUI.thumb(art, item, locked)
	if not owns then
		for _, child in art:GetDescendants() do
			if child:IsA("ImageLabel") and child.Image ~= ICONS.Lock then
				child.ImageTransparency = 0.35
			end
		end
	end
	UI.text({
		Position = UDim2.fromOffset(6, 86),
		Size = UDim2.new(1, -12, 0, 20),
		Font = UI.Display,
		TextSize = 17,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextColor3 = if item.category == "title" then Flair.Rarity[item.rarity] or UI.Parchment else UI.Parchment,
		Text = item.name,
	}, button)
	UI.text({
		Position = UDim2.fromOffset(6, 108),
		Size = UDim2.new(1, -12, 0, 18),
		TextSize = 14,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextColor3 = if equipped then UI.Gold elseif owns then UI.Jade else UI.Dim,
		Text = status(item, owns, equipped, state.progress),
	}, button)
	button.Activated:Connect(function()
		selected[tab] = item.id
		Panels.redraw()
	end)
end

local function levelPips(parent: Instance, item: Catalog.Item, level: number, y: number)
	local row = UI.new("Frame", {
		Position = UDim2.fromOffset(12, y),
		Size = UDim2.new(1, -24, 0, 18),
		BackgroundTransparency = 1,
	}, parent)
	UI.new("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		Padding = UDim.new(0, 6),
		VerticalAlignment = Enum.VerticalAlignment.Center,
	}, row)
	for i = 1, #(item.levels or {}) do
		local pip = UI.new("Frame", {
			Size = UDim2.fromOffset(34, 10),
			BackgroundColor3 = if i <= level then UI.Gold else UI.Ink,
			BorderSizePixel = 0,
		}, row)
		UI.corner(pip, UDim.new(1, 0))
		UI.stroke(pip, UI.Bronze, 1, 0.3)
	end
	UI.text({
		Size = UDim2.fromOffset(50, 18),
		Font = UI.Bold,
		TextSize = 15,
		TextColor3 = UI.Gold,
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
		BackgroundColor3 = UI.PanelLight,
	}, parent)
	StoreUI.frame(box, item.rarity)
	-- The art sits left of centre so the Preview button (top right) never covers it.
	local art = UI.new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, -30, 0, 6),
		Size = UDim2.fromOffset(artSize, artSize),
		BackgroundTransparency = 1,
	}, box)
	StoreUI.thumb(art, item, false)
	UI.text({
		Position = UDim2.fromOffset(12, y),
		Size = UDim2.new(1, -24, 0, 26),
		Font = UI.Display,
		TextSize = 24,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextColor3 = if item.category == "title" then Flair.Rarity[item.rarity] or UI.Parchment else UI.Parchment,
		Text = item.name,
	}, box)
	UI.text({
		Position = UDim2.fromOffset(12, y + 26),
		Size = UDim2.new(1, -24, 0, 16),
		TextSize = 14,
		TextColor3 = Flair.Rarity[item.rarity] or UI.Parchment,
		Text = StoreUI.rarityName(item.rarity),
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
		Position = UDim2.fromOffset(12, y + 46),
		Size = UDim2.new(1, -24, 0, if upgradable then 20 else 56),
		TextWrapped = true,
		TextYAlignment = Enum.TextYAlignment.Top,
		TextSize = 15,
		TextTransparency = 0.1,
		Text = text,
	}, box)
	if isLine and owns then
		levelPips(box, item, level, y + 70)
	end

	-- The action button at the bottom.
	local touch = UI.Touch
	-- Side by side with Upgrade for a line that can still level up.
	local action = UI.button({
		Name = "Action",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 12, 1, -10),
		Size = if upgradable then UDim2.new(0.4, -12, 0, touch) else UDim2.new(1, -24, 0, touch),
		TextSize = 19,
		Text = "",
	}, box)
	local coins, gems = StoreUI.attr("Coins", 0), StoreUI.attr("Gems", 0)
	local whetstones = StoreUI.attr("Whetstones", 0)
	local entry = state.progress[item.id]
	local ruleMet = not item.rule or not (typeof(entry) == "table" and entry[1] < entry[2])
	local price = item.price

	-- Lines: an Upgrade button above the action once owned.
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
			AnchorPoint = Vector2.new(1, 1),
			Position = UDim2.new(1, -12, 1, -10),
			Size = UDim2.new(0.6, -6, 0, touch),
			TextSize = 14,
			TextWrapped = true,
			BackgroundColor3 = if canStones or canMixed then UI.Crimson else UI.Panel,
			TextColor3 = if canStones or canMixed then UI.Parchment else UI.Dim,
			Text = if canStones
				then `Upgrade to L{nextLevel.level}\n{cost} whetstones`
				elseif canMixed then `L{nextLevel.level}: {cost - viaGems} whetstones\n+ {gemCost} gems`
				else `L{nextLevel.level}: {cost} whetstones\n(you have {whetstones})`,
		}, box)
		upgrade.Activated:Connect(function()
			if canStones then
				StoreUI.fire("UpgradeLine", item.id)
			elseif canMixed then
				UI.confirm(
					window,
					`Upgrade {item.name}`,
					`Level {nextLevel.level} costs {cost} whetstones. Use {cost - viaGems} whetstones and {gemCost} gems for the rest?`,
					"Upgrade",
					function()
						StoreUI.fire("UpgradeLine", { id = item.id, gems = viaGems })
					end
				)
			else
				Toasts.notice(
					`Whetstones come from trials, wins and boss clears · gems can cover up to {maxGemStones} of these {cost}`,
					UI.Parchment
				)
			end
		end)
	end

	if equipped then
		action.Text = if item.category == "title" then "Take off" else "Equipped"
		UI.setButtonColor(action, UI.Panel)
		action.TextColor3 = UI.Gold
		if item.category == "title" then
			action.Activated:Connect(function()
				StoreUI.fire("EquipItem", NO_TITLE)
			end)
		end
	elseif owns then
		action.Text = "Equip"
		UI.setButtonColor(action, UI.Crimson)
		action.Activated:Connect(function()
			StoreUI.fire("EquipItem", item.id)
		end)
	elseif price and not price.product and ruleMet and not Catalog.isReady(item) then
		action.Text = "Coming soon"
		UI.setButtonColor(action, UI.Panel)
		action.TextColor3 = UI.Dim
	elseif price and price.coins and ruleMet then
		local afford = coins >= price.coins
		action.Text = if afford
			then `Unlock  ·  {UI.number(price.coins)} coins`
			else `{UI.number(price.coins - coins)} more coins`
		UI.setButtonColor(action, if afford then UI.Crimson else UI.Panel)
		action.TextColor3 = if afford then UI.Parchment else UI.Dim
		action.Activated:Connect(function()
			if not afford then
				Toasts.notice("Coins come from every match, trials and the daily reward.", UI.Gold)
				return
			end
			UI.confirm(window, item.name, `Unlock {item.name} for {UI.number(price.coins)} coins?`, "Unlock", function()
				StoreUI.fire("BuyItem", item.id)
			end)
		end)
	elseif price and price.gems and ruleMet then
		local afford = gems >= price.gems
		action.Text = if afford then `Unlock  ·  {UI.number(price.gems)} gems` else "Get gems"
		UI.setButtonColor(action, if afford then UI.Crimson else UI.PanelLight)
		if not afford then
			UI.stroke(action, UI.Jade, 1.5, 0.2)
		end
		action.Activated:Connect(function()
			if not afford then
				StorePanel.show("Gems")
				return
			end
			UI.confirm(window, item.name, `Spend {UI.number(price.gems)} gems on {item.name}?`, "Spend gems", function()
				StoreUI.fire("BuyItem", item.id)
			end)
		end)
	elseif price and price.product then
		action.Text = "See it in the Store"
		UI.setButtonColor(action, UI.PanelLight)
		action.Activated:Connect(function()
			StorePanel.show("Offers")
		end)
	else
		action.Text = "Locked"
		UI.setButtonColor(action, UI.Panel)
		action.TextColor3 = UI.Dim
		action.Activated:Connect(function()
			Toasts.notice(howToGet(item, state.progress), UI.Parchment)
		end)
	end

	-- Preview (part C's hooks) for the categories that have one.
	local previewer = previewers[item.category]
	if previewer then
		local look = UI.button({
			Name = "Preview",
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -8, 0, 8),
			Size = UDim2.fromOffset(92, 54),
			TextSize = 15,
			Text = "Preview",
		}, box)
		UI.stroke(look)
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
	local button = UI.button({
		Name = "NoTitle",
		LayoutOrder = 0,
		Text = "",
		BackgroundColor3 = if isSelected then UI.Selected else UI.PanelLight,
	}, parent)
	UI.stroke(button, if isSelected then UI.Gold else UI.Bronze, if isSelected then 2.5 else 1, 0.2)
	UI.text({
		Position = UDim2.fromOffset(6, 30),
		Size = UDim2.new(1, -12, 0, 40),
		Font = UI.Display,
		TextSize = 20,
		Text = "No title",
	}, button)
	UI.text({
		Position = UDim2.fromOffset(6, 108),
		Size = UDim2.new(1, -12, 0, 18),
		TextSize = 14,
		TextColor3 = if equipped then UI.Gold else UI.Jade,
		Text = if equipped then "Equipped" else "Owned",
	}, button)
	button.Activated:Connect(function()
		if not equipped then
			StoreUI.fire("EquipItem", NO_TITLE)
		end
		selected.title = NO_TITLE
		Panels.redraw()
	end)
end

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
		table.insert(tabs, { id = entry.id, label = entry.label })
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
		progress = progress,
		selected = pick,
	}
	if pickItem then
		preview(area, pickItem, state)
	else
		local box = UI.panel({ Size = UDim2.new(0, 250, 1, 0), BackgroundColor3 = UI.PanelLight }, area)
		UI.text({
			Position = UDim2.fromOffset(12, 40),
			Size = UDim2.new(1, -24, 0, 80),
			TextWrapped = true,
			Font = UI.Display,
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
		ScrollBarThickness = 6,
		ScrollBarImageColor3 = UI.Bronze,
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(),
		ScrollingDirection = Enum.ScrollingDirection.Y,
	}, area)
	UI.new("UIGridLayout", {
		CellSize = UDim2.fromOffset(116, 134),
		CellPadding = UDim2.fromOffset(8, 8),
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
			TextSize = 13,
			TextTransparency = 0.3,
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
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 132),
		Size = UDim2.fromOffset(240, UI.Touch),
		Text = "Back to the Locker",
		TextSize = 20,
		BackgroundColor3 = UI.Crimson,
	}, gui)
	UI.stroke(back, UI.Parchment, 1.5, 0.3)
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
