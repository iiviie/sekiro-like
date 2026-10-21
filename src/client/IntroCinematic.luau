--!strict
-- Pre-fight intros on screen: before round 1 of a duel and at the start of a boss trial, both
-- fighters play their intro (Shared/Intros; clips from Shared/BakedIntros, effects and props
-- from client/IntroFX) under a short cinematic: letterbox, a low hero shot of each fighter with
-- their card (title, name, rank or boss line, and the intro's name), then a VS beat with both
-- cards and the 決闘 stamp. The round countdown starts when it ends. Replaces the old static duel
-- card (DuelHUD keeps its score banner and splashes).
--
-- The server owns the timing (DuelService / BossService "Intro" { mode, at, endsAt, fighters,
-- skip }): it freezes and protects both bodies, waits, and sends "IntroEnd" if everyone skipped.
-- Skipping: Space / Enter / gamepad A / the Skip button sends "SkipIntro"; a duel ends early once
-- every human has pressed it (a bot always agrees), a boss intro once you've seen it before.
--
--   full   fighter 1's shot (2 s), fighter 2's shot (2 s), VS (0.7 s)
--   short  (the same two met in the last 20 min) both at once in one wide shot, then VS
--
-- Also: IntroCinematic.preview(ref) for the Locker (your own intro on your character, with the
-- camera and your card), and the royale's one-second flourish (no freeze, no camera): every
-- fighter plays their intro's best second as the match starts.

local ContextActionService = game:GetService("ContextActionService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Assets = require(ReplicatedStorage.Shared.Assets)
local BakedIntros = require(ReplicatedStorage.Shared.BakedIntros)
local Bosses = require(ReplicatedStorage.Shared.Bosses)
local Catalog = require(ReplicatedStorage.Shared.Catalog)
local Config = require(ReplicatedStorage.Shared.Config)
local Flair = require(ReplicatedStorage.Shared.Flair)
local Intros = require(ReplicatedStorage.Shared.Intros)
local Ranks = require(ReplicatedStorage.Shared.Ranks)
local Animator = require(script.Parent.Animator)
local IntroFX = require(script.Parent.IntroFX)
local UI = require(script.Parent.UI)

local player = Players.LocalPlayer
local THEME = UI.Theme
local T = Intros.Timing

local IntroCinematic = {}

-- Who a card is about.
export type Card = {
	name: string,
	title: Catalog.Item?,
	title2: Catalog.Item?,
	sub: string?, -- rank, or a boss's Japanese name
	subColor: Color3?,
	line: string?, -- a boss's line
	stars: number?,
	accent: Color3, -- the intro's (or boss's) colour
	introName: string?,
	kanji: string?,
	edge: Color3?, -- banner edge colour
}

type Fighter = {
	model: Model,
	clip: string, -- intro ref whose clip plays
	card: Card,
	fx: IntroFX.Handle?,
}

type Session = {
	token: number,
	mode: string,
	startClock: number, -- os.clock() of the intro's time 0
	length: number,
	fighters: { Fighter },
	gui: ScreenGui,
	bars: { Frame },
	cards: { Frame },
	skipLabel: TextLabel?,
	skipButton: TextButton?,
	canSkip: boolean,
	voted: boolean,
	remote: RemoteEvent?,
	hidden: { ScreenGui },
	camFrom: CFrame?,
	preview: boolean,
	fov: number,
	firstTo: number?,
	rated: boolean?,
}

local session: Session? = nil
local token = 0

local function serverNow(): number
	return workspace:GetServerTimeNow()
end

local KANJI = Assets.Cosmetics.Kanji

local function kanjiImage(key: string?): string?
	if key == "Slay" then
		return Assets.UI.KanjiSlay
	end
	return if key then KANJI[key] else nil
end

---------------------------------------------------------------------------------------
-- Cards

local function loadoutOf(who: Player): { [string]: string }
	local raw = who:GetAttribute("Loadout")
	if typeof(raw) ~= "string" then
		return {}
	end
	local ok, decoded = pcall(HttpService.JSONDecode, HttpService, raw)
	return if ok and typeof(decoded) == "table" then decoded else {}
end

-- The intro a player has equipped (its ref), the default otherwise.
function IntroCinematic.equippedRef(who: Player): string
	local item = Catalog.get(loadoutOf(who).intro)
	return Intros.resolve(if item and item.category == "intro" then item.ref else nil).ref
end

-- A fighter's card: a player's title(s), name and rank; a bot's name; a boss's name, Japanese
-- name, tomoe and line.
function IntroCinematic.cardOf(who: Player?, model: Model?, fallbackName: string, introRef: string?): Card
	local intro = Intros.resolve(introRef)
	if who then
		local loadout = loadoutOf(who)
		local rank = Ranks.of(who:GetAttribute("Rating") or Config.Rating.Start)
		local passes = who:GetAttribute("Passes")
		local hasSlot = typeof(passes) == "string"
			and string.find("," .. passes .. ",", ",pass.TitleSlot,", 1, true) ~= nil
		local second = if hasSlot and loadout.title2 ~= loadout.title then Catalog.get(loadout.title2) else nil
		return {
			name = who.DisplayName,
			title = Catalog.get(loadout.title),
			title2 = if second and second.category == "title" then second else nil,
			sub = rank.name,
			subColor = rank.color,
			accent = intro.accent,
			introName = intro.name,
			kanji = intro.kanji,
			edge = Flair.banner(Flair.ref(loadout.banner)).edge,
		}
	end
	local bossId = model and model:GetAttribute("Boss")
	local def = if typeof(bossId) == "string" then Bosses.def(bossId) else nil
	if def and typeof(bossId) == "string" then
		local b = Intros.Bosses[bossId]
		return {
			name = def.name,
			sub = def.nameJP,
			subColor = THEME.Dim,
			line = if b then b.line else nil,
			stars = def.stars,
			accent = if b then b.accent else intro.accent,
			kanji = nil,
		}
	end
	return {
		name = fallbackName,
		sub = "Wandering swordsman",
		subColor = THEME.Dim,
		accent = intro.accent,
		introName = intro.name,
		kanji = intro.kanji,
	}
end

local function titleColor(item: Catalog.Item?): Color3
	return if item then UI.rarity(item.rarity).text else THEME.Bone
end

local CARD_W, CARD_H = 380, 104

-- A lower-third card: an accent edge, the intro's kanji, title over name, rank (or the boss's
-- name in Japanese), then the intro's name or the boss's line. `right` mirrors it.
local function buildCard(parent: Instance, card: Card, right: boolean): Frame
	local frame = UI.new("CanvasGroup", {
		Name = if right then "CardRight" else "CardLeft",
		AnchorPoint = Vector2.new(if right then 1 else 0, 1),
		Position = UDim2.new(if right then 1 else 0, if right then -28 else 28, 0.88, -10),
		Size = UDim2.fromOffset(CARD_W, CARD_H),
		BackgroundColor3 = THEME.Ink,
		BackgroundTransparency = 0.18,
		GroupTransparency = 1,
	}, parent) :: Frame
	UI.new("UIGradient", {
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, if right then 0.6 else 0),
			NumberSequenceKeypoint.new(1, if right then 0 else 0.6),
		}),
	}, frame)
	-- the accent edge
	UI.new("Frame", {
		Name = "Edge",
		AnchorPoint = Vector2.new(if right then 1 else 0, 0),
		Position = UDim2.fromScale(if right then 1 else 0, 0),
		Size = UDim2.new(0, 5, 1, 0),
		BackgroundColor3 = card.accent,
		BorderSizePixel = 0,
	}, frame)
	UI.new("Frame", {
		Name = "Rule",
		AnchorPoint = Vector2.new(if right then 1 else 0, 1),
		Position = UDim2.fromScale(if right then 1 else 0, 1),
		Size = UDim2.new(1, 0, 0, 2),
		BackgroundColor3 = card.edge or THEME.Gold,
		BorderSizePixel = 0,
	}, frame)
	local x = 16
	local image = kanjiImage(card.kanji)
	if image then
		UI.new("ImageLabel", {
			Name = "Kanji",
			AnchorPoint = Vector2.new(if right then 1 else 0, 0.5),
			Position = UDim2.new(if right then 1 else 0, if right then -14 else 14, 0.5, 0),
			Size = UDim2.fromOffset(64, 64),
			BackgroundTransparency = 1,
			Image = image,
			ImageColor3 = card.accent,
		}, frame)
		x = 88
	end
	local align = if right then Enum.TextXAlignment.Right else Enum.TextXAlignment.Left
	local function line(name: string, y: number, h: number, props: { [string]: any })
		local label = UI.text({
			Name = name,
			AnchorPoint = Vector2.new(if right then 1 else 0, 0),
			Position = UDim2.new(if right then 1 else 0, if right then -x else x, 0, y),
			Size = UDim2.new(1, -x - 12, 0, h),
			TextXAlignment = align,
			TextTruncate = Enum.TextTruncate.AtEnd,
			TextStrokeColor3 = THEME.Ink,
			TextStrokeTransparency = 0.5,
		}, frame)
		for k, v in props do
			(label :: any)[k] = v
		end
		return label
	end
	local titleText = if card.title then card.title.name else ""
	if card.title2 then
		titleText ..= `  ·  {card.title2.name}`
	end
	if card.stars then
		titleText = string.rep("◆ ", card.stars) -- difficulty (Builder Sans has no star glyphs)
	end
	line("Title", 8, 18, {
		FontFace = UI.Fonts.Label,
		TextSize = 15,
		TextColor3 = if card.stars then THEME.Gold else titleColor(card.title),
		Text = titleText,
	})
	line("Name", 25, 36, {
		FontFace = UI.Fonts.Display,
		TextSize = 30,
		TextColor3 = THEME.Bone,
		Text = card.name,
	})
	line("Sub", 61, 18, {
		FontFace = UI.Fonts.Body,
		TextSize = 15,
		TextColor3 = card.subColor or THEME.Dim,
		Text = card.sub or "",
	})
	line("Intro", 79, 18, {
		FontFace = if card.line then UI.Fonts.Body else UI.Fonts.Label,
		TextSize = 14,
		TextColor3 = if card.line then THEME.Bone else card.accent:Lerp(THEME.Bone, 0.35),
		Text = if card.line
			then `“{card.line}”`
			elseif card.introName then UI.tracked(string.upper(card.introName))
			else "",
	})
	UI.new("UIScale", { Name = "Scale" }, frame)
	return frame
