--!strict
-- The lobby's screen, kept to the edges so the character stays in view: the Mastery plate
-- top-left; coins, gems and Whetstones top-right ("+" opens the Store's gem packs) with one
-- small chip while the Initiate's Bundle is on offer; a compact PLAY in the bottom-right
-- corner with Invite and the lobby-sparring toggle over it; and a nav rail down the left edge
-- (How to fight / Locker / Pass / Store / Profile / Rewards / Settings) that opens the panels
-- in client/Panels, with a seal where something is waiting (a pass tier to claim, a Shrine
-- Draw to open, the daily reward). Shown only while your character is in the lobby; it steps
-- aside under the large panels and the boss picker. Reads everything from server-published
-- attributes; every change is a request on a remote.
--
-- Also: the lobby's Store and Season boards open their panels (ProximityPrompt or click),
-- and the one contextual offer: after your first level-up or first loss, a small card
-- for the Initiate's Bundle, once per account (only the first of the two can trigger it:
-- a level-up shows it only with no losses yet, a loss only at level 1).

local Players = game:GetService("Players")
local SocialService = game:GetService("SocialService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ProximityPromptService = game:GetService("ProximityPromptService")

local BossHUD = require(script.Parent.BossHUD)
local CombatHUD = require(script.Parent.CombatHUD)
local LockerPanel = require(script.Parent.LockerPanel)
local Panels = require(script.Parent.Panels)
local Podium = require(script.Parent.Podium)
local StorePanel = require(script.Parent.StorePanel)
local StoreUI = require(script.Parent.StoreUI)
local Toasts = require(script.Parent.Toasts)
local UI = require(script.Parent.UI)
local Assets = require(ReplicatedStorage.Shared.Assets)
local Round = require(ReplicatedStorage.Shared.Round)
local Text = require(ReplicatedStorage.Shared.Text)

-- Part S's pass panel (registered as the Pass tab when it exists).
type PassModule = {
	build: (Frame) -> (),
	Title: string?,
	Icon: string?,
	badge: (() -> number)?,
}
local PassPanel: PassModule? = nil
do
	local module = script.Parent:FindFirstChild("PassPanel")
	if module and module:IsA("ModuleScript") then
		local ok, loaded = pcall(require, module)
		if ok and typeof(loaded) == "table" and typeof(loaded.build) == "function" then
			PassPanel = loaded :: any
		else
			warn("[LobbyHUD] PassPanel failed to load:", loaded)
		end
	end
end

local player = Players.LocalPlayer
local lobbyAction = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("LobbyAction") :: RemoteEvent

local LobbyHUD = {}

local screen: ScreenGui
local coinsPill: UI.Pill
local gemsPill: UI.Pill
local stonesPill: UI.Pill
local top: Frame
local offerChip: TextButton
local storeBadge: GuiObject
local passBadge: GuiObject?
local playButton: TextButton
local playSwipe: ImageLabel
local playSub: TextLabel
local playSubStrip: Frame
local leaveButton: TextButton
local pvpButton: TextButton
local pvpPip: Frame
local rewardsBadge: GuiObject
local trialsBadge: GuiObject?
local levelLabel: TextLabel
local xpBar: UI.Progress
local saveNotice: TextLabel

local inviteButton: TextButton
local bottom: Frame
local playCluster: Frame
local nav: Frame
local navPlate: Frame
local navLayout: UIGridLayout
local addGems: TextButton
local navItems: { [string]: TextButton } = {}
local offerCard: Frame? = nil -- the one-time Initiate card, while it's on screen
local trialsSeen = false -- the Trials badge shows until the panel is opened once
local compact = false -- phone layout: a two-column rail, PLAY lifted over the jump button

local ICONS = Assets.Icons
local PASS_ICON = (PassPanel and PassPanel.Icon) or (ICONS :: any).SeasonPass or Assets.RankCrests.Gold
local LOCKER_ICON = ((ICONS :: any).Tabs and (ICONS :: any).Tabs.Outfits) or ICONS.Weapons
local NAV = {
	{ id = "Guide", icon = ICONS.Guide, label = "Guide" },
	{ id = "Locker", icon = LOCKER_ICON, label = "Locker" },
	if PassPanel
		then { id = "Pass", icon = PASS_ICON, label = "Pass" }
		else { id = "Trials", icon = ICONS.Trials, label = "Trials" },
	{ id = "Store", icon = ICONS.Store, label = "Store" },
	{ id = "Profile", icon = ICONS.Profile, label = "Profile" },
	{ id = "Rewards", icon = ICONS.Rewards, label = "Rewards" },
	{ id = "Settings", icon = ICONS.Settings, label = "Settings" },
}

-- Geometry at scale 1 (UI.Hud): a nav rail down the left edge (one column, or two on a short
-- phone screen), PLAY in the bottom-right corner (above the jump button on a phone), the
-- Mastery plate and the pills tight to the top corners. The middle of the screen stays the
-- character's.
local HUD = UI.Hud
local CELL = HUD.NavCell
local RAIL_TOP = 76 -- under the Mastery plate
local RAIL_GAP = 2
local JUMP_CLEAR = 170 -- a phone's jump button owns the bottom-right ~120 pt (156 at 0.77)

local function badge(parent: Instance): GuiObject
	local seal = UI.badge(parent, "new", 20)
	seal.Position = UDim2.new(1, -10, 0, 8)
	seal.Visible = false
	return seal
end

local refresh: () -> ()

-- Lays the HUD out for the screen. Touch screens get 60 px hit areas (46 pt at the phone's
-- 0.77) on the small buttons; the visuals stay small.
local function applyLayout()
	local viewport = UI.viewport()
	compact = UI.compact(viewport)
	local touch = UI.touchSized()
	local scale = UI.lobbyScale(viewport)
	-- The HUD's height in scale-1 units, under the Roblox top bar.
	local height = (viewport.Y - 58) / scale

	-- Nav rail: as many rows as fit above the bottom margin, then a second column.
	local rowsFit = math.max(1, math.floor((height - RAIL_TOP - 16) / (CELL.Y + RAIL_GAP)))
	local columns = if rowsFit >= #NAV then 1 else 2
	local rows = math.ceil(#NAV / columns)
	navLayout.CellSize = UDim2.fromOffset(CELL.X, CELL.Y)
	navLayout.CellPadding = UDim2.fromOffset(RAIL_GAP, RAIL_GAP)
	navLayout.FillDirectionMaxCells = columns
	local railW = columns * CELL.X + (columns - 1) * RAIL_GAP
	local railH = rows * CELL.Y + (rows - 1) * RAIL_GAP
	nav.Position = UDim2.fromOffset(HUD.Edge + 6, RAIL_TOP + 6)
	nav.Size = UDim2.fromOffset(railW, railH)
	navPlate.Position = UDim2.fromOffset(HUD.Edge, RAIL_TOP)
	navPlate.Size = UDim2.fromOffset(railW + 12, railH + 12)

	-- PLAY: the bottom-right corner; on a phone, lifted over the jump button.
	local small = if touch then UI.Touch else HUD.Small
	local subH = 26
	local clusterH = small + 4 + subH + 2 + HUD.Play.Y
	playCluster.AnchorPoint = Vector2.new(1, 1)
	playCluster.Position = UDim2.new(1, -HUD.Edge, 1, if compact then -JUMP_CLEAR else -HUD.Edge)
	playCluster.Size = UDim2.fromOffset(HUD.Play.X, clusterH)
	local half = (HUD.Play.X - 6) / 2
	inviteButton.Position = UDim2.fromOffset(0, 0)
	inviteButton.Size = UDim2.fromOffset(half, small)
	pvpButton.Position = UDim2.fromOffset(half + 6, 0)
	pvpButton.Size = UDim2.fromOffset(half, small)
	playSubStrip.Position = UDim2.new(1, 0, 0, small + 4 + subH / 2)
	leaveButton.Position = UDim2.new(1, 0, 0, small + 4 + subH / 2)
	leaveButton.Size = UDim2.fromOffset(130, subH)
	playButton.Position = UDim2.fromScale(0.5, 1)
	playSwipe.Position = UDim2.new(0.5, 0, 1, -HUD.Play.Y / 2)

	-- The "+" next to the gems: a touch-sized hit area around a small disc.
	addGems.Size = UDim2.fromOffset(if touch then UI.Touch else 44, if touch then UI.Touch else 44)
	offerChip.Size = UDim2.fromOffset(176, if touch then UI.Touch else 44)
	top.Size = UDim2.fromOffset(720, if touch then UI.Touch else 44)
	for _, item in NAV do
		navItems[item.id]:SetAttribute("IconSize", HUD.NavIcon)
	end
end

local function build()
	screen = UI.new("ScreenGui", {
		Name = "LobbyHUD",
		ResetOnSpawn = false,
		IgnoreGuiInset = false,
		ScreenInsets = Enum.ScreenInsets.CoreUISafeInsets,
		DisplayOrder = 5,
		Enabled = false,
	})

	-- Top-right: the offer chip (while the Initiate's Bundle is on offer), Whetstones (when you
	-- have any), coins, gems and the gold "+". One row, so the chip never stacks with toasts.
	top = UI.new("Frame", {
		Name = "Currencies",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -HUD.Edge, 0, 8),
		Size = UDim2.fromOffset(720, 44),
		BackgroundTransparency = 1,
	}, screen)
	UI.new("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		HorizontalAlignment = Enum.HorizontalAlignment.Right,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		Padding = UDim.new(0, 12),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, top)
	stonesPill = UI.currencyPill(
		{ Name = "Whetstones", currency = "stones", width = 84, height = HUD.Pill, LayoutOrder = 0 },
		top
	)
	coinsPill =
		UI.currencyPill({ Name = "Coins", currency = "coins", width = 112, height = HUD.Pill, LayoutOrder = 1 }, top)
	gemsPill =
		UI.currencyPill({ Name = "Gems", currency = "gems", width = 100, height = HUD.Pill, LayoutOrder = 2 }, top)
	addGems = UI.iconButton({
		Name = "AddGems",
		kind = "plus",
		fill = UI.Theme.Gold,
		visual = 30,
		hit = 44,
		LayoutOrder = 3,
	}, top)
	addGems.Activated:Connect(function()
		StorePanel.show("Gems")
	end)

	-- One calm chip while the Initiate's Bundle is on offer: a small pill, no countdown (the
	-- Store's Offers tab has the clock).
	offerChip = UI.new("TextButton", {
		Name = "OfferChip",
		LayoutOrder = -1,
		Size = UDim2.fromOffset(176, 44),
		BackgroundTransparency = 1,
		AutoButtonColor = false,
		Text = "",
		Visible = false,
	}, top)
	local chipPlate = UI.panel({
		Name = "Plate",
		material = "pill",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.fromScale(0, 0.5),
		Size = UDim2.new(1, 0, 0, HUD.Pill),
	}, offerChip)
	UI.stroke(chipPlate, UI.Theme.Gold, 1, 0.35)
	UI.new("ImageLabel", {
		Name = "Icon",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, -4, 0.5, 0),
		Size = UDim2.fromOffset(38, 38),
		BackgroundTransparency = 1,
		Image = (ICONS :: any).InitiateBundle or ICONS.Katana,
		ZIndex = 3,
	}, offerChip)
	UI.label("label", {
		Name = "Text",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 36, 0.5, 0),
		Size = UDim2.new(1, -44, 0, 20),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = UI.Theme.GoldHi,
		TextSize = 14,
		Text = "Initiate's Bundle",
		ZIndex = 3,
	}, offerChip)
	UI.juice(offerChip, { hover = 1.04 })
	offerChip.Activated:Connect(function()
		StorePanel.show("Offers")
	end)

	-- The profile didn't load (or another server took it): say so, plainly and for as long as
	-- it's true. The server also blocks purchases and spends for the session.
	local noticePlate = UI.panel({
		Name = "SaveNoticePlate",
		material = "plain",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -HUD.Edge, 0, 60),
		Size = UDim2.fromOffset(340, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Visible = false,
	}, screen)
	UI.new("Frame", {
		Name = "Edge",
		Size = UDim2.new(0, 3, 1, -12),
		Position = UDim2.fromOffset(6, 6),
		BackgroundColor3 = UI.Theme.LacquerRed,
		BorderSizePixel = 0,
	}, noticePlate)
	saveNotice = UI.text({
		Name = "SaveNotice",
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextSize = 15,
		TextColor3 = UI.Danger,
		Text = "",
	}, noticePlate)
	UI.new("UIPadding", {
		PaddingLeft = UDim.new(0, 18),
		PaddingRight = UDim.new(0, 12),
		PaddingTop = UDim.new(0, 8),
		PaddingBottom = UDim.new(0, 8),
	}, saveNotice)
	saveNotice:GetPropertyChangedSignal("Visible"):Connect(function()
		noticePlate.Visible = saveNotice.Visible
	end)
	saveNotice.Visible = false

	-- Top-left: the Mastery plate, its medallion overlapping the left end.
	local mastery = UI.panel({
		Name = "Mastery",
		material = "plain",
		sliceScale = 0.4,
		Position = UDim2.fromOffset(HUD.Edge + 22, 10),
		Size = UDim2.fromOffset(220, HUD.Plate),
	}, screen)
	UI.new("ImageLabel", {
		Name = "Medal",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromOffset(2, HUD.Plate / 2),
		Size = UDim2.fromOffset(56, 56),
		BackgroundTransparency = 1,
		Image = ICONS.Level,
		ZIndex = 3,
	}, mastery)
	UI.label("caption", {
		Position = UDim2.fromOffset(38, 6),
		Size = UDim2.new(1, -50, 0, 16),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = UI.Theme.GoldHi,
		TextSize = 14,
		Text = "Mastery",
		ZIndex = 2,
	}, mastery)
	levelLabel = UI.label("number", {
		Name = "Level",
		Position = UDim2.fromOffset(38, 4),
		Size = UDim2.new(1, -50, 0, 20),
		TextXAlignment = Enum.TextXAlignment.Right,
		TextSize = 16,
		Text = "Lv 1",
		ZIndex = 2,
	}, mastery)
	xpBar = UI.progress({
		Name = "XP",
		Position = UDim2.fromOffset(38, 25),
		Size = UDim2.new(1, -50, 0, 24),
		height = 6,
		tone = "gold",
		label = "below",
		textSize = 14,
		format = function(v: number, m: number): string
			return `{UI.number(v)} / {UI.number(m)} XP`
		end,
	}, mastery)

	-- PLAY with Invite and Lobby PvP above it: one compact cluster in the bottom-right corner.
	bottom = UI.new("Frame", {
		Name = "Bottom",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
	}, screen)
	playCluster = UI.new("Frame", {
		Name = "PlayCluster",
		Size = UDim2.fromOffset(HUD.Play.X, 160),
		BackgroundTransparency = 1,
	}, bottom)
	playSwipe = UI.brush(playCluster, "swipe", {
		Name = "PlaySwipe",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Size = UDim2.fromOffset(HUD.Play.X + 60, HUD.Play.Y + 22),
		color = UI.Theme.LacquerRed,
		ImageTransparency = 0.05,
	})
	playButton = UI.button({
		Name = "Play",
		variant = "primary",
		AnchorPoint = Vector2.new(0.5, 1),
		Size = UDim2.fromOffset(HUD.Play.X, HUD.Play.Y),
		Text = "PLAY",
		FontFace = UI.Fonts.Display,
		TextSize = 30,
		ZIndex = 2,
	}, playCluster)
	-- One short line over PLAY, right-aligned, only when there's something to say.
	playSubStrip = UI.new("Frame", {
		Name = "SubStrip",
		AnchorPoint = Vector2.new(1, 0.5),
		Size = UDim2.fromOffset(0, 22),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundColor3 = UI.Theme.Ink,
		BackgroundTransparency = 0.45,
		BorderSizePixel = 0,
		Visible = false,
	}, playCluster)
	UI.new("UICorner", { CornerRadius = UDim.new(1, 0) }, playSubStrip)
	UI.new("UIPadding", { PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10) }, playSubStrip)
	playSub = UI.text({
		Name = "Sub",
		Size = UDim2.fromOffset(0, 22),
		AutomaticSize = Enum.AutomaticSize.X,
		TextSize = 14,
		TextColor3 = UI.Theme.Bone,
		Text = "",
	}, playSubStrip)
	playButton.Activated:Connect(function()
		lobbyAction:FireServer("Queue", player:GetAttribute("Queued") ~= true)
	end)
	leaveButton = UI.tertiary({
		Name = "LeaveQueue",
		AnchorPoint = Vector2.new(1, 0.5),
		Size = UDim2.fromOffset(130, 26),
		TextXAlignment = Enum.TextXAlignment.Right,
		Text = "Leave queue",
		TextSize = 15,
		TextColor3 = UI.Theme.Bone,
		Visible = false,
	}, playCluster)
	leaveButton.Activated:Connect(function()
		lobbyAction:FireServer("Queue", false)
	end)

	-- Fights are better with friends: invite from the lobby, nudged when you're queued alone.
	local invite = UI.button({
		Name = "Invite",
		variant = "secondary",
		Size = UDim2.fromOffset(115, HUD.Small),
		TextSize = 15,
		Text = "Invite",
	}, playCluster)
	invite.Activated:Connect(function()
		local ok, can = pcall(SocialService.CanSendGameInviteAsync, SocialService, player)
		if ok and can then
			local shown = pcall(SocialService.PromptGameInvite, SocialService, player)
			if shown then
				return
			end
		end
		-- Studio, a private test server, or an account that can't invite: say so instead of
		-- doing nothing.
		Toasts.notice("Invites aren't available here. Share the game's link with a friend.", UI.Parchment)
	end)
	inviteButton = invite

	pvpButton = UI.button({
		Name = "PvP",
		variant = "secondary",
		Size = UDim2.fromOffset(115, HUD.Small),
		TextSize = 15,
		Text = "PvP: Off",
	}, playCluster)
	pvpPip = UI.new("Frame", {
		Name = "Pip",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -9, 0.5, 0),
		Size = UDim2.fromOffset(8, 8),
		BackgroundColor3 = UI.Theme.Ash,
		ZIndex = 3,
	}, pvpButton)
	UI.new("UICorner", { CornerRadius = UDim.new(1, 0) }, pvpPip)
	UI.new("UIStroke", { Color = UI.Theme.Ink, Thickness = 1.5 }, pvpPip)
	pvpButton.Activated:Connect(function()
		local on = player:GetAttribute("LobbyPvP")
		lobbyAction:FireServer("PvP", on ~= true and on ~= "Pending")
	end)

	-- The nav: a lacquer rail down the left edge, small icons over small captions; a crimson
	-- swipe under the open panel's caption.
	navPlate = UI.panel({ Name = "NavPlate", material = "plain", sliceScale = 0.4 }, bottom)
	nav = UI.new("Frame", {
		Name = "Nav",
		BackgroundTransparency = 1,
		ZIndex = 2,
	}, bottom)
	navLayout = UI.new("UIGridLayout", {
		SortOrder = Enum.SortOrder.LayoutOrder,
		FillDirection = Enum.FillDirection.Horizontal,
		HorizontalAlignment = Enum.HorizontalAlignment.Left,
		VerticalAlignment = Enum.VerticalAlignment.Top,
	}, nav)
	for i, item in NAV do
		local button = UI.new("TextButton", {
			Name = item.id,
			LayoutOrder = i,
			BackgroundTransparency = 1,
			AutoButtonColor = false,
			Text = "",
			ZIndex = 2,
		}, nav)
		UI.brush(button, "swipe", {
			Name = "Swipe",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(0.5, 0, 1, -10),
			Size = UDim2.new(1, 0, 0, 22),
			color = UI.Theme.Crimson,
			ZIndex = 2,
			Visible = false,
		})
		local icon = UI.new("ImageLabel", {
			Name = "Icon",
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.new(0.5, 0, 0, 2),
			Size = UDim2.fromOffset(HUD.NavIcon, HUD.NavIcon),
			BackgroundTransparency = 1,
			Image = item.icon,
			ZIndex = 3,
		}, button)
		UI.label("label", {
			Name = "Caption",
			AnchorPoint = Vector2.new(0.5, 1),
			Position = UDim2.new(0.5, 0, 1, -2),
			Size = UDim2.new(1, 4, 0, 16),
			TextSize = 14,
			TextColor3 = UI.Theme.Dim,
			TextStrokeColor3 = UI.Theme.Ink,
			TextStrokeTransparency = 0.5,
			Text = item.label,
			ZIndex = 4,
		}, button)
		-- A little lift on hover, like picking the item up.
		button.MouseEnter:Connect(function()
			if UI.isTouch() then
				return
			end
			local size = button:GetAttribute("IconSize") or HUD.NavIcon
			UI.play(icon, UI.Motion.Hover, {
				Size = UDim2.fromOffset(size * 1.1, size * 1.1),
				Position = UDim2.new(0.5, 0, 0, -2),
			})
		end)
		button.MouseLeave:Connect(function()
			local size = button:GetAttribute("IconSize") or HUD.NavIcon
			UI.play(icon, UI.Motion.Hover, { Size = UDim2.fromOffset(size, size), Position = UDim2.new(0.5, 0, 0, 2) })
		end)
		UI.juice(button, { hover = 1, press = 0.92 })
		button.Activated:Connect(function()
			if item.id == "Trials" then
				trialsSeen = true
				refresh()
			end
			Panels.toggle(item.id)
		end)
		navItems[item.id] = button
		if item.id == "Rewards" then
			rewardsBadge = badge(button)
		elseif item.id == "Trials" then
			trialsBadge = badge(button)
		elseif item.id == "Pass" then
			passBadge = badge(button)
		elseif item.id == "Store" then
			storeBadge = badge(button)
		end
	end

	UI.new("UIScale", { Name = "Fit" }, screen)
	applyLayout()
	screen.Parent = player:WaitForChild("PlayerGui")
