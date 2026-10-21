--!strict
-- New things you've earned, made visible: a calm "New" card in the lobby for each item the
-- server unlocks by a rule (Progress "Unlock": a title, a boss blade, an outfit at a Mastery
-- level), with Equip (or, when the server already put it on over the default, Undo) and a
-- way to the Locker; and the 新 seal the Locker shows on things you got this session and
-- haven't looked at yet.
--
-- The card waits for a quiet moment: in the lobby, no match report, no panel, no reveal, no
-- offer card, no preview. Several unlocks share one card. It closes itself after a while.
-- Something bought with coins, gems or Shards (Locker, Store) gets the same card at once,
-- over the open panel, with Equip and Preview: a purchase ends in a moment, not a toast.
--
--   NewItems.start(openLocker(slot, id))   LockerPanel wires it
--   NewItems.isNew(id) -> boolean          got this session, not looked at yet
--   NewItems.seen(id)                      looked at (the Locker selected it)
--   NewItems.bought(ids)                   a purchase was asked for: the card once it's granted

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Catalog = require(ReplicatedStorage.Shared.Catalog)
local CosmeticPreview = require(script.Parent.CosmeticPreview)
local Panels = require(script.Parent.Panels)
local Reveal = require(script.Parent.Reveal)
local StoreUI = require(script.Parent.StoreUI)
local Toasts = require(script.Parent.Toasts)
local UI = require(script.Parent.UI)

local player = Players.LocalPlayer
local T = UI.Theme

local NewItems = {}

local CARD_TIME = 14 -- seconds a card stays when nobody touches it

local baseline: { [string]: boolean }? = nil -- what was owned when the profile arrived
local fresh: { [string]: boolean } = {} -- got since, not looked at
type Unlock = { id: string, equipped: boolean, previous: string? }
local queue: { Unlock } = {}
local open: ((string?, string?) -> ())? = nil
local screen: ScreenGui? = nil
local showing = false
local closeShown: (() -> ())? = nil -- closes the card on screen

function NewItems.isNew(id: string): boolean
	return fresh[id] == true
end

function NewItems.seen(id: string)
	fresh[id] = nil
end

local function onInventory()
	if player:GetAttribute("DataLoaded") ~= true then
		return
	end
	local owned = StoreUI.owned()
	if not baseline then
		baseline = owned
		return
	end
	local base = baseline :: { [string]: boolean }
	for id in owned do
		if not base[id] then
			base[id] = true
			fresh[id] = true
		end
	end
end

-- A quiet moment in the lobby: nothing else is asking for the player's attention.
local function calm(): boolean
	local character = player.Character
	if not character or character:GetAttribute("InMatch") == true or character:GetAttribute("InDuel") == true then
		return false
	end
	if Toasts.reportOpen() or Panels.isOpen() or Reveal.isOpen() or CosmeticPreview.active() then
		return false
	end
	local gui = player:FindFirstChild("PlayerGui")
	local hud = gui and gui:FindFirstChild("LobbyHUD")
	if not hud or not hud:IsA("ScreenGui") or not hud.Enabled or hud:FindFirstChild("OfferCard") then
		return false
	end
	return true
end

local function slotOf(item: Catalog.Item): string?
	return (Catalog.SlotOf :: any)[item.category]
end

-- Tries `item` on (CosmeticPreview, or the intro on your own character), back to the Locker.
local function preview(item: Catalog.Item, slot: string?)
	Panels.closeAll()
	local function back()
		if open then
			open(slot, item.id)
		end
	end
	if item.category == "intro" then
		local intro = require(script.Parent.IntroCinematic) :: any
		intro.preview(item.ref, back)
		return
	end
	CosmeticPreview.present(item, { back = "Back to the Locker", onBack = back })
end