end

local function showCard(card: Frame, show: boolean, slide: boolean?)
	local right = card.Name == "CardRight"
	local home = UDim2.new(if right then 1 else 0, if right then -28 else 28, 0.88, -10)
	if show then
		if slide ~= false then
			card.Position = home + UDim2.fromOffset(if right then 120 else -120, 0)
		end
		TweenService:Create(card, TweenInfo.new(0.32, Enum.EasingStyle.Quart, Enum.EasingDirection.Out), {
			Position = home,
			GroupTransparency = 0,
		}):Play()
	else
		TweenService:Create(card, TweenInfo.new(0.2), { GroupTransparency = 1 }):Play()
	end
end

---------------------------------------------------------------------------------------
-- Camera

local function rootOf(model: Model): BasePart?
	local r = model:FindFirstChild("HumanoidRootPart")
	return if r and r:IsA("BasePart") then r else nil
end

local function heightOf(model: Model): number
	local s = model:GetAttribute("BodyScale")
	return if typeof(s) == "number" and s > 0 then s else 1
end

-- A low hero shot of `f`, from `side` (1 its right, -1 its left), `alpha` 0..1 through the shot.
local function heroShot(f: Fighter, side: number, alpha: number, punch: number): (CFrame, number)
	local r = rootOf(f.model)
	if not r then
		return workspace.CurrentCamera.CFrame, 50
	end
	local s = heightOf(f.model)
	local e = 1 - (1 - alpha) ^ 2
	local angle = math.rad(side * (30 - 18 * e))
	local dist = (9.2 - 1.6 * e - punch * 1.2) * s
	local base = r.CFrame
	local offset = CFrame.Angles(0, angle, 0) * Vector3.new(0, 0, -dist)
	local eye = base * Vector3.new(offset.X, -0.9 * s + 0.3 * e * s, offset.Z)
	local focus = base * Vector3.new(0, 0.9 * s, 0)
	return CFrame.lookAt(eye, focus), 46 - 3 * e - punch * 4
