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
local coinsLabel: TextLabel
local gemsLabel: TextLabel
local stonesLabel: TextLabel
local offerChip: TextButton
local offerText: TextLabel
local storeBadge: Frame
local passBadge: Frame?
local playButton: TextButton
local playSub: TextLabel
local pvpButton: TextButton
local rewardsBadge: Frame
local trialsBadge: Frame?
local levelLabel: TextLabel
local xpFill: Frame
local xpText: TextLabel
local saveNotice: TextLabel

local inviteButton: TextButton
local bottom: Frame
local trialsSeen = false -- the Trials badge shows until the panel is opened once

local ICONS = Assets.Icons
local PASS_ICON = (PassPanel and PassPanel.Icon) or (ICONS :: any).SeasonPass or Assets.RankCrests.Gold
local NAV = {
	{ id = "Guide", icon = ICONS.Guide, label = "How to fight" },
	{ id = "Locker", icon = ICONS.Weapons, label = "Locker" },
	if PassPanel
		then { id = "Pass", icon = PASS_ICON, label = "Pass" }
		else { id = "Trials", icon = ICONS.Trials, label = "Trials" },
	{ id = "Store", icon = ICONS.Store, label = "Store" },
	{ id = "Profile", icon = ICONS.Profile, label = "Profile" },
	{ id = "Rewards", icon = ICONS.Rewards, label = "Rewards" },
	{ id = "Settings", icon = ICONS.Settings, label = "Settings" },
}

local function badge(parent: Instance): Frame
	local dot = UI.new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(1, -6, 0, 6),
		Size = UDim2.fromOffset(16, 16),
		BackgroundColor3 = UI.Crimson,
		BorderSizePixel = 0,
		Visible = false,
		ZIndex = 3,
	}, parent)
	UI.corner(dot, UDim.new(1, 0))
	UI.stroke(dot, UI.Parchment, 1.5, 0)
	return dot
end

local function currencyPill(parent: Instance, order: number, color: Color3, icon: string, width: number?): TextLabel
	local pill = UI.panel({
		Size = UDim2.fromOffset(width or 170, 40),
		LayoutOrder = order,
		BackgroundColor3 = UI.Ink,
		BackgroundTransparency = 0.15,
	}, parent)
	UI.new("ImageLabel", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Size = UDim2.fromOffset(46, 46),
		Position = UDim2.fromOffset(20, 20),
		BackgroundTransparency = 1,
		Image = icon,
		ZIndex = 2,
	}, pill)
	return UI.text({
		Size = UDim2.new(1, -52, 1, 0),
		Position = UDim2.fromOffset(48, 0),
		TextXAlignment = Enum.TextXAlignment.Left,
		Font = UI.Bold,
		TextSize = 22,
		TextColor3 = color,
		Text = "0",
	}, pill)
end

local refresh: () -> ()

