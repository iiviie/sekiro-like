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
local Config = require(ReplicatedStorage.Shared.Config)
local Round = require(ReplicatedStorage.Shared.Round)
local Types = require(ReplicatedStorage.Shared.Types)
local UI = require(script.Parent.UI)

local player = Players.LocalPlayer
local state = Round.state()

local FONT = Enum.Font.Garamond
local PARCHMENT = Color3.fromRGB(232, 222, 200)
local GOLD = Color3.fromRGB(240, 200, 110)
local CRIMSON = Color3.fromRGB(200, 40, 34)
local FEED_LIFETIME = 6
local FEED_MAX = 3
-- The mist wall is a ring of vertical, camera-facing beams: double-sided, unlike a
-- cylinder part, whose inside faces are culled so it vanishes once you're within it.
local MIST_COLUMNS = 72
local MIST_HEIGHT = 28
local MIST_BASE_Y = 1 -- just under the courtyard floor, so the mist rises out of the ground

local RoundHUD = {}

local screen: ScreenGui
local phaseLabel: TextLabel
local subLabel: TextLabel
local feed: Frame
local feedList: UIListLayout
local feedInLobby: boolean? = nil
local spectateBar: Frame
local spectateName: TextLabel
local warning: Frame
local ring: Part
local mistBottoms: { Attachment } = {}
local mistTops: { Attachment } = {}
local mistBeams: { Beam } = {}
local mistWidth = 0
local ringShown = false
local mistGrade: ColorCorrectionEffect
local spectating: Model? = nil
local stepSpectate: (step: number) -> ()

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

-- The feed's corner: top-right in a fight, bottom-left in the lobby (newest line nearest the
-- edge either way).
local function placeFeed(lobby: boolean)
	if feedInLobby == lobby then
		return
	end
	feedInLobby = lobby
	if lobby then
		feed.AnchorPoint = Vector2.new(0, 1)
		feed.Position = UDim2.new(0, 16, 1, -16)
		feedList.HorizontalAlignment = Enum.HorizontalAlignment.Left
		feedList.VerticalAlignment = Enum.VerticalAlignment.Bottom
	else
		feed.AnchorPoint = Vector2.new(1, 0)
		feed.Position = UDim2.new(1, -16, 0, 64)
		feedList.HorizontalAlignment = Enum.HorizontalAlignment.Right
		feedList.VerticalAlignment = Enum.VerticalAlignment.Top
	end
	-- Newest first at the top in a fight, newest last (at the bottom) in the lobby.
	for _, child in feed:GetChildren() do
		if child:IsA("GuiObject") then
			child.LayoutOrder = -child.LayoutOrder
		end
	end
end