-- `bought`: a purchase the player just made (shown at once, over an open panel; Equip and
-- Preview, or Preview and Locker when the server already put it on).
local function showCard(batch: { Unlock }, bought: boolean?)
	local first = batch[1]
	local item = Catalog.get(first.id)
	if not item or not screen then
		return
	end
	showing = true
	local card = UI.panel({
		Name = "NewItem",
		material = "lacquer",
		sliceScale = 0.6,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -16, 0.42, 0),
		Size = UDim2.fromOffset(330, 132),
	}, screen)
	UI.stroke(card, T.Gold, 1, 0.3)
	local art = UI.new("Frame", {
		Name = "Art",
		Position = UDim2.fromOffset(10, 10),
		Size = UDim2.fromOffset(60, 60),
		BackgroundTransparency = 1,
	}, card)
	StoreUI.thumb(art, item)
	UI.label("caption", {
		Position = UDim2.fromOffset(80, 10),
		Size = UDim2.new(1, -130, 0, 18),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = T.GoldHi,
		Text = if bought
			then (if first.equipped then "UNLOCKED  ·  ON YOU NOW" else "UNLOCKED")
			elseif first.equipped then "NEW  ·  ON YOU NOW"
			else "NEW",
	}, card)
	local more = if #batch > 1 then `  +{#batch - 1} more` else ""
	UI.text({
		Name = "ItemName",
		Position = UDim2.fromOffset(80, 28),
		Size = UDim2.new(1, -130, 0, 26),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		FontFace = UI.Fonts.Display,
		TextSize = 19,
		TextColor3 = UI.rarity(item.rarity).text,
		Text = item.name .. more,
	}, card)
	UI.label("caption", {
		Position = UDim2.fromOffset(80, 54),
		Size = UDim2.new(1, -90, 0, 18),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = T.Dim,
		Text = string.upper(item.rarity),
	}, card)

	local closed = false
	local function close()
		if closed then
			return
		end
		closed = true
		if closeShown == close then
			closeShown = nil
		end
		UI.play(card, UI.Motion.Close, { Position = UDim2.new(1, 360, 0.42, 0) })
		task.delay(0.2, function()
			card:Destroy()
			showing = false
		end)
	end
	local x = UI.iconButton({
		Name = "Close",
		kind = "close",
		visual = 30,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
	}, card)
	x.Activated:Connect(close)

	local row = UI.new("Frame", {
		Name = "Actions",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 10, 1, -8),
		Size = UDim2.new(1, -20, 0, 46),
		BackgroundTransparency = 1,
	}, card)
	UI.new("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		HorizontalAlignment = Enum.HorizontalAlignment.Right,
		Padding = UDim.new(0, 8),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, row)
	closeShown = close
	local slot = slotOf(item)
	local canPreview = StoreUI.previewable(item)
	if bought and canPreview then
		local look = UI.button({
			Name = "Preview",
			variant = "secondary",
			LayoutOrder = 3,
			Size = UDim2.fromOffset(110, 46),
			TextSize = 16,
			Text = "Preview",
		}, row)
		look.Activated:Connect(function()
			close()
			preview(item, slot)
		end)
	end
	-- A bought item already on you (a new blade goes straight on) has nothing to equip.
	if first.equipped and not bought then
		local undo = UI.tertiary({
			Name = "Undo",
			LayoutOrder = 1,
			Size = UDim2.fromOffset(90, 46),
			Text = "Undo",
			TextSize = 16,
		}, row)
		undo.Activated:Connect(function()
			local previous = first.previous or ""
			StoreUI.fire("EquipItem", if previous == "" then "title." else previous)
			close()
		end)
	elseif slot and not first.equipped then
		local equip = UI.button({
			Name = "Equip",
			variant = "primary",
			LayoutOrder = 2,
			Size = UDim2.fromOffset(110, 46),
			TextSize = 17,
			Text = "Equip",
		}, row)
		equip.Activated:Connect(function()
			UI.sound("Equip")
			StoreUI.fire("EquipItem", item.id)
			NewItems.seen(item.id)
			close()
		end)
	end
	if not (bought and canPreview) or first.equipped then
		local locker = UI.button({
			Name = "Locker",
			variant = "secondary",
			LayoutOrder = 3,
			Size = UDim2.fromOffset(110, 46),
			TextSize = 16,
			Text = "Locker",
		}, row)
		locker.Activated:Connect(function()
			close()
			if open then
				open(slot, item.id)
			end
		end)
	end

	-- Over an open panel (a purchase) with no room beside the window (a 1223 px screen), the
	-- card rests inside the window's right edge rather than straddling it.
	local restX = -16
	local gui = screen :: ScreenGui
	if bought and Panels.isOpen() then
		local window = Panels.window()
		local room = gui.AbsolutePosition.X + gui.AbsoluteSize.X - (window.AbsolutePosition.X + window.AbsoluteSize.X)
		if room < card.AbsoluteSize.X + 32 then
			restX = -math.floor(room + 20)
		end
	end
	card.Position = UDim2.new(1, 360, 0.42, 0)
	UI.play(card, UI.Motion.Open, { Position = UDim2.new(1, restX, 0.42, 0) })
	UI.sound("Stamp")
	task.delay(CARD_TIME, close)
	-- Leaving the lobby (a match, a duel) or opening a panel puts it away.
	task.spawn(function()
		while not closed and card.Parent do
			task.wait(0.5)
			local character = player.Character
			if
				(Panels.isOpen() and not bought)
				or not character
				or character:GetAttribute("InMatch") == true
				or character:GetAttribute("InDuel") == true
			then
				close()
			end
		end
	end)