local function build()
	screen = UI.new("ScreenGui", {
		Name = "LobbyHUD",
		ResetOnSpawn = false,
		IgnoreGuiInset = false,
		ScreenInsets = Enum.ScreenInsets.CoreUISafeInsets,
		DisplayOrder = 5,
		Enabled = false,
	})

	-- Top-right: coins and gems, with "+" opening the store.
	local top = UI.new("Frame", {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -16, 0, 12),
		Size = UDim2.fromOffset(600, 40),
		BackgroundTransparency = 1,
	}, screen)
	UI.new("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		HorizontalAlignment = Enum.HorizontalAlignment.Right,
		Padding = UDim.new(0, 10),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, top)
	coinsLabel = currencyPill(top, 1, UI.Gold, ICONS.Coin, 140)
	gemsLabel = currencyPill(top, 2, UI.Jade, ICONS.Gem, 130)
	stonesLabel = currencyPill(top, 0, UI.Parchment, (ICONS :: any).Whetstone or ICONS.Skin, 104)
	stonesLabel.Parent.Name = "Whetstones"

	-- One calm chip while the Initiate's Bundle is on offer (its real 72 h window).
	offerChip = UI.button({
		Name = "OfferChip",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -16, 0, 62),
		Size = UDim2.fromOffset(280, 60),
		Text = "",
		BackgroundColor3 = UI.Ink,
		Visible = false,
	}, screen)
	UI.stroke(offerChip, UI.Gold, 1.5, 0.3)
	UI.new("ImageLabel", {
		Position = UDim2.fromOffset(4, 4),
		Size = UDim2.fromOffset(52, 52),
		BackgroundTransparency = 1,
		Image = (ICONS :: any).InitiateBundle or ICONS.Katana,
	}, offerChip)
	offerText = UI.text({
		Position = UDim2.fromOffset(56, 0),
		Size = UDim2.new(1, -64, 1, 0),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextSize = 15,
		TextWrapped = true,
		Text = "",
	}, offerChip)
	offerChip.Activated:Connect(function()
		StorePanel.show("Offers")
	end)

	-- The profile didn't load (or another server took it): say so, plainly and for as long as
	-- it's true. The server also blocks purchases and spends for the session.
	saveNotice = UI.text({
		Name = "SaveNotice",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -16, 0, 128),
		Size = UDim2.fromOffset(420, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Right,
		TextSize = 15,
		TextColor3 = UI.Danger,
		TextStrokeTransparency = 0.4,
		Visible = false,
		Text = "",
	}, screen)
	UI.new("UIPadding", {
		PaddingLeft = UDim.new(0, 10),
		PaddingRight = UDim.new(0, 10),
		PaddingTop = UDim.new(0, 6),
		PaddingBottom = UDim.new(0, 6),
	}, saveNotice)

	-- Top-left: Mastery level and the XP bar toward the next one.
	local mastery = UI.panel({
		Position = UDim2.fromOffset(16, 12),
		Size = UDim2.fromOffset(300, 54),
		BackgroundColor3 = UI.Ink,
		BackgroundTransparency = 0.15,
	}, screen)
	local medal = UI.new("ImageLabel", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromOffset(28, 27),
		Size = UDim2.fromOffset(62, 62),
		BackgroundTransparency = 1,
		Image = ICONS.Level,
		ZIndex = 2,
	}, mastery)
	local plate = UI.new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.86),
		Size = UDim2.fromOffset(34, 22),
		BackgroundColor3 = UI.Ink,
		BorderSizePixel = 0,
		ZIndex = 3,
	}, medal)
	UI.corner(plate, UDim.new(1, 0))
	UI.stroke(plate, UI.Gold, 1.5, 0)
	levelLabel = UI.text({
		Size = UDim2.fromScale(1, 1),
		Font = UI.Bold,
		TextSize = 16,
		TextColor3 = UI.Gold,
		Text = "1",
		ZIndex = 4,
	}, plate)
	UI.text({
		Position = UDim2.fromOffset(64, 5),
		Size = UDim2.new(1, -74, 0, 22),
		TextXAlignment = Enum.TextXAlignment.Left,
		Font = UI.Display,
		TextSize = 20,
		Text = "MASTERY",
	}, mastery)
	local track = UI.new("Frame", {
		Position = UDim2.fromOffset(64, 30),
		Size = UDim2.new(1, -76, 0, 14),
		BackgroundColor3 = Color3.fromRGB(12, 10, 12),
		BorderSizePixel = 0,
	}, mastery)
	UI.corner(track, UDim.new(1, 0))
	UI.stroke(track, UI.Bronze, 1, 0.4)
	xpFill = UI.new("Frame", {
		Size = UDim2.fromScale(0, 1),
		BackgroundColor3 = UI.Gold,
		BorderSizePixel = 0,
	}, track)
	UI.corner(xpFill, UDim.new(1, 0))
	xpText = UI.text({
		Size = UDim2.fromScale(1, 1),
		TextSize = 12,
		Font = UI.Bold,
		TextStrokeTransparency = 0.3,
		Text = "",
		ZIndex = 2,
	}, track)
	local plus = UI.button({
		Size = UDim2.fromOffset(40, 40),
		LayoutOrder = 3,
		Text = "+",
		TextSize = 26,
		BackgroundColor3 = UI.Crimson,
	}, top)
	-- A bigger invisible hit area, so "+" is a comfortable tap on a phone.
	local plusHit = UI.new("TextButton", {
		Name = "Hit",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(62, 62),
		BackgroundTransparency = 1,
		Text = "",
		ZIndex = 3,
	}, plus)
	plus.Name = "AddGems"
	plus.Size = UDim2.fromOffset(46, 46)
	plusHit.Activated:Connect(function()
		StorePanel.show("Gems")
	end)

	-- Bottom: PLAY over the nav bar.
	bottom = UI.new("Frame", {
		Name = "Bottom",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -14),
		Size = UDim2.fromOffset(760, 170),
		BackgroundTransparency = 1,
	}, screen)

	playButton = UI.button({
		Name = "Play",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 0),
		Size = UDim2.fromOffset(260, 58),
		Text = "PLAY",
		Font = UI.Display,
		TextSize = 34,
		BackgroundColor3 = UI.Crimson,
	}, bottom)
	UI.stroke(playButton, UI.Parchment, 2, 0.35)
	playSub = UI.text({
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 60),
		Size = UDim2.fromOffset(300, 18),
		TextSize = 15,
		TextTransparency = 0.25,
		Text = "",
	}, bottom)
	playButton.Activated:Connect(function()
		lobbyAction:FireServer("Queue", player:GetAttribute("Queued") ~= true)
	end)

	pvpButton = UI.button({
		AnchorPoint = Vector2.new(0, 0),
		Position = UDim2.new(0.5, 140, 0, 0),
		Size = UDim2.fromOffset(112, 58),
		TextSize = 14,
		Text = "Lobby PvP: Off",
	}, bottom)
	UI.stroke(pvpButton)
	-- Fights are better with friends: invite from the lobby, nudged when you're queued alone.
	local invite = UI.button({
		Name = "Invite",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(0.5, -140, 0, 0),
		Size = UDim2.fromOffset(112, 58),
		TextSize = 14,
		Text = "Invite friends",
		BackgroundColor3 = Color3.fromRGB(40, 70, 58),
	}, bottom)
	UI.stroke(invite, UI.Jade)
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

	pvpButton.Activated:Connect(function()
		local on = player:GetAttribute("LobbyPvP")
		lobbyAction:FireServer("PvP", on ~= true and on ~= "Pending")
	end)

	local nav = UI.new("Frame", {
		Name = "Nav",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.fromScale(0.5, 1),
		Size = UDim2.fromOffset(760, 76),
		BackgroundTransparency = 1,
	}, bottom)
	UI.new("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
		Padding = UDim.new(0, 10),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, nav)
	for i, item in NAV do
		local button = UI.button({
			Name = item.id,
			Size = UDim2.fromOffset(92, 76),
			LayoutOrder = i,
			Text = "",
			BackgroundColor3 = UI.Panel,
		}, nav)
		UI.stroke(button)
		local icon = UI.new("ImageLabel", {
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.new(0.5, 0, 0, -10),
			Size = UDim2.fromOffset(62, 62),
			BackgroundTransparency = 1,
			Image = item.icon,
			ZIndex = 2,
		}, button)
		-- A little lift on hover, like picking the item up.
		button.MouseEnter:Connect(function()
			UI.tween(icon, 0.12, { Size = UDim2.fromOffset(70, 70), Position = UDim2.new(0.5, 0, 0, -16) })
		end)
		button.MouseLeave:Connect(function()
			UI.tween(icon, 0.12, { Size = UDim2.fromOffset(62, 62), Position = UDim2.new(0.5, 0, 0, -10) })
		end)
		UI.text({
			Size = UDim2.new(1, 0, 0, 20),
			Position = UDim2.new(0, 0, 1, -24),
			TextSize = 15,
			Text = item.label,
		}, button)
		button.Activated:Connect(function()
			if item.id == "Trials" then
				trialsSeen = true
				refresh()
			end
			Panels.toggle(item.id)
		end)
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
	screen.Parent = player:WaitForChild("PlayerGui")
