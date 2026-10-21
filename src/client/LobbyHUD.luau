--!strict
-- The lobby's screen: coins, gems and Whetstones up top ("+" opens the Store's gem packs),
-- one calm chip while the Initiate's Bundle is on offer, the PLAY button with the
-- lobby-sparring toggle, and a bottom bar (How to fight / Locker / Pass / Store / Profile /
-- Rewards / Settings) that opens the panels in client/Panels, with a dot where something
-- is waiting (a pass tier to claim, a Shrine Draw to open, the daily reward). Shown only
-- while your character is in the lobby; it steps aside under the large panels. Reads
-- everything from server-published attributes; every change is a request on a remote.
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
local StorePanel = require(script.Parent.StorePanel)
local StoreUI = require(script.Parent.StoreUI)
local Toasts = require(script.Parent.Toasts)
local UI = require(script.Parent.UI)
local Assets = require(ReplicatedStorage.Shared.Assets)
local Round = require(ReplicatedStorage.Shared.Round)

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
local offerText: TextLabel
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
local nav: ScrollingFrame
local navPlate: Frame
local navLayout: UIListLayout
local navItems: { [string]: TextButton } = {}
local trialsSeen = false -- the Trials badge shows until the panel is opened once
local compact = false -- phone layout: nav rail on the left, PLAY on the right

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

-- Nav geometry at scale 1: desktop bar items (icon over label) and phone rail items.
local BAR_ITEM = Vector2.new(92, 92)
local RAIL_ITEM = Vector2.new(76, 70)

local function badge(parent: Instance): GuiObject
	local seal = UI.badge(parent, "new", 26)
	seal.Position = UDim2.new(1, -16, 0, 4)
	seal.Visible = false
	return seal
end

local refresh: () -> ()