local function buildScreen()
	screen = Instance.new("ScreenGui")
	screen.Name = "RoundHUD"
	screen.ResetOnSpawn = false
	screen.IgnoreGuiInset = true
	-- Phones get the HUD at their own scale (UI.hudScale).
	local fit = UI.new("UIScale", { Name = "Fit" }, screen)
	local function refit()
		fit.Scale = UI.hudScale()
	end
	workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(refit)
	player:GetAttributeChangedSignal("UIViewport"):Connect(refit)
	refit()

	-- Phase banner: spaced small caps over the gold ornament, a quieter line beneath; small,
	-- in the top bar's middle.
	local banner = Instance.new("Frame")
	banner.Name = "Banner"
	banner.BackgroundTransparency = 1
	banner.AnchorPoint = Vector2.new(0.5, 0)
	banner.Position = UDim2.new(0.5, 0, 0, 12)
	banner.Size = UDim2.fromOffset(400, 56)
	banner.Parent = screen

	phaseLabel = label(banner, 20, PARCHMENT)
	phaseLabel.Size = UDim2.new(1, 0, 0, 22)
	phaseLabel.TextStrokeColor3 = UI.Theme.Ink
	phaseLabel.TextStrokeTransparency = 0.35
	local divider = Instance.new("ImageLabel")
	divider.BackgroundTransparency = 1
	divider.Image = Assets.UI.PostureOrnament
	divider.ImageTransparency = 0.15
	divider.AnchorPoint = Vector2.new(0.5, 0.5)
	divider.Position = UDim2.new(0.5, 0, 0, 28)
	divider.Size = UDim2.fromOffset(150, 16)
	divider.Parent = banner
	subLabel = UI.label("body", {
		Name = "Sub",
		Position = UDim2.fromOffset(0, 37),
		Size = UDim2.new(1, 0, 0, 18),
		TextSize = 14,
		TextColor3 = UI.Theme.Bone,
		TextStrokeColor3 = UI.Theme.Ink,
		TextStrokeTransparency = 0.35,
	}, banner)

	-- Kill feed: top-right under the Roblox top bar in a fight; in the lobby (where the
	-- pills and toasts own the top-right) it drops to the bottom-left corner, under the nav.
	feed = Instance.new("Frame")
	feed.Name = "Feed"
	feed.BackgroundTransparency = 1
	feed.Size = UDim2.fromOffset(360, FEED_MAX * 32)
	feed.Parent = screen
	feedList = Instance.new("UIListLayout")
	feedList.SortOrder = Enum.SortOrder.LayoutOrder
	feedList.Padding = UDim.new(0, 3)
	feedList.Parent = feed
	placeFeed(false)

	-- Spectating: previous / next around a plate with who you're watching.
	spectateBar = UI.new("Frame", {
		Name = "Spectate",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -28),
		Size = UDim2.fromOffset(460, 60),
		BackgroundTransparency = 1,
		Visible = false,
	}, screen)
	UI.new("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		Padding = UDim.new(0, 8),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, spectateBar)
	local prev = UI.iconButton({ Name = "Previous", kind = "prev", LayoutOrder = 1 }, spectateBar)
	local plate = UI.panel({
		Name = "Plate",
		material = "plain",
		sliceScale = 0.4,
		LayoutOrder = 2,
		Size = UDim2.fromOffset(300, 54),
	}, spectateBar)
	UI.label("caption", {
		Position = UDim2.fromOffset(0, 6),
		Size = UDim2.new(1, 0, 0, 16),
		Text = "Watching",
	}, plate)
	spectateName = UI.label("heading", {
		Name = "Target",
		Position = UDim2.fromOffset(10, 22),
		Size = UDim2.new(1, -20, 0, 26),
		TextSize = 20,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Text = "",
	}, plate)
	local nextButton = UI.iconButton({ Name = "Next", kind = "next", LayoutOrder = 3 }, spectateBar)
	prev.Activated:Connect(function()
		stepSpectate(-1)
	end)
	nextButton.Activated:Connect(function()
		stepSpectate(1)
	end)

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

local function hex(c: Color3): string
	return string.format("#%02X%02X%02X", c.R * 255, c.G * 255, c.B * 255)
end

local function escape(text: string): string
	return (text:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

-- One kill-feed plate: "killer / victim" (killer in bone, victim dimmed, the slash in the
-- accent colour), or a plain line in `accent` when there's no pair.
local function pushFeed(text: string, accent: Color3, killer: string?, victim: string?, tail: string?)
	local theme = UI.Theme
	local plate = UI.panel({
		Name = "Line",
		material = "plain",
		sliceScale = 0.4,
		Size = UDim2.fromOffset(0, 29),
		AutomaticSize = Enum.AutomaticSize.X,
		LayoutOrder = (if feedInLobby then 1 else -1) * math.floor(os.clock() * 1000),
	}, feed)
	UI.new("UIPadding", { PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10) }, plate)
	local rich = if killer and victim
		then `<font color="{hex(theme.Bone)}">{escape(killer)}</font>  <font color="{hex(accent)}"><b>/</b></font>  <font color="{hex(
			theme.Dim
		)}">{escape(victim)}</font>{if tail then `<font color="{hex(theme.Ash)}">  {escape(tail)}</font>` else ""}`
		else `<font color="{hex(accent)}">{escape(text)}</font>`
	local line = UI.label("label", {
		Name = "Text",
		Size = UDim2.fromScale(0, 1),
		AutomaticSize = Enum.AutomaticSize.X,
		TextSize = 14,
		RichText = true,
		Text = rich,
	}, plate)
	local lines = feed:GetChildren()
	local count = 0
	for _, child in lines do
		if child.Name == "Line" then
			count += 1
		end
	end
	if count > FEED_MAX then
		-- Drop the oldest line (made first: the smallest |LayoutOrder|).
		local oldest: GuiObject? = nil
		for _, child in lines do
			if
				child.Name == "Line"
				and child:IsA("GuiObject")
				and (not oldest or math.abs(child.LayoutOrder) < math.abs((oldest :: GuiObject).LayoutOrder))
			then
				oldest = child
			end
		end
		if oldest then
			oldest:Destroy()
		end
	end
	task.delay(FEED_LIFETIME, function()
		if plate.Parent then
			local info = TweenInfo.new(0.6)
			TweenService:Create(line, info, { TextTransparency = 1 }):Play()
			TweenService:Create(plate, info, { ImageTransparency = 1, BackgroundTransparency = 1 }):Play()
			local edge = plate:FindFirstChildWhichIsA("UIStroke")
			if edge then
				TweenService:Create(edge, info, { Transparency = 1 }):Play()
			end
			task.wait(0.65)
			plate:Destroy()
		end
	end)
end

---------------------------------------------------------------------------------------
-- Ring

-- Column transparency by distance to the camera: hidden, faint, normal.
local MIST_NEAR = {
	NumberSequence.new(1),
	NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.85),
		NumberSequenceKeypoint.new(0.3, 0.93),
		NumberSequenceKeypoint.new(1, 1),
	}),
	NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.45),
		NumberSequenceKeypoint.new(0.3, 0.75),
		NumberSequenceKeypoint.new(1, 1),
	}),
}
local mistLevels: { number } = {}