end

function refresh()
	coinsLabel.Text = UI.number(player:GetAttribute("Coins") or 0)
	gemsLabel.Text = UI.number(player:GetAttribute("Gems") or 0)
	stonesLabel.Text = UI.number(player:GetAttribute("Whetstones") or 0)
	local offerOpen = StoreUI.initiateOpen()
	offerChip.Visible = offerOpen
	if offerOpen then
		local left = StoreUI.duration(StoreUI.attr("InitiateEndsAt", 0) - StoreUI.now())
		offerText.Text = `Initiate's Bundle  ·  {left} left`
	end
	local loaded = player:GetAttribute("DataLoaded") == true
	storeBadge.Visible = loaded and StorePanel.badge()
	if passBadge then
		local ok, count = pcall(function()
			return if PassPanel and PassPanel.badge then PassPanel.badge() else 0
		end)
		passBadge.Visible = loaded and ok and typeof(count) == "number" and count > 0
	end

	local queued = player:GetAttribute("Queued") == true
	playButton.Text = if queued then "QUEUED" else "PLAY"
	UI.setButtonColor(playButton, if queued then UI.PanelLight else UI.Crimson)
	local state = Round.state()
	local duelState = player:GetAttribute("DuelState")
	if duelState == "Waiting" then
		playSub.Text = "On a duel pad  ·  the royale skips you until you step off"
	elseif queued then
		playSub.Text = if state:GetAttribute("Waiting") == false and Round.phase() == "Intermission"
			then "The royale is about to begin  ·  click to leave the queue"
			else "Waiting for the next royale  ·  click to leave the queue"
	else
		playSub.Text = "Queue for the royale"
	end
	-- Alone in the server: the invite button glows.
	local alone = #Players:GetPlayers() <= 1
	inviteButton.Text = if alone then "Invite a friend!" else "Invite friends"
	inviteButton.TextColor3 = if alone then UI.Gold else UI.Parchment

	local pvp = player:GetAttribute("LobbyPvP")
	pvpButton.Text = if pvp == true
		then "Lobby PvP: On"
		elseif pvp == "Pending" then "Lobby PvP: ..."
		else "Lobby PvP: Off"
	pvpButton.TextColor3 = if pvp == true then UI.Crimson else UI.Parchment

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
	levelLabel.Text = tostring(player:GetAttribute("Level") or 1)
	xpText.Text = `{UI.number(xp)} / {UI.number(need)} XP`
	UI.tween(xpFill, 0.4, { Size = UDim2.fromScale(math.clamp(xp / need, 0.02, 1), 1) })
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
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -16, 0.45, 0),
		Size = UDim2.fromOffset(330, 184),
		BackgroundColor3 = UI.Ink,
	}, screen)
	UI.stroke(card, UI.Gold, 1.5, 0.2)
	UI.new("ImageLabel", {
		Position = UDim2.fromOffset(6, 2),
		Size = UDim2.fromOffset(56, 56),
		BackgroundTransparency = 1,
		Image = (ICONS :: any).InitiateBundle or ICONS.Katana,
	}, card)
	UI.text({
		Position = UDim2.fromOffset(68, 16),
		Size = UDim2.new(1, -130, 0, 26),
		TextXAlignment = Enum.TextXAlignment.Left,
		Font = UI.Display,
		TextSize = 22,
		TextColor3 = UI.Gold,
		Text = "Initiate's Bundle",
	}, card)
	UI.text({
		Position = UDim2.fromOffset(14, 60),
		Size = UDim2.new(1, -28, 0, 50),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		TextWrapped = true,
		TextSize = 14,
		Text = "A blade of your own, the Initiate title, 300 gems and 1,500 coins. Only during your first 72 hours.",
	}, card)
	local close = UI.button({
		Name = "Dismiss",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -6, 0, 6),
		Size = UDim2.fromOffset(46, 46),
		Text = "X",
		TextSize = 18,
		BackgroundColor3 = UI.PanelLight,
	}, card)
	close.Activated:Connect(dismissOffer)
	local later = UI.button({
		Name = "NotNow",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 10, 1, -10),
		Size = UDim2.new(0.5, -15, 0, 52),
		Text = "Not now",
		TextSize = 17,
	}, card)
	UI.stroke(later)
	later.Activated:Connect(dismissOffer)
	local look = UI.button({
		Name = "Look",
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -10, 1, -10),
		Size = UDim2.new(0.5, -15, 0, 52),
		Text = "Take a look",
		TextSize = 17,
		BackgroundColor3 = UI.Crimson,
	}, card)
	look.Activated:Connect(function()
		dismissOffer()
		StorePanel.show("Offers")
	end)
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
	-- The offer chip counts down in hours: refresh it now and then.
	task.spawn(function()
		while true do
			task.wait(30)
			refresh()
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
		fitScale.Scale = math.clamp(camera.ViewportSize.X / 1100, 0.6, 1)
	end
	camera:GetPropertyChangedSignal("ViewportSize"):Connect(fit)
	fit()
end

return LobbyHUD