end

-- Both fighters from the side nearest the local camera, pushing in.
local function twoShot(a: Fighter, b: Fighter, alpha: number, sideSign: number): (CFrame, number)
	local ra, rb = rootOf(a.model), rootOf(b.model)
	if not ra or not rb then
		return workspace.CurrentCamera.CFrame, 50
	end
	local pa, pb = ra.Position, rb.Position
	local mid = (pa + pb) / 2
	local across = pb - pa
	across = Vector3.new(across.X, 0, across.Z)
	local axis = if across.Magnitude > 1e-3 then across.Unit else Vector3.xAxis
	local perp = axis:Cross(Vector3.yAxis).Unit * sideSign
	local span = across.Magnitude
	local e = 1 - (1 - alpha) ^ 2
	local dist = span * 0.62 + 9 - 2.2 * e
	local eye = mid + perp * dist + Vector3.new(0, 1.2 + 0.6 * e, 0) + axis * (1.5 - 3 * e)
	return CFrame.lookAt(eye, mid + Vector3.new(0, 1.4, 0)), 52 - 4 * e
end

-- Where the gameplay camera will pick up (behind you, looking at your foe), for the hand-off.
local function behindMe(foe: Model?): CFrame?
	local character = player.Character
	local me = character and rootOf(character)
	if not me then
		return nil
	end
	local target = if foe and rootOf(foe)
		then (rootOf(foe) :: BasePart).Position
		else me.Position + me.CFrame.LookVector * 10
	local flat = target - me.Position
	flat = Vector3.new(flat.X, 0, flat.Z)
	local look = if flat.Magnitude > 1e-3 then flat.Unit else me.CFrame.LookVector
	local eye = me.Position - look * 10 + Vector3.new(0, 3.5, 0) + look:Cross(Vector3.yAxis) * -2
	return CFrame.lookAt(eye, target + Vector3.new(0, 1, 0))
