--!strict
-- Duel presentation: the intro card as the first round counts down (both fighters' banner,
-- title, blade and rank, face to face), the score banner at the top of the screen (it
-- takes the royale banner's place while you duel), a line while you wait on a duel pad,
-- and the round, point and result splashes. Driven by the Duel remote and the DuelState / DuelBotAt
-- player attributes (see server/DuelService).

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Assets = require(ReplicatedStorage.Shared.Assets)
local Catalog = require(ReplicatedStorage.Shared.Catalog)
local Config = require(ReplicatedStorage.Shared.Config)
local Flair = require(ReplicatedStorage.Shared.Flair)
local Progression = require(ReplicatedStorage.Shared.Progression)
local Ranks = require(ReplicatedStorage.Shared.Ranks)
local CombatHUD = require(script.Parent.CombatHUD)
local LockOn = require(script.Parent.LockOn)
local UI = require(script.Parent.UI)

local player = Players.LocalPlayer

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

---------------------------------------------------------------------------------------
-- The intro card: two banners face to face while the first round counts down.

type Fighter = {
	name: string,
	title: Catalog.Item?,
	banner: string?,
	blade: string,
	bladeTint: Color3,
	rank: string?,
	rankColor: Color3?,
	crest: string?,
}

local function loadoutOf(who: Player): { [string]: string }
	local raw = who:GetAttribute("Loadout")
	if typeof(raw) ~= "string" then
		return {}
	end
	local ok, decoded = pcall(HttpService.JSONDecode, HttpService, raw)
	return if ok and typeof(decoded) == "table" then decoded else {}
end

local function tintOf(v: Vector3): Color3
	return Color3.new(math.min(v.X, 1), math.min(v.Y, 1), math.min(v.Z, 1))
end

local function fighterOf(who: Player?, model: Model?, fallbackName: string): Fighter
	if who then
		local loadout = loadoutOf(who)
		local bladeItem = Catalog.get(loadout.bladeSkin)
		local skinRef = if bladeItem and bladeItem.category == "bladeSkin" then bladeItem.ref else "Steel"
		local rank = Ranks.of(who:GetAttribute("Rating") or Config.Rating.Start)
		return {
			name = who.DisplayName,
			title = Catalog.get(loadout.title),
			banner = Flair.ref(loadout.banner),
			blade = if bladeItem then bladeItem.name else Progression.skin(skinRef).name,
			bladeTint = tintOf(Progression.skin(skinRef).tint),
			rank = rank.name,
			rankColor = rank.color,
			crest = (Assets.RankCrests :: any)[rank.tier],
		}
	end
	local skinRef = model and model:GetAttribute("Skin")
	local skin = Progression.skin(if typeof(skinRef) == "string" then skinRef else "Steel")
	return {
		name = fallbackName,
		title = nil,
		banner = nil,
		blade = skin.name,
		bladeTint = tintOf(skin.tint),
		rank = "Wandering swordsman",
		rankColor = UI.Parchment,
		crest = nil,
	}
end

local introCard: Frame? = nil
local introGui: ScreenGui? = nil

-- The card lives in its own ScreenGui with sibling layering, so the banner art stays under
-- the fighter's details.
local function introLayer(): ScreenGui
	if not introGui then
		introGui = UI.new("ScreenGui", {
			Name = "DuelIntro",
			ResetOnSpawn = false,
			IgnoreGuiInset = true,
			DisplayOrder = 6,
			ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		}, player:WaitForChild("PlayerGui"))
	end
	return introGui :: ScreenGui
end

local function half(parent: Instance, f: Fighter, left: boolean): Frame
	local look = Flair.banner(f.banner)
	local side = UI.new("Frame", {
		Name = if left then "You" else "Foe",
		AnchorPoint = Vector2.new(if left then 1 else 0, 0.5),
		Position = UDim2.new(0.5, if left then -46 else 46, 0.5, 0),
		Size = UDim2.fromOffset(300, 300),
		BackgroundColor3 = look.cloth,
		BackgroundTransparency = 0.05,
		BorderSizePixel = 0,
	}, parent)
	UI.stroke(side, look.edge, 3, 0)
	UI.new("UIGradient", {
		Rotation = 90,
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0),
			NumberSequenceKeypoint.new(0.8, 0.05),
			NumberSequenceKeypoint.new(1, 0.35),
		}),
	}, side)
	-- The banner's brushed character, large and faint behind the fighter's details.
	-- The cloth layer holds the banner art, under the fighter's details.
	local cloth = UI.new("Frame", {
		Name = "Cloth",
		Size = UDim2.new(1, 0, 1, -150), -- the part above the details strip
		BackgroundTransparency = 1,
		ZIndex = 1,
	}, side)
	local motif = UI.text({
		Name = "Motif",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.8, 0.9),
		Font = UI.Display,
		TextScaled = true,
		TextColor3 = look.ink,
		TextTransparency = 0.72,
		Text = look.motif,
	}, cloth)
	if Flair.decorateBanner(cloth, f.banner or "Plain") then
		motif.Visible = false -- part C's painted pattern and kanji replace the text motif
	end
	local shade = UI.new("Frame", {
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.new(1, 0, 0, 150),
		BackgroundColor3 = UI.Ink,
		BackgroundTransparency = 0.25,
		BorderSizePixel = 0,
		ZIndex = 5,
	}, side)
	if f.crest then
		UI.new("ImageLabel", {
			Position = UDim2.fromOffset(8, 8),
			Size = UDim2.fromOffset(64, 64),
			BackgroundTransparency = 1,
			Image = f.crest,
			ZIndex = 5,
		}, side)
	end
	UI.text({
		Name = "Title",
		Position = UDim2.fromOffset(10, 8),
		Size = UDim2.new(1, -20, 0, 22),
		Font = UI.Display,
		TextSize = 20,
		TextColor3 = if f.title then Flair.Rarity[f.title.rarity] or UI.Gold else UI.Parchment,
		TextTransparency = if f.title then 0 else 1,
		Text = if f.title then f.title.name else "",
	}, shade)
	UI.text({
		Name = "PlayerName",
		Position = UDim2.fromOffset(10, 30),
		Size = UDim2.new(1, -20, 0, 38),
		Font = UI.Display,
		TextSize = 34,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextStrokeTransparency = 0.6,
		Text = f.name,
	}, shade)
	UI.text({
		Name = "Rank",
		Position = UDim2.fromOffset(10, 70),
		Size = UDim2.new(1, -20, 0, 22),
		Font = UI.Bold,
		TextSize = 18,
		TextColor3 = f.rankColor or UI.Parchment,
		Text = f.rank or "",
	}, shade)
	local blade = UI.new("Frame", {
		Position = UDim2.fromOffset(10, 98),
		Size = UDim2.new(1, -20, 0, 40),
		BackgroundTransparency = 1,
	}, shade)
	UI.new("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		Padding = UDim.new(0, 6),
	}, blade)
	UI.new("ImageLabel", {
		Size = UDim2.fromOffset(40, 40),
		BackgroundTransparency = 1,
		Image = Assets.Icons.Katana,
		ImageColor3 = f.bladeTint,
	}, blade)
	UI.text({
		Name = "Blade",
		Size = UDim2.fromOffset(0, 30),
		AutomaticSize = Enum.AutomaticSize.X,
		TextSize = 17,
		Text = f.blade,
	}, blade)
	return side
