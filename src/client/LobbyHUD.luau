--!strict
-- The lobby's screen: coins and gems up top, the PLAY button with the lobby-sparring
-- toggle, and a bottom bar of Weapons / Store / Profile / Rewards / Settings that opens
-- the panels in client/Panels. Shown only while your character is in the lobby. Reads
-- everything from player attributes published by the server's StatsService; every
-- change is a request on the LobbyAction remote.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CombatHUD = require(script.Parent.CombatHUD)
local Panels = require(script.Parent.Panels)
local UI = require(script.Parent.UI)
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

local NAV = {
	{ id = "Weapons", glyph = "刀", label = "Weapons" },
	{ id = "Store", glyph = "店", label = "Store" },
	{ id = "Profile", glyph = "名", label = "Profile" },
	{ id = "Rewards", glyph = "賞", label = "Rewards" },
	{ id = "Settings", glyph = "設", label = "Settings" },
}

local function currencyPill(parent: Instance, order: number, color: Color3, glyph: string): TextLabel
	local pill = UI.panel({
		Size = UDim2.fromOffset(170, 40),
		LayoutOrder = order,
		BackgroundColor3 = UI.Ink,
		BackgroundTransparency = 0.15,
	}, parent)
	local icon = UI.new("Frame", {
		Size = UDim2.fromOffset(26, 26),
		Position = UDim2.fromOffset(8, 7),
		BackgroundColor3 = color,
		BorderSizePixel = 0,
		Rotation = if glyph == "◆" then 45 else 0,
	}, pill)
	UI.corner(icon, if glyph == "◆" then UDim.new(0, 4) else UDim.new(1, 0))
	UI.stroke(icon, Color3.new(0, 0, 0), 1.5, 0.4)
	return UI.text({
		Size = UDim2.new(1, -46, 1, 0),
		Position = UDim2.fromOffset(42, 0),
		TextXAlignment = Enum.TextXAlignment.Left,
		Font = UI.Bold,
		TextSize = 22,
		TextColor3 = color,
		Text = "0",
	}, pill)
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
	coinsLabel = currencyPill(top, 1, UI.Gold, "●")
	gemsLabel = currencyPill(top, 2, Color3.fromRGB(214, 70, 64), "◆")
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
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -14),
		Size = UDim2.fromOffset(520, 170),
		BackgroundTransparency = 1,
	}, screen)

	playButton = UI.button({
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
	pvpButton.Activated:Connect(function()
		local on = player:GetAttribute("LobbyPvP")
		lobbyAction:FireServer("PvP", on ~= true and on ~= "Pending")
	end)

	local nav = UI.new("Frame", {
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.fromScale(0.5, 1),
		Size = UDim2.fromOffset(520, 76),
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
			Size = UDim2.fromOffset(92, 76),
			LayoutOrder = i,
			Text = "",
			BackgroundColor3 = UI.Panel,
		}, nav)
		UI.stroke(button)
		UI.text({
			Size = UDim2.new(1, 0, 0, 46),
			Position = UDim2.fromOffset(0, 4),
			Font = UI.Display,
			TextSize = 36,
			TextColor3 = if item.id == "Rewards" then UI.Gold else UI.Parchment,
			Text = item.glyph,
		}, button)
		UI.text({
			Size = UDim2.new(1, 0, 0, 20),
			Position = UDim2.new(0, 0, 1, -24),
			TextSize = 15,
			Text = item.label,
		}, button)
		button.Activated:Connect(function()
			Panels.toggle(item.id)
		end)
		if item.id == "Rewards" then
			rewardsBadge = UI.new("Frame", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.new(1, -6, 0, 6),
				Size = UDim2.fromOffset(16, 16),
				BackgroundColor3 = UI.Crimson,
				BorderSizePixel = 0,
				Visible = false,
			}, button)
			UI.corner(rewardsBadge, UDim.new(1, 0))
			UI.stroke(rewardsBadge, UI.Parchment, 1.5, 0)
		end
	end

	UI.new("UIScale", { Name = "Fit" }, screen)
	screen.Parent = player:WaitForChild("PlayerGui")
end

local function refresh()
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

	local pvp = player:GetAttribute("LobbyPvP")
	pvpButton.Text = if pvp == true
		then "Lobby PvP: On"
		elseif pvp == "Pending" then "Lobby PvP: ..."
		else "Lobby PvP: Off"
	pvpButton.TextColor3 = if pvp == true then UI.Crimson else UI.Parchment

	local today = math.floor(os.time() / 86400)
	rewardsBadge.Visible = player:GetAttribute("DataLoaded") == true and (player:GetAttribute("LastDaily") or 0) < today
end

local function refreshVisibility()
	local character = player.Character
	local inLobby = character ~= nil and character:GetAttribute("InMatch") ~= true
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
end

function LobbyHUD.start()
	build()
	Panels.start(lobbyAction)

	player.AttributeChanged:Connect(refresh)
	Round.state().AttributeChanged:Connect(refresh)
	local function watch(character: Model)
		character:GetAttributeChangedSignal("InMatch"):Connect(refreshVisibility)
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