end

---------------------------------------------------------------------------------------
-- The session

local HUD_GUIS = { "LobbyHUD", "CombatHUD", "RoundHUD", "BossHUD", "DuelHUD", "TouchHUD", "Coach", "Toasts" }
local SKIP_ACTION = "IntroSkip"
local SINK_ACTION = "IntroSink"
local SUNK = {
	Enum.UserInputType.MouseButton1,
	Enum.KeyCode.ButtonR1,
	Enum.KeyCode.F,
	Enum.KeyCode.ButtonL1,
	Enum.KeyCode.E,
	Enum.KeyCode.ButtonY,
	Enum.KeyCode.Q,
	Enum.KeyCode.ButtonB,
	Enum.KeyCode.C,
	Enum.KeyCode.ButtonX,
	Enum.KeyCode.G,
	Enum.KeyCode.DPadUp,
	Enum.KeyCode.R,
	Enum.UserInputType.MouseButton3,
	Enum.KeyCode.ButtonR3,
}

local function setSkipText(s: Session)
	local label = s.skipLabel
	if not label then
		return
	end
	if not s.canSkip then
		label.Text = ""
		if s.skipButton then
			s.skipButton.Visible = false
		end
		return
	end
	if s.voted then
		label.Text = "Waiting for your opponent to skip"
	else
		label.Text = if UI.isTouch() then "" else "SPACE  ·  skip"
	end
	if s.skipButton then
		s.skipButton.Visible = not s.voted
	end
end

local function vote(s: Session)
	if s.voted or not s.canSkip then
		return
	end
	s.voted = true
	UI.sound("Press")
	setSkipText(s)
	if s.remote then
		s.remote:FireServer("SkipIntro")
	else
		IntroCinematic.finish() -- a preview or a test: nobody else to wait for
	end
end

local function endSession(s: Session, quick: boolean?)
	if session ~= s then
		return
	end
	session = nil
	RunService:UnbindFromRenderStep("IntroCinematic")
	ContextActionService:UnbindAction(SKIP_ACTION)
	ContextActionService:UnbindAction(SINK_ACTION)
	for _, f in s.fighters do
		if f.fx then
			IntroFX.stop(f.fx, if quick then 0 else 0.6)
		end
		-- an intro cut short blends straight to the stance
		local current = Animator.current(f.model)
		if current and string.sub(current, 1, 6) == "Intro_" then
			Animator.stop(f.model)
		end
	end
	for _, bar in s.bars do
		TweenService:Create(bar, TweenInfo.new(0.3), { Size = UDim2.fromScale(1, 0) }):Play()
	end
	for _, card in s.cards do
		showCard(card, false)
	end
	if s.skipLabel then
		s.skipLabel.Visible = false
	end
	if s.skipButton then
		s.skipButton.Visible = false
	end
	for _, gui in s.hidden do
		gui.Enabled = true
	end
	local camera = workspace.CurrentCamera
	camera.CameraType = Enum.CameraType.Custom
	camera.FieldOfView = s.fov
	task.delay(0.4, function()
		s.gui:Destroy()
	end)