end

local function showIntro(me: Fighter, foe: Fighter, holdFor: number)
	if introCard then
		introCard:Destroy()
	end
	local card = UI.new("Frame", {
		Name = "Intro",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.46),
		Size = UDim2.fromOffset(780, 330),
		BackgroundTransparency = 1,
	}, introLayer())
	local scale = UI.new("UIScale", {}, card)
	local view = workspace.CurrentCamera.ViewportSize
	scale.Scale = math.clamp(math.min((view.X - 24) / 780, (view.Y * 0.8) / 330), 0.4, 1)
	local left = half(card, me, true)
	local right = half(card, foe, false)
	UI.new("ImageLabel", {
		Name = "Kanji",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.45),
		Size = UDim2.fromOffset(110, 110),
		BackgroundTransparency = 1,
		Image = Assets.UI.KanjiDuel,
	}, card)
	UI.text({
		Name = "Info",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0.45, 60),
		Size = UDim2.fromOffset(110, 40),
		TextWrapped = true,
		TextSize = 14,
		TextStrokeTransparency = 0.5,
		Text = `First to {firstTo}{if rated then "\nranked" else ""}`,
	}, card)
	-- Slide in from the sides, hold through the countdown, fade.
	local leftHome, rightHome = left.Position, right.Position
	left.Position = leftHome - UDim2.fromOffset(240, 0)
	right.Position = rightHome + UDim2.fromOffset(240, 0)
	UI.tween(left, 0.35, { Position = leftHome })
	UI.tween(right, 0.35, { Position = rightHome })
	introCard = card
	task.delay(math.max(1.2, holdFor), function()
		if introCard ~= card then
			return
		end
		for _, item in card:GetDescendants() do
			if item:IsA("TextLabel") then
				UI.tween(item, 0.3, { TextTransparency = 1, TextStrokeTransparency = 1 })
			elseif item:IsA("ImageLabel") then
				UI.tween(item, 0.3, { ImageTransparency = 1 })
			elseif item:IsA("Frame") and item.BackgroundTransparency < 1 then
				UI.tween(item, 0.3, { BackgroundTransparency = 1 })
			elseif item:IsA("UIStroke") then
				UI.tween(item, 0.3, { Transparency = 1 })
			end
		end
		task.delay(0.35, function()
			card:Destroy()
			if introCard == card then
				introCard = nil
			end
		end)
	end)