end

-- The open panel's nav item gets the crimson swipe and a Bone label.
local function markOpen()
	local open = Panels.current()
	for id, button in navItems do
		local on = id == open
		local swipe = button:FindFirstChild("Swipe") :: ImageLabel
		local caption = button:FindFirstChild("Caption") :: TextLabel
		swipe.Visible = on
		caption.TextColor3 = if on then UI.Theme.Bone else UI.Theme.Dim
		caption.FontFace = if on then UI.Fonts.Number else UI.Fonts.Label
	end
end

local lastCoins, lastGems, lastStones = -1, -1, -1

-- "QUEUED · 0:04" while the royale counts down.
local function queueLabel(): string
	local state = Round.state()
	if state:GetAttribute("Waiting") == false and Round.phase() == "Intermission" then
		local left = math.max(0, math.ceil(Round.endsAt() - workspace:GetServerTimeNow()))
		return string.format("QUEUED · %d:%02d", left // 60, left % 60)
	end
	return "QUEUED"
end

function refresh()
	local coins = player:GetAttribute("Coins") or 0
	local gems = player:GetAttribute("Gems") or 0
	local stones = player:GetAttribute("Whetstones") or 0
	coinsPill.set(coins, lastCoins >= 0)
	gemsPill.set(gems, lastGems >= 0)
	stonesPill.set(stones, lastStones >= 0)
	stonesPill.frame.Visible = stones > 0
	lastCoins, lastGems, lastStones = coins, gems, stones
	-- The chip: while the bundle is on offer, from the first lobby visit after a fight (not on
	-- a brand-new player's first screen), and never alongside the offer card or the save notice.
	local played = player:GetAttribute("Played")
	local failed = player:GetAttribute("DataFailed") == true
	offerChip.Visible = StoreUI.initiateOpen()
		and typeof(played) == "number"
		and played >= 1
		and offerCard == nil
		and not failed
		and player:GetAttribute("DataWaiting") ~= true
	local loaded = player:GetAttribute("DataLoaded") == true
	storeBadge.Visible = loaded and StorePanel.badge()
	if passBadge then
		local ok, count = pcall(function()
			return if PassPanel and PassPanel.badge then PassPanel.badge() else 0
		end)
		passBadge.Visible = loaded and ok and typeof(count) == "number" and count > 0
	end

	-- Queued, PLAY stays crimson: its label counts down and the swipe breathes; a "Leave
	-- queue" link sits over it (on a touch screen, tapping QUEUED again leaves).
	local queued = player:GetAttribute("Queued") == true
	local touch = UI.touchSized()
	playButton.Text = if queued then queueLabel() else "PLAY"
	playButton.TextSize = if queued then 22 else 30
	if queued ~= (playSwipe:GetAttribute("Pulsing") == true) then
		playSwipe:SetAttribute("Pulsing", queued)
		local existing = playSwipe:FindFirstChild("PulseTween")
		if existing then
			existing:Destroy()
		end
		playSwipe.ImageTransparency = 0.05
		if queued and not UI.reducedMotion() then
			local tween = UI.play(playSwipe, UI.Motion.Pulse, { ImageTransparency = 0.55 })
			tween.Name = "PulseTween"
			tween.Parent = playSwipe
		end
	end
	-- The line over PLAY says only what the round banner doesn't.
	local duelState = player:GetAttribute("DuelState")
	local sub = if duelState == "Waiting"
		then "On a duel pad: the royale skips you"
		elseif queued and touch then "Tap QUEUED to leave"
		else ""
	playSub.Text = sub
	playSubStrip.Visible = sub ~= ""
	leaveButton.Visible = queued and not touch and duelState ~= "Waiting"
	-- Alone in the server: the invite button says so in gold.
	local alone = #Players:GetPlayers() <= 1
	inviteButton.Text = "Invite"
	inviteButton.TextColor3 = if alone then UI.Theme.GoldHi else UI.Theme.Bone

	local pvp = player:GetAttribute("LobbyPvP")
	local pvpWord = "PvP"
	pvpButton.Text = if pvp == true
		then `{pvpWord}: On`
		elseif pvp == "Pending" then `{pvpWord}: ...`
		else `{pvpWord}: Off`
	pvpPip.BackgroundColor3 = if pvp == true then UI.Theme.JadeText else UI.Theme.Ash

	rewardsBadge.Visible = player:GetAttribute("DataLoaded") == true and player:GetAttribute("DailyClaimed") == false
	saveNotice.Visible = failed or player:GetAttribute("DataWaiting") == true
	saveNotice.Text = if failed
		then player:GetAttribute("DataError") or Text.ProgressFailed
		else "Waiting for your save to free up from another server..."
	if trialsBadge then
		trialsBadge.Visible = player:GetAttribute("DataLoaded") == true and not trialsSeen
	end

	local xp = player:GetAttribute("XP") or 0
	local need = player:GetAttribute("XPToNext") or 1
	levelLabel.Text = `Lv {player:GetAttribute("Level") or 1}`
	xpBar.set(xp, need, true)
end

local pickerOpen = false -- the boss picker is a modal window: the HUD steps aside under it
local dismissOffer: () -> ()

local function refreshVisibility()
	local character = player.Character
	local inLobby = character ~= nil
		and character:GetAttribute("InMatch") ~= true
		and character:GetAttribute("InDuel") ~= true
	local visible = inLobby and LobbyHUD.entered
	-- The large panels (Store, Locker, Pass) and the boss picker take the screen: the HUD
	-- steps aside under them.
	screen.Enabled = visible and not Panels.isLarge() and not pickerOpen
	CombatHUD.setLobbyMode(inLobby)
	if not visible then
		Panels.closeAll()
		-- A fight starting takes the offer card with it; it doesn't wait behind the HUD.
		if offerCard then
			dismissOffer()
		end
	end
	LobbyHUD.offerCheck()
end

---------------------------------------------------------------------------------------
-- The one contextual offer: after the first level-up or the first loss (whichever comes
-- first, so once per account), a small dismissible card for the Initiate's Bundle while it
-- is on offer. It waits for a calm lobby moment: no panel, match report, podium or Coach
-- tip on screen, and not a royale about to start. It sits on the right edge, goes away by
-- itself after a while, and is never shown on a phone (the chip is).

local OFFER_LIFE = 15
local offerPending = false
local offerShown = false
local lastLevel: number? = nil
local lastLosses: number? = nil

function dismissOffer()
	if offerCard then
		local card = offerCard
		offerCard = nil
		UI.tween(card, 0.2, { Position = card.Position + UDim2.fromOffset(40, 0) })
		task.delay(0.2, function()
			card:Destroy()
		end)
		refresh()
	end
end

-- Something else holds the screen's attention right now.
local function busy(): boolean
	if not screen.Enabled or Panels.isOpen() or Toasts.reportOpen() or Podium.showing() then
		return true
	end
	local gui = player:FindFirstChild("PlayerGui")
	local coach = gui and gui:FindFirstChild("Coach")
	local tip = coach and coach:FindFirstChild("Tip")
	if tip and tip:IsA("GuiObject") and tip.Visible then
		return true
	end
	-- Queued with the royale about to start: the card would only flash up and vanish.
	if player:GetAttribute("Queued") == true and Round.phase() == "Intermission" then
		local left = Round.endsAt() - workspace:GetServerTimeNow()
		if Round.state():GetAttribute("Waiting") == false and left < 20 then
			return true
		end
	end
	return false
end

local function showOfferCard()
	offerShown = true
	offerPending = false
	local card = UI.panel({
		Name = "OfferCard",
		material = "lacquer",
		sliceScale = 0.6,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -HUD.Edge, 0.42, 0),
		Size = UDim2.fromOffset(300, 156),
	}, screen)
	UI.stroke(card, UI.Theme.Gold, 1, 0.25)
	UI.new("ImageLabel", {
		Position = UDim2.fromOffset(8, 6),
		Size = UDim2.fromOffset(52, 52),
		BackgroundTransparency = 1,
		Image = (ICONS :: any).InitiateBundle or ICONS.Katana,
	}, card)
	UI.text({
		Position = UDim2.fromOffset(66, 16),
		Size = UDim2.new(1, -118, 0, 26),
		TextXAlignment = Enum.TextXAlignment.Left,
		FontFace = UI.Fonts.Display,
		TextSize = 19,
		TextColor3 = UI.Theme.GoldHi,
		Text = "Initiate's Bundle",
	}, card)
	UI.text({
		Position = UDim2.fromOffset(16, 58),
		Size = UDim2.new(1, -32, 0, 38),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		TextWrapped = true,
		TextSize = 14,
		Text = "A blade of your own, the Initiate title, 300 gems and 1,500 coins. Here for your first 3 days.",
	}, card)
	local close = UI.iconButton({
		Name = "Dismiss",
		kind = "close",
		visual = 32,
		hit = 48,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
	}, card)
	close.Activated:Connect(dismissOffer)
	local later = UI.button({
		Name = "NotNow",
		variant = "secondary",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 12, 1, -10),
		Size = UDim2.new(0.5, -16, 0, HUD.Small),
		Text = "Later",
		TextSize = 15,
		sound = "Cancel",
	}, card)
	later.Activated:Connect(dismissOffer)
	local look = UI.button({
		Name = "Look",
		variant = "premium",
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -12, 1, -10),
		Size = UDim2.new(0.5, -16, 0, HUD.Small),
		Text = "Take a look",
		TextSize = 15,
	}, card)
	look.Activated:Connect(function()
		dismissOffer()
		StorePanel.show("Offers")
	end)
	UI.openMotion(card)
	offerCard = card
	refresh()
	task.delay(OFFER_LIFE, function()
		if offerCard == card then
			dismissOffer()
		end
	end)