end

-- Ends the intro now (the server's IntroEnd, or a preview skipped).
function IntroCinematic.finish()
	local s = session
	if s then
		endSession(s, true)
	end
end

function IntroCinematic.active(): boolean
	return session ~= nil
end

local function buildGui(): (ScreenGui, { Frame })
	local gui = UI.new("ScreenGui", {
		Name = "IntroCinematic",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		DisplayOrder = 8,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	}, player:WaitForChild("PlayerGui")) :: ScreenGui
	local bars = {}
	for i, anchor in { 0, 1 } do
		local bar = UI.new("Frame", {
			Name = if i == 1 then "BarTop" else "BarBottom",
			AnchorPoint = Vector2.new(0, anchor),
			Position = UDim2.fromScale(0, anchor),
			Size = UDim2.fromScale(1, 0),
			BackgroundColor3 = THEME.Black,
			BorderSizePixel = 0,
		}, gui)
		TweenService:Create(bar, TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Size = UDim2.fromScale(1, 0.1),
		}):Play()
		table.insert(bars, bar)
	end
	return gui, bars
end

local function stampVS(s: Session)
	local holder = UI.new("Frame", {
		Name = "VS",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0.1, 8),
		Size = UDim2.fromOffset(160, 120),
		BackgroundTransparency = 1,
	}, s.gui)
	UI.new("UIScale", { Scale = math.clamp(workspace.CurrentCamera.ViewportSize.Y / 800, 0.6, 1) }, holder)
	local kanji = UI.new("ImageLabel", {
		Name = "Kanji",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 0),
		Size = UDim2.fromOffset(84, 84),
		BackgroundTransparency = 1,
		Image = Assets.UI.KanjiDuel,
		ImageColor3 = THEME.Crimson,
	}, holder)
	UI.stamp(kanji, 0)
	UI.sound("Stamp")
	local caption = if s.firstTo then `First to {s.firstTo}{if s.rated then "  ·  ranked" else ""}` else "Trial"
	UI.text({
		Name = "Caption",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 88),
		Size = UDim2.fromOffset(220, 22),
		FontFace = UI.Fonts.Label,
		TextSize = 15,
		TextColor3 = THEME.Bone,
		TextStrokeColor3 = THEME.Ink,
		TextStrokeTransparency = 0.4,
		Text = UI.tracked(string.upper(caption)),
	}, holder)
end

export type Spec = {
	mode: string, -- "full" | "short" | "preview"
	at: number, -- server time of the intro's time 0 (preview: ignored)
	length: number,
	fighters: { { model: Model, intro: string, card: Card } },
	canSkip: boolean,
	remote: RemoteEvent?,
	firstTo: number?,
	rated: boolean?,
}

