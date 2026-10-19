--!strict
-- Round presentation: the phase banner and timer at the top of the screen, the kill
-- feed, start and victory splashes, the closing ring of red mist, and spectating
-- after you fall. Everything is derived from ReplicatedStorage.RoundState and the
-- RoundEvent remote; the ring is the only thing touched every frame, and only during
-- a match.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Assets = require(ReplicatedStorage.Shared.Assets)
local CombatHUD = require(script.Parent.CombatHUD)
local Round = require(ReplicatedStorage.Shared.Round)
local Types = require(ReplicatedStorage.Shared.Types)

local player = Players.LocalPlayer
local state = Round.state()

local FONT = Enum.Font.Garamond
local PARCHMENT = Color3.fromRGB(232, 222, 200)
local GOLD = Color3.fromRGB(240, 200, 110)
local CRIMSON = Color3.fromRGB(200, 40, 34)
local FEED_LIFETIME = 6
local FEED_MAX = 4
local RING_HEIGHT = 80

local RoundHUD = {}

local screen: ScreenGui
local phaseLabel: TextLabel
local subLabel: TextLabel
local feed: Frame
local spectateLabel: TextLabel
local warning: Frame
local ring: Part
local spectating: Model? = nil

local function now(): number
	return workspace:GetServerTimeNow()
end

local function label(parent: Instance, size: number, color: Color3): TextLabel
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Font = FONT
	l.TextSize = size
	l.TextColor3 = color
	l.TextStrokeTransparency = 0.6
	l.Parent = parent
	return l
end

local function clock(seconds: number): string
	seconds = math.max(0, math.floor(seconds))
	return string.format("%d:%02d", seconds // 60, seconds % 60)
end

local function buildScreen()
	screen = Instance.new("ScreenGui")
	screen.Name = "RoundHUD"
	screen.ResetOnSpawn = false
	screen.IgnoreGuiInset = true

	-- Phase banner: spaced small caps over the gold ornament, a quieter line beneath.
	local banner = Instance.new("Frame")
	banner.BackgroundTransparency = 1
	banner.AnchorPoint = Vector2.new(0.5, 0)
	banner.Position = UDim2.new(0.5, 0, 0, 16)
	banner.Size = UDim2.fromOffset(460, 64)
	banner.Parent = screen

	phaseLabel = label(banner, 21, PARCHMENT)
	phaseLabel.Size = UDim2.new(1, 0, 0, 24)
	local divider = Instance.new("ImageLabel")
	divider.BackgroundTransparency = 1
	divider.Image = Assets.UI.PostureOrnament
	divider.ImageTransparency = 0.15
	divider.AnchorPoint = Vector2.new(0.5, 0.5)
	divider.Position = UDim2.new(0.5, 0, 0, 33)
	divider.Size = UDim2.fromOffset(200, 22)
	divider.Parent = banner
	subLabel = label(banner, 16, PARCHMENT)
	subLabel.TextTransparency = 0.3
	subLabel.Position = UDim2.fromOffset(0, 44)
	subLabel.Size = UDim2.new(1, 0, 0, 18)

	-- Kill feed, top-right.
	feed = Instance.new("Frame")
	feed.BackgroundTransparency = 1
	feed.AnchorPoint = Vector2.new(1, 0)
	feed.Position = UDim2.new(1, -24, 0, 20)
	feed.Size = UDim2.fromOffset(360, 140)
	feed.Parent = screen
	local list = Instance.new("UIListLayout")
	list.HorizontalAlignment = Enum.HorizontalAlignment.Right
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Padding = UDim.new(0, 4)
	list.Parent = feed

	spectateLabel = label(screen, 18, PARCHMENT)
	spectateLabel.AnchorPoint = Vector2.new(0.5, 1)
	spectateLabel.Position = UDim2.new(0.5, 0, 1, -40)
	spectateLabel.Size = UDim2.fromOffset(500, 22)
	spectateLabel.Visible = false

	-- A red edge vignette while you stand in the mist.
	warning = Instance.new("Frame")
	warning.Size = UDim2.fromScale(1, 1)
	warning.BackgroundColor3 = Color3.fromRGB(120, 0, 0)
	warning.BackgroundTransparency = 1
	warning.BorderSizePixel = 0
	warning.ZIndex = 0
	local edge = Instance.new("UIGradient")
	edge.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.2),
		NumberSequenceKeypoint.new(0.18, 1),
		NumberSequenceKeypoint.new(0.82, 1),
		NumberSequenceKeypoint.new(1, 0.2),
	})
	edge.Parent = warning
	warning.Parent = screen

	screen.Parent = player:WaitForChild("PlayerGui")
end