end

-- Shows the pending offer card once the moment is right (checked again every few seconds).
local offerWaiting = false
function LobbyHUD.offerCheck()
	if not offerPending or offerShown or not screen or offerWaiting then
		return
	end
	if not StoreUI.initiateOpen() then
		offerPending = false
		return
	end
	offerWaiting = true
	task.spawn(function()
		-- A few calm seconds in a row, not just one.
		local calm = 0
		while offerPending and not offerShown do
			if compact or not StoreUI.initiateOpen() then
				break
			end
			calm = if busy() then 0 else calm + 1
			if calm >= 4 then
				showOfferCard()
				break
			end
			task.wait(1)
		end
		offerWaiting = false
	end)
end

local function watchMilestones()
	local level = player:GetAttribute("Level")
	local royale = player:GetAttribute("Losses")
	if player:GetAttribute("DataLoaded") ~= true or typeof(level) ~= "number" or typeof(royale) ~= "number" then
		return
	end
	-- A lost royale or a lost duel both count.
	local duels = player:GetAttribute("DuelLosses")
	local losses = royale + (if typeof(duels) == "number" then duels else 0)
	if lastLevel and lastLosses and not offerShown then
		local firstLevelUp = lastLevel <= 1 and level >= 2 and losses == 0
		local firstLoss = lastLosses == 0 and losses >= 1 and lastLevel <= 1
		if firstLevelUp or firstLoss then
			offerPending = true
		end
	end
	lastLevel, lastLosses = level, losses
	LobbyHUD.offerCheck()