end

-- A coin / gem / Shard purchase was asked for: once the server's grant arrives (the Inventory
-- attribute; a refusal never grants, and the server says why), the card shows at once.
function NewItems.bought(ids: { string })
	local id = ids[1]
	if not id or not Catalog.get(id) then
		return
	end
	task.spawn(function()
		local deadline = os.clock() + 6
		while os.clock() < deadline and not StoreUI.owned()[id] do
			task.wait(0.2)
		end
		if not StoreUI.owned()[id] then
			return
		end
		task.wait(0.15) -- the loadout attribute (a new blade goes on) lands in the same publish
		local item = Catalog.get(id) :: Catalog.Item
		local slot = slotOf(item)
		local worn = slot and StoreUI.loadout()[slot]
		local batch: { Unlock } = {}
		for _, each in ids do
			table.insert(batch, { id = each, equipped = each == id and worn == id })
		end
		if closeShown then
			closeShown()
			task.wait(0.2)
		end
		showCard(batch, true)
	end)
end

function NewItems.start(openLocker: (string?, string?) -> ())
	open = openLocker
	screen = UI.new("ScreenGui", {
		Name = "NewItems",
		ResetOnSpawn = false,
		DisplayOrder = 7, -- over the panels (6): a purchase's card shows with the Store open
		ScreenInsets = Enum.ScreenInsets.CoreUISafeInsets,
	}, player:WaitForChild("PlayerGui"))
	player:GetAttributeChangedSignal("Inventory"):Connect(onInventory)
	player:GetAttributeChangedSignal("DataLoaded"):Connect(onInventory)
	onInventory()
	task.spawn(function()
		local remote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("Progress") :: RemoteEvent
		remote.OnClientEvent:Connect(function(kind: string, data: any)
			if kind == "Unlock" and typeof(data) == "table" and typeof(data.id) == "string" then
				fresh[data.id] = true
				table.insert(queue, {
					id = data.id,
					equipped = data.equipped == true,
					previous = if typeof(data.previous) == "string" then data.previous else nil,
				})
			end
		end)
	end)
	-- Shows what's queued at the next quiet moment (a second of calm first, so it never lands
	-- on the same frame a panel closes).
	task.spawn(function()
		local calmSince: number? = nil
		while true do
			task.wait(0.5)
			if #queue == 0 or showing then
				calmSince = nil
				continue
			end
			if not calm() then
				calmSince = nil
				continue
			end
			calmSince = calmSince or os.clock()
			if os.clock() - (calmSince :: number) >= 1.5 then
				local batch = queue
				queue = {}
				showCard(batch)
			end
		end
	end)
end

return NewItems