function IntroCinematic.play(spec: Spec)
	local old = session
	if old then
		endSession(old, true)
	end
	BakedIntros.register()
	token += 1
	local elapsed = if spec.mode == "preview" then 0 else serverNow() - spec.at
	local gui, bars = buildGui()
	local s: Session = {
		token = token,
		mode = spec.mode,
		startClock = os.clock() - elapsed,
		length = spec.length,
		fighters = {},
		gui = gui,
		bars = bars,
		cards = {},
		canSkip = spec.canSkip,
		voted = false,
		remote = spec.remote,
		hidden = {},
		preview = spec.mode == "preview",
		fov = workspace.CurrentCamera.FieldOfView,
		firstTo = spec.firstTo,
		rated = spec.rated,
	}
	session = s

	-- Hide the HUD (the cinematic is the whole screen for a few seconds).
	local playerGui = player:WaitForChild("PlayerGui")
	for _, name in HUD_GUIS do
		local g = playerGui:FindFirstChild(name)
		if g and g:IsA("ScreenGui") and g.Enabled then
			g.Enabled = false
			table.insert(s.hidden, g)
		end
	end

	-- Fighters: clips, props and effects. Full: fighter 2 holds its first pose until its shot.
	for i, f in spec.fighters do
		local intro = Intros.resolve(f.intro)
		local fighter: Fighter = { model = f.model, clip = intro.ref, card = f.card }
		table.insert(s.fighters, fighter)
		local startsIn = if spec.mode == "full" and i == 2 then T.Shot - T.ClipLead else 0
		startsIn = math.max(startsIn - elapsed, 0)
		Animator.play(f.model, `Intro_{intro.ref}`, nil, startsIn)
		local okFx, handle = pcall(IntroFX.start, f.model, intro.ref, f.card.accent, startsIn)
		if okFx then
			fighter.fx = handle
		else
			warn("[IntroCinematic] effects:", handle)
		end
	end

	-- Cards
	local single = #s.fighters == 1
	for i, f in s.fighters do
		local card = buildCard(gui, f.card, i == 2)
		local scale = card:FindFirstChild("Scale") :: UIScale
		scale.Scale = math.clamp(workspace.CurrentCamera.ViewportSize.X / 1300, 0.62, 1)
		table.insert(s.cards, card)
	end

	-- Skip
	local skipLabel = UI.text({
		Name = "Skip",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -24, 0.95, 0),
		Size = UDim2.fromOffset(320, 22),
		FontFace = UI.Fonts.Label,
		TextSize = 15,
		TextXAlignment = Enum.TextXAlignment.Right,
		TextColor3 = THEME.Dim,
		Text = "",
	}, gui)
	s.skipLabel = skipLabel
	if UI.isTouch() and spec.canSkip then
		local button = UI.new("TextButton", {
			Name = "SkipButton",
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -20, 0.95, 0),
			Size = UDim2.fromOffset(110, 48),
			BackgroundColor3 = THEME.Lacquer,
			BackgroundTransparency = 0.2,
			FontFace = UI.Fonts.Label,
			TextSize = 18,
			TextColor3 = THEME.Bone,
			Text = "Skip",
		}, gui) :: TextButton
		UI.new("UICorner", { CornerRadius = UDim.new(0, 8) }, button)
		button.Activated:Connect(function()
			vote(s)
		end)
		s.skipButton = button
	end
	setSkipText(s)
	ContextActionService:BindActionAtPriority(SKIP_ACTION, function(_, state)
		if state == Enum.UserInputState.Begin then
			vote(s)
		end
		return Enum.ContextActionResult.Sink
	end, false, 3000, Enum.KeyCode.Space, Enum.KeyCode.Return, Enum.KeyCode.ButtonA)
	-- Swings, guards and dashes can't start under the intro (the server refuses them too).
	if not s.preview then
		ContextActionService:BindActionAtPriority(SINK_ACTION, function()
			return Enum.ContextActionResult.Sink
		end, false, 3000, table.unpack(SUNK))
	end

	-- The camera and the beats.
	local camera = workspace.CurrentCamera
	camera.CameraType = Enum.CameraType.Scriptable
	local sideSign = 1
	do
		local a, b = s.fighters[1], s.fighters[2]
		local ra, rb = a and rootOf(a.model), b and rootOf(b.model)
		if ra and rb then
			local across = rb.Position - ra.Position
			local perp = Vector3.new(across.X, 0, across.Z).Unit:Cross(Vector3.yAxis)
			sideSign = if perp:Dot(camera.CFrame.Position - (ra.Position + rb.Position) / 2) >= 0 then 1 else -1
		end
	end
	local me = player.Character
	local foe: Model? = nil
	for _, f in s.fighters do
		if f.model ~= me then
			foe = f.model
		end
	end
	local shown: { [number]: boolean } = {}
	local vsShown = false
	local function cardOn(i: number, slide: boolean?)
		if not shown[i] and s.cards[i] then
			shown[i] = true
			showCard(s.cards[i], true, slide)
		end
	end
	local vsAt = if spec.mode == "full"
		then 2 * T.Shot
		elseif spec.mode == "short" then spec.length - T.VS
		else math.huge
	RunService:BindToRenderStep("IntroCinematic", Enum.RenderPriority.Camera.Value + 10, function()
		if session ~= s then
			return
		end
		local t = os.clock() - s.startClock
		if t >= s.length then
			endSession(s)
			return
		end
		camera.CameraType = Enum.CameraType.Scriptable
		local cf: CFrame, fov: number
		if single then
			local f = s.fighters[1]
			local intro = Intros.resolve(f.clip)
			local punch = math.max(0, 1 - math.abs(t - intro.climax) / 0.25)
			cf, fov = heroShot(f, 1, math.clamp(t / s.length, 0, 1), punch)
			cardOn(1)
		elseif spec.mode == "full" and t < 2 * T.Shot then
			local i = if t < T.Shot then 1 else 2
			local f = s.fighters[i]
			local local_t = t - (i - 1) * T.Shot
			local intro = Intros.resolve(f.clip)
			local clipT = local_t + T.ClipLead
			local punch = math.max(0, 1 - math.abs(clipT - intro.climax) / 0.25)
			cf, fov = heroShot(f, if i == 1 then 1 else -1, local_t / T.Shot, punch)
			if i == 2 and shown[1] and s.cards[1] then
				shown[1] = false
				showCard(s.cards[1], false)
			end
			if local_t > 0.25 then
				cardOn(i)
			end
		else
			local a, b = s.fighters[1], s.fighters[2]
			local from = if spec.mode == "full" then 2 * T.Shot else 0
			local alpha = math.clamp((t - from) / math.max(s.length - from, 0.1), 0, 1)
			cf, fov = twoShot(a, b, alpha, sideSign)
			cardOn(1, spec.mode ~= "full")
			cardOn(2, spec.mode ~= "full")
			-- the last 0.3 s ease toward where the gameplay camera picks up
			local handoff = behindMe(foe)
			local lastT = s.length - 0.35
			if handoff and t > lastT and not s.preview then
				local k = math.clamp((t - lastT) / 0.35, 0, 1)
				cf = cf:Lerp(handoff, k * k)
				fov = fov + (70 - fov) * k
			end
		end
		if t >= vsAt and not vsShown and #s.fighters >= 2 then
			vsShown = true
			stampVS(s)
		end
		camera.CFrame = cf
		camera.FieldOfView = fov
	end)