end

-- Test hook (Studio): show the card against any model or player.
function DuelHUD.previewIntro(foe: Instance?, hold: number?)
	local foePlayer = if foe and foe:IsA("Player") then foe else nil
	local foeModel = if foe and foe:IsA("Model") then foe else nil
	showIntro(
		fighterOf(player, nil, player.DisplayName),
		fighterOf(foePlayer, foeModel, if foe then foe.Name else "Ronin"),
		hold or 3
	)
end

local function refreshScore()
	titleLabel.Text = `YOU   {mine}  —  {theirs}   {string.upper(opponent)}`
end

local function onDuel(kind: string, data: { [string]: any })
	if kind == "Start" then
		opponent = data.opponent or "?"
		firstTo = data.firstTo or 3
		rated = data.rated == true
		mine, theirs = 0, 0
		refreshScore()
		-- The intro card (on round 1, which follows at once with the foe's body) replaces
		-- the old "Duel against" splash.
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
		else
			local foeModel = if typeof(data.foe) == "Instance" and data.foe:IsA("Model") then data.foe else nil
			local foePlayer = foeModel and Players:GetPlayerFromCharacter(foeModel)
			showIntro(
				fighterOf(player, nil, player.DisplayName),
				fighterOf(foePlayer, foeModel, opponent),
				fightAt - now() - 0.4
			)
		end
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
		subLabel.Text = if t < fightAt
			then `Fight in {math.ceil(fightAt - t)}`
			else `First to {firstTo}{if rated then "  ·  ranked" else ""}`
	end
	local botAt = player:GetAttribute("DuelBotAt")
	local blocked = state == nil and onBusyPad()
	waitLabel.Visible = state == "Waiting" or blocked
	if blocked then
		waitLabel.Text = "A duel is under way on this terrace  ·  the pads open when it ends"
	elseif state == "Waiting" then
		local left = if typeof(botAt) == "number" then math.max(0, math.ceil(botAt - now())) else nil
		waitLabel.Text = if left
			then `Waiting for a challenger on the other pad  ·  a bot steps in in {left}`
			else "Waiting for a challenger on the other pad"
	end
end

function DuelHUD.start()
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
		Size = UDim2.fromOffset(560, 64),
		Visible = false,
	}, screen)
	titleLabel = UI.text({
		Name = "Score",
		Size = UDim2.new(1, 0, 0, 28),
		Font = UI.Display,
		TextSize = 26,
		TextStrokeTransparency = 0.6,
		Text = "",
	}, banner)
	UI.new("ImageLabel", {
		BackgroundTransparency = 1,
		Image = Assets.UI.PostureOrnament,
		ImageTransparency = 0.15,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0, 36),
		Size = UDim2.fromOffset(200, 22),
	}, banner)
	subLabel = UI.text({
		Name = "Sub",
		Position = UDim2.fromOffset(0, 46),
		Size = UDim2.new(1, 0, 0, 18),
		Font = UI.Display,
		TextSize = 16,
		TextTransparency = 0.3,
		TextStrokeTransparency = 0.6,
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
		TextStrokeTransparency = 0.5,
		Visible = false,
		Text = "",
	}, screen)

	local remote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("Duel") :: RemoteEvent
	remote.OnClientEvent:Connect(onDuel)
	RunService.Heartbeat:Connect(step)
end

return DuelHUD
