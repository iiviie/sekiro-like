--!strict
-- The lobby's menus, one centred panel at a time: How to fight, Trials, Profile (stats, most
-- used weapons, ranked season), Rewards (daily streak) and Settings live here; the Store,
-- the Locker and the Pass are registered from their own modules (Panels.register) and open
-- in a large window that takes most of the screen (the lobby HUD steps aside under it).
-- Every panel redraws from player attributes, so it is always current. What the player
-- owns, what's unlocked and what day it is come from the server (attributes), never from
-- client-side rules or clocks.

local GuiService = game:GetService("GuiService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Assets = require(ReplicatedStorage.Shared.Assets)
local Config = require(ReplicatedStorage.Shared.Config)
local EconomyConfig = require(ReplicatedStorage.Shared.EconomyConfig)
local Progression = require(ReplicatedStorage.Shared.Progression)
local Ranks = require(ReplicatedStorage.Shared.Ranks)
local Season = require(ReplicatedStorage.Shared.Season)
local Text = require(ReplicatedStorage.Shared.Text)
local Weapons = require(ReplicatedStorage.Shared.Weapons)
local InputNames = require(script.Parent.InputNames)
local Toasts = require(script.Parent.Toasts)
local UI = require(script.Parent.UI)

local player = Players.LocalPlayer

local Panels = {}

local screen: ScreenGui
local window: Frame
local titleLabel: TextLabel
local body: Frame
local current: string? = nil
local lobbyAction: RemoteEvent
local gamepad: () -> boolean
local selectIn: (previous: { name: string, parent: string }?) -> ()

local function attr(name: string, default: any): any
	local value = player:GetAttribute(name)
	return if value == nil then default else value
end

-- The server's UTC day and when it ends (Economy publishes both on ReplicatedStorage).
local function serverDay(): number
	return ReplicatedStorage:GetAttribute("ServerDay") or 0
end

local function secondsLeftToday(): number
	local endsAt = ReplicatedStorage:GetAttribute("DayEndsAt") or 0
	return math.max(0, endsAt - workspace:GetServerTimeNow())
end

local function clear()
	for _, child in body:GetChildren() do
		child:Destroy()
	end
end

-- A small caps section label with a gold rule fading out to the right.
local function sectionTitle(text: string, y: number, parent: Instance?)
	local into = parent or body
	UI.label("caption", {
		Position = UDim2.fromOffset(0, y),
		Size = UDim2.new(1, 0, 0, 20),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = UI.Theme.GoldHi,
		TextSize = 15,
		Text = text,
	}, into)
	UI.divider(into, { Position = UDim2.fromOffset(0, y + 20), Size = UDim2.new(1, 0, 0, 6), ornament = "none" })
end

-- A stat chip on an inset plate: the label in small caps, the value in the number face.
local function statBox(parent: Instance, label: string, value: string, position: UDim2, size: UDim2)
	local box = UI.panel({ Position = position, Size = size, material = "inset" }, parent)
	UI.label("caption", {
		Position = UDim2.fromOffset(0, 6),
		Size = UDim2.new(1, 0, 0, 18),
		Text = label,
	}, box)
	UI.label("number", {
		Position = UDim2.fromOffset(0, 24),
		Size = UDim2.new(1, 0, 1, -28),
		TextSize = 26,
		Text = value,
	}, box)
end

---------------------------------------------------------------------------------------

-- How to fight: the rules in the order a new player needs them, in the player's own input
-- names (keyboard, gamepad or touch: InputNames).
local function guideEntries(): { { string } }
	local k = InputNames.get()
	local scheme = InputNames.scheme()
	local touch = scheme == "Touch"
	-- "Dodge (Q)" on keys and pads; just "Dodge" on touch, where the button carries the word.
	local function named(word: string, input: string): string
		return if touch then word else `{word} ({input})`
	end
	-- A heading with its input, unless the input is the word itself (touch's Deflect button).
	local function head(word: string, input: string): string
		return if word == input then word else `{word}  ·  {input}`
	end
	local tap = if touch then "tap" else "press"
	local jumpKey = if touch then "" else ` ({k.jump})`
	local feint = if touch then "Tap Deflect" else `Press {k.block}`
	local morphs = `{named("Thrust", k.thrust)} or {named("Sweep", k.sweep)}`
	local lockKey = if scheme == "Gamepad" then "R3" else "R (or the middle mouse button)"
	local lock = if touch
		then "On touch the camera locks on to the nearest enemy by itself; Lock lets go for a free look."
		else `{lockKey} locks the camera on the nearest enemy, so they never slip out of view behind you. Press it again to let go.`
	return {
		{
			head("Deflect", k.block),
			`Tap {k.block} just before the enemy's blade lands. Watch for the white glint at their sword tip: {tap} as it flashes. A deflect costs you nothing and fills THEIR posture; a perfect one (tighter timing) fills it more. The first two hits of a string are only knocked aside: keep deflecting. Deflect the third hit (or a thrust) and they stagger: slash at once for a Riposte.`,
		},
		{
			`Guard  ·  hold {k.block}`,
			`Holding {k.block} blocks damage but fills YOUR posture. Don't turtle: tap to deflect instead. Re-pressing {k.block} right after letting go opens the window late: tap once per glint.`,
		},
		{
			"Posture",
			"The bar in the middle. When it's full you're Broken: open to a deathblow, which takes a big chunk of vitality and kills a wounded fighter. Posture drains back once you stop taking hits.",
		},
		{
			"Red 危 = perilous",
			`Can't be guarded. A thrust: deflect it, or dash INTO it with {named("Dodge", k.dodge)} for a Mikiri Counter. A sweep: jump over it{jumpKey}; dodging doesn't help. Either way, reading it wrecks the attacker's posture.`,
		},
		{
			head("Attacking", k.attack),
			`Slash on the beat for a three-hit string; it speeds up while it keeps landing. Pause before the third for a slow overhead that beats early deflects. {morphs} late in a string turns the ender perilous. {feint} mid-swing to feint.`,
		},
		{
			"Survive",
			`{named("Dodge", k.dodge)}: dash into thrusts; jump over sweeps. {named("Heal", k.heal)} sips your gourd (3 per life): only when you're safe. Outnumbered by two or more? You gain Resolve: faster posture and shorter stun.`,
		},
		{ if touch then "Lock on" else head("Lock on", k.lock), lock },
		{
			"Other fights",
			"Duels: stand on a gold duel pad east or west of the spawn plaza for a first-to-3 duel; a bot steps up after 8 s. Boss trials: cross the rope bridge to the back islet and step on the shrine pad. Start with the Shikigami: it teaches perilous attacks step by step.",
		},
	}
end

-- How to fight reads as a washi scroll: ink headings and body text on paper; the perilous
-- entry shows the brushed 危 as an image.
local function guidePanel()
	local scroll = UI.panel({ Name = "Scroll", material = "washi", Size = UDim2.fromScale(1, 1) }, body)
	UI.grain(scroll, 0.88)
	local list = UI.new("ScrollingFrame", {
		Position = UDim2.fromOffset(18, 14),
		Size = UDim2.new(1, -30, 1, -24),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 5,
		ScrollBarImageColor3 = UI.Theme.Bronze,
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(),
	}, scroll)
	UI.new("UIListLayout", { Padding = UDim.new(0, 10), SortOrder = Enum.SortOrder.LayoutOrder }, list)
	UI.new("UIPadding", { PaddingRight = UDim.new(0, 12), PaddingBottom = UDim.new(0, 8) }, list)
	local guide = guideEntries()
	for i, entry in guide do
		local card = UI.new("Frame", {
			Size = UDim2.fromScale(1, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			LayoutOrder = i,
			BackgroundTransparency = 1,
		}, list)
		UI.new("UIListLayout", { Padding = UDim.new(0, 2), SortOrder = Enum.SortOrder.LayoutOrder }, card)
		local perilous = string.find(entry[1], "危") ~= nil
		local headRow = UI.new("Frame", {
			Size = UDim2.new(1, 0, 0, 32),
			LayoutOrder = 1,
			BackgroundTransparency = 1,
		}, card)
		local x = 0
		if perilous then
			UI.kanji("KanjiPeril", {
				Position = UDim2.fromOffset(-4, -4),
				Size = UDim2.fromOffset(40, 40),
				ImageColor3 = UI.Theme.LacquerRed,
			}, headRow)
			x = 40
		end
		UI.text({
			Position = UDim2.fromOffset(x, 0),
			Size = UDim2.new(1, -x, 1, 0),
			TextXAlignment = Enum.TextXAlignment.Left,
			FontFace = UI.Fonts.Display,
			TextSize = 22,
			TextColor3 = if perilous then UI.Theme.LacquerRed else UI.Theme.Ink,
			Text = if perilous then "Red = perilous" else entry[1],
		}, headRow)
		UI.text({
			Size = UDim2.fromScale(1, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			LayoutOrder = 2,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextWrapped = true,
			TextSize = 17,
			TextColor3 = UI.Theme.Ink,
			Text = entry[2],
		}, card)
		if i < #guide then
			UI.divider(card, { LayoutOrder = 3, Size = UDim2.new(1, 0, 0, 12), color = UI.Theme.Bronze })
		end
	end
	UI.text({
		Size = UDim2.new(1, 0, 0, 44),
		LayoutOrder = 99,
		TextWrapped = true,
		TextSize = 16,
		TextColor3 = UI.Theme.Bronze,
		FontFace = UI.Fonts.Label,
		Text = "Practise on the Deflect Trainer in the dojo (left wing): it tells you how many milliseconds early you pressed.",
	}, list)
end

-- Daily Trials: three goals a day that pay out the moment they're done.
local function trialsPanel()
	local progress = {}
	local ok, decoded = pcall(HttpService.JSONDecode, HttpService, attr("TrialProgress", "{}"))
	if ok and typeof(decoded) == "table" then
		progress = decoded
	end
	-- Today's trials as the server picked them; progress counts only if it's from today.
	local fresh = attr("TrialDay", 0) == serverDay()
	local today = string.split(attr("Trials", ""), ",")
	for i, id in today do
		local trial = Progression.trial(id)
		if trial then
			local value = if fresh then math.min(progress[id] or 0, trial.goal) else 0
			local done = value >= trial.goal
			local card = UI.panel({
				Name = id,
				Position = UDim2.fromOffset(0, (i - 1) * 86),
				Size = UDim2.new(1, -4, 0, 78),
				material = "inset",
				tint = if done then UI.Theme.JadeBtn:Lerp(UI.Theme.Plate, 0.5) else UI.Theme.Plate,
			}, body)
			UI.new("ImageLabel", {
				Position = UDim2.fromOffset(6, 4),
				Size = UDim2.fromOffset(70, 70),
				BackgroundTransparency = 1,
				Image = Assets.Icons.Trials,
				ImageTransparency = if done then 0.35 else 0,
			}, card)
			if done then
				UI.badge(card, "done", 28).Position = UDim2.fromOffset(62, 58)
			end
			UI.text({
				Position = UDim2.fromOffset(88, 8),
				Size = UDim2.new(1, -250, 0, 28),
				TextXAlignment = Enum.TextXAlignment.Left,
				FontFace = UI.Fonts.Display,
				TextSize = 21,
				TextTruncate = Enum.TextTruncate.AtEnd,
				TextColor3 = if done then UI.Theme.Dim else UI.Theme.Bone,
				Text = trial.text,
			}, card)
			UI.progress({
				Position = UDim2.fromOffset(88, 44),
				Size = UDim2.new(1, -250, 0, 22),
				value = value,
				max = trial.goal,
				tone = "crimson",
				doneTone = "jade",
				textWidth = 70,
				format = function(v: number, m: number): string
					return if v >= m then "Done" else `{v} / {m}`
				end,
			}, card)
			local reward = UI.new("Frame", {
				AnchorPoint = Vector2.new(1, 0.5),
				Position = UDim2.new(1, -14, 0.5, 0),
				Size = UDim2.fromOffset(130, 62),
				BackgroundTransparency = 1,
			}, card)
			UI.price({
				currency = "coins",
				amount = trial.coins,
				Position = UDim2.fromOffset(10, 2),
				Size = UDim2.new(1, -10, 0, 30),
			}, reward)
			UI.label("number", {
				Position = UDim2.fromOffset(0, 36),
				Size = UDim2.new(1, 0, 0, 22),
				TextXAlignment = Enum.TextXAlignment.Right,
				TextSize = 16,
				TextColor3 = UI.Theme.GoldHi,
				Text = `+{trial.xp} XP`,
			}, reward)
		end
	end
	local secondsLeft = secondsLeftToday()
	UI.text({
		Position = UDim2.fromOffset(0, 256),
		Size = UDim2.new(1, 0, 0, 20),
		TextSize = 16,
		TextColor3 = UI.Theme.Dim,
		Text = `New trials in {math.floor(secondsLeft / 3600)}h {math.floor(secondsLeft % 3600 / 60)}m  ·  rewards pay out the moment a trial is done`,
	}, body)
end

-- The Season card's bottom line: the soft reset this player just had (for two weeks after a
-- season ends, from the server's RankedReset), else where the season end will ease the
-- rating to (EconomyConfig Ranked.SoftReset; the server applies it).
local function rankedNote(rating: number, rank: Ranks.Rank): string
	local ok, reset = pcall(function()
		return HttpService:JSONDecode(attr("RankedReset", ""))
	end)
	if ok and typeof(reset) == "table" and os.time() - (tonumber(reset.t) or 0) < 14 * 86400 then
		return `{Season.label(reset.season)} ended  ·  rating {reset.from} → {reset.to}`
	end
	local rule = EconomyConfig.Ranked.SoftReset
	local eased = math.floor(rule.Toward + (rating - rule.Toward) * rule.Keep + 0.5)
	return if eased == rating
		then `{rank.floor} → {rank.ceiling}  ·  vs players, not bots`
		else `{rank.floor} → {rank.ceiling}  ·  season end: {eased}`
end

local function profilePanel()
	local wins, losses = attr("Wins", 0), attr("Losses", 0)
	local played = attr("Played", 0)
	local ratio = if losses > 0 then wins / losses else wins
	sectionTitle(player.DisplayName, 0)
	local stats = {
		{ "Wins", tostring(wins) },
		{ "Losses", tostring(losses) },
		{ "W/L", string.format("%.2f", ratio) },
		{ "Cut down", tostring(attr("Kills", 0)) },
		{ "Deathblows", tostring(attr("Deathblows", 0)) },
		{ "Played", tostring(played) },
	}
	for i, stat in stats do
		local column = (i - 1) % 3
		local row = (i - 1) // 3
		statBox(body, stat[1], stat[2], UDim2.new(column / 3, 4, 0, 34 + row * 70), UDim2.new(1 / 3, -8, 0, 62))
	end

	UI.label("caption", {
		Position = UDim2.fromOffset(0, 184),
		Size = UDim2.new(0.5, -8, 0, 20),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = UI.Theme.GoldHi,
		TextSize = 15,
		Text = "Most used weapons",
	}, body)
	local ok, uses = pcall(function()
		return HttpService:JSONDecode(attr("WeaponUses", "{}"))
	end)
	local sorted = {}
	for id, count in if ok and typeof(uses) == "table" then uses else {} do
		table.insert(sorted, { id = id, count = count })
	end
	table.sort(sorted, function(a, b)
		return a.count > b.count
	end)
	for i = 1, 3 do
		local entry = sorted[i]
		local games = if entry then Text.count(entry.count, "game") else ""
		UI.text({
			Position = UDim2.fromOffset(0, 184 + i * 23),
			Size = UDim2.new(0.5, -8, 0, 22),
			TextXAlignment = Enum.TextXAlignment.Left,
			TextSize = 17,
			TextColor3 = if entry then UI.Theme.Bone else UI.Theme.Ash,
			RichText = true,
			Text = if entry
				then `<font color="#E8C77A">{i}</font>   {Weapons.get(entry.id).name}  <font color="#A89F92">·  {games}</font>`
				else `{i}   —`,
		}, body)
	end

	-- Ranked season: tier, rating and progress through the division.
	local rating = attr("Rating", Config.Rating.Start)
	local rank = Ranks.of(rating)
	local season = UI.panel({
		Name = "Season",
		Position = UDim2.new(0.5, 4, 0, 184),
		Size = UDim2.new(0.5, -4, 0, 92),
		material = "inset",
	}, body)
	UI.new("ImageLabel", {
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 2, 0.5, 0),
		Size = UDim2.fromOffset(84, 84),
		BackgroundTransparency = 1,
		Image = Assets.RankCrests[rank.tier] or "",
		ZIndex = 2,
	}, season)
	UI.label("caption", {
		Position = UDim2.fromOffset(92, 8),
		Size = UDim2.new(1, -104, 0, 18),
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = `Season 1  ·  peak {attr("PeakRating", rating)}`,
	}, season)
	UI.text({
		Position = UDim2.fromOffset(92, 26),
		Size = UDim2.new(1, -104, 0, 30),
		TextXAlignment = Enum.TextXAlignment.Left,
		FontFace = UI.Fonts.Display,
		TextSize = 24,
		TextColor3 = rank.color,
		Text = rank.name,
	}, season)
	UI.label("number", {
		Position = UDim2.fromOffset(92, 26),
		Size = UDim2.new(1, -104, 0, 30),
		TextXAlignment = Enum.TextXAlignment.Right,
		TextSize = 20,
		Text = `{rating}`,
	}, season)
	local bar = UI.new("Frame", {
		Position = UDim2.fromOffset(92, 60),
		Size = UDim2.new(1, -104, 0, 6),
		BackgroundColor3 = UI.Ink,
		BorderSizePixel = 0,
	}, season)
	UI.corner(bar, UDim.new(1, 0))
	UI.stroke(bar, UI.Bronze, 1, 0)
	local fill = UI.new("Frame", {
		Size = UDim2.fromScale(math.clamp((rating - rank.floor) / (rank.ceiling - rank.floor), 0, 1), 1),
		BackgroundColor3 = rank.color,
		BorderSizePixel = 0,
	}, bar)
	UI.corner(fill, UDim.new(1, 0))
	UI.text({
		Position = UDim2.fromOffset(92, 68),
		Size = UDim2.new(1, -104, 0, 20),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextSize = 16,
		TextColor3 = UI.Theme.Ash,
		Text = rankedNote(rating, rank),
		TextTruncate = Enum.TextTruncate.AtEnd,
	}, season)
end

local function rewardsPanel()
	-- The server says which day the next claim pays (a missed day pauses the streak).
	local claimedToday = attr("DailyClaimed", false) == true
	local nextDay = attr("DailyNext", 1)
	local daily = EconomyConfig.Daily
	sectionTitle("Daily reward  ·  miss a day and your streak just waits", 0)
	for day, coins in daily.Coins do
		local done = day < nextDay or (claimedToday and day == nextDay)
		local isNext = day == nextDay and not claimedToday
		local last = day == #daily.Coins
		local card = UI.panel({
			Name = `Day{day}`,
			Position = UDim2.new((day - 1) / 7, 3, 0, 34),
			Size = UDim2.new(1 / 7, -6, 0, 114),
			material = "inset",
			tint = if isNext
				then UI.Theme.JadeBtn
				elseif last then UI.Theme.LacquerHi:Lerp(UI.Theme.Gold, 0.18)
				else UI.Theme.Plate,
		}, body)
		if isNext then
			UI.new("UIStroke", { Name = "_Pulse", Color = UI.Theme.JadeText, Thickness = 2 }, card)
			if not UI.reducedMotion() then
				UI.play(card:FindFirstChild("_Pulse") :: UIStroke, UI.Motion.Pulse, { Transparency = 0.7 })
			end
		end
		UI.label("caption", {
			Position = UDim2.fromOffset(0, 6),
			Size = UDim2.new(1, 0, 0, 18),
			TextColor3 = if isNext then UI.Theme.Bone else UI.Theme.Dim,
			Text = `Day {day}`,
		}, card)
		UI.new("ImageLabel", {
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.new(0.5, 0, 0, 26),
			Size = UDim2.fromOffset(40, 40),
			BackgroundTransparency = 1,
			Image = if last then Assets.Icons.Rewards else Assets.Icons.Coin,
			ImageTransparency = if done then 0.5 else 0,
		}, card)
		UI.label("number", {
			Position = UDim2.fromOffset(0, 66),
			Size = UDim2.new(1, 0, 0, 22),
			TextSize = 18,
			TextColor3 = if done then UI.Theme.Ash else UI.Theme.GoldHi,
			Text = UI.number(coins),
		}, card)
		if last then
			UI.label("number", {
				Position = UDim2.fromOffset(0, 86),
				Size = UDim2.new(1, 0, 0, 20),
				TextSize = 15,
				TextColor3 = if done then UI.Theme.Ash else UI.Theme.JadeText,
				Text = `+{daily.LastDayGems} gems`,
			}, card)
		end
		if done then
			UI.badge(card, "done", 26).Position = UDim2.new(1, -14, 0, 14)
		end
	end
	local claim = UI.button({
		Name = "Claim",
		variant = if claimedToday then "disabled" else "reward",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 166),
		Size = UDim2.fromOffset(260, UI.Touch),
		FontFace = UI.Fonts.Display,
		TextSize = 24,
		Text = if claimedToday then "Come back tomorrow" else "Claim",
		sound = if claimedToday then false else "Press",
	}, body)
	if claimedToday then
		claim:SetAttribute("Quiet", true)
	end
	claim.Activated:Connect(function()
		if not claimedToday then
			UI.sound("Claim")
			-- Say what it paid once the server has granted it.
			local nextCoins = daily.Coins[nextDay] or 0
			player:GetAttributeChangedSignal("LastDaily"):Once(function()
				Toasts.notice(`Day {nextDay} reward claimed  ·  +{nextCoins} coins`, UI.Gold)
			end)
			lobbyAction:FireServer("ClaimDaily")
		end
	end)
end

-- Settings the player picked, sent to the server (LobbyAction "Settings") half a second after
-- the last pick, so a run of taps is one request. The server saves them in the profile and
-- client/init applies them on the next join.
local SAVE_DELAY = 0.5
local unsaved: { [string]: any } = {}
local saveQueued = false

local function saveSetting(key: string, value: any)
	player:SetAttribute(key, value) -- read by the effects code at once
	unsaved[key] = value
	if saveQueued then
		return
	end
	saveQueued = true
	task.delay(SAVE_DELAY, function()
		saveQueued = false
		local changes = unsaved
		unsaved = {}
		if lobbyAction and next(changes) ~= nil then
			lobbyAction:FireServer("Settings", changes)
		end
	end)
end

-- Settings rows: a 46 px control, 60 (UI.Touch) on a touch screen, one row every ROW_GAP more.
local SCROLLBAR = 5
local ROW_GAP = 8

local function rowHeight(): number
	return if UI.touchSized() then UI.Touch else 46
end

-- One settings row: the label left, a segmented control right (ink track, crimson thumb),
-- kept clear of the scrollbar.
local function segmented(
	parent: Instance,
	y: number,
	key: string,
	label: string,
	options: { { text: string, value: any } },
	selected: any,
	onPick: (any) -> ()
)
	local height = rowHeight()
	local width = 86 * #options
	local inset = SCROLLBAR + 6
	UI.label("label", {
		Position = UDim2.fromOffset(0, y),
		Size = UDim2.new(1, -(width + inset + 8), 0, height + 4),
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = label,
	}, parent)
	local track = UI.new("Frame", {
		Name = key,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -inset, 0, y + 2),
		Size = UDim2.fromOffset(width, height),
		BackgroundColor3 = UI.Ink,
		BorderSizePixel = 0,
	}, parent)
	UI.corner(track, UDim.new(0, 6))
	UI.stroke(track, UI.Theme.Bronze, 1, 0)
	for i, option in options do
		local on = option.value == selected
		local seg = UI.new("TextButton", {
			Name = option.text,
			Position = UDim2.new((i - 1) / #options, 3, 0, 3),
			Size = UDim2.new(1 / #options, -6, 1, -6),
			BackgroundColor3 = if on then UI.Theme.CrimsonBtn else UI.Ink,
			BackgroundTransparency = if on then 0 else 1,
			AutoButtonColor = false,
			FontFace = if on then UI.Fonts.Number else UI.Fonts.Label,
			TextSize = 16,
			TextColor3 = if on then UI.Theme.Bone else UI.Theme.Dim,
			Text = option.text,
		}, track)
		UI.corner(seg, UDim.new(0, 4))
		UI.juice(seg, { sound = "Tab" })
		seg.Activated:Connect(function()
			if not on then
				onPick(option.value)
				Panels.redraw()
			end
		end)
	end
end

local function settingsPanel()
	-- `offByDefault`: the attribute reads as off until it's switched on (the rest read as on).
	local options: { { key: string, label: string, offByDefault: boolean? } } = {
		{ key = "SettingCameraShake", label = "Camera shake" },
		{ key = "SettingHitstop", label = "Hit freeze" },
		{ key = "SettingControlsHint", label = "Show controls reminder" },
		{ key = "SettingReducedEffects", label = "Fewer particles", offByDefault = true },
	}
	local pitch = rowHeight() + ROW_GAP
	local function rowY(i: number): number
		return 30 + i * pitch
	end
	local list = UI.new("ScrollingFrame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = SCROLLBAR,
		ScrollBarImageColor3 = UI.Theme.Gold,
		CanvasSize = UDim2.fromOffset(0, rowY(#options + 5) + 4),
	}, body)
	-- The window is already titled Settings: say where they live (a profile that didn't load
	-- can't save them).
	sectionTitle(
		if player:GetAttribute("DataFailed") == true then "Not saved this time" else "Saved with your progress",
		0,
		list
	)
	for i, option in options do
		local value = player:GetAttribute(option.key)
		local on = if option.offByDefault then value == true else value ~= false
		segmented(
			list,
			rowY(i - 1),
			option.key,
			option.label,
			{
				{ text = "Off", value = false },
				{ text = "On", value = true },
			},
			on,
			function(v)
				saveSetting(option.key, v)
			end
		)
	end
	-- Reduce motion follows the Roblox setting until it's picked here.
	segmented(
		list,
		rowY(#options),
		"SettingReduceMotion",
		"Reduce motion",
		{
			{ text = "Off", value = false },
			{ text = "On", value = true },
		},
		UI.reducedMotion(),
		function(v)
			saveSetting("SettingReduceMotion", v)
		end
	)
	local volume = player:GetAttribute("SettingUIVolume")
	segmented(
		list,
		rowY(#options + 1),
		"SettingUIVolume",
		"Menu sounds",
		{
			{ text = "Off", value = 0 },
			{ text = "Low", value = 0.5 },
			{ text = "Full", value = 1 },
		},
		if typeof(volume) == "number" then volume else 1,
		function(v)
			saveSetting("SettingUIVolume", v)
			UI.sound("Press")
		end
	)
	-- Sound levels (client/Audio's groups): everything, music and stingers, effects and ambience.
	local levels = {
		{ key = "SettingMasterVolume", label = "Sound" },
		{ key = "SettingMusicVolume", label = "Music" },
		{ key = "SettingSFXVolume", label = "Effects" },
	}
	for i, level in levels do
		local stored = player:GetAttribute(level.key)
		segmented(
			list,
			rowY(#options + 1 + i),
			level.key,
			level.label,
			{
				{ text = "Off", value = 0 },
				{ text = "Low", value = 0.35 },
				{ text = "Mid", value = 0.7 },
				{ text = "Full", value = 1 },
			},
			if typeof(stored) == "number" then stored else 1,
			function(v)
				saveSetting(level.key, v)
				UI.sound("Press")
			end
		)
	end
end

type Def = { title: string, build: (body: Frame) -> (), large: boolean? }

local panels: { [string]: Def } = {
	Guide = { title = "How to fight", build = guidePanel },
	Trials = { title = "Daily Trials", build = trialsPanel },
	Profile = { title = "Profile", build = profilePanel },
	Rewards = { title = "Rewards", build = rewardsPanel },
	Settings = { title = "Settings", build = settingsPanel },
}

-- Adds (or replaces) a panel: `build(body)` fills the body frame on every redraw. A `large`
-- panel (Store, Locker, Pass) opens in the big window over the HUD.
function Panels.register(id: string, def: Def)
	panels[id] = def
end

function Panels.has(id: string): boolean
	return panels[id] ~= nil
end

local drawn: string? = nil -- the panel body currently holds
local refit: () -> () = function() end

-- Forget the body's scroll position, so the next redraw starts at the top (a new tab).
function Panels.resetScroll()
	drawn = nil
end

function Panels.redraw()
	if not current then
		return
	end
	local def = panels[current :: string]
	if not def then
		return
	end
	-- Panels redraw on every attribute change (coins, XP, queue...): keep a scrolled list
	-- where it was instead of jumping back to the top.
	local scroll = Vector2.zero
	local old = body:FindFirstChildWhichIsA("ScrollingFrame", true)
	if old and drawn == current then
		scroll = old.CanvasPosition
	end
	clear()
	local extra = window:FindFirstChild("HeaderExtra")
	if extra then
		extra:Destroy()
	end
	drawn = current
	titleLabel.Text = def.title
	-- A gamepad selection inside the window survives the redraw (the same button, rebuilt).
	local selected = GuiService.SelectedObject
	local keep = if selected
			and selected:IsDescendantOf(window)
			and selected.Parent
		then { name = selected.Name, parent = selected.Parent.Name }
		else nil
	local ok, err = pcall(def.build, body)
	if keep then
		task.defer(selectIn, keep)
	end
	if not ok then
		warn(`[Panels] {current} failed to draw: {err}`)
	end
	local list = body:FindFirstChildWhichIsA("ScrollingFrame", true)
	if list and scroll ~= Vector2.zero then
		task.defer(function()
			if list.Parent then
				list.CanvasPosition = scroll
			end
		end)
	end
end

local openedCallbacks: { () -> () } = {}

-- Gamepad menus (Roblox's selection): which input the player is using, and picking a
-- button in the window.
function gamepad(): boolean
	return InputNames.scheme() == "Gamepad"
end

-- Selects `name` under a parent called `parentName` in the window if it's still there (a
-- redraw rebuilt it), else the first tab, else the first button in the body, else the close.
function selectIn(previous: { name: string, parent: string }?)
	local pick: GuiObject? = nil
	local tabs: GuiObject? = nil
	local first: GuiObject? = nil
	for _, d in window:GetDescendants() do
		if d:IsA("GuiButton") and d.Selectable and d.Visible then
			local parent = d.Parent
			if previous and d.Name == previous.name and parent and parent.Name == previous.parent then
				pick = d
				break
			end
			if not tabs and parent and parent.Name == "Tabs" then
				tabs = d
			end
			if not first and d:IsDescendantOf(body) then
				first = d
			end
		end
	end
	local close = window:FindFirstChild("Close", true)
	GuiService.SelectedObject = pick or tabs or first or (if close and close:IsA("GuiObject") then close else nil)
end
local changeCallbacks: { (string?) -> () } = {}

-- Runs `callback` whenever a panel opens (the boss picker closes itself so the two never
-- stack).
function Panels.onOpen(callback: () -> ())
	table.insert(openedCallbacks, callback)
end

-- Runs `callback(id or nil)` whenever the open panel changes or all close.
function Panels.onChange(callback: (string?) -> ())
	table.insert(changeCallbacks, callback)
end

local function changed()
	for _, callback in changeCallbacks do
		task.spawn(callback, current)
	end
end

function Panels.isOpen(): boolean
	return current ~= nil
end

function Panels.current(): string?
	return current
end

-- Whether the open panel is a large one (the lobby HUD hides under it).
function Panels.isLarge(): boolean
	local def = current and panels[current :: string]
	return def ~= nil and def.large == true
end

function Panels.window(): Frame
	return window
end

-- A strip in the title bar, right of the title and left of the close button, cleared on
-- every redraw (the Store and the Locker show balances there). Right-aligned list layout.
function Panels.header(): Frame
	local strip = UI.new("Frame", {
		Name = "HeaderExtra",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -76, 0, 16),
		Size = UDim2.new(1, -330, 0, 40),
		BackgroundTransparency = 1,
	}, window)
	UI.new("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		HorizontalAlignment = Enum.HorizontalAlignment.Right,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		Padding = UDim.new(0, 8),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, strip)
	return strip
end

function Panels.open(id: string)
	if not panels[id] then
		return
	end
	local was = current
	current = id
	if was ~= id then
		drawn = nil
	end
	if not window.Visible then
		UI.openMotion(window)
		UI.sound("Confirm")
	end
	window.Visible = true
	refit()
	Panels.redraw()
	-- A gamepad gets something selected straight away: the first tab, else the first button.
	if gamepad() then
		task.defer(function()
			if current == id then
				selectIn(nil)
			end
		end)
	end
	for _, callback in openedCallbacks do
		task.spawn(callback)
	end
	changed()
end

function Panels.closeAll()
	local was = current
	current = nil
	if window then
		if window.Visible then
			UI.sound("Cancel")
		end
		local selected = GuiService.SelectedObject
		if selected and selected:IsDescendantOf(window) then
			GuiService.SelectedObject = nil
		end
		window.Visible = false
		local sheet = window:FindFirstChild("Sheet")
		if sheet then
			sheet:Destroy()
		end
	end
	if was then
		changed()
	end
end

function Panels.toggle(id: string)
	if current == id then
		Panels.closeAll()
	else
		Panels.open(id)
	end
end

-- Normal panels: 660 x 372, sitting over the PLAY button and nav bar and shrinking on short
-- screens. Large panels: 820 x 420 in the middle of the screen, as big as fits (on a phone
-- in landscape that's about 0.8, so 60 px buttons stay over 45 px).
local NORMAL = Vector2.new(660, 372)
local LARGE = Vector2.new(820, 420)

function Panels.start(remote: RemoteEvent)
	lobbyAction = remote
	screen = UI.new("ScreenGui", {
		Name = "LobbyPanels",
		ResetOnSpawn = false,
		DisplayOrder = 6,
		ScreenInsets = Enum.ScreenInsets.CoreUISafeInsets,
	})
	window = UI.panel({
		Name = "Window",
		material = "lacquer",
		sliceScale = 1,
		Size = UDim2.fromOffset(NORMAL.X, NORMAL.Y),
		Visible = false,
		Active = true,
	}, screen)
	UI.grain(window, 0.9)
	local scale = UI.new("UIScale", { Name = "Fit" }, window)
	local camera = workspace.CurrentCamera
	refit = function()
		local large = Panels.isLarge()
		local dims = if large then LARGE else NORMAL
		-- Desktop and tablet (the large window fits at scale 1): taller, up to 600, so the
		-- Store's packs, the Locker's rows and the Pass's bounties aren't cut in half. A phone
		-- keeps 420 (its scale stays >= 0.8).
		if large then
			local area = screen.AbsoluteSize
			if area.X < 1 then
				area = camera.ViewportSize
			end
			if math.min((area.X - 16) / LARGE.X, (area.Y - 12) / LARGE.Y) >= 1 then
				dims = Vector2.new(LARGE.X, math.clamp(area.Y - 80, LARGE.Y, 600))
			end
		end
		window.Size = UDim2.fromOffset(dims.X, dims.Y)
		-- On a phone the lobby nav is a rail on the left, so normal panels centre too, clear
		-- of the rail.
		local compact = UI.compact(camera.ViewportSize)
		if large or compact then
			local area = screen.AbsoluteSize
			if area.X < 1 then
				area = camera.ViewportSize
			end
			local side = if large then 16 else 200
			window.AnchorPoint = Vector2.new(0.5, 0.5)
			window.Position = UDim2.fromScale(0.5, 0.5)
			scale.Scale = math.clamp(math.min((area.X - side) / dims.X, (area.Y - 12) / dims.Y), 0.4, 1)
		else
			local size = camera.ViewportSize
			local reserve = math.floor(200 * UI.lobbyScale(size))
			window.AnchorPoint = Vector2.new(0.5, 1)
			window.Position = UDim2.new(0.5, 0, 1, -reserve)
			scale.Scale = math.clamp((size.Y - reserve - 44) / dims.Y, 0.45, 1)
		end
	end
	camera:GetPropertyChangedSignal("ViewportSize"):Connect(refit)
	screen:GetPropertyChangedSignal("AbsoluteSize"):Connect(refit)
	-- Title in Merriweather with a crimson brush under it, the seigaiha band behind the
	-- header, and the tsuba close in the corner.
	local chrome = UI.windowChrome(window)
	titleLabel = chrome.title
	chrome.close.Activated:Connect(Panels.closeAll)
	-- B on a gamepad closes the window (a sheet over it closes first: UI).
	UI.onBack(function(): boolean
		if current then
			Panels.closeAll()
			return true
		end
		return false
	end)
	body = UI.new("Frame", {
		Name = "Body",
		Position = UDim2.fromOffset(24, 76),
		Size = UDim2.new(1, -48, 1, -92),
		BackgroundTransparency = 1,
		ClipsDescendants = true,
	}, window)
	screen.Parent = player:WaitForChild("PlayerGui")
	refit()

	player.AttributeChanged:Connect(function()
		if current then
			Panels.redraw()
		end
	end)
end

return Panels