end

---------------------------------------------------------------------------------------
-- Remotes

local function fightersFrom(data: { [string]: any }): { { model: Model, intro: string, card: Card } }
	local out = {}
	for _, f in data.fighters or {} do
		local model = f.model
		if typeof(model) == "Instance" and model:IsA("Model") then
			local who = Players:GetPlayerFromCharacter(model)
			local ref = if typeof(f.intro) == "string" then f.intro else Intros.Default
			table.insert(out, {
				model = model,
				intro = ref,
				card = IntroCinematic.cardOf(
					who,
					model,
					if typeof(f.name) == "string" then f.name else model.Name,
					ref
				),
			})
		end
	end
	return out
end

local function onIntro(remote: RemoteEvent, data: { [string]: any })
	local fighters = fightersFrom(data)
	if #fighters == 0 then
		return
	end
	local mode = if data.mode == "short" then "short" else "full"
	local at = if typeof(data.at) == "number" then data.at else serverNow()
	local endsAt = if typeof(data.endsAt) == "number" then data.endsAt else at + T.Full
	IntroCinematic.play({
		mode = mode,
		at = at,
		length = endsAt - at,
		fighters = fighters,
		canSkip = data.skip == true,
		remote = remote,
		firstTo = if typeof(data.firstTo) == "number" then data.firstTo else nil,
		rated = data.rated == true,
	})
end

local function listen(remote: RemoteEvent)
	remote.OnClientEvent:Connect(function(kind: string, data: any)
		if kind == "Intro" and typeof(data) == "table" then
			onIntro(remote, data)
		elseif kind == "IntroEnd" then
			IntroCinematic.finish()
		elseif kind == "IntroVote" and session and typeof(data) == "table" then
			-- someone else pressed skip: say so on the skip line
			local s = session :: Session
			if s.skipLabel and not s.voted then
				s.skipLabel.Text = "Your opponent wants to skip  ·  SPACE"
			end
		end
	end)
end

---------------------------------------------------------------------------------------
-- Locker preview: your own intro on your character, with its camera and your card.

local previewing = false

