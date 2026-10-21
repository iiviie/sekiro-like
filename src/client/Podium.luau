--!strict
-- The end-of-royale podium: the top three fighters standing on three steps, each in front of
-- their equipped banner with their title, name and blade, for a few seconds. Sent by
-- server/RoundService ("Podium" on RoundEvent) only when a human placed in the top three.
-- Everyone in the server sees it; a fighter sees it once their match report closes (it never
-- covers the report), and a new match or a duel takes it down. Calm: a fade, no sound.

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Assets = require(ReplicatedStorage.Shared.Assets)
local Catalog = require(ReplicatedStorage.Shared.Catalog)
local Flair = require(ReplicatedStorage.Shared.Flair)
local Progression = require(ReplicatedStorage.Shared.Progression)
local Round = require(ReplicatedStorage.Shared.Round)
local UI = require(script.Parent.UI)

local player = Players.LocalPlayer
local THEME = UI.Theme

local HOLD = 5 -- seconds on screen
local WAIT_FOR_REPORT = 16 -- give up if the match report is still open this long after
local REPORT_APPEARS = 8 -- how long a fighter's report card may take to open
local STEP = { 64, 46, 34 } -- step heights by place
local CARD_W, CARD_H = 636, 360
local ORDER = { 2, 1, 3 } -- left to right
local PLACE = { "1st", "2nd", "3rd" }
local PLACE_COLOR = { THEME.GoldHi, THEME.Steel, Color3.fromRGB(196, 140, 92) }

export type Entry = { place: number, name: string, player: Player?, skin: string? }

local Podium = {}

local gui: ScreenGui? = nil
local shown: CanvasGroup? = nil
local token = 0

local function layer(): ScreenGui
	if not gui then
		gui = UI.new("ScreenGui", {
			Name = "Podium",
			ResetOnSpawn = false,
			IgnoreGuiInset = true,
			DisplayOrder = 5,
			ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		}, player:WaitForChild("PlayerGui"))
	end
	return gui :: ScreenGui
end

local function loadoutOf(who: Player): { [string]: string }
	local raw = who:GetAttribute("Loadout")
	local ok, decoded = pcall(HttpService.JSONDecode, HttpService, if typeof(raw) == "string" then raw else "")
	return if ok and typeof(decoded) == "table" then decoded else {}
end

local function tintOf(v: Vector3): Color3
	return Color3.new(math.min(v.X, 1), math.min(v.Y, 1), math.min(v.Z, 1))
end

type Look = { title: Catalog.Item?, banner: string?, blade: string, tint: Color3, userId: number? }

local function lookOf(entry: Entry): Look
	local who = entry.player
	if who and who.Parent then
		local loadout = loadoutOf(who)
		local item = Catalog.get(loadout.bladeSkin)
		local skin = Progression.skin(if item and item.category == "bladeSkin" then item.ref else "Steel")
		local title = Catalog.get(loadout.title)
		return {
			title = if title and title.category == "title" then title else nil,
			banner = Flair.ref(loadout.banner),
			blade = if item then item.name else skin.name,
			tint = tintOf(skin.tint),
			userId = if who.UserId > 0 then who.UserId else nil,
		}
	end
	local skin = Progression.skin(entry.skin or "Steel")
	return { title = nil, banner = nil, blade = skin.name, tint = tintOf(skin.tint), userId = nil }
end

-- One column: the banner cloth with the fighter standing in front of it on their step (the
-- place on the step), then title, name and blade underneath (wrapped, never cut off).
local COLUMN_W = 196
local BASE_Y = 292 -- where the steps meet the floor, in the card
local CLOTH_H = 150