local function buildRing()
	ring = Instance.new("Part")
	ring.Name = "MistRing"
	ring.Anchored = true
	ring.CanCollide = false
	ring.CanQuery = false
	ring.CanTouch = false
	ring.CastShadow = false
	ring.Transparency = 1
	ring.Size = Vector3.one
	ring.CFrame = CFrame.identity
	for i = 1, MIST_COLUMNS do
		local bottom = Instance.new("Attachment")
		bottom.Parent = ring
		local top = Instance.new("Attachment")
		top.Parent = ring
		local beam = Instance.new("Beam")
		beam.Attachment0 = bottom
		beam.Attachment1 = top
		beam.FaceCamera = true
		beam.Segments = 1
		beam.Color = ColorSequence.new(Color3.fromRGB(210, 36, 28), Color3.fromRGB(110, 12, 12))
		beam.Transparency = MIST_NEAR[3]
		beam.LightEmission = 0.5
		beam.LightInfluence = 0.3
		beam.Enabled = false
		beam.Parent = ring
		mistBottoms[i], mistTops[i], mistBeams[i] = bottom, top, beam
	end
	ring.Parent = workspace

	-- Per-player grade (under the camera, not Lighting) while you stand in the mist.
	mistGrade = Instance.new("ColorCorrectionEffect")
	mistGrade.Name = "MistGrade"
	mistGrade.Enabled = false
	mistGrade.Parent = workspace.CurrentCamera
end

local function showRing(visible: boolean)
	if visible ~= ringShown then
		ringShown = visible
		for _, beam in mistBeams do
			beam.Enabled = visible
		end
	end
end

local function placeRing(center: Vector3, radius: number)
	-- Camera-facing columns right beside the lens would fill the screen with flat red, so
	-- columns fade out as the camera gets close; the screen tint says you're in the mist.
	local camera = workspace.CurrentCamera
	local eye = if camera then camera.CFrame.Position else Vector3.zero
	for i = 1, MIST_COLUMNS do
		local angle = (i / MIST_COLUMNS) * math.pi * 2
		local base = Vector3.new(center.X + math.cos(angle) * radius, MIST_BASE_Y, center.Z + math.sin(angle) * radius)
		mistBottoms[i].Position = base
		mistTops[i].Position = base + Vector3.new(0, MIST_HEIGHT, 0)
		local gap = Vector3.new(base.X - eye.X, 0, base.Z - eye.Z).Magnitude
		local level = if gap < 9 then 1 elseif gap < 20 then 2 else 3
		if mistLevels[i] ~= level then
			mistLevels[i] = level
			mistBeams[i].Transparency = MIST_NEAR[level]
		end
	end
	-- Each column a little wider than the gap to its neighbour, so the wall has no holes.
	local width = 2 * math.pi * radius / MIST_COLUMNS + 0.4
	if math.abs(width - mistWidth) > 0.05 then
		mistWidth = width
		for _, beam in mistBeams do
			beam.Width0 = width
			beam.Width1 = width
		end
	end