-- Lays the HUD out for the screen: the bottom bar on desktop and console, the left rail
-- and right-hand PLAY on phones (clear of the thumbstick and the jump button).
local function applyLayout()
	local viewport = UI.viewport()
	compact = UI.compact(viewport)
	local scale = UI.lobbyScale(viewport)
	local height = viewport.Y / scale -- the HUD's height in scale-1 units
	if compact then
		local railTop = 92
		-- Four (or as many as fit) visible, the rest scroll: the bottom-left corner stays free
		-- for the thumbstick.
		local visible = math.max(3, math.min(4, math.floor((height - railTop - 12) / (RAIL_ITEM.Y + 4))))
		navLayout.FillDirection = Enum.FillDirection.Vertical
		navLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
		navLayout.VerticalAlignment = Enum.VerticalAlignment.Top
		navLayout.Padding = UDim.new(0, 4)
		nav.AnchorPoint = Vector2.zero
		nav.Position = UDim2.fromOffset(14, railTop + 6)
		nav.Size = UDim2.fromOffset(RAIL_ITEM.X, visible * (RAIL_ITEM.Y + 4))
		nav.ScrollingDirection = Enum.ScrollingDirection.Y
		nav.AutomaticCanvasSize = Enum.AutomaticSize.Y
		nav.ClipsDescendants = true
		nav.ScrollBarThickness = 3
		navPlate.AnchorPoint = Vector2.zero
		navPlate.Position = UDim2.fromOffset(8, railTop)
		navPlate.Size = UDim2.fromOffset(RAIL_ITEM.X + 12, visible * (RAIL_ITEM.Y + 4) + 12)
		playCluster.AnchorPoint = Vector2.new(1, 0.5)
		playCluster.Position = UDim2.new(1, -20, 0.5, 0)
		-- Invite and PvP under PLAY, the leave link under them.
		inviteButton.AnchorPoint = Vector2.new(1, 0)
		inviteButton.Position = UDim2.new(0.5, -4, 0, 108)
		inviteButton.Size = UDim2.fromOffset(142, 60)
		pvpButton.AnchorPoint = Vector2.new(0, 0)
		pvpButton.Position = UDim2.new(0.5, 4, 0, 108)
		pvpButton.Size = UDim2.fromOffset(142, 60)
		leaveButton.Position = UDim2.new(0.5, 0, 0, 170)
	else
		navLayout.FillDirection = Enum.FillDirection.Horizontal
		navLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
		navLayout.VerticalAlignment = Enum.VerticalAlignment.Bottom
		navLayout.Padding = UDim.new(0, 0)
		local width = #NAV * BAR_ITEM.X
		nav.AnchorPoint = Vector2.new(0.5, 1)
		nav.Position = UDim2.new(0.5, 0, 1, -10)
		nav.Size = UDim2.fromOffset(width, BAR_ITEM.Y + 24)
		nav.ScrollingDirection = Enum.ScrollingDirection.X
		nav.AutomaticCanvasSize = Enum.AutomaticSize.None
		nav.ClipsDescendants = false
		nav.ScrollBarThickness = 0
		navPlate.AnchorPoint = Vector2.new(0.5, 1)
		navPlate.Position = UDim2.new(0.5, 0, 1, -8)
		navPlate.Size = UDim2.fromOffset(width + 28, 70)
		playCluster.AnchorPoint = Vector2.new(0.5, 1)
		playCluster.Position = UDim2.new(0.5, 0, 1, -BAR_ITEM.Y + 34)
		inviteButton.AnchorPoint = Vector2.new(1, 0)
		inviteButton.Position = UDim2.new(0.5, -152, 0, 10)
		inviteButton.Size = UDim2.fromOffset(150, 60)
		pvpButton.AnchorPoint = Vector2.new(0, 0)
		pvpButton.Position = UDim2.new(0.5, 152, 0, 10)
		pvpButton.Size = UDim2.fromOffset(150, 60)
		leaveButton.Position = UDim2.new(0.5, 0, 0, 98)
	end
	for _, item in NAV do
		local button = navItems[item.id]
		local icon = button:FindFirstChild("Icon") :: ImageLabel
		local label = button:FindFirstChild("Caption") :: TextLabel
		local swipe = button:FindFirstChild("Swipe") :: ImageLabel
		if compact then
			button.Size = UDim2.fromOffset(RAIL_ITEM.X, RAIL_ITEM.Y)
			icon.Size = UDim2.fromOffset(48, 48)
			icon.Position = UDim2.fromScale(0.5, 0)
			label.Position = UDim2.new(0, 0, 1, -20)
			label.TextSize = 14
			swipe.Position = UDim2.new(0.5, 0, 1, -10)
			swipe.Size = UDim2.new(1, 4, 0, 26)
		else
			button.Size = UDim2.fromOffset(BAR_ITEM.X, BAR_ITEM.Y + 24)
			icon.Size = UDim2.fromOffset(70, 70)
			icon.Position = UDim2.fromScale(0.5, 0)
			label.Position = UDim2.new(0, 0, 1, -30)
			label.TextSize = 15
			swipe.Position = UDim2.new(0.5, 0, 1, -20)
			swipe.Size = UDim2.new(1, 20, 0, 30)
		end
		button:SetAttribute("IconSize", icon.Size.X.Offset)
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

	-- Top-right: Whetstones (when you have any), coins, gems and the gold "+".
	top = UI.new("Frame", {
		Name = "Currencies",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -16, 0, 14),
		Size = UDim2.fromOffset(640, 46),
		BackgroundTransparency = 1,
	}, screen)
	UI.new("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		HorizontalAlignment = Enum.HorizontalAlignment.Right,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		Padding = UDim.new(0, 18),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, top)
	stonesPill =
		UI.currencyPill({ Name = "Whetstones", currency = "stones", width = 96, height = 40, LayoutOrder = 0 }, top)
	coinsPill = UI.currencyPill({ Name = "Coins", currency = "coins", width = 134, height = 40, LayoutOrder = 1 }, top)
	gemsPill = UI.currencyPill({ Name = "Gems", currency = "gems", width = 122, height = 40, LayoutOrder = 2 }, top)
	local plus = UI.iconButton({
		Name = "AddGems",
		kind = "plus",
		fill = UI.Theme.Gold,
		visual = 40,
		hit = 62,
		LayoutOrder = 3,
	}, top)
	plus.Activated:Connect(function()
		StorePanel.show("Gems")
	end)

	-- One calm chip while the Initiate's Bundle is on offer (its real 72 h window).
	offerChip = UI.new("TextButton", {
		Name = "OfferChip",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -16, 0, 70),
		Size = UDim2.fromOffset(290, 62),
		BackgroundTransparency = 1,
		AutoButtonColor = false,
		Text = "",
		Visible = false,
	}, screen)
	local chipPlate = UI.panel({ Name = "Plate", material = "lacquer", Size = UDim2.fromScale(1, 1) }, offerChip)
	UI.stroke(chipPlate, UI.Theme.Gold, 1.5, 0.2)
	UI.new("ImageLabel", {
		Position = UDim2.fromOffset(2, 1),
		Size = UDim2.fromOffset(60, 60),
		BackgroundTransparency = 1,
		Image = (ICONS :: any).InitiateBundle or ICONS.Katana,
		ZIndex = 2,
	}, offerChip)
	UI.label("label", {
		Position = UDim2.fromOffset(66, 8),
		Size = UDim2.new(1, -78, 0, 22),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = UI.Theme.GoldHi,
		TextSize = 16,
		Text = "Initiate's Bundle",
		ZIndex = 2,
	}, offerChip)
	offerText = UI.text({
		Position = UDim2.fromOffset(66, 30),
		Size = UDim2.new(1, -78, 0, 22),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextSize = 15,
		TextColor3 = UI.Theme.Dim,
		Text = "",
		ZIndex = 2,
	}, offerChip)
	UI.juice(offerChip, { hover = 1.03 })
	offerChip.Activated:Connect(function()
		StorePanel.show("Offers")
	end)

	-- The profile didn't load (or another server took it): say so, plainly and for as long as
	-- it's true. The server also blocks purchases and spends for the session.
	local noticePlate = UI.panel({
		Name = "SaveNoticePlate",
		material = "plain",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -16, 0, 140),
		Size = UDim2.fromOffset(420, 0),
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
		TextSize = 16,
		TextColor3 = UI.Danger,
		Text = "",
	}, noticePlate)
	UI.new("UIPadding", {
		PaddingLeft = UDim.new(0, 18),
		PaddingRight = UDim.new(0, 12),
		PaddingTop = UDim.new(0, 10),
		PaddingBottom = UDim.new(0, 10),
	}, saveNotice)
	saveNotice:GetPropertyChangedSignal("Visible"):Connect(function()
		noticePlate.Visible = saveNotice.Visible
	end)
	saveNotice.Visible = false

	-- Top-left: the Mastery plate, its medallion overlapping the left end.
	local mastery = UI.panel({
		Name = "Mastery",
		material = "plain",
		Position = UDim2.fromOffset(40, 14),
		Size = UDim2.fromOffset(290, 64),
	}, screen)
	local medal = UI.new("ImageLabel", {
		Name = "Medal",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromOffset(4, 32),
		Size = UDim2.fromOffset(74, 74),
		BackgroundTransparency = 1,
		Image = ICONS.Level,
		ZIndex = 3,
	}, mastery)
	UI.label("caption", {
		Position = UDim2.fromOffset(50, 9),
		Size = UDim2.new(1, -66, 0, 18),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = UI.Theme.GoldHi,
		TextSize = 15,
		Text = "Mastery",
		ZIndex = 2,
	}, mastery)
	levelLabel = UI.label("number", {
		Name = "Level",
		Position = UDim2.fromOffset(50, 7),
		Size = UDim2.new(1, -66, 0, 22),
		TextXAlignment = Enum.TextXAlignment.Right,
		TextSize = 18,
		Text = "Lv 1",
		ZIndex = 2,
	}, mastery)
	xpBar = UI.progress({
		Name = "XP",
		Position = UDim2.fromOffset(50, 31),
		Size = UDim2.new(1, -66, 0, 30),
		height = 8,
		tone = "gold",
		label = "below",
		textSize = 14,
		format = function(v: number, m: number): string
			return `{UI.number(v)} / {UI.number(m)} XP`
		end,
	}, mastery)
	local _ = medal

	-- PLAY with Invite and Lobby PvP: one cluster, at the bottom centre on desktop and on the
	-- right on phones.
	bottom = UI.new("Frame", {
		Name = "Bottom",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
	}, screen)
	playCluster = UI.new("Frame", {
		Name = "PlayCluster",
		Size = UDim2.fromOffset(300, 232),
		BackgroundTransparency = 1,
	}, bottom)
	playSwipe = UI.brush(playCluster, "swipe", {
		Name = "PlaySwipe",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0, 40),
		Size = UDim2.fromOffset(400, 104),
		color = UI.Theme.LacquerRed,
		ImageTransparency = 0.05,
	})
	playButton = UI.button({
		Name = "Play",
		variant = "primary",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 0),
		Size = UDim2.fromOffset(280, 76),
		Text = "PLAY",
		FontFace = UI.Fonts.Display,
		TextSize = 40,
		ZIndex = 2,
	}, playCluster)
	playSubStrip = UI.new("Frame", {
		Name = "SubStrip",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 80),
		Size = UDim2.fromOffset(0, 24),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundColor3 = UI.Theme.Ink,
		BackgroundTransparency = 0.45,
		BorderSizePixel = 0,
	}, playCluster)
	UI.new("UICorner", { CornerRadius = UDim.new(1, 0) }, playSubStrip)
	UI.new("UIPadding", { PaddingLeft = UDim.new(0, 12), PaddingRight = UDim.new(0, 12) }, playSubStrip)
	playSub = UI.text({
		Name = "Sub",
		Size = UDim2.fromOffset(0, 24),
		AutomaticSize = Enum.AutomaticSize.X,
		TextSize = 15,
		TextColor3 = UI.Theme.Bone,
		Text = "",
	}, playSubStrip)
	playButton.Activated:Connect(function()
		lobbyAction:FireServer("Queue", player:GetAttribute("Queued") ~= true)
	end)
	leaveButton = UI.tertiary({
		Name = "LeaveQueue",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 104),
		Size = UDim2.fromOffset(170, 60),
		Text = "Leave queue",
		TextSize = 16,
		Visible = false,
	}, playCluster)
	leaveButton.Activated:Connect(function()
		lobbyAction:FireServer("Queue", false)
	end)

	-- Fights are better with friends: invite from the lobby, nudged when you're queued alone.
	local invite = UI.button({
		Name = "Invite",
		variant = "secondary",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(0.5, -152, 0, 10),
		Size = UDim2.fromOffset(150, 56),
		TextSize = 17,
		Text = "Invite friends",
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
		AnchorPoint = Vector2.new(0, 0),
		Position = UDim2.new(0.5, 152, 0, 10),
		Size = UDim2.fromOffset(150, 56),
		TextSize = 17,
		Text = "Lobby PvP",
	}, playCluster)
	pvpPip = UI.new("Frame", {
		Name = "Pip",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -12, 0.5, 0),
		Size = UDim2.fromOffset(10, 10),
		BackgroundColor3 = UI.Theme.Ash,
		ZIndex = 3,
	}, pvpButton)
	UI.new("UICorner", { CornerRadius = UDim.new(1, 0) }, pvpPip)
	UI.new("UIStroke", { Color = UI.Theme.Ink, Thickness = 1.5 }, pvpPip)
	pvpButton.Activated:Connect(function()
		local on = player:GetAttribute("LobbyPvP")
		lobbyAction:FireServer("PvP", on ~= true and on ~= "Pending")
	end)

	-- The nav: one lacquer strip, icons over labels; a crimson swipe under the open panel.
	navPlate = UI.panel({ Name = "NavPlate", material = "plain" }, bottom)
	nav = UI.new("ScrollingFrame", {
		Name = "Nav",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 0,
		CanvasSize = UDim2.new(),
		ElasticBehavior = Enum.ElasticBehavior.Never,
		ClipsDescendants = false,
		ZIndex = 2,
	}, bottom)
	navLayout = UI.new("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder }, nav)
	for i, item in NAV do
		local button = UI.new("TextButton", {
			Name = item.id,
			LayoutOrder = i,
			BackgroundTransparency = 1,
			AutoButtonColor = false,
			Text = "",
			ZIndex = 2,
		}, nav)
		local swipe = UI.brush(button, "swipe", {
			Name = "Swipe",
			AnchorPoint = Vector2.new(0.5, 0.5),
			color = UI.Theme.Crimson,
			ZIndex = 2,
			Visible = false,
		})
		local _ = swipe
		local icon = UI.new("ImageLabel", {
			Name = "Icon",
			AnchorPoint = Vector2.new(0.5, 0),
			BackgroundTransparency = 1,
			Image = item.icon,
			ZIndex = 3,
		}, button)
		UI.label("label", {
			Name = "Caption",
			Size = UDim2.new(1, 0, 0, 20),
			TextSize = 15,
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
			local size = button:GetAttribute("IconSize") or 70
			UI.play(icon, UI.Motion.Hover, {
				Size = UDim2.fromOffset(size * 1.1, size * 1.1),
				Position = UDim2.new(0.5, 0, 0, -6),
			})
		end)
		button.MouseLeave:Connect(function()
			local size = button:GetAttribute("IconSize") or 70
			UI.play(icon, UI.Motion.Hover, { Size = UDim2.fromOffset(size, size), Position = UDim2.fromScale(0.5, 0) })
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
	local offerOpen = StoreUI.initiateOpen()
	-- On a phone the chip would crowd PLAY; the Store's Offers tab and the one-time card
	-- still show the bundle.
	offerChip.Visible = offerOpen and not compact
	if offerOpen then
		local left = StoreUI.duration(StoreUI.attr("InitiateEndsAt", 0) - StoreUI.now())
		offerText.Text = `{left} left  ·  take a look`
	end
	local loaded = player:GetAttribute("DataLoaded") == true
	storeBadge.Visible = loaded and StorePanel.badge()
	if passBadge then
		local ok, count = pcall(function()
			return if PassPanel and PassPanel.badge then PassPanel.badge() else 0
		end)
		passBadge.Visible = loaded and ok and typeof(count) == "number" and count > 0
	end

	-- Queued, PLAY stays crimson: its label counts down and the swipe breathes; a quiet
	-- "Leave queue" link sits under it.
	local queued = player:GetAttribute("Queued") == true
	playButton.Text = if queued then queueLabel() else "PLAY"
	playButton.TextSize = if queued then 30 else 40
	leaveButton.Visible = queued
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
	local state = Round.state()
	local duelState = player:GetAttribute("DuelState")
	if duelState == "Waiting" then
		playSub.Text = "On a duel pad  ·  the royale skips you until you step off"
	elseif queued then
		playSub.Text = if state:GetAttribute("Waiting") == false and Round.phase() == "Intermission"
			then "The royale is about to begin"
			else "Waiting for the next royale  ·  bots fill empty seats"
	else
		playSub.Text = "Queue for the royale"
	end
	-- Alone in the server: the invite button says so in gold.
	local alone = #Players:GetPlayers() <= 1
	inviteButton.Text = if alone then "Invite a friend" else "Invite friends"
	inviteButton.TextColor3 = if alone then UI.Theme.GoldHi else UI.Theme.Bone

	local pvp = player:GetAttribute("LobbyPvP")
	local pvpWord = if compact then "PvP" else "Lobby PvP"
	pvpButton.Text = if pvp == true
		then `{pvpWord}: On`
		elseif pvp == "Pending" then `{pvpWord}: ...`
		else `{pvpWord}: Off`
	pvpPip.BackgroundColor3 = if pvp == true then UI.Theme.JadeText else UI.Theme.Ash

	rewardsBadge.Visible = player:GetAttribute("DataLoaded") == true and player:GetAttribute("DailyClaimed") == false
	local failed = player:GetAttribute("DataFailed") == true
	saveNotice.Visible = failed or player:GetAttribute("DataWaiting") == true
	saveNotice.Text = if failed
		then player:GetAttribute("DataError") or "Your progress couldn't be loaded; this session won't be saved."
		else "Waiting for your save to free up from another server..."
	if trialsBadge then
		trialsBadge.Visible = player:GetAttribute("DataLoaded") == true and not trialsSeen
	end

	local xp = player:GetAttribute("XP") or 0
	local need = player:GetAttribute("XPToNext") or 1
	levelLabel.Text = `Lv {player:GetAttribute("Level") or 1}`
	xpBar.set(xp, need, true)
end

local function refreshVisibility()
	local character = player.Character
	local inLobby = character ~= nil
		and character:GetAttribute("InMatch") ~= true
		and character:GetAttribute("InDuel") ~= true
	local visible = inLobby and LobbyHUD.entered
	-- The large panels (Store, Locker, Pass) take the screen: the HUD steps aside under them.
	screen.Enabled = visible and not Panels.isLarge()
	CombatHUD.setLobbyMode(inLobby)
	if not visible then
		Panels.closeAll()
	end
	LobbyHUD.offerCheck()
end

---------------------------------------------------------------------------------------
-- The one contextual offer: after the first level-up or the first loss (whichever comes
-- first, so once per account), a small dismissible card for the Initiate's Bundle while it
-- is on offer. It waits for the lobby with no panel open, a few seconds after the match.

local offerPending = false
local offerShown = false
local offerCard: Frame? = nil
local lastLevel: number? = nil
local lastLosses: number? = nil

local function dismissOffer()
	if offerCard then
		local card = offerCard
		offerCard = nil
		UI.tween(card, 0.2, { Position = card.Position + UDim2.fromOffset(40, 0) })
		task.delay(0.2, function()
			card:Destroy()
		end)
	end
end

local function showOfferCard()
	offerShown = true
	offerPending = false
	local card = UI.panel({
		Name = "OfferCard",
		material = "lacquer",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -16, 0.45, 0),
		Size = UDim2.fromOffset(340, 196),
	}, screen)
	UI.stroke(card, UI.Theme.Gold, 1.5, 0.15)
	UI.new("ImageLabel", {
		Position = UDim2.fromOffset(8, 4),
		Size = UDim2.fromOffset(64, 64),
		BackgroundTransparency = 1,
		Image = (ICONS :: any).InitiateBundle or ICONS.Katana,
	}, card)
	UI.text({
		Position = UDim2.fromOffset(78, 18),
		Size = UDim2.new(1, -140, 0, 28),
		TextXAlignment = Enum.TextXAlignment.Left,
		FontFace = UI.Fonts.Display,
		TextSize = 22,
		TextColor3 = UI.Theme.GoldHi,
		Text = "Initiate's Bundle",
	}, card)
	UI.text({
		Position = UDim2.fromOffset(18, 70),
		Size = UDim2.new(1, -36, 0, 48),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		TextWrapped = true,
		TextSize = 15,
		Text = "A blade of your own, the Initiate title, 300 gems and 1,500 coins. Only during your first 72 hours.",
	}, card)
	local close = UI.iconButton({
		Name = "Dismiss",
		kind = "close",
		visual = 38,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -2, 0, 2),
	}, card)
	close.Activated:Connect(dismissOffer)
	local later = UI.button({
		Name = "NotNow",
		variant = "secondary",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 14, 1, -14),
		Size = UDim2.new(0.5, -18, 0, 56),
		Text = "Later",
		TextSize = 17,
		sound = "Cancel",
	}, card)
	later.Activated:Connect(dismissOffer)
	local look = UI.button({
		Name = "Look",
		variant = "premium",
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -14, 1, -14),
		Size = UDim2.new(0.5, -18, 0, 56),
		Text = "Take a look",
		TextSize = 17,
	}, card)
	look.Activated:Connect(function()
		dismissOffer()
		StorePanel.show("Offers")
	end)
	UI.openMotion(card)
	offerCard = card
end

-- Shows the pending offer card once the moment is right.
function LobbyHUD.offerCheck()
	if not offerPending or offerShown or not screen then
		return
	end
	if not StoreUI.initiateOpen() then
		offerPending = false
		return
	end
	if not screen.Enabled or Panels.isOpen() then
		return
	end
	task.delay(4, function()
		if offerPending and not offerShown and screen.Enabled and not Panels.isOpen() and StoreUI.initiateOpen() then
			showOfferCard()
		end
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
		bottom.Visible = not open
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
		fitScale.Scale = UI.lobbyScale(camera.ViewportSize)
		applyLayout()
		refresh()
	end
	camera:GetPropertyChangedSignal("ViewportSize"):Connect(fit)
	player:GetAttributeChangedSignal("UIViewport"):Connect(fit)
	player:GetAttributeChangedSignal("UICompact"):Connect(fit)
	fit()
end

return LobbyHUD