function IntroCinematic.preview(ref: string, onDone: (() -> ())?)
	local character = player.Character
	if not character or not rootOf(character) then
		return
	end
	local intro = Intros.resolve(ref)
	previewing = true
	IntroCinematic.play({
		mode = "preview",
		at = serverNow(),
		length = 2.6,
		fighters = {
			{
				model = character,
				intro = intro.ref,
				card = IntroCinematic.cardOf(player, character, player.DisplayName, intro.ref),
			},
		},
		canSkip = true,
		remote = nil,
	})
	local s = session
	if s and onDone then
		task.spawn(function()
			while session == s do
				task.wait(0.1)
			end
			if previewing then
				previewing = false
				onDone()
			end
		end)
	end
end

function IntroCinematic.stopPreview()
	if previewing then
		previewing = false
		IntroCinematic.finish()
	end
end

---------------------------------------------------------------------------------------
-- The royale flourish: a second of each fighter's intro as the match begins (no freeze, no
-- camera; a swing or a step simply replaces it).

local function flourish(model: Model)
	local who = Players:GetPlayerFromCharacter(model)
	local ref = if who then IntroCinematic.equippedRef(who) else Intros.forBot(model.Name)
	local intro = Intros.resolve(ref)
	local name = BakedIntros.flourish(intro.ref, intro.flourish[1], intro.flourish[2])
	if not name or model:GetAttribute("CombatState") ~= "Idle" then
		return
	end
	if Animator.current(model) then
		return -- already doing something
	end
	Animator.play(model, name)
end

local function watchRoyale(model: Model)
	model:GetAttributeChangedSignal("InMatch"):Connect(function()
		if model:GetAttribute("InMatch") == true then
			task.delay(0.6 + math.random() * 0.4, function()
				if model.Parent and model:GetAttribute("InMatch") == true then
					flourish(model)
				end
			end)
		end
	end)
end

function IntroCinematic.start()
	BakedIntros.register()
	local remotes = ReplicatedStorage:WaitForChild("Remotes")
	task.spawn(function()
		listen(remotes:WaitForChild("Duel") :: RemoteEvent)
	end)
	task.spawn(function()
		listen(remotes:WaitForChild("Boss") :: RemoteEvent)
	end)
	-- every fighter model that appears (players' characters and bots)
	local function consider(instance: Instance)
		if instance:IsA("Model") and instance:FindFirstChildOfClass("Humanoid") then
			watchRoyale(instance)
		end
	end
	for _, p in Players:GetPlayers() do
		if p.Character then
			consider(p.Character)
		end
		p.CharacterAdded:Connect(consider)
	end
	Players.PlayerAdded:Connect(function(p)
		p.CharacterAdded:Connect(consider)
	end)
	-- The Locker's Preview button on an intro: play it here, then reopen the Locker on intros.
	local lockerModule = script.Parent:FindFirstChild("LockerPanel")
	if lockerModule and lockerModule:IsA("ModuleScript") then
		local ok, locker = pcall(require, lockerModule)
		if ok and typeof(locker) == "table" and typeof(locker.setPreview) == "function" then
			locker.setPreview("intro", function(item: Catalog.Item)
				IntroCinematic.preview(item.ref, function()
					if typeof(locker.show) == "function" then
						locker.show("intro")
					end
				end)
			end)
		end
	end
	-- Studio test hook: PlayerScripts.IntroTest:Invoke("preview", "Iai") / ("vs", model, ref)
	if RunService:IsStudio() then
		local hook = Instance.new("BindableFunction")
		hook.Name = "IntroTest"
		hook.OnInvoke = function(command: string, a: any, b: any): any
			if command == "preview" then
				IntroCinematic.preview(a)
			elseif command == "vs" then
				local character = player.Character :: Model
				IntroCinematic.play({
					mode = if b == "short" then "short" else "full",
					at = serverNow(),
					length = if b == "short" then T.Short else T.Full,
					fighters = {
						{
							model = character,
							intro = IntroCinematic.equippedRef(player),
							card = IntroCinematic.cardOf(
								player,
								character,
								player.DisplayName,
								IntroCinematic.equippedRef(player)
							),
						},
						{
							model = a,
							intro = Intros.forBot(a.Name),
							card = IntroCinematic.cardOf(nil, a, a.Name, Intros.forBot(a.Name)),
						},
					},
					canSkip = true,
				})
			elseif command == "stop" then
				IntroCinematic.finish()
			elseif command == "active" then
				return IntroCinematic.active()
			end
			return nil
		end
		hook.Parent = player:WaitForChild("PlayerScripts")
	end
end

return IntroCinematic