end

local inMist = false
local function updateRing()
	if Round.phase() ~= "Match" then
		showRing(false)
		if inMist then
			inMist = false
			warning.BackgroundTransparency = 1
			mistGrade.Enabled = false
		end
		return
	end
	local center, radius = Round.zone(now())
	placeRing(center, radius)
	showRing(true)

	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local outside = false
	-- Only fighters in the match can be caught by the mist; the lobby is far outside it.
	if root and root:IsA("BasePart") and character and character:GetAttribute("InMatch") then
		local offset = root.Position - center
		outside = Vector3.new(offset.X, 0, offset.Z).Magnitude > radius
	end
	if outside ~= inMist then
		inMist = outside
		TweenService:Create(warning, TweenInfo.new(0.4), { BackgroundTransparency = if outside then 0.55 else 1 })
			:Play()
		mistGrade.Enabled = true
		TweenService:Create(mistGrade, TweenInfo.new(0.5), {
			TintColor = if outside then Color3.fromRGB(255, 196, 190) else Color3.new(1, 1, 1),
			Saturation = if outside then -0.35 else 0,
		}):Play()
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
			and instance:GetAttribute("InMatch") == true
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
		spectateName.Text = model and model.Name or ""
		spectateBar.Visible = true
	else
		spectateBar.Visible = false
	end
end

local wasInMatch = false -- this client's character fought in the current match

local function needsSpectate(): boolean
	if Round.phase() ~= "Match" or not wasInMatch then
		return false
	end
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	return not humanoid or humanoid.Health <= 0
end