end

---------------------------------------------------------------------------------------
-- The lobby's Store and Season boards (server/LobbyBuilder) open their panels.

local function openFromBoard(which: unknown)
	if not screen or not LobbyHUD.entered then
		return
	end
	if which == "Store" then
		StorePanel.show("Featured")
	elseif which == "Pass" then
		Panels.open(if Panels.has("Pass") then "Pass" else "Trials")
	elseif which == "Locker" then
		LockerPanel.show()
	end
end

local function watchBoards()
	ProximityPromptService.PromptTriggered:Connect(function(prompt)
		local which = prompt:GetAttribute("OpensPanel")
		if which then
			openFromBoard(which)
		end
	end)
	local function hook(detector: Instance)
		if detector:IsA("ClickDetector") and detector:GetAttribute("OpensPanel") then
			detector.MouseClick:Connect(function(who)
				if who == player then
					openFromBoard(detector:GetAttribute("OpensPanel"))
				end
			end)
		end
	end
	local lobby = workspace:WaitForChild("Lobby", 30)
	if not lobby then
		return
	end
	for _, d in lobby:GetDescendants() do
		hook(d)
	end
	lobby.DescendantAdded:Connect(hook)
end

---------------------------------------------------------------------------------------

LobbyHUD.entered = false -- set once the title card is dismissed