local function stand(parent: Instance, entry: Entry, column: number)
	local look = lookOf(entry)
	local cloth = Flair.banner(look.banner)
	local root = UI.new("Frame", {
		Name = `Place{entry.place}`,
		Position = UDim2.fromOffset(16 + (column - 1) * (COLUMN_W + 8), 0),
		Size = UDim2.fromOffset(COLUMN_W, CARD_H),
		BackgroundTransparency = 1,
	}, parent)
	local step = STEP[entry.place] or STEP[3]
	local top = BASE_Y - step -- where the figure's feet meet the step
	local mid = COLUMN_W / 2
	local banner = UI.new("Frame", {
		Name = "Cloth",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.fromOffset(mid, top),
		Size = UDim2.fromOffset(140, CLOTH_H),
		BackgroundColor3 = cloth.cloth,
		BorderSizePixel = 0,
		ClipsDescendants = true,
	}, root)
	UI.new("UIStroke", { Color = cloth.edge, Thickness = 2 }, banner)
	local motif = UI.text({
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.8, 0.9),
		Font = UI.Display,
		TextScaled = true,
		TextColor3 = cloth.ink,
		TextTransparency = 0.72,
		Text = cloth.motif,
	}, banner)
	if Flair.decorateBanner(banner, look.banner or "Plain") then
		motif.Visible = false
	end
	-- The fighter: their avatar for a player, their blade for a bot.
	UI.new("ImageLabel", {
		Name = "Figure",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.fromOffset(mid, if look.userId then top + 6 else top - 24),
		Size = if look.userId then UDim2.fromOffset(170, 170) else UDim2.fromOffset(104, 104),
		BackgroundTransparency = 1,
		Image = if look.userId then `rbxthumb://type=Avatar&id={look.userId}&w=420&h=420` else Assets.Icons.Katana,
		ImageColor3 = if look.userId then Color3.new(1, 1, 1) else look.tint,
		ZIndex = 3,
	}, root)
	local color = PLACE_COLOR[entry.place] or THEME.Bronze
	local block = UI.panel({
		Name = "Step",
		material = "inset",
		tint = THEME.Plate,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromOffset(mid, top),
		Size = UDim2.fromOffset(COLUMN_W - 12, step),
		ZIndex = 2,
	}, root)
	UI.stroke(block, color, 1.5, 0.15)
	UI.text({
		Name = "Place",
		Size = UDim2.fromScale(1, 1),
		FontFace = UI.Fonts.Display,
		TextSize = if entry.place == 1 then 30 else 24,
		TextColor3 = color,
		Text = PLACE[entry.place] or "",
		ZIndex = 3,
	}, block)
	local details = UI.new("Frame", {
		Name = "Details",
		Position = UDim2.fromOffset(0, BASE_Y + 6),
		Size = UDim2.fromOffset(COLUMN_W, CARD_H - BASE_Y - 12),
		BackgroundTransparency = 1,
	}, root)
	UI.new("UIListLayout", {
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
		Padding = UDim.new(0, 1),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, details)
	UI.text({
		Name = "Title",
		LayoutOrder = 1,
		Size = UDim2.fromOffset(COLUMN_W, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		TextWrapped = true,
		FontFace = UI.Fonts.Display,
		TextSize = 15,
		TextColor3 = if look.title then UI.rarity(look.title.rarity).text else THEME.Ash,
		Text = if look.title then look.title.name else "",
		Visible = look.title ~= nil,
	}, details)
	UI.text({
		Name = "PlayerName",
		LayoutOrder = 2,
		Size = UDim2.fromOffset(COLUMN_W, 26),
		FontFace = UI.Fonts.Display,
		TextSize = 21,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextColor3 = THEME.Bone,
		Text = entry.name,
	}, details)
	UI.label("body", {
		Name = "Blade",
		LayoutOrder = 3,
		Size = UDim2.fromOffset(COLUMN_W, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		TextWrapped = true,
		TextSize = 14,
		TextColor3 = THEME.Dim,
		Text = look.blade,
	}, details)
end

function Podium.hide()
	token += 1
	local card = shown
	shown = nil
	if card and card.Parent then
		UI.tween(card, 0.4, { GroupTransparency = 1 })
		task.delay(0.45, function()
			card:Destroy()
		end)
	end
end

function Podium.show(entries: { Entry }, hold: number?)
	Podium.hide()
	token += 1
	local mine = token
	local card = UI.new("CanvasGroup", {
		Name = "Card",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.45),
		Size = UDim2.fromOffset(CARD_W, CARD_H),
		BackgroundTransparency = 1,
		GroupTransparency = 1,
	}, layer())
	local view = workspace.CurrentCamera.ViewportSize
	UI.new("UIScale", {
		Scale = math.clamp(math.min((view.X - 32) / CARD_W, (view.Y * 0.8) / CARD_H), 0.45, 1),
	}, card)
	local plate = UI.panel({ Name = "Plate", material = "lacquer", Size = UDim2.fromScale(1, 1) }, card)
	UI.label("caption", {
		Name = "Heading",
		Position = UDim2.fromOffset(0, 14),
		Size = UDim2.new(1, 0, 0, 24),
		FontFace = UI.Fonts.Display,
		TextSize = 18,
		TextColor3 = THEME.GoldHi,
		Text = UI.tracked("Top three"),
	}, plate)

	local byPlace: { [number]: Entry } = {}
	for _, entry in entries do
		byPlace[entry.place] = entry
	end
	for column, place in ORDER do
		local entry = byPlace[place]
		if entry then
			stand(plate, entry, column)
		end
	end
	shown = card
	UI.tween(card, if UI.reducedMotion() then 0.15 else 0.5, { GroupTransparency = 0 })
	task.delay(hold or HOLD, function()
		if token == mine then
			Podium.hide()
		end
	end)
end

-- Shows the podium once nothing else needs the screen: the match report closed (fighters),
-- not in a duel or boss trial, and no new match started.
local function reportOpen(): boolean
	local toasts = player.PlayerGui:FindFirstChild("Toasts")
	return toasts ~= nil and toasts:FindFirstChild("Report", true) ~= nil
end

-- A fighter's match report (client/Toasts) comes a moment after the match ends, behind any
-- banners still showing: when one is on its way, wait for it to open and then to close.
local reportAt = -math.huge

local function whenClear(entries: { Entry })
	token += 1
	local mine = token
	task.spawn(function()
		task.wait(1) -- the Report remote can arrive just after this one
		local deadline = os.clock() + WAIT_FOR_REPORT
		if os.clock() - reportAt < 6 then
			local appearBy = os.clock() + REPORT_APPEARS
			while token == mine and not reportOpen() and os.clock() < appearBy do
				task.wait(0.2)
			end
		end
		while token == mine and os.clock() < deadline do
			local busy = player:GetAttribute("DuelState")
			if Round.phase() == "Match" and player.Character and player.Character:GetAttribute("InMatch") then
				return -- fighting again
			end
			if not reportOpen() and (busy == nil or busy == "") then
				Podium.show(entries)
				return
			end
			task.wait(0.25)
		end
	end)
end

function Podium.start()
	local remotes = ReplicatedStorage:WaitForChild("Remotes")
	local roundEvent = remotes:WaitForChild("RoundEvent") :: RemoteEvent
	local progress = remotes:WaitForChild("Progress") :: RemoteEvent
	progress.OnClientEvent:Connect(function(kind: string, data: any)
		if kind == "Report" and typeof(data) == "table" and not data.boss and not data.duel then
			reportAt = os.clock()
		end
	end)
	roundEvent.OnClientEvent:Connect(function(kind: string, data: any)
		if kind == "Podium" and typeof(data) == "table" and typeof(data.entries) == "table" then
			whenClear(data.entries)
		end
	end)
	Round.state():GetAttributeChangedSignal("Phase"):Connect(function()
		if Round.phase() == "Match" then
			Podium.hide()
		end
	end)
end

-- Studio test hook: the podium with any entries (default: you first, then two bots).
function Podium.preview(entries: { Entry }?, hold: number?)
	Podium.show(entries or {
		{ place = 1, name = player.DisplayName, player = player },
		{ place = 2, name = "Ronin", skin = "Jade" },
		{ place = 3, name = "Wanderer", skin = "Crimson" },
	}, hold or 8)
end

return Podium