local function pushFeed(text: string, color: Color3)
	local line = label(feed, 17, color)
	line.Size = UDim2.new(1, 0, 0, 20)
	line.TextXAlignment = Enum.TextXAlignment.Right
	line.Text = text
	line.LayoutOrder = -math.floor(os.clock() * 1000)
	local lines = feed:GetChildren()
	local count = 0
	for _, child in lines do
		if child:IsA("TextLabel") then
			count += 1
		end
	end
	if count > FEED_MAX then
		-- Drop the oldest line (the highest LayoutOrder sits at the bottom).
		local oldest: TextLabel? = nil
		for _, child in lines do
			if child:IsA("TextLabel") and (not oldest or child.LayoutOrder > (oldest :: TextLabel).LayoutOrder) then
				oldest = child
			end
		end
		if oldest then
			oldest:Destroy()
		end
	end
	task.delay(FEED_LIFETIME, function()
		if line.Parent then
			TweenService:Create(line, TweenInfo.new(0.6), { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
			task.wait(0.65)
			line:Destroy()
		end
	end)
end

---------------------------------------------------------------------------------------
-- Ring

local function buildRing()
	ring = Instance.new("Part")
	ring.Name = "MistRing"
	ring.Shape = Enum.PartType.Cylinder
	ring.Anchored = true
	ring.CanCollide = false
	ring.CanQuery = false
	ring.CanTouch = false
	ring.CastShadow = false
	ring.Material = Enum.Material.ForceField
	ring.Color = Color3.fromRGB(170, 30, 26)
	ring.Transparency = 1
	ring.Parent = workspace
end

local inMist = false
local function updateRing()
	if Round.phase() ~= "Match" then
		if ring.Transparency < 1 then
			ring.Transparency = 1
		end
		if inMist then
			inMist = false
			warning.BackgroundTransparency = 1
		end
		return
	end
	local center, radius = Round.zone(now())
	ring.Transparency = 0
	ring.Size = Vector3.new(RING_HEIGHT, radius * 2, radius * 2)
	ring.CFrame = CFrame.new(center + Vector3.new(0, RING_HEIGHT / 2 - 4, 0)) * CFrame.Angles(0, 0, math.rad(90))

	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local outside = false
	if root and root:IsA("BasePart") then
		local offset = root.Position - center
		outside = Vector3.new(offset.X, 0, offset.Z).Magnitude > radius
	end
	if outside ~= inMist then
		inMist = outside
		TweenService:Create(warning, TweenInfo.new(0.4), { BackgroundTransparency = if outside then 0.55 else 1 })
			:Play()
	end
end

---------------------------------------------------------------------------------------
-- Spectating

local function livingFighters(): { Model }
	local list = {}
	for _, instance in CollectionService:GetTagged(Types.Tag) do
		if
			instance:IsA("Model")
			and instance ~= player.Character
			and instance:GetAttribute("CombatState") ~= "Dead"
		then
			table.insert(list, instance)
		end
	end
	return list
end

local function spectate(model: Model?)
	spectating = model
	local humanoid = model and model:FindFirstChildOfClass("Humanoid")
	if humanoid then
		local camera = workspace.CurrentCamera
		camera.CameraSubject = humanoid
		spectateLabel.Text = `Watching {model and model.Name or ""}  ·  click to switch`
		spectateLabel.Visible = true
	else
		spectateLabel.Visible = false
	end
end

local function needsSpectate(): boolean
	if Round.phase() ~= "Match" then
		return false
	end
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	return not humanoid or humanoid.Health <= 0
end

local function nextSpectateTarget()
	local fighters = livingFighters()
	if #fighters == 0 then
		spectate(nil)
		return
	end
	local index = table.find(fighters, spectating :: Model) or 0
	spectate(fighters[index % #fighters + 1])
end

---------------------------------------------------------------------------------------

-- "Intermission" -> "I N T E R M I S S I O N", the way Souls games set their titles.
local function spaced(text: string): string
	return (string.upper(text):gsub("(.)", "%1 ")):sub(1, -2)
end

local function refreshBanner()
	local phase = Round.phase()
	local remaining = Round.endsAt() - now()
	if phase == "Intermission" then
		phaseLabel.Text = spaced("Intermission")
		subLabel.Text = `The royale begins in {clock(remaining)}`
	elseif phase == "Match" then
		local alive = state:GetAttribute("Alive") or 0
		phaseLabel.Text = spaced(`{alive} Remain`)
		local shrinkStart = state:GetAttribute("ZoneShrinkStart") or 0
		if now() < shrinkStart then
			subLabel.Text = `The mist closes in {clock(shrinkStart - now())}`
		else
			subLabel.Text = `Time left  {clock(remaining)}`
		end
	else
		phaseLabel.Text = spaced("Decided")
		subLabel.Text = `Next round in {clock(remaining)}`
	end
end

local function onRoundEvent(kind: string, data: { [string]: any })
	if kind == "MatchStart" then
		CombatHUD.splash(Assets.UI.KanjiDuel, `{data.fighters} fighters enter. One leaves.`, CRIMSON, 1.6)
	elseif kind == "Eliminated" then
		local text = if data.killer and data.deathblow
			then `{data.killer} executed {data.victim}`
			elseif data.killer then `{data.killer} slew {data.victim}`
			else `{data.victim} was swallowed by the mist`
		pushFeed(text, if data.deathblow then CRIMSON else PARCHMENT)
	elseif kind == "Victory" then
		if data.winner and data.winner == player.Character then
			CombatHUD.splash(Assets.UI.KanjiVictory, "Victory Achieved", GOLD, 3.5)
		elseif data.name then
			CombatHUD.splash(Assets.UI.KanjiEnd, `{data.name} prevails`, PARCHMENT, 3)
		end
	end
end

function RoundHUD.start()
	buildScreen()
	buildRing()

	ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("RoundEvent").OnClientEvent:Connect(onRoundEvent)

	-- Text only needs to change a few times a second.
	task.spawn(function()
		while true do
			refreshBanner()
			if needsSpectate() then
				if not spectating or spectating:GetAttribute("CombatState") == "Dead" or not spectating.Parent then
					nextSpectateTarget()
				end
			elseif spectating then
				spectate(nil)
				local character = player.Character
				local humanoid = character and character:FindFirstChildOfClass("Humanoid")
				if humanoid then
					local camera = workspace.CurrentCamera
					camera.CameraSubject = humanoid
				end
			end
			task.wait(0.25)
		end
	end)

	RunService.RenderStepped:Connect(updateRing)

	UserInputService.InputBegan:Connect(function(input, processed)
		if not processed and spectating and input.UserInputType == Enum.UserInputType.MouseButton1 then
			nextSpectateTarget()
		end
	end)
end

return RoundHUD