function LobbyHUD.setEntered()
	LobbyHUD.entered = true
	refreshVisibility()
	-- No rules screen before the first fight: new players are queued straight into a match
	-- against novice bots, and the fight itself teaches the deflect (CombatHUD prompts).
end

function LobbyHUD.start()
	Panels.start(lobbyAction)
	StorePanel.start()
	LockerPanel.start()
	if PassPanel then
		local pass = PassPanel :: PassModule
		Panels.register("Pass", { title = pass.Title or "Path of the Blade", build = pass.build, large = true })
	end
	build()
	Panels.onChange(function()
		markOpen()
		refreshVisibility()
		if offerCard and Panels.isOpen() then
			dismissOffer()
		end
	end)
	-- The boss picker is a modal window: PLAY and the nav bar step aside under it.
	BossHUD.onPicker(function(open: boolean)
		pickerOpen = open
		refreshVisibility()
	end)

	player.AttributeChanged:Connect(refresh)
	player.AttributeChanged:Connect(watchMilestones)
	watchMilestones()
	task.spawn(watchBoards)
	-- The offer chip counts down in hours: refresh it now and then; the queue label every
	-- second while queued.
	task.spawn(function()
		local n = 0
		while true do
			task.wait(1)
			n += 1
			if n % 30 == 0 then
				refresh()
			elseif player:GetAttribute("Queued") == true then
				playButton.Text = queueLabel()
			end
		end
	end)
	Round.state().AttributeChanged:Connect(refresh)
	local function watch(character: Model)
		character:GetAttributeChangedSignal("InMatch"):Connect(refreshVisibility)
		character:GetAttributeChangedSignal("InDuel"):Connect(refreshVisibility)
		refreshVisibility()
	end
	player.CharacterAdded:Connect(watch)
	if player.Character then
		watch(player.Character)
	end
	refresh()

	-- Fit the HUD on small screens.
	local camera = workspace.CurrentCamera
	local function fit()
		local fitScale = screen:FindFirstChild("Fit") :: UIScale
		fitScale.Scale = UI.lobbyScale(UI.viewport())
		applyLayout()
		refresh()
	end
	camera:GetPropertyChangedSignal("ViewportSize"):Connect(fit)
	player:GetAttributeChangedSignal("UIViewport"):Connect(fit)
	player:GetAttributeChangedSignal("UICompact"):Connect(fit)
	fit()
end

return LobbyHUD
