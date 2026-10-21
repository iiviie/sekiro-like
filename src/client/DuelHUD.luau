--!strict
-- Duel presentation: the score banner at the top of the screen (it
-- takes the royale banner's place while you duel), a line while you wait on a duel pad,
-- and the round, point and result splashes. Driven by the Duel remote and the DuelState / DuelBotAt
-- player attributes (see server/DuelService).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Assets = require(ReplicatedStorage.Shared.Assets)
local Config = require(ReplicatedStorage.Shared.Config)
local CombatHUD = require(script.Parent.CombatHUD)
local IntroCinematic = require(script.Parent.IntroCinematic)
local LockOn = require(script.Parent.LockOn)
local UI = require(script.Parent.UI)

local player = Players.LocalPlayer
local THEME = UI.Theme

local REASONS: { [string]: string } = {
	Time = "on vitality, as time ran out",
	Forfeit = "your opponent left",
	Draw = "both fell: no point",
}

local DuelHUD = {}

local screen: ScreenGui
local titleLabel: TextLabel
local subLabel: TextLabel
local waitLabel: TextLabel

local opponent = ""
local firstTo = 3
local rated = false
local mine, theirs = 0, 0
local fightAt = 0

local function now(): number
	return workspace:GetServerTimeNow()
end

-- Test hook (Studio): the pre-fight intro against any model (see client/IntroCinematic).
function DuelHUD.previewIntro(foe: Model, mode: string?)
	local hook = player:FindFirstChild("PlayerScripts") and (player :: any).PlayerScripts:FindFirstChild("IntroTest")
	if hook and hook:IsA("BindableFunction") then
		hook:Invoke("vs", foe, mode)
	end
end

local function refreshScore()
	titleLabel.Text = `{UI.tracked("You")}    {mine}  —  {theirs}    {UI.tracked(opponent)}`
end

local function onDuel(kind: string, data: { [string]: any })
	if kind == "Start" then
		opponent = data.opponent or "?"
		firstTo = data.firstTo or 3
		rated = data.rated == true
		mine, theirs = 0, 0
		refreshScore()
		CombatHUD.showControls()
	elseif kind == "Round" then
		mine, theirs = data.mine or 0, data.theirs or 0
		fightAt = data.fightAt or now()
		refreshScore()
		if typeof(data.foe) == "Instance" and data.foe:IsA("Model") then
			LockOn.engage(data.foe)
		end
		if (data.round or 1) > 1 then
			CombatHUD.splash(Assets.UI.KanjiDuel, `Round {data.round}`, UI.Parchment, 1)
		end
		-- Round 1 follows the pre-fight intro (client/IntroCinematic), which shows both cards.
	elseif kind == "Point" then
		mine, theirs = data.mine or mine, data.theirs or theirs
		refreshScore()
		local reason = REASONS[data.reason or ""]
		if data.reason == "Draw" then
			CombatHUD.splash(Assets.UI.KanjiEnd, `Round drawn  ·  {reason}`, UI.Parchment, 1.4)
		elseif data.you and data.reason ~= "Forfeit" then
			local text = if reason then `Round taken  ·  {reason}` else "Round taken"
			CombatHUD.splash(Assets.UI.KanjiSlay, `{text}  ·  {mine} - {theirs}`, UI.Gold, 1.4)
		elseif not data.you then
			local text = if reason then `Round lost  ·  {reason}` else "Round lost"
			CombatHUD.splash(Assets.UI.KanjiDeath, `{text}  ·  {mine} - {theirs}`, UI.Crimson, 1.4)
		end
	elseif kind == "End" then
		mine, theirs = data.mine or mine, data.theirs or theirs
		refreshScore()
		local rating = data.rating
		local suffix = if typeof(rating) == "number"
			then `  ·  rating {if rating >= 0 then "+" else ""}{rating}`
			else ""
		if data.won then
			CombatHUD.splash(Assets.UI.KanjiVictory, `Duel won  {mine} - {theirs}{suffix}`, UI.Gold, 3)
		else
			CombatHUD.splash(Assets.UI.KanjiEnd, `{data.opponent} wins  {theirs} - {mine}{suffix}`, UI.Parchment, 3)
		end
	end
end

-- Standing on a pad of a terrace that's mid-duel: the pads ignore you until it ends, so say so.
local function onBusyPad(): boolean
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local lobby = workspace:FindFirstChild("Lobby")
	local folder = lobby and lobby:FindFirstChild("DuelGrounds")
	if not root or not root:IsA("BasePart") or not folder then
		return false
	end
	for _, holder in folder:GetChildren() do
		if holder:GetAttribute("Busy") == true then
			for _, key in { "PadA", "PadB" } do
				local pad = holder:GetAttribute(key)
				if typeof(pad) == "Vector3" then
					local offset = root.Position - pad
					if
						Vector3.new(offset.X, 0, offset.Z).Magnitude <= Config.Duel.PadRadius
						and math.abs(offset.Y) < 6
					then
						return true
					end
				end
			end
		end
	end
	return false
end

-- Banner and pad line, once a frame: both are cheap text updates.
local function step()
	local state = player:GetAttribute("DuelState")
	local banner = titleLabel.Parent :: Frame
	banner.Visible = state == "Dueling"
	if state == "Dueling" then
		local t = now()
		subLabel.Text = string.upper(
			if t < fightAt
				then `Fight in {math.ceil(fightAt - t)}`
				else `First to {firstTo}{if rated then "  ·  ranked" else ""}`
		)
	end
	local botAt = player:GetAttribute("DuelBotAt")
	local blocked = state == nil and onBusyPad()
	waitLabel.Visible = state == "Waiting" or blocked
	if blocked then
		waitLabel.Text = "A duel is under way on this terrace  ·  the pads open when it ends"
	elseif state == "Waiting" then
		local left = if typeof(botAt) == "number" then math.max(0, math.ceil(botAt - now())) else nil
		waitLabel.Text = if left
			then `Waiting for a challenger  ·  a bot joins in {left}s`
			else "Waiting for a challenger on the other pad"
	end
end

function DuelHUD.start()
	IntroCinematic.start()
	screen = UI.new("ScreenGui", {
		Name = "DuelHUD",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		DisplayOrder = 5,
	}, player:WaitForChild("PlayerGui"))

	-- Same spot and type as the royale's phase banner, which hides while you duel.
	local banner = UI.new("Frame", {
		Name = "Banner",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 16),
		Size = UDim2.fromOffset(720, 66),
		Visible = false,
	}, screen)
	titleLabel = UI.label("banner", {
		Name = "Score",
		Size = UDim2.new(1, 0, 0, 28),
		TextSize = 26,
		TextScaled = true,
		TextStrokeColor3 = THEME.Ink,
		TextStrokeTransparency = 0.35,
		Text = "",
	}, banner)
	UI.new("UITextSizeConstraint", { MinTextSize = 18, MaxTextSize = 26 }, titleLabel)
	UI.new("ImageLabel", {
		BackgroundTransparency = 1,
		Image = Assets.UI.PostureOrnament,
		ImageTransparency = 0.15,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0, 36),
		Size = UDim2.fromOffset(200, 22),
	}, banner)
	subLabel = UI.label("caption", {
		Name = "Sub",
		Position = UDim2.fromOffset(0, 46),
		Size = UDim2.new(1, 0, 0, 20),
		TextSize = 15,
		TextColor3 = THEME.Dim,
		TextStrokeColor3 = THEME.Ink,
		TextStrokeTransparency = 0.35,
		Text = "",
	}, banner)

	waitLabel = UI.text({
		Name = "Waiting",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -300), -- above the lobby's PLAY button
		Size = UDim2.fromOffset(640, 24),
		Font = UI.Display,
		TextSize = 20,
		TextColor3 = UI.Gold,
		TextStrokeColor3 = THEME.Ink,
		TextStrokeTransparency = 0.35,
		Visible = false,
		Text = "",
	}, screen)

	local remote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("Duel") :: RemoteEvent
	remote.OnClientEvent:Connect(onDuel)
	RunService.Heartbeat:Connect(step)
end

return DuelHUD