-- The next (step 1) or previous (step -1) living fighter.
function stepSpectate(step: number)
	if not spectating then
		return
	end
	local fighters = livingFighters()
	if #fighters == 0 then
		spectate(nil)
		return
	end
	local index = table.find(fighters, spectating :: Model) or 0
	spectate(fighters[(index - 1 + step) % #fighters + 1])
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
	return (string.upper(text):gsub(utf8.charpattern, "%0 ")):sub(1, -2)
end

local function refreshBanner()
	-- While you duel, DuelHUD's score banner takes this spot.
	local banner = phaseLabel.Parent :: Frame
	local duelState = player:GetAttribute("DuelState")
	banner.Visible = duelState ~= "Dueling" and duelState ~= "Boss" -- and BossHUD's banner in a boss fight
	local phase = Round.phase()
	local remaining = Round.endsAt() - now()
	local character = player.Character
	local fighting = character ~= nil and character:GetAttribute("InMatch") == true
	placeFeed(
		character ~= nil
			and character:GetAttribute("InMatch") ~= true
			and character:GetAttribute("InDuel") ~= true
			and not needsSpectate()
	)
	if phase == "Intermission" then
		local queued = state:GetAttribute("Queued") or 0
		if state:GetAttribute("Waiting") then
			phaseLabel.Text = spaced("Lobby")
			subLabel.Text = "Press PLAY or step on the red pad to queue"
		else
			phaseLabel.Text = spaced(`Royale in {clock(remaining)}`)
			subLabel.Text = if player:GetAttribute("Queued")
				then `{queued} queued  ·  bots fill the empty seats`
				else `{queued} queued  ·  press PLAY to join`
		end
	elseif phase == "Match" and not fighting and not needsSpectate() then
		local alive = state:GetAttribute("Alive") or 0
		phaseLabel.Text = spaced("Royale under way")
		subLabel.Text = `{alive} remain  ·  you'll join the next one`
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

local function omenById(id: string?): { [string]: string }?
	for _, omen in Config.Omens.List do
		if omen.id == id then
			return omen
		end
	end
	return nil
end

-- Blood Moon stains the whole match red.
local bloodMoonGrade: ColorCorrectionEffect? = nil
local function refreshOmenGrade()
	local on = state:GetAttribute("Omen") == "BloodMoon"
	if on and not bloodMoonGrade then
		local grade = Instance.new("ColorCorrectionEffect")
		grade.Name = "BloodMoon"
		grade.TintColor = Color3.new(1, 1, 1)
		grade.Parent = workspace.CurrentCamera
		bloodMoonGrade = grade
		TweenService:Create(grade, TweenInfo.new(2), {
			TintColor = Color3.fromRGB(255, 176, 168),
			Contrast = 0.12,
			Saturation = 0.1,
		}):Play()
	elseif not on and bloodMoonGrade then
		bloodMoonGrade:Destroy()
		bloodMoonGrade = nil
	end
end

local killStreak = 0
local finalShown = false

local function onRoundEvent(kind: string, data: { [string]: any })
	if (kind == "Eliminated" or kind == "CutDown") and data.killer == player.DisplayName and not data.deathblow then
		-- Your own kill: a 斬 splash that counts the streak (deathblows get 忍殺 instead).
		killStreak += 1
		local words = { "Cut down", "Two cut down", "Three cut down", "Four cut down", "Five cut down" }
		CombatHUD.splash(Assets.UI.KanjiSlay, words[math.min(killStreak, #words)], CRIMSON, 0.9)
	end
	if kind == "MatchStart" then
		local character = player.Character
		killStreak = 0
		finalShown = false
		wasInMatch = character ~= nil and character:GetAttribute("InMatch") == true
		if not wasInMatch then
			return
		end
		CombatHUD.splash(Assets.UI.KanjiDuel, `{data.fighters} fighters enter. One leaves.`, CRIMSON, 1.6)
		CombatHUD.showControls()
		local omen = omenById(data.omen)
		if omen then
			task.delay(3, function()
				CombatHUD.splash(Assets.UI.Omens[omen.id], `Omen: {omen.name}  ·  {omen.text}`, GOLD, 2)
			end)
		end
	elseif kind == "Eliminated" then
		if data.killer then
			pushFeed(
				"",
				if data.deathblow then CRIMSON else GOLD,
				data.killer,
				data.victim,
				if data.deathblow then "executed" else nil
			)
		else
			pushFeed(`{data.victim} was swallowed by the mist`, PARCHMENT)
		end
	elseif kind == "CutDown" then
		if data.killer then
			pushFeed("", GOLD, data.killer, data.victim, "cut down · may rise")
		else
			pushFeed(`{data.victim} fell to the mist  ·  may rise`, PARCHMENT)
		end
	elseif kind == "Victory" then
		local fought = wasInMatch
		wasInMatch = false
		local character = player.Character
		local inLobby = character == nil or character:GetAttribute("InMatch") ~= true
		if not fought or (inLobby and not (data.winner and data.winner == character)) then
			-- Back in the lobby: just a line in the feed, not a full-screen banner.
			if data.name then
				pushFeed(`{data.name} won the royale`, GOLD)
			end
			return
		end
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

	state:GetAttributeChangedSignal("Omen"):Connect(refreshOmenGrade)

	-- Two left: the royale becomes a duel, and says so.
	state:GetAttributeChangedSignal("Alive"):Connect(function()
		if Round.phase() ~= "Match" or state:GetAttribute("Alive") ~= 2 or finalShown then
			return
		end
		finalShown = true
		local character = player.Character
		local fighting = character ~= nil
			and character:GetAttribute("InMatch") == true
			and character:GetAttribute("CombatState") ~= "Dead"
		if fighting then
			task.delay(1, function()
				CombatHUD.splash(Assets.UI.KanjiFinal, "Final duel", CRIMSON, 1.4)
			end)
		else
			pushFeed("Two remain: the final duel", CRIMSON)
		end
	end)

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
