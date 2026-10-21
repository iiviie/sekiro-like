--!strict
-- The lobby's screen: coins and gems up top, the PLAY button with the lobby-sparring
-- toggle, and a bottom bar of Weapons / Store / Profile / Rewards / Settings that opens
-- the panels in client/Panels. Shown only while your character is in the lobby. Reads
-- everything from player attributes published by the server's StatsService; every
-- change is a request on the LobbyAction remote.

local Players = game:GetService("Players")
local SocialService = game:GetService("SocialService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CombatHUD = require(script.Parent.CombatHUD)
local Panels = require(script.Parent.Panels)
local UI = require(script.Parent.UI)
local Assets = require(ReplicatedStorage.Shared.Assets)
local Round = require(ReplicatedStorage.Shared.Round)

local player = Players.LocalPlayer
local lobbyAction = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("LobbyAction") :: RemoteEvent

local LobbyHUD = {}

local screen: ScreenGui
local coinsLabel: TextLabel
local gemsLabel: TextLabel
local playButton: TextButton
local playSub: TextLabel
local pvpButton: TextButton
local rewardsBadge: Frame
local trialsBadge: Frame
local levelLabel: TextLabel
local xpFill: Frame
local xpText: TextLabel

local inviteButton: TextButton
local trialsSeen = false -- the Trials badge shows until the panel is opened once

local ICONS = Assets.Icons
local NAV = {
	{ id = "Guide", icon = ICONS.Guide, label = "How to fight" },
	{ id = "Weapons", icon = ICONS.Weapons, label = "Arsenal" },
	{ id = "Trials", icon = ICONS.Trials, label = "Trials" },
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

local function currencyPill(parent: Instance, order: number, color: Color3, icon: string): TextLabel
	local pill = UI.panel({
		Size = UDim2.fromOffset(170, 40),
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
		Size = UDim2.fromOffset(420, 40),
		BackgroundTransparency = 1,
	}, screen)
	UI.new("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		HorizontalAlignment = Enum.HorizontalAlignment.Right,
		Padding = UDim.new(0, 10),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, top)
	coinsLabel = currencyPill(top, 1, UI.Gold, ICONS.Coin)
	gemsLabel = currencyPill(top, 2, UI.Jade, ICONS.Gem)

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
	plus.Activated:Connect(function()
		Panels.open("Store")
	end)

	-- Bottom: PLAY over the nav bar.
	local bottom = UI.new("Frame", {
		Name = "Bottom",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -14),
		Size = UDim2.fromOffset(720, 170),
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
		Position = UDim2.new(0.5, 140, 0, 10),
		Size = UDim2.fromOffset(112, 38),
		TextSize = 14,
		Text = "Lobby PvP: Off",
	}, bottom)
	UI.stroke(pvpButton)
	-- Fights are better with friends: invite from the lobby, nudged when you're queued alone.
	local invite = UI.button({
		Name = "Invite",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(0.5, -140, 0, 10),
		Size = UDim2.fromOffset(112, 38),
		TextSize = 14,
		Text = "Invite friends",
		BackgroundColor3 = Color3.fromRGB(40, 70, 58),
	}, bottom)
	UI.stroke(invite, UI.Jade)
	invite.Activated:Connect(function()
		local ok, can = pcall(SocialService.CanSendGameInviteAsync, SocialService, player)
		if ok and can then
			pcall(SocialService.PromptGameInvite, SocialService, player)
		end
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
		Size = UDim2.fromOffset(720, 76),
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
		end
	end

	UI.new("UIScale", { Name = "Fit" }, screen)
	screen.Parent = player:WaitForChild("PlayerGui")
end

function refresh()
	coinsLabel.Text = UI.number(player:GetAttribute("Coins") or 0)
	gemsLabel.Text = UI.number(player:GetAttribute("Gems") or 0)

	local queued = player:GetAttribute("Queued") == true
	playButton.Text = if queued then "QUEUED" else "PLAY"
	playButton.BackgroundColor3 = if queued then UI.PanelLight else UI.Crimson
	local state = Round.state()
	if queued then
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

	local today = math.floor(os.time() / 86400)
	rewardsBadge.Visible = player:GetAttribute("DataLoaded") == true and (player:GetAttribute("LastDaily") or 0) < today
	trialsBadge.Visible = player:GetAttribute("DataLoaded") == true and not trialsSeen

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
	screen.Enabled = visible
	CombatHUD.setLobbyMode(inLobby)
	if not visible then
		Panels.closeAll()
	end
end

LobbyHUD.entered = false -- set once the title card is dismissed

function LobbyHUD.setEntered()
	LobbyHUD.entered = true
	refreshVisibility()
	-- No rules screen before the first fight: new players are queued straight into a match
	-- against novice bots, and the fight itself teaches the deflect (CombatHUD prompts).
end

function LobbyHUD.start()
	build()
	Panels.start(lobbyAction)

	player.AttributeChanged:Connect(refresh)
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
