--!strict
-- The LAST BLADE interface kit (research_notes/progression/ui/ui_style_guide.md). Three
-- materials (black lacquer, bone washi, inset plates), gold hairlines, one crimson cut;
-- Merriweather for titles, Builder Sans for everything people read, tracked Garamond for
-- banners only. Every menu, HUD plate and button comes from here, so a restyle happens in
-- one file.
--
-- Chrome art is 9-slice PNGs from art/ui/chrome.py (Assets.UI.Chrome). Until an id is
-- registered there, each surface draws a native stand-in in the same colours (gradient
-- fill, gold hairline, small chamfer-ish corner), so the UI looks right either way.
--
-- Old helpers (panel, button, actionButton, text, tabs, pill, sheet, confirm, dot, note,
-- heading) keep their signatures and now draw the new style; new components (card,
-- progress, currencyPill, iconButton, window chrome, toasts plates, motion and sound
-- helpers) sit beside them.

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Assets = require(ReplicatedStorage.Shared.Assets)

local UI = {}

---------------------------------------------------------------------------------------
-- Tokens (guide section 3)

local function rgb(r: number, g: number, b: number): Color3
	return Color3.fromRGB(r, g, b)
end

UI.Theme = {
	Ink = rgb(26, 23, 24),
	Lacquer = rgb(36, 30, 32),
	LacquerHi = rgb(52, 43, 45),
	Plate = rgb(74, 62, 63), -- inset plate tint (rows, chips, cards on a lacquer window)
	Bone = rgb(237, 227, 207),
	Washi = rgb(230, 218, 192),
	Dim = rgb(168, 159, 146),
	Ash = rgb(140, 131, 120),
	Gold = rgb(212, 165, 74),
	GoldHi = rgb(232, 199, 122),
	GoldDeep = rgb(128, 88, 22), -- gold numbers on washi
	Bronze = rgb(107, 74, 34),
	Crimson = rgb(200, 16, 46),
	CrimsonBtn = rgb(176, 14, 42),
	CrimsonText = rgb(239, 107, 91),
	LacquerRed = rgb(122, 10, 26),
	Jade = rgb(62, 158, 132),
	JadeText = rgb(108, 196, 164),
	JadeBtn = rgb(35, 98, 79),
	JadeDeep = rgb(20, 90, 72), -- gem numbers on washi
	Steel = rgb(184, 194, 204),
	ShardText = rgb(159, 216, 230),
	Disabled = rgb(60, 52, 54),
	Black = rgb(0, 0, 0),
}
local T = UI.Theme

UI.Fonts = {
	Display = Font.new("rbxasset://fonts/families/Merriweather.json", Enum.FontWeight.Bold),
	DisplayHeavy = Font.new("rbxasset://fonts/families/Merriweather.json", Enum.FontWeight.Heavy),
	Banner = Font.new("rbxasset://fonts/families/Guru.json"),
	Body = Font.new("rbxasset://fonts/families/BuilderSans.json", Enum.FontWeight.Medium),
	Label = Font.new("rbxasset://fonts/families/BuilderSans.json", Enum.FontWeight.Bold),
	Number = Font.new("rbxasset://fonts/families/BuilderSans.json", Enum.FontWeight.ExtraBold),
}

UI.Motion = {
	Hover = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
	Press = TweenInfo.new(0.06, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
	Release = TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
	Select = TweenInfo.new(0.2, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
	Open = TweenInfo.new(0.22, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
	Close = TweenInfo.new(0.14, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
	Slide = TweenInfo.new(0.28, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
	Count = TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
	Pop = TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
	Stamp = TweenInfo.new(0.22, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
	Pulse = TweenInfo.new(1.2, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
	Reveal = TweenInfo.new(0.45, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
	Fade = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
}

UI.Space = { S1 = 4, S2 = 8, S3 = 12, S4 = 16, S5 = 24, S6 = 32, S7 = 48 }

export type RarityStyle = { frame: string, light: Color3, dark: Color3, text: Color3, glow: number, kanji: string }
UI.Rarity = {
	common = {
		frame = "Common",
		light = T.Steel,
		dark = rgb(120, 128, 138),
		text = T.Steel,
		glow = 0,
		kanji = "KanjiCommon",
	},
	uncommon = {
		frame = "Uncommon",
		light = T.JadeText,
		dark = rgb(46, 110, 92),
		text = T.JadeText,
		glow = 0.25,
		kanji = "KanjiUncommon",
	},
	rare = {
		frame = "Rare",
		light = rgb(74, 132, 196),
		dark = rgb(38, 76, 128),
		text = rgb(127, 176, 234),
		glow = 0.3,
		kanji = "KanjiRare",
	},
	epic = {
		frame = "Epic",
		light = rgb(150, 92, 196),
		dark = rgb(88, 48, 128),
		text = rgb(190, 140, 235),
		glow = 0.35,
		kanji = "KanjiEpic",
	},
	legendary = {
		frame = "Legendary",
		light = T.Gold,
		dark = T.Bronze,
		text = T.GoldHi,
		glow = 0.45,
		kanji = "KanjiLegendary",
	},
	mythic = {
		frame = "Mythic",
		light = T.Crimson,
		dark = T.LacquerRed,
		text = rgb(240, 82, 94),
		glow = 0.5,
		kanji = "",
	},
} :: { [string]: RarityStyle }

function UI.rarity(rarity: string?): RarityStyle
	return UI.Rarity[rarity or "common"] or UI.Rarity.common
end

-- Currencies: icon and number colour (on dark, and the deeper ink on washi).
export type CurrencyStyle = { icon: string, color: Color3, deep: Color3, name: string }
local ICONS = Assets.Icons :: any
UI.Currency = {
	coins = { icon = ICONS.Coin, color = T.GoldHi, deep = T.GoldDeep, name = "coins" },
	gems = { icon = ICONS.Gem, color = T.JadeText, deep = T.JadeDeep, name = "gems" },
	stones = { icon = ICONS.Whetstone or ICONS.Skin, color = T.Steel, deep = rgb(60, 70, 84), name = "Whetstones" },
	shards = { icon = ICONS.Shard or ICONS.Gem, color = T.ShardText, deep = rgb(36, 96, 116), name = "shards" },
} :: { [string]: CurrencyStyle }

-- Legacy names, kept so every caller keeps working; they now point at the tokens. The
-- font enums are mapped to FontFaces in UI.new (Display is Merriweather *Bold*).
UI.Display = Enum.Font.Merriweather
UI.Banner = Enum.Font.Garamond -- tracked caps banners only, >= 24 px
UI.Body = Enum.Font.BuilderSansMedium
UI.Bold = Enum.Font.BuilderSansBold
UI.Number = Enum.Font.BuilderSansExtraBold
UI.Ink = T.Ink
UI.Panel = T.Lacquer
UI.PanelLight = T.LacquerHi
UI.Parchment = T.Bone
UI.Bronze = T.Bronze
UI.Crimson = T.CrimsonBtn
UI.Gold = T.GoldHi
UI.Jade = T.JadeText
UI.Corner = UDim.new(0, 4)
UI.Dim = T.Dim -- secondary text
UI.Selected = rgb(64, 46, 36) -- a picked card
UI.Muted = rgb(28, 24, 27) -- a card for something not owned
UI.Danger = T.CrimsonText -- warnings (save failed)
UI.Touch = 60 -- touch target height at scale 1 (large panels scale to >= 0.8 on a phone)

---------------------------------------------------------------------------------------
-- Text size: nothing under 14 px; honour the player's preferred text size on body and
-- label sizes (titles keep their size so layouts hold).

local function textFactor(): number
	local ok, size = pcall(function()
		return (GuiService :: any).PreferredTextSize
	end)
	if not ok or typeof(size) ~= "EnumItem" then
		return 1
	end
	return ({ Medium = 1, Large = 1.15, Larger = 1.3, Largest = 1.45 } :: { [string]: number })[size.Name] or 1
end
local TEXT_FACTOR = textFactor()

local function fitTextSize(size: number): number
	if size <= 20 and TEXT_FACTOR ~= 1 then
		size = math.floor(size * TEXT_FACTOR + 0.5)
	end
	return math.max(14, size)
end
UI.textSize = fitTextSize

local FACES: { [EnumItem]: Font } = {
	[Enum.Font.Merriweather] = UI.Fonts.Display,
	[Enum.Font.BuilderSansMedium] = UI.Fonts.Body,
	[Enum.Font.BuilderSansBold] = UI.Fonts.Label,
	[Enum.Font.BuilderSansExtraBold] = UI.Fonts.Number,
	-- Source Sans anywhere in the old code becomes Builder Sans.
	[Enum.Font.SourceSans] = UI.Fonts.Body,
	[Enum.Font.SourceSansSemibold] = UI.Fonts.Body,
	[Enum.Font.SourceSansBold] = UI.Fonts.Label,
}

local TEXT_CLASSES = { TextLabel = true, TextButton = true, TextBox = true }

function UI.new(className: string, props: { [string]: any }, parent: Instance?): any
	local instance = Instance.new(className)
	if TEXT_CLASSES[className] then
		local font = props.Font
		if font ~= nil then
			props.Font = nil
			local face = FACES[font]
			if face then
				props.FontFace = face
			else
				(instance :: any).Font = font
			end
		end
		if typeof(props.TextSize) == "number" then
			props.TextSize = fitTextSize(props.TextSize)
		end
	end
	for key, value in props do
		(instance :: any)[key] = value
	end
	if parent then
		instance.Parent = parent
	end
	return instance
end

---------------------------------------------------------------------------------------
-- Chrome art (Assets.UI.Chrome). `UI.preview` lets a Studio test hand in EditableImage
-- content before the PNGs are uploaded.

local CHROME: { [string]: any } = (Assets.UI :: any).Chrome or {}
UI.preview = {} :: { [string]: any }

local SLICE: { [string]: Rect } = {
	PanelLacquer = Rect.new(40, 40, 216, 216),
	PanelPlain = Rect.new(40, 40, 216, 216),
	PanelInset = Rect.new(24, 24, 104, 104),
	PanelWashi = Rect.new(36, 36, 220, 220),
	ButtonBase = Rect.new(24, 20, 168, 44),
	Pill = Rect.new(24, 0, 136, 48),
	SelectRing = Rect.new(32, 32, 96, 96),
	RevealSlip = Rect.new(48, 40, 464, 120),
}

-- Puts chrome art `key` on an image; false when it isn't available (draw a stand-in).
function UI.art(image: ImageLabel | ImageButton, key: string): boolean
	local id = CHROME[key]
	if typeof(id) == "string" and id ~= "" then
		image.Image = id
		return true
	end
	local content = UI.preview[key]
	if content ~= nil then
		(image :: any).ImageContent = content
		return true
	end
	return false
end

function UI.hasArt(key: string): boolean
	local id = CHROME[key]
	return (typeof(id) == "string" and id ~= "") or UI.preview[key] ~= nil
end

local MATERIAL = {
	lacquer = { key = "PanelLacquer", scale = 0.5, fill = T.LacquerHi, edge = T.Gold, edgeT = 0.35, corner = 6 },
	plain = { key = "PanelPlain", scale = 0.5, fill = T.LacquerHi, edge = T.Bronze, edgeT = 0.25, corner = 6 },
	inset = { key = "PanelInset", scale = 0.5, fill = T.Plate, edge = rgb(90, 74, 60), edgeT = 0.2, corner = 4 },
	washi = { key = "PanelWashi", scale = 1, fill = T.Washi, edge = T.Bronze, edgeT = 0.1, corner = 3 },
	button = { key = "ButtonBase", scale = 1, fill = T.LacquerHi, edge = T.Ink, edgeT = 0, corner = 5 },
	pill = { key = "Pill", scale = 1, fill = T.Ink, edge = T.Gold, edgeT = 0.45, corner = -1 },
}

local function decor(obj: Instance, className: string, name: string, props: { [string]: any })
	local existing = obj:FindFirstChild(name)
	if not existing then
		existing = Instance.new(className)
		existing.Name = name
		existing.Parent = obj
	end
	for k, v in props do
		(existing :: any)[k] = v
	end
end

local function clearDecor(obj: Instance)
	for _, name in { "_Fill", "_Edge", "_Corner" } do
		local child = obj:FindFirstChild(name)
		if child then
			child:Destroy()
		end
	end
end

-- Paints `obj` (an ImageLabel/ImageButton) as one of the materials: the 9-slice art tinted
-- by `tint`, or the native stand-in (gradient fill, hairline edge, small corner).
function UI.paint(obj: ImageLabel | ImageButton, material: string, tint: Color3?, sliceScale: number?)
	local m = MATERIAL[material] or MATERIAL.inset
	obj:SetAttribute("Material", material)
	obj:SetAttribute("Skinned", true)
	if UI.art(obj, m.key) then
		clearDecor(obj)
		obj.ScaleType = Enum.ScaleType.Slice
		obj.SliceCenter = SLICE[m.key]
		obj.SliceScale = sliceScale or m.scale
		-- Lacquer, plain and washi are painted in their colours; inset, button and pill tint.
		obj.ImageColor3 = if material == "lacquer"
				or material == "plain"
				or material == "washi"
			then Color3.new(1, 1, 1)
			else tint or m.fill
		obj.BackgroundTransparency = 1
		obj:SetAttribute("ArtMode", true)
		return
	end
	obj:SetAttribute("ArtMode", false)
	obj.Image = ""
	obj.BackgroundTransparency = 0
	local fill = tint or m.fill
	obj.BackgroundColor3 = fill
	if material == "washi" then
		decor(obj, "UIGradient", "_Fill", {
			Rotation = 90,
			Color = ColorSequence.new({
				ColorSequenceKeypoint.new(0, Color3.new(1, 1, 1)),
				ColorSequenceKeypoint.new(0.85, rgb(246, 242, 234)),
				ColorSequenceKeypoint.new(1, rgb(214, 200, 176)),
			}),
		})
	elseif material == "button" then
		decor(obj, "UIGradient", "_Fill", {
			Rotation = 90,
			Color = ColorSequence.new({
				ColorSequenceKeypoint.new(0, Color3.new(1, 1, 1)),
				ColorSequenceKeypoint.new(0.3, rgb(236, 236, 236)),
				ColorSequenceKeypoint.new(1, rgb(170, 170, 170)),
			}),
		})
	else
		decor(obj, "UIGradient", "_Fill", {
			Rotation = 90,
			Color = ColorSequence.new(Color3.new(1, 1, 1), rgb(150, 146, 146)),
		})
	end
	decor(obj, "UIStroke", "_Edge", {
		Color = if material == "inset" and tint then tint:Lerp(Color3.new(1, 1, 1), 0.22) else m.edge,
		Thickness = if material == "button" or material == "washi" then 2 else 1,
		Transparency = m.edgeT,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	})
	decor(obj, "UICorner", "_Corner", { CornerRadius = if m.corner < 0 then UDim.new(1, 0) else UDim.new(0, m.corner) })
end

-- Recolours a painted surface (inset plates, buttons, pills) keeping its material.
function UI.tint(obj: GuiObject, color: Color3)
	local target: any = obj
	local skin = obj:FindFirstChild("Skin")
	if skin and skin:IsA("ImageLabel") then
		target = skin
	end
	if target:GetAttribute("ArtMode") == true then
		target.ImageColor3 = color
	else
		target.BackgroundColor3 = color
		local edge = target:FindFirstChild("_Edge")
		if edge and target:GetAttribute("Material") == "inset" then
			edge.Color = color:Lerp(Color3.new(1, 1, 1), 0.22)
		end
	end
end

function UI.corner(parent: Instance, radius: UDim?)
	if parent:GetAttribute("Skinned") then
		return -- the material draws its own corners
	end
	UI.new("UICorner", { CornerRadius = radius or UI.Corner }, parent)
end

-- Strokes: the default bronze border is part of every material now, so on a painted
-- surface only a coloured (selection / accent) stroke is drawn, and it replaces the edge.
function UI.stroke(parent: Instance, color: Color3?, thickness: number?, transparency: number?)
	if parent:GetAttribute("Skinned") then
		if color == nil or color == UI.Bronze then
			return
		end
		-- Lacquer and washi art carry their own gold or bronze rim.
		local material = parent:GetAttribute("Material")
		if
			parent:GetAttribute("ArtMode") == true
			and (material == "lacquer" or material == "plain" or material == "washi")
		then
			return
		end
		local edge = parent:FindFirstChild("_Edge")
		if edge and edge:IsA("UIStroke") then
			edge.Color = color
			edge.Thickness = thickness or 1.5
			edge.Transparency = transparency or 0.2
			return
		end
	end
	UI.new("UIStroke", {
		Name = "_Edge",
		Color = color or UI.Bronze,
		Thickness = thickness or 1.5,
		Transparency = transparency or 0.2,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	}, parent)
end

---------------------------------------------------------------------------------------
-- Reduced motion and sound

function UI.reducedMotion(): boolean
	local player = Players.LocalPlayer
	local setting = player and player:GetAttribute("SettingReduceMotion")
	if setting ~= nil then
		return setting == true
	end
	local ok, on = pcall(function()
		return (GuiService :: any).ReducedMotionEnabled
	end)
	return ok and on == true
end

function UI.isTouch(): boolean
	return UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
end

-- name -> { id, volume, pitch }
local SFX = Assets.Cosmetics.Sounds :: any
local SOUNDS: { [string]: { any } } = {
	Press = { SFX.InkSwish, 0.35, 1.3 },
	Confirm = { SFX.LineChime, 0.3, 1.2 },
	Cancel = { SFX.InkSwish, 0.25, 0.9 },
	Tab = { SFX.InkSwish, 0.25, 1.5 },
	Equip = { Assets.Sounds.Deflect, 0.35, 1.25 },
	Purchase = { SFX.LineChime, 0.4, 1.1 },
	Robux = { SFX.TempleBell, 0.5, 1 },
	Claim = { SFX.Chimes, 0.4, 1.1 },
	Denied = { Assets.Sounds.Guard, 0.3, 0.7 },
	Stamp = { SFX.InkSplash, 0.25, 1.4 },
	LevelUp = { SFX.TempleBell, 0.6, 1 },
	Hum = { SFX.MoonHum, 0.4, 0.9 },
	Knock = { Assets.Sounds.Guard, 0.22, 1.7 },
	RevealCommon = { SFX.Chimes, 0.35, 1 },
	RevealRare = { Assets.Sounds.PerfectDeflect, 0.5, 1 },
	RevealLegendary = { SFX.TempleBell, 0.6, 0.8 },
}

local soundGroup: SoundGroup? = nil
local lastPlayed: { [string]: number } = {}

local function group(): SoundGroup
	if soundGroup and soundGroup.Parent then
		return soundGroup
	end
	local existing = SoundService:FindFirstChild("UI")
	soundGroup = if existing and existing:IsA("SoundGroup")
		then existing
		else UI.new("SoundGroup", { Name = "UI", Volume = 0.6 }, SoundService)
	return soundGroup :: SoundGroup
end

-- Plays a UI sound (section 10 of the guide) through the "UI" SoundGroup; each name at
-- most once per 60 ms. The Settings slider (SettingUIVolume, 0..1) scales the group.
function UI.sound(name: string, pitch: number?): Sound?
	local def = SOUNDS[name]
	if not def or typeof(def[1]) ~= "string" then
		return nil
	end
	local now = os.clock()
	if lastPlayed[name] and now - lastPlayed[name] < 0.06 then
		return nil
	end
	lastPlayed[name] = now
	local g = group()
	local player = Players.LocalPlayer
	local volume = player and player:GetAttribute("SettingUIVolume")
	g.Volume = 0.6 * (if typeof(volume) == "number" then math.clamp(volume, 0, 1) else 1)
	if g.Volume <= 0 then
		return nil
	end
	local s = UI.new("Sound", {
		SoundId = def[1],
		Volume = def[2],
		PlaybackSpeed = pitch or def[3],
		SoundGroup = g,
	}, g)
	s:Play()
	s.Ended:Once(function()
		s:Destroy()
	end)
	task.delay(8, function()
		if s.Parent then
			s:Destroy()
		end
	end)
	return s
end

---------------------------------------------------------------------------------------
-- Motion helpers

function UI.tween(instance: Instance, time: number, goal: { [string]: any })
	TweenService:Create(instance, TweenInfo.new(time, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), goal):Play()
end

function UI.play(instance: Instance, info: TweenInfo, goal: { [string]: any }): Tween
	local tween = TweenService:Create(instance, info, goal)
	tween:Play()
	return tween
end

local function scaleOf(obj: Instance, name: string): UIScale
	local s = obj:FindFirstChild(name)
	if s and s:IsA("UIScale") then
		return s
	end
	return UI.new("UIScale", { Name = name }, obj)
end

-- 1 -> 1.25 -> 1 (a currency icon taking a gain).
function UI.pop(obj: GuiObject, amount: number?)
	if UI.reducedMotion() then
		return
	end
	local s = scaleOf(obj, "Pop")
	s.Scale = amount or 1.25
	UI.play(s, UI.Motion.Pop, { Scale = 1 })
end

-- A seal or kanji stamping down: from 1.6x and tilted to rest.
function UI.stamp(obj: GuiObject, rotation: number?)
	local rest = rotation or obj.Rotation
	if UI.reducedMotion() then
		obj.Rotation = rest
		return
	end
	local s = scaleOf(obj, "Stamp")
	s.Scale = 1.6
	obj.Rotation = rest - 6
	UI.play(s, UI.Motion.Stamp, { Scale = 1 })
	UI.play(obj, UI.Motion.Stamp, { Rotation = rest })
end

-- A 4 px horizontal "no" shake.
function UI.shake(obj: GuiObject)
	if UI.reducedMotion() or obj:GetAttribute("Shaking") then
		return
	end
	obj:SetAttribute("Shaking", true)
	local base = obj.Position
	task.spawn(function()
		for _, dx in { -4, 4, -3, 3, -1, 0 } do
			obj.Position = base + UDim2.fromOffset(dx, 0)
			task.wait(0.04)
		end
		obj.Position = base
		obj:SetAttribute("Shaking", nil)
	end)
end

-- Counts a label from `from` to `to` (fixed steps, so the width doesn't jitter).
function UI.countUp(label: TextLabel, from: number, to: number, format: ((number) -> string)?, duration: number?)
	local fmt = format or UI.number
	if UI.reducedMotion() or from == to then
		label.Text = fmt(to)
		return
	end
	local token = (label:GetAttribute("CountToken") or 0) + 1
	label:SetAttribute("CountToken", token)
	local time = duration or 0.4
	local steps = math.clamp(math.abs(to - from), 1, 20)
	task.spawn(function()
		for i = 1, steps do
			if label:GetAttribute("CountToken") ~= token then
				return
			end
			local t = i / steps
			local eased = 1 - (1 - t) * (1 - t)
			label.Text = fmt(math.floor(from + (to - from) * eased + 0.5))
			task.wait(time / steps)
		end
		if label:GetAttribute("CountToken") == token then
			label.Text = fmt(to)
		end
	end)
end

-- A full-screen dimmer that fades in; a TextButton so it eats clicks behind it.
function UI.scrim(parent: Instance, transparency: number?, z: number?): TextButton
	local target = transparency or 0.45
	local scrim = UI.new("TextButton", {
		Name = "Scrim",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = T.Black,
		BackgroundTransparency = 1,
		AutoButtonColor = false,
		Text = "",
		ZIndex = z or 20,
	}, parent)
	UI.play(scrim, UI.Motion.Fade, { BackgroundTransparency = target })
	return scrim
end

---------------------------------------------------------------------------------------
-- Text

-- True when `parent` sits on a washi sheet (default text turns to ink).
local function onWashi(parent: Instance?): boolean
	local node = parent
	while node do
		if node:GetAttribute("Washi") == true then
			return true
		end
		if node:IsA("LayerCollector") then
			return false
		end
		node = node.Parent
	end
	return false
end
UI.onWashi = onWashi

function UI.text(props: { [string]: any }, parent: Instance?): TextLabel
	props.BackgroundTransparency = 1
	if props.Font == nil and props.FontFace == nil then
		props.FontFace = UI.Fonts.Body
	end
	if props.TextColor3 == nil then
		props.TextColor3 = if onWashi(parent) then T.Ink else T.Bone
	end
	props.TextSize = props.TextSize or 18
	return UI.new("TextLabel", props, parent)
end

local ROLES: { [string]: { font: Font, size: number, color: Color3 } } = {
	title = { font = UI.Fonts.Display, size = 34, color = T.Bone },
	heading = { font = UI.Fonts.Display, size = 24, color = T.Bone },
	banner = { font = UI.Fonts.Banner, size = 26, color = T.Bone },
	splash = { font = UI.Fonts.DisplayHeavy, size = 64, color = T.Bone },
	body = { font = UI.Fonts.Body, size = 18, color = T.Bone },
	label = { font = UI.Fonts.Label, size = 18, color = T.Bone },
	number = { font = UI.Fonts.Number, size = 22, color = T.Bone },
	caption = { font = UI.Fonts.Label, size = 14, color = T.Dim },
}

-- A text label in one of the type roles (guide 4.2): title, heading, banner, splash,
-- body, label, number, caption. Caption text is upper-cased.
function UI.label(role: string, props: { [string]: any }, parent: Instance?): TextLabel
	local r = ROLES[role] or ROLES.body
	props.FontFace = props.FontFace or r.font
	props.TextSize = props.TextSize or r.size
	if props.TextColor3 == nil then
		props.TextColor3 = if onWashi(parent) and r.color == T.Bone then T.Ink else r.color
	end
	if role == "caption" and typeof(props.Text) == "string" then
		props.Text = string.upper(props.Text)
	end
	return UI.text(props, parent)
end

-- Spaces out caps for the Garamond banner face ("ROYALE" -> "R O Y A L E").
function UI.tracked(text: string): string
	local out = {}
	for _, code in utf8.codes(string.upper(text)) do
		local ch = utf8.char(code)
		table.insert(out, if ch == " " then " " else ch)
	end
	return table.concat(out, " ")
end

---------------------------------------------------------------------------------------
-- Panels

-- A surface in one of the materials. props.material = "lacquer" | "plain" | "inset" |
-- "washi" | "pill"; props.tint (inset/pill colour); props.sliceScale. Without a material
-- the old BackgroundColor3 picks one: Ink / none -> lacquer (windows, HUD plates), the
-- panel greys -> an inset plate, any other colour -> an inset plate in that colour.
-- Returns an ImageLabel (typed Frame for the old call sites).
function UI.panel(props: { [string]: any }, parent: Instance?): Frame
	local material: string? = props.material
	local tint: Color3? = props.tint
	local sliceScale: number? = props.sliceScale
	local color: Color3? = props.BackgroundColor3
	local transparency: number? = props.BackgroundTransparency
	props.material, props.tint, props.sliceScale = nil, nil, nil
	props.BackgroundColor3, props.BackgroundTransparency = nil, nil
	if not material then
		if color == nil or color == T.Ink then
			material = "lacquer"
		else
			material = "inset"
			tint = color
		end
	end
	props.BorderSizePixel = 0
	local img = UI.new("ImageLabel", props)
	UI.paint(img, material :: string, tint, sliceScale)
	if material == "washi" then
		img:SetAttribute("Washi", true)
	end
	if transparency and transparency > 0.3 then
		img.ImageTransparency = transparency
		if img:GetAttribute("ArtMode") ~= true then
			img.BackgroundTransparency = transparency
		end
	end
	if parent then
		img.Parent = parent
	end
	return img :: any
end

-- A tiled paper-grain overlay (washi sheets, large windows). No-op until the art exists.
function UI.grain(parent: GuiObject, transparency: number?)
	local img = UI.new("ImageLabel", {
		Name = "Grain",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		ScaleType = Enum.ScaleType.Tile,
		TileSize = UDim2.fromOffset(256, 256),
		ImageTransparency = transparency or 0.85,
		ZIndex = parent.ZIndex,
	}, parent)
	if not UI.art(img, "PaperGrain") then
		img:Destroy()
	end
end

-- A 1 px rule with an optional diamond in the middle.
function UI.divider(parent: Instance, props: { [string]: any }?): Frame
	local p = props or {}
	local onPaper = onWashi(parent)
	local color = p.color or (if onPaper then T.Bronze else T.Gold)
	local holder = UI.new("Frame", {
		Name = p.Name or "Divider",
		Position = p.Position or UDim2.new(),
		Size = p.Size or UDim2.new(1, 0, 0, 10),
		AnchorPoint = p.AnchorPoint or Vector2.zero,
		LayoutOrder = p.LayoutOrder or 0,
		BackgroundTransparency = 1,
	}, parent)
	local line = UI.new("Frame", {
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.fromScale(0, 0.5),
		Size = UDim2.new(1, 0, 0, 1),
		BackgroundColor3 = color,
		BackgroundTransparency = if onPaper then 0.2 else 0.45,
		BorderSizePixel = 0,
	}, holder)
	UI.new("UIGradient", {
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.15, 0),
			NumberSequenceKeypoint.new(0.85, 0),
			NumberSequenceKeypoint.new(1, 1),
		}),
	}, line)
	if p.ornament ~= "none" then
		UI.new("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(7, 7),
			Rotation = 45,
			BackgroundColor3 = T.Ink,
			BorderSizePixel = 0,
		}, holder)
		local d = holder:GetChildren()[2] :: Frame
		UI.new("UIStroke", { Color = color, Thickness = 1 }, d)
	end
	return holder
end

-- A dry-brush stroke under or behind something (selected tab, title, PLAY): the art, or
-- a tapered bar in the same colour.
function UI.brush(parent: Instance, kind: "underline" | "swipe", props: { [string]: any }): ImageLabel
	local color = props.color or T.Crimson
	props.color = nil
	props.BackgroundTransparency = 1
	props.Name = props.Name or (if kind == "underline" then "Underline" else "Swipe")
	local img = UI.new("ImageLabel", props, parent)
	img.ImageColor3 = color
	if not UI.art(img, if kind == "underline" then "BrushUnderline" else "BrushSwipe") then
		-- A tapered bar: thin for the underline, a soft wide band for the swipe.
		img.BackgroundTransparency = if kind == "underline" then 0 else 0.15
		img.BackgroundColor3 = color
		local bar = UI.new("UIGradient", {
			Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 1),
				NumberSequenceKeypoint.new(0.08, 0.1),
				NumberSequenceKeypoint.new(0.7, 0),
				NumberSequenceKeypoint.new(1, 1),
			}),
		}, img)
		bar.Name = "Taper"
		if kind == "underline" then
			UI.new("UISizeConstraint", { MaxSize = Vector2.new(math.huge, 4) }, img)
		else
			UI.new("UICorner", { CornerRadius = UDim.new(0.5, 0) }, img)
		end
	end
	return img
end

-- A crimson 新 seal ("something new"), or a jade check seal ("done"), at a corner.
function UI.badge(parent: Instance, kind: "new" | "done" | "count", size: number?, count: number?): ImageLabel
	local s = size or 22
	local img = UI.new("ImageLabel", {
		Name = if kind == "done" then "Done" else "Dot",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = if kind == "done"
			then UDim2.fromOffset(s / 2 + 2, s / 2 + 2)
			else UDim2.new(1, -s / 2 + 2, 0, s / 2 - 2),
		Size = UDim2.fromOffset(s, s),
		BackgroundTransparency = 1,
		Rotation = if kind == "new" then -6 else 0,
		ZIndex = 5,
	}, parent)
	local key = if kind == "done" then "HankoCheck" else "HankoNew"
	if not UI.art(img, key) then
		-- Stand-in: a crimson diamond seal / a jade disc with a tick.
		img.BackgroundTransparency = 0
		if kind == "done" then
			img.BackgroundColor3 = T.Jade
			UI.new("UICorner", { CornerRadius = UDim.new(1, 0) }, img)
			UI.text({
				Size = UDim2.fromScale(1, 1),
				FontFace = UI.Fonts.Number,
				TextSize = math.max(14, math.floor(s * 0.7)),
				TextColor3 = T.Ink,
				Text = "✓",
				ZIndex = 6,
			}, img)
		else
			img.BackgroundColor3 = T.Crimson
			img.Size = UDim2.fromOffset(s * 0.72, s * 0.72)
			img.Rotation = 45
			UI.new("UIStroke", { Color = T.Bone, Thickness = 1.5 }, img)
		end
	end
	if kind == "count" and count and count > 1 then
		local chip = UI.new("Frame", {
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.new(0.5, 0, 1, -2),
			Size = UDim2.fromOffset(0, 18),
			AutomaticSize = Enum.AutomaticSize.X,
			BackgroundColor3 = T.Ink,
			ZIndex = 6,
		}, img)
		UI.new("UICorner", { CornerRadius = UDim.new(1, 0) }, chip)
		UI.new("UIPadding", { PaddingLeft = UDim.new(0, 5), PaddingRight = UDim.new(0, 5) }, chip)
		UI.text({
			Size = UDim2.fromOffset(0, 18),
			AutomaticSize = Enum.AutomaticSize.X,
			FontFace = UI.Fonts.Number,
			TextSize = 14,
			Text = tostring(count),
			ZIndex = 7,
		}, chip)
	end
	return img
end

-- Old name: a "something new" mark in a corner of `parent` (now the hanko seal).
function UI.dot(parent: Instance, size: number?, _color: Color3?): Frame
	return UI.badge(parent, "new", math.max(20, (size or 14) + 8)) :: any
end

-- A brush kanji image from Assets.UI (KanjiDuel...) or the chrome set (KanjiRare...).
function UI.kanji(key: string, props: { [string]: any }, parent: Instance?): ImageLabel?
	props.BackgroundTransparency = 1
	props.ScaleType = props.ScaleType or Enum.ScaleType.Fit
	local img = UI.new("ImageLabel", props)
	local id = (Assets.UI :: any)[key]
	if typeof(id) == "string" then
		img.Image = id
	elseif not UI.art(img, key) then
		img:Destroy()
		return nil
	end
	if parent then
		img.Parent = parent
	end
	return img
end

---------------------------------------------------------------------------------------
-- Buttons (guide section 7)

export type Variant = "primary" | "premium" | "reward" | "secondary" | "tertiary" | "danger" | "disabled" | "ghost"

local VARIANTS: { [string]: { fill: Color3, text: Color3 } } = {
	primary = { fill = T.CrimsonBtn, text = T.Bone },
	premium = { fill = T.Gold, text = T.Ink },
	reward = { fill = T.JadeBtn, text = T.Bone },
	secondary = { fill = T.LacquerHi, text = T.Bone },
	ghost = { fill = T.Lacquer, text = T.Dim },
	danger = { fill = T.LacquerRed, text = T.Bone },
	disabled = { fill = T.Disabled, text = T.Ash },
	washi = { fill = rgb(98, 86, 74), text = T.Bone }, -- "Not now" on a washi sheet
}
UI.Variants = VARIANTS

local SIZES: { [string]: Vector2 } = {
	XL = Vector2.new(300, 76),
	L = Vector2.new(180, 60),
	M = Vector2.new(140, 60),
	S = Vector2.new(96, 48),
}

-- The gold focus ring for gamepad selection (shared).
local selectRing: GuiObject? = nil
local function ring(): GuiObject
	if selectRing then
		return selectRing
	end
	local img = UI.new("ImageLabel", {
		Name = "SelectRing",
		Size = UDim2.new(1, 8, 1, 8),
		Position = UDim2.fromOffset(-4, -4),
		BackgroundTransparency = 1,
		ImageColor3 = T.GoldHi,
	})
	if UI.art(img, "SelectRing") then
		img.ScaleType = Enum.ScaleType.Slice
		img.SliceCenter = SLICE.SelectRing
		img.SliceScale = 0.5
	else
		UI.new("UIStroke", { Color = T.GoldHi, Thickness = 2.5 }, img)
		UI.new("UICorner", { CornerRadius = UDim.new(0, 6) }, img)
	end
	selectRing = img
	return img
end

function UI.select(obj: GuiObject)
	obj.SelectionImageObject = ring()
end

local function skinOf(button: GuiObject): ImageLabel?
	local skin = button:FindFirstChild("Skin")
	return if skin and skin:IsA("ImageLabel") then skin else nil
end

local function setSkinColor(button: GuiObject, color: Color3)
	local skin = skinOf(button)
	if not skin then
		return
	end
	if skin:GetAttribute("ArtMode") == true then
		skin.ImageColor3 = color
	else
		skin.BackgroundColor3 = color
	end
end

local function restColor(button: GuiObject): Color3
	local c = button:GetAttribute("RestColor")
	return if typeof(c) == "Color3" then c else T.LacquerHi
end

-- Hover / press / release feel on any button: UIScale 1.04 on hover (mouse), 0.94 while
-- held, a Back overshoot on release; the fill leans 10% toward gold on hover and 15% toward
-- ink while pressed; the press sound; the gold focus ring for gamepads. Quiet buttons
-- (disabled look) don't grow, and shake with a dull "no" instead.
function UI.juice(button: GuiButton, opts: { [string]: any }?)
	local o = opts or {}
	local hoverScale = o.hover or 1.04
	local pressScale = o.press or 0.94
	local pressSound = if o.sound == nil then "Press" else o.sound
	local scale = scaleOf(button, "Juice")
	local hovered = false
	local function quiet(): boolean
		return button:GetAttribute("Quiet") == true
	end
	local function to(value: number, info: TweenInfo)
		if UI.reducedMotion() then
			scale.Scale = 1
			return
		end
		UI.play(scale, info, { Scale = value })
	end
	button.MouseEnter:Connect(function()
		if UI.isTouch() or quiet() then
			return
		end
		hovered = true
		to(hoverScale, UI.Motion.Hover)
		setSkinColor(button, restColor(button):Lerp(T.GoldHi, 0.1))
	end)
	button.MouseLeave:Connect(function()
		hovered = false
		to(1, UI.Motion.Hover)
		setSkinColor(button, restColor(button))
	end)
	button.MouseButton1Down:Connect(function()
		if quiet() then
			UI.shake(button)
			UI.sound("Denied")
			return
		end
		to(pressScale, UI.Motion.Press)
		setSkinColor(button, restColor(button):Lerp(T.Ink, 0.15))
		if pressSound then
			UI.sound(pressSound)
		end
	end)
	local function release()
		if quiet() then
			return
		end
		to(if hovered then hoverScale else 1, UI.Motion.Release)
		setSkinColor(button, if hovered then restColor(button):Lerp(T.GoldHi, 0.1) else restColor(button))
	end
	button.MouseButton1Up:Connect(release)
	button.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch then
			hovered = false
			release()
		end
	end)
	button.SelectionGained:Connect(function()
		to(hoverScale, UI.Motion.Hover)
	end)
	button.SelectionLost:Connect(function()
		to(1, UI.Motion.Hover)
	end)
	UI.select(button)
end

local MIRROR = {
	"Text",
	"TextColor3",
	"TextSize",
	"FontFace",
	"TextWrapped",
	"TextScaled",
	"TextXAlignment",
	"TextYAlignment",
	"RichText",
	"TextTruncate",
	"TextStrokeTransparency",
	"TextStrokeColor3",
	"LineHeight",
}

-- A button. props.variant = "primary" | "premium" | "reward" | "secondary" | "tertiary" |
-- "danger" | "disabled" | "ghost"; props.size = "XL" | "L" | "M" | "S" (when no Size);
-- props.sound = the press sound (false for none). Old call sites pass BackgroundColor3,
-- which is used as the fill. Returns the TextButton: its Text, TextColor3, BackgroundColor3
-- and ZIndex can be changed later as before (the skin and label follow).
function UI.button(props: { [string]: any }, parent: Instance?): TextButton
	local variant: string = props.variant or "secondary"
	local sizeKey: string? = props.size
	local sound = props.sound
	props.variant, props.size, props.sound = nil, nil, nil
	if variant == "tertiary" then
		return UI.tertiary(props, parent)
	end
	local v = VARIANTS[variant] or VARIANTS.secondary
	local fill: Color3 = props.BackgroundColor3 or v.fill
	if props.TextColor3 == nil then
		props.TextColor3 = if fill == T.Gold or fill == T.GoldHi then T.Ink else v.text
	end
	if props.Size == nil and sizeKey and SIZES[sizeKey] then
		local s = SIZES[sizeKey]
		props.Size = UDim2.fromOffset(s.X, s.Y)
	end
	if props.Font == nil and props.FontFace == nil then
		props.FontFace = UI.Fonts.Label
	end
	props.TextSize = props.TextSize or 18
	props.BackgroundColor3 = fill
	props.BackgroundTransparency = 1
	props.BorderSizePixel = 0
	props.AutoButtonColor = false
	props.TextTransparency = 1
	local button = UI.new("TextButton", props)
	button:SetAttribute("Skinned", true)
	button:SetAttribute("RestColor", fill)
	local height = button.Size.Y.Offset
	local skin = UI.new("ImageLabel", {
		Name = "Skin",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		ZIndex = button.ZIndex,
	}, button)
	UI.paint(skin, "button", fill, if height > 0 and height < 52 then 0.75 else 1)
	local label = UI.new("TextLabel", {
		Name = "Label",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(1, -14, 1, -4),
		BackgroundTransparency = 1,
		ZIndex = button.ZIndex,
	}, button)
	for _, key in MIRROR do
		(label :: any)[key] = (button :: any)[key]
		button:GetPropertyChangedSignal(key :: any):Connect(function()
			(label :: any)[key] = (button :: any)[key]
		end)
	end
	button:GetPropertyChangedSignal("TextTransparency"):Connect(function()
		if button.TextTransparency ~= 1 then
			label.TextTransparency = button.TextTransparency
			button.TextTransparency = 1
		end
	end)
	button:GetPropertyChangedSignal("BackgroundColor3"):Connect(function()
		button:SetAttribute("RestColor", button.BackgroundColor3)
		setSkinColor(button, button.BackgroundColor3)
	end)
	button:GetPropertyChangedSignal("BackgroundTransparency"):Connect(function()
		local t = button.BackgroundTransparency
		if t ~= 1 then
			skin.Visible = t < 0.95
			button.BackgroundTransparency = 1
		end
	end)
	button:GetPropertyChangedSignal("ZIndex"):Connect(function()
		skin.ZIndex = button.ZIndex
		label.ZIndex = button.ZIndex
	end)
	if variant == "disabled" then
		button:SetAttribute("Quiet", true)
	end
	UI.juice(button, { sound = if sound == nil then "Press" else sound })
	if parent then
		button.Parent = parent
	end
	return button
end

-- A text-only link ("View odds"): Dim, Bone on hover, a brush underline drawn in under it.
function UI.tertiary(props: { [string]: any }, parent: Instance?): TextButton
	props.BackgroundTransparency = 1
	props.AutoButtonColor = false
	if props.Font == nil and props.FontFace == nil then
		props.FontFace = UI.Fonts.Label
	end
	local onPaper = onWashi(parent)
	local rest = props.TextColor3 or (if onPaper then T.Bronze else T.Dim)
	props.TextColor3 = rest
	props.TextSize = props.TextSize or 18
	props.BackgroundColor3 = nil
	local button = UI.new("TextButton", props, parent)
	local line = UI.brush(button, "underline", {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 1, -8),
		Size = UDim2.fromOffset(0, 10),
		color = if onPaper then T.LacquerRed else T.Bone,
		ImageTransparency = 0.2,
		ZIndex = button.ZIndex,
	})
	local function show(on: boolean)
		button.TextColor3 = if on then (if onPaper then T.Ink else T.Bone) else rest
		UI.play(line, UI.Motion.Select, { Size = UDim2.new(if on then 0.9 else 0, 0, 0, 10) })
	end
	button.MouseEnter:Connect(function()
		show(true)
	end)
	button.MouseLeave:Connect(function()
		show(false)
	end)
	button.SelectionGained:Connect(function()
		show(true)
	end)
	button.SelectionLost:Connect(function()
		show(false)
	end)
	button.MouseButton1Down:Connect(function()
		UI.sound("Press")
	end)
	UI.select(button)
	return button
end

-- Old name: the fill and text colours change; RestColor keeps hover honest.
function UI.setButtonColor(button: TextButton, color: Color3)
	button:SetAttribute("RestColor", color)
	button.BackgroundColor3 = color
end

-- Switches a button to another variant (fill and label colour).
function UI.setVariant(button: TextButton, variant: string)
	local v = VARIANTS[variant] or VARIANTS.secondary
	button:SetAttribute("Quiet", variant == "disabled")
	button.BackgroundColor3 = v.fill
	button.TextColor3 = v.text
end

-- A button styled by whether it can be pressed now (crimson when live, the quiet disabled
-- look when not; it still fires, so callers can explain why or open the Gems tab).
function UI.actionButton(parent: Instance, props: { [string]: any }, live: boolean): TextButton
	if props.BackgroundColor3 == UI.Panel then
		props.BackgroundColor3 = nil -- old "owned/quiet" fill -> the disabled variant
	end
	props.variant = props.variant or (if live then "primary" else "disabled")
	local button = UI.button(props, parent)
	if not live then
		button:SetAttribute("Quiet", nil) -- looks quiet, still answers (callers explain why)
	end
	return button
end

-- A round icon button (close, +, previous / next) with a 60 px hit area around a smaller
-- disc. kind = "close" | "plus" | "prev" | "next".
function UI.iconButton(props: { [string]: any }, parent: Instance?): TextButton
	local kind: string = props.kind or "close"
	local visual: number = props.visual or 44
	local hit: number = props.hit or UI.Touch
	local fill: Color3 = props.fill or T.Lacquer
	props.kind, props.visual, props.hit, props.fill = nil, nil, nil, nil
	props.Size = props.Size or UDim2.fromOffset(hit, hit)
	props.BackgroundTransparency = 1
	props.AutoButtonColor = false
	props.Text = ""
	local button = UI.new("TextButton", props)
	local disc = UI.new("ImageLabel", {
		Name = "Disc",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(visual, visual),
		BackgroundTransparency = 1,
		ZIndex = button.ZIndex,
	}, button)
	local key = (
		{ close = "IconClose", plus = "IconPlus", prev = "IconPrev", next = "IconNext" } :: { [string]: string }
	)[kind]
	if not (key and UI.art(disc, key)) then
		disc.BackgroundTransparency = 0
		disc.BackgroundColor3 = fill
		UI.new("UICorner", { CornerRadius = UDim.new(1, 0) }, disc)
		UI.new("UIStroke", { Color = T.Gold, Thickness = 1.5, Transparency = 0.1 }, disc)
		UI.new(
			"UIGradient",
			{ Rotation = 90, Color = ColorSequence.new(Color3.new(1, 1, 1), rgb(150, 146, 146)) },
			disc
		)
		UI.text({
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, if kind == "close" or kind == "plus" then 0.46 else 0.44),
			Size = UDim2.fromScale(1, 1),
			FontFace = UI.Fonts.Number,
			TextSize = math.floor(visual * (if kind == "close" or kind == "plus" then 0.62 else 0.7)),
			TextColor3 = if fill == T.Gold then T.Ink else T.Bone,
			Text = ({ close = "×", plus = "+", prev = "‹", next = "›" } :: { [string]: string })[kind] or "",
			ZIndex = button.ZIndex,
		}, disc)
	elseif fill ~= T.Lacquer then
		disc.ImageColor3 = fill:Lerp(Color3.new(1, 1, 1), 0.5)
	end
	button:SetAttribute("Skinned", true)
	UI.juice(button, { hover = 1.08, sound = if kind == "close" then "Cancel" else "Press" })
	if parent then
		button.Parent = parent
	end
	return button
end

-- A small key-cap chip ("F"), for keybind hints.
function UI.keycap(parent: Instance, key: string, props: { [string]: any }?): Frame
	local p = props or {}
	local chip = UI.new("Frame", {
		Name = p.Name or `Key{key}`,
		LayoutOrder = p.LayoutOrder or 0,
		Position = p.Position or UDim2.new(),
		Size = UDim2.fromOffset(0, 26),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundColor3 = T.Ink,
		BackgroundTransparency = 0.1,
	}, parent)
	UI.new("UICorner", { CornerRadius = UDim.new(0, 4) }, chip)
	UI.new("UIStroke", { Color = T.Dim, Thickness = 1, Transparency = 0.3 }, chip)
	UI.new("UIPadding", { PaddingLeft = UDim.new(0, 7), PaddingRight = UDim.new(0, 7) }, chip)
	UI.text({
		Size = UDim2.fromOffset(0, 26),
		AutomaticSize = Enum.AutomaticSize.X,
		FontFace = UI.Fonts.Number,
		TextSize = 14,
		Text = key,
	}, chip)
	return chip
end

---------------------------------------------------------------------------------------
-- Layout helpers

-- The lobby HUD's own scale on a screen this size (LobbyHUD's "Fit" UIScale).
function UI.lobbyScale(viewport: Vector2): number
	return math.clamp(viewport.X / 1100, 0.6, 1)
end

-- A phone-sized landscape screen (the lobby switches to the left nav rail).
function UI.compact(viewport: Vector2): boolean
	return UI.isTouch() or viewport.Y < 500
end

-- Keeps a lobby window (`height` px tall at scale 1) above the PLAY button and nav bar on
-- any screen: its bottom sits just over them and it shrinks to the height that's left.
function UI.fitAboveNav(window: GuiObject, height: number)
	local scale = UI.new("UIScale", { Name = "FitAboveNav" }, window)
	local camera = workspace.CurrentCamera
	local function refit()
		local size = camera.ViewportSize
		local reserve = math.floor(200 * UI.lobbyScale(size))
		window.AnchorPoint = Vector2.new(0.5, 1)
		window.Position = UDim2.new(0.5, 0, 1, -reserve)
		scale.Scale = math.clamp((size.Y - reserve - 44) / height, 0.45, 1)
	end
	camera:GetPropertyChangedSignal("ViewportSize"):Connect(refit)
	refit()
end

-- 1,234,567
function UI.number(n: number): string
	local s = tostring(math.floor(n))
	local formatted = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	return (formatted:gsub("^,", ""))
end

-- 12.4K, 1.2M (pills only; dialogs show exact numbers).
function UI.short(n: number): string
	if n >= 1e6 then
		return string.format("%.1fM", n / 1e6):gsub("%.0M", "M")
	elseif n >= 1e5 then
		return string.format("%dK", math.floor(n / 1e3))
	elseif n >= 1e4 then
		return (string.format("%.1fK", n / 1e3):gsub("%.0K", "K"))
	end
	return UI.number(n)
end

---------------------------------------------------------------------------------------
-- Lists, notes, headings

-- A quiet wrapped line in a list layout.
function UI.note(parent: Instance, text: string, order: number, height: number?): TextLabel
	return UI.text({
		Name = "Note",
		LayoutOrder = order,
		Size = UDim2.new(1, 0, 0, height or 24),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextWrapped = true,
		TextSize = 16,
		TextColor3 = if onWashi(parent) then T.Ink else T.Dim,
		Text = text,
	}, parent)
end

-- A section heading in a list layout: Display, with a short crimson stroke under it.
function UI.heading(parent: Instance, text: string, order: number): TextLabel
	local label = UI.text({
		LayoutOrder = order,
		Size = UDim2.new(1, 0, 0, 34),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		FontFace = UI.Fonts.Display,
		TextSize = 22,
		TextColor3 = if onWashi(parent) then T.Ink else T.GoldHi,
		Text = text,
	}, parent)
	UI.brush(label, "underline", {
		Position = UDim2.fromOffset(-4, 24),
		Size = UDim2.fromOffset(110, 10),
		color = T.Crimson,
		ImageTransparency = 0.1,
	})
	return label
end

-- A scrolling list filling `parent` (vertical list layout).
function UI.scroll(parent: Instance, padding: number?): ScrollingFrame
	local list = UI.new("ScrollingFrame", {
		Name = "List",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 5,
		ScrollBarImageColor3 = T.Gold,
		ScrollBarImageTransparency = 0.3,
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(),
		ScrollingDirection = Enum.ScrollingDirection.Y,
	}, parent)
	UI.new("UIListLayout", { Padding = UDim.new(0, padding or 10), SortOrder = Enum.SortOrder.LayoutOrder }, list)
	UI.new("UIPadding", {
		PaddingRight = UDim.new(0, 10),
		PaddingBottom = UDim.new(0, 8),
		PaddingTop = UDim.new(0, 2),
	}, list)
	return list
end

---------------------------------------------------------------------------------------
-- Tabs (guide 8.1): text tabs with one crimson brush underline that travels between them.

local lastTab: { [string]: { x: number, w: number } } = {}

function UI.tabs(
	parent: Instance,
	tabs: { { id: string, label: string, dot: boolean?, icon: string? } },
	selected: string,
	onPick: (string) -> (),
	height: number?
): Frame
	local h = math.max(height or 48, 48)
	local key = ""
	for _, tab in tabs do
		key ..= tab.id .. "|"
	end
	-- A bar holding the scrolling row of tabs, a faint rule and the underline layer.
	local bar = UI.new("Frame", {
		Name = "TabBar",
		Size = UDim2.new(1, 0, 0, h),
		BackgroundTransparency = 1,
	}, parent)
	local row = UI.new("ScrollingFrame", {
		Name = "Tabs",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 0,
		ScrollingDirection = Enum.ScrollingDirection.X,
		AutomaticCanvasSize = Enum.AutomaticSize.X,
		CanvasSize = UDim2.new(),
		ElasticBehavior = Enum.ElasticBehavior.Never,
		ZIndex = 2,
	}, bar)
	UI.new("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		Padding = UDim.new(0, 4),
		SortOrder = Enum.SortOrder.LayoutOrder,
		VerticalAlignment = Enum.VerticalAlignment.Center,
	}, row)
	UI.new("Frame", {
		Name = "Rule",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.new(1, 0, 0, 1),
		BackgroundColor3 = T.Gold,
		BackgroundTransparency = 0.75,
		BorderSizePixel = 0,
	}, bar)
	local selectedButton: TextButton? = nil
	for i, tab in tabs do
		local on = tab.id == selected
		local button = UI.new("TextButton", {
			Name = tab.id,
			LayoutOrder = i,
			Size = UDim2.fromScale(0, 1),
			AutomaticSize = Enum.AutomaticSize.X,
			BackgroundTransparency = 1,
			AutoButtonColor = false,
			Text = "",
		}, row)
		UI.new("UIPadding", { PaddingLeft = UDim.new(0, 14), PaddingRight = UDim.new(0, 14) }, button)
		UI.new("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			Padding = UDim.new(0, 6),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}, button)
		if tab.icon then
			UI.new("ImageLabel", {
				Name = "Icon",
				LayoutOrder = 1,
				Size = UDim2.fromOffset(34, 34),
				BackgroundTransparency = 1,
				Image = tab.icon,
				ImageTransparency = if on then 0 else 0.25,
			}, button)
		end
		UI.text({
			Name = "Label",
			LayoutOrder = 2,
			Size = UDim2.new(0, 0, 1, -8),
			AutomaticSize = Enum.AutomaticSize.X,
			FontFace = if on then UI.Fonts.Number else UI.Fonts.Label,
			TextSize = 17,
			TextColor3 = if on then T.Bone else T.Dim,
			Text = string.upper(tab.label),
		}, button)
		if tab.dot then
			local seal = UI.badge(button, "new", 22)
			seal.Position = UDim2.new(1, 8, 0, 12)
		end
		button.MouseEnter:Connect(function()
			if not on then
				local l = button:FindFirstChild("Label") :: TextLabel
				l.TextColor3 = T.Bone
			end
		end)
		button.MouseLeave:Connect(function()
			if not on then
				local l = button:FindFirstChild("Label") :: TextLabel
				l.TextColor3 = T.Dim
			end
		end)
		button.MouseButton1Down:Connect(function()
			if not on then
				UI.sound("Tab")
			end
		end)
		button.Activated:Connect(function()
			if not on then
				onPick(tab.id)
			end
		end)
		UI.select(button)
		if on then
			selectedButton = button
		end
	end
	-- The underline lives in the row's canvas so it scrolls with the tabs; it starts where
	-- the last selected tab was and travels to this one.
	if selectedButton then
		local sel = selectedButton :: TextButton
		local overlay = UI.new("Frame", {
			Name = "UnderlineLayer",
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 1,
			ClipsDescendants = true,
			ZIndex = 1,
		}, bar)
		local line = UI.brush(overlay, "underline", {
			Name = "Underline",
			Size = UDim2.fromOffset(0, 14),
			color = T.Crimson,
		})
		local layout = row:FindFirstChildWhichIsA("UIListLayout") :: UIListLayout
		local function place(animate: boolean)
			local x = sel.AbsolutePosition.X - row.AbsolutePosition.X
			local w = sel.AbsoluteSize.X
			local uiScale = 1
			local node: Instance? = row
			while node do
				local s = node:FindFirstChildWhichIsA("UIScale")
				if s then
					uiScale *= s.Scale
				end
				node = node.Parent
			end
			x, w = x / uiScale, w / uiScale
			local target = {
				Position = UDim2.fromOffset(x + 8, h - 14),
				Size = UDim2.fromOffset(math.max(40, w - 16), 14),
			}
			local prev = lastTab[key]
			if animate and prev and not UI.reducedMotion() and math.abs(prev.x - x) > 1 then
				line.Position = UDim2.fromOffset(prev.x + 8, h - 14)
				line.Size = UDim2.fromOffset(math.max(40, prev.w - 16), 14)
				UI.play(line, UI.Motion.Select, target)
			else
				line.Position = target.Position
				line.Size = target.Size
			end
			lastTab[key] = { x = x, w = w }
		end
		layout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
			place(false)
		end)
		row:GetPropertyChangedSignal("CanvasPosition"):Connect(function()
			place(false)
		end)
		task.defer(function()
			if sel.Parent then
				place(true)
			end
		end)
	end
	return bar
end

---------------------------------------------------------------------------------------
-- Currency pills and prices (guide 8.3)

export type Pill = { frame: Frame, label: TextLabel, icon: ImageLabel, set: (number, boolean?) -> () }

-- A koban pill: the currency icon overflowing its left end, the number right-aligned.
-- props: currency ("coins" | "gems" | "stones" | "shards"), amount, width, height,
-- short (abbreviate 12.4K), LayoutOrder, Name. set(amount, animate) counts up, pops the
-- icon and floats the difference.
function UI.currencyPill(props: { [string]: any }, parent: Instance?): Pill
	local style = UI.Currency[props.currency or "coins"] or UI.Currency.coins
	local h: number = props.height or 40
	local w: number = props.width or 150
	local frame = UI.panel({
		Name = props.Name or "Pill",
		material = "pill",
		LayoutOrder = props.LayoutOrder or 0,
		Size = UDim2.fromOffset(w, h),
		Position = props.Position or UDim2.new(),
		AnchorPoint = props.AnchorPoint or Vector2.zero,
	}, parent)
	local iconSize = math.floor(h * 1.2)
	local icon = UI.new("ImageLabel", {
		Name = "Icon",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0, math.floor(h * 0.32), 0.5, 0),
		Size = UDim2.fromOffset(iconSize, iconSize),
		BackgroundTransparency = 1,
		Image = props.icon or style.icon,
		ZIndex = 3,
	}, frame)
	local label = UI.text({
		Name = "Amount",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -math.floor(h * 0.38), 0.5, 0),
		Size = UDim2.new(1, -iconSize, 1, 0),
		TextXAlignment = Enum.TextXAlignment.Right,
		FontFace = UI.Fonts.Number,
		TextSize = math.max(16, math.floor(h * 0.55)),
		TextColor3 = props.color or style.color,
		Text = "0",
		ZIndex = 3,
	}, frame)
	local short = props.short ~= false
	local current = props.amount or 0
	local function fmt(n: number): string
		return if short then UI.short(n) else UI.number(n)
	end
	label.Text = fmt(current)
	local function set(amount: number, animate: boolean?)
		local was = current
		current = amount
		if not animate or was == amount then
			label.Text = fmt(amount)
			return
		end
		UI.countUp(label, was, amount, fmt)
		if amount > was then
			UI.pop(icon)
			if not UI.reducedMotion() then
				local float = UI.text({
					AnchorPoint = Vector2.new(1, 0),
					Position = UDim2.new(1, -10, 1, 2),
					Size = UDim2.fromOffset(120, 24),
					TextXAlignment = Enum.TextXAlignment.Right,
					FontFace = UI.Fonts.Number,
					TextSize = 20,
					TextColor3 = style.color,
					TextStrokeColor3 = T.Ink,
					TextStrokeTransparency = 0.3,
					Text = `+{UI.number(amount - was)}`,
					ZIndex = 4,
				}, frame)
				UI.play(
					float,
					TweenInfo.new(0.7, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
					{ Position = UDim2.new(1, -10, 1, 26), TextTransparency = 1, TextStrokeTransparency = 1 }
				)
				task.delay(0.75, function()
					float:Destroy()
				end)
			end
		end
	end
	return { frame = frame, label = label, icon = icon, set = set }
end

-- Old name: a small balance pill for a panel header ("[gem] 1,240").
function UI.pill(parent: Instance, image: string, value: number, color: Color3, order: number)
	local digits = #UI.number(value)
	local p = UI.currencyPill({
		currency = "coins",
		icon = image,
		color = color,
		amount = value,
		short = false,
		height = 34,
		width = 58 + digits * 11,
		LayoutOrder = order,
	}, parent)
	p.frame.Name = "Balance"
end

-- A compact price chip (cards, buttons): currency icon + number, or "R$ 199".
function UI.price(props: { [string]: any }, parent: Instance?): Frame
	local h: number = props.height or 30
	local robux = props.robux
	local style = UI.Currency[props.currency or "coins"] or UI.Currency.coins
	local text = if robux then `R$ {UI.number(robux)}` else UI.number(props.amount or 0)
	local frame = UI.panel({
		Name = props.Name or "Price",
		material = "pill",
		LayoutOrder = props.LayoutOrder or 0,
		AnchorPoint = props.AnchorPoint or Vector2.zero,
		Position = props.Position or UDim2.new(),
		Size = props.Size or UDim2.fromOffset(math.max(72, 30 + #text * 10), h),
		ZIndex = props.ZIndex or 1,
	}, parent)
	if not robux then
		UI.new("ImageLabel", {
			Name = "Icon",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(0, math.floor(h * 0.3), 0.5, 0),
			Size = UDim2.fromOffset(math.floor(h * 1.15), math.floor(h * 1.15)),
			BackgroundTransparency = 1,
			Image = style.icon,
			ZIndex = frame.ZIndex + 1,
		}, frame)
	end
	UI.text({
		Name = "Amount",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -math.floor(h * 0.4), 0.5, 0),
		Size = UDim2.new(1, -h, 1, 0),
		TextXAlignment = if robux then Enum.TextXAlignment.Center else Enum.TextXAlignment.Right,
		FontFace = UI.Fonts.Number,
		TextSize = math.max(15, math.floor(h * 0.55)),
		TextColor3 = props.color or (if robux then T.GoldHi else style.color),
		Text = text,
		ZIndex = frame.ZIndex + 1,
	}, frame)
	return frame
end

---------------------------------------------------------------------------------------
-- Progress bars (guide 8.4)

export type Progress = { frame: Frame, fill: Frame, text: TextLabel?, set: (number, number?, boolean?) -> () }

local TONES: { [string]: { Color3 } } = {
	gold = { T.GoldHi, T.Gold },
	crimson = { rgb(220, 40, 60), T.CrimsonBtn },
	jade = { T.JadeText, T.Jade },
	steel = { T.Bone, T.Steel },
}

-- A bar: ink track with a bronze rule, a gradient fill, the value text outside (right).
-- props: value, max, tone, label = "outside" | "none" | "below", height (track), format.
function UI.progress(props: { [string]: any }, parent: Instance?): Progress
	local trackH: number = props.height or 10
	local labelMode: string = props.label or "outside"
	local frame = UI.new("Frame", {
		Name = props.Name or "Progress",
		LayoutOrder = props.LayoutOrder or 0,
		Position = props.Position or UDim2.new(),
		AnchorPoint = props.AnchorPoint or Vector2.zero,
		Size = props.Size or UDim2.new(1, 0, 0, if labelMode == "below" then trackH + 22 else math.max(trackH, 20)),
		BackgroundTransparency = 1,
	}, parent)
	local textW = if labelMode == "outside" then (props.textWidth or 90) else 0
	local track = UI.new("Frame", {
		Name = "Track",
		AnchorPoint = Vector2.new(0, if labelMode == "below" then 0 else 0.5),
		Position = UDim2.fromScale(0, if labelMode == "below" then 0 else 0.5),
		Size = UDim2.new(1, -textW - (if textW > 0 then 8 else 0), 0, trackH),
		BackgroundColor3 = rgb(12, 10, 11),
		BorderSizePixel = 0,
	}, frame)
	UI.new("UICorner", { CornerRadius = UDim.new(1, 0) }, track)
	UI.new("UIStroke", { Color = T.Bronze, Thickness = 1 }, track)
	local ghost = UI.new("Frame", {
		Name = "Ghost",
		Size = UDim2.fromScale(0, 1),
		BackgroundColor3 = T.Bone,
		BackgroundTransparency = 0.4,
		BorderSizePixel = 0,
	}, track)
	UI.new("UICorner", { CornerRadius = UDim.new(1, 0) }, ghost)
	local fill = UI.new("Frame", {
		Name = "Fill",
		Size = UDim2.fromScale(0, 1),
		BackgroundColor3 = Color3.new(1, 1, 1),
		BorderSizePixel = 0,
	}, track)
	UI.new("UICorner", { CornerRadius = UDim.new(1, 0) }, fill)
	local gradient = UI.new("UIGradient", { Rotation = 90 }, fill)
	local text: TextLabel? = nil
	if labelMode ~= "none" then
		text = UI.text({
			Name = "Value",
			AnchorPoint = if labelMode == "below" then Vector2.new(1, 0) else Vector2.new(1, 0.5),
			Position = if labelMode == "below" then UDim2.new(1, 0, 0, trackH + 3) else UDim2.fromScale(1, 0.5),
			Size = UDim2.fromOffset(if labelMode == "below" then 200 else textW, 20),
			TextXAlignment = Enum.TextXAlignment.Right,
			FontFace = UI.Fonts.Number,
			TextSize = props.textSize or 15,
			TextColor3 = T.Dim,
			Text = "",
		}, frame)
	end
	local value, max = props.value or 0, math.max(props.max or 1, 1e-6)
	local format: (number, number) -> string = props.format
		or function(v: number, m: number): string
			return `{UI.number(v)} / {UI.number(m)}`
		end
	local function paintTone(tone: string)
		local c = TONES[tone] or TONES.gold
		gradient.Color = ColorSequence.new(c[1], c[2])
	end
	local function set(v: number, m: number?, animate: boolean?)
		value = v
		max = math.max(m or max, 1e-6)
		local ratio = math.clamp(value / max, 0, 1)
		local tone = props.tone or "gold"
		if props.doneTone and ratio >= 1 then
			tone = props.doneTone
		end
		paintTone(tone)
		local goal = UDim2.fromScale(if ratio > 0 then math.max(ratio, 0.03) else 0, 1)
		if animate and not UI.reducedMotion() then
			ghost.Size = goal
			UI.play(fill, UI.Motion.Count, { Size = goal })
		else
			ghost.Size = goal
			fill.Size = goal
		end
		if text then
			text.Text = format(value, max)
		end
	end
	set(value, max, false)
	return { frame = frame, fill = fill, text = text, set = set }
end

---------------------------------------------------------------------------------------
-- Rarity frames and item cards (guide 8.2)

-- The painted rarity frame (9-slice) around a card. Uncommon has its own jade frame; until
-- its art is uploaded the steel one is tinted jade.
function UI.rarityFrame(parent: GuiObject, rarity: string?, z: number?, sliceScale: number?): ImageLabel?
	local style = UI.rarity(rarity)
	local frames = ICONS.RarityFrames
	if typeof(frames) ~= "table" then
		return nil
	end
	local image = frames[style.frame]
	local tint = Color3.new(1, 1, 1)
	if typeof(image) ~= "string" and style.frame == "Uncommon" then
		image = frames.Common
		tint = rgb(120, 222, 182)
	end
	if typeof(image) ~= "string" then
		return nil
	end
	return UI.new("ImageLabel", {
		Name = "RarityFrame",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Image = image,
		ImageColor3 = tint,
		ScaleType = Enum.ScaleType.Slice,
		SliceCenter = Rect.new(96, 96, 416, 416),
		SliceScale = sliceScale or 0.16,
		ZIndex = z or 3,
	}, parent)
end

-- A soft rarity-coloured glow behind item art (top of a card).
function UI.rarityGlow(parent: GuiObject, rarity: string?, z: number?)
	local style = UI.rarity(rarity)
	if style.glow <= 0 then
		return
	end
	local glow = UI.new("Frame", {
		Name = "Glow",
		Size = UDim2.fromScale(1, 0.75),
		BackgroundColor3 = style.light,
		BackgroundTransparency = 0,
		BorderSizePixel = 0,
		ZIndex = z or 1,
	}, parent)
	UI.new("UIGradient", {
		Rotation = 90,
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1 - style.glow),
			NumberSequenceKeypoint.new(0.55, 1 - style.glow * 0.6),
			NumberSequenceKeypoint.new(1, 1),
		}),
	}, glow)
end

-- A light streak sweeping across `parent` every 4 s (legendary items).
function UI.shine(parent: GuiObject, z: number?)
	if UI.reducedMotion() then
		return
	end
	local clip = UI.new("Frame", {
		Name = "ShineClip",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		ClipsDescendants = true,
		ZIndex = z or 4,
	}, parent)
	local streak = UI.new("ImageLabel", {
		Name = "Shine",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(-0.4, 0.5),
		Size = UDim2.fromScale(0.35, 1.4),
		Rotation = 20,
		BackgroundTransparency = 1,
		ImageTransparency = 0.35,
		ZIndex = z or 4,
	}, clip)
	if not UI.art(streak, "Shine") then
		streak.BackgroundTransparency = 0.55
		streak.BackgroundColor3 = Color3.new(1, 1, 1)
		UI.new("UIGradient", {
			Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 1),
				NumberSequenceKeypoint.new(0.5, 0.2),
				NumberSequenceKeypoint.new(1, 1),
			}),
		}, streak)
	end
	task.spawn(function()
		while clip.Parent do
			task.wait(3.2)
			if not clip.Parent then
				break
			end
			streak.Position = UDim2.fromScale(-0.4, 0.5)
			UI.play(
				streak,
				TweenInfo.new(0.8, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut),
				{ Position = UDim2.fromScale(1.4, 0.5) }
			)
			task.wait(0.8)
		end
	end)
end

export type CardProps = {
	name: string,
	rarity: string?,
	art: ((Frame) -> ())?,
	image: string?,
	caption: string?, -- under the name (defaults to the rarity in caps)
	captionColor: Color3?,
	state: string?, -- "buy" | "owned" | "equipped" | "locked"
	status: string?, -- bottom line when there's no price ("Owned", "3/10", "Locked")
	statusColor: Color3?,
	price: { currency: string, amount: number }?,
	robux: number?,
	isNew: boolean?,
	selected: boolean?,
	Name: string?,
	LayoutOrder: number?,
	Size: UDim2?,
	Position: UDim2?,
	onActivated: (() -> ())?,
}

-- An item card: rarity glow behind the art, the rarity frame, a name band, the rarity in
-- caps, then a price pill or a status line; seals for equipped (jade check) and new (新);
-- a gold ring when selected; a shine on legendaries. Returns the card's TextButton.
function UI.card(props: CardProps, parent: Instance?): TextButton
	local style = UI.rarity(props.rarity)
	local card = UI.new("TextButton", {
		Name = props.Name or "Card",
		LayoutOrder = props.LayoutOrder or 0,
		Size = props.Size or UDim2.fromOffset(160, 214),
		Position = props.Position or UDim2.new(),
		BackgroundTransparency = 1,
		AutoButtonColor = false,
		Text = "",
	})
	local base = UI.panel({
		Name = "Base",
		material = "inset",
		tint = if props.selected then rgb(92, 70, 52) else T.Plate,
		Size = UDim2.fromScale(1, 1),
	}, card)
	UI.rarityGlow(base, props.rarity, 1)
	local bottomH = if props.price or props.robux or props.status then 30 else 0
	local artArea = UI.new("Frame", {
		Name = "Art",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 10),
		Size = UDim2.new(0.74, 0, 1, -(bottomH + 54 + 12)),
		BackgroundTransparency = 1,
		ZIndex = 2,
	}, card)
	UI.new("UIAspectRatioConstraint", { AspectRatio = 1, DominantAxis = Enum.DominantAxis.Height }, artArea)
	if props.art then
		props.art(artArea)
	elseif props.image then
		UI.new("ImageLabel", {
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 1,
			Image = props.image,
			ScaleType = Enum.ScaleType.Fit,
			ZIndex = 2,
		}, artArea)
	end
	for _, d in artArea:GetDescendants() do
		if d:IsA("GuiObject") then
			d.ZIndex = math.max(d.ZIndex, 2)
		end
	end
	if props.state == "locked" then
		for _, d in artArea:GetDescendants() do
			if d:IsA("ImageLabel") then
				d.ImageColor3 = d.ImageColor3:Lerp(rgb(110, 110, 110), 0.6)
				d.ImageTransparency = math.max(d.ImageTransparency, 0.25)
			end
		end
		UI.new("ImageLabel", {
			Name = "Lock",
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -6, 0, 6),
			Size = UDim2.fromOffset(28, 28),
			BackgroundTransparency = 1,
			Image = ICONS.Lock,
			ZIndex = 5,
		}, card)
	end
	-- Name band and rarity caption.
	local bandY = -(bottomH + 54 + (if bottomH > 0 then 4 else 0))
	local band = UI.new("Frame", {
		Name = "Band",
		Position = UDim2.new(0, 6, 1, bandY),
		Size = UDim2.new(1, -12, 0, 26),
		BackgroundColor3 = T.Ink,
		BackgroundTransparency = 0.25,
		BorderSizePixel = 0,
		ZIndex = 3,
	}, card)
	UI.new("UIGradient", {
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.15, 0),
			NumberSequenceKeypoint.new(0.85, 0),
			NumberSequenceKeypoint.new(1, 1),
		}),
	}, band)
	UI.text({
		Name = "ItemName",
		Position = UDim2.new(0, 8, 1, bandY),
		Size = UDim2.new(1, -16, 0, 26),
		FontFace = UI.Fonts.Label,
		TextSize = 16,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Text = props.name,
		ZIndex = 4,
	}, card)
	UI.text({
		Name = "Rarity",
		Position = UDim2.new(0, 8, 1, bandY + 27),
		Size = UDim2.new(1, -16, 0, 18),
		FontFace = UI.Fonts.Number,
		TextSize = 14,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextColor3 = props.captionColor or style.text,
		Text = string.upper(props.caption or (props.rarity or "common")),
		ZIndex = 4,
	}, card)
	-- Bottom: price pill or status.
	if props.price then
		UI.price({
			currency = props.price.currency,
			amount = props.price.amount,
			AnchorPoint = Vector2.new(0.5, 1),
			Position = UDim2.new(0.5, 0, 1, -8),
			Size = UDim2.new(0.78, 0, 0, 28),
			height = 28,
			ZIndex = 4,
		}, card)
	elseif props.robux then
		UI.price({
			robux = props.robux,
			AnchorPoint = Vector2.new(0.5, 1),
			Position = UDim2.new(0.5, 0, 1, -8),
			Size = UDim2.new(0.78, 0, 0, 28),
			height = 28,
			ZIndex = 4,
		}, card)
	elseif props.status then
		UI.text({
			Name = "Status",
			AnchorPoint = Vector2.new(0.5, 1),
			Position = UDim2.new(0.5, 0, 1, -8),
			Size = UDim2.new(1, -12, 0, 24),
			FontFace = UI.Fonts.Label,
			TextSize = 15,
			TextTruncate = Enum.TextTruncate.AtEnd,
			TextColor3 = props.statusColor or T.Dim,
			Text = props.status,
			ZIndex = 4,
		}, card)
	end
	UI.rarityFrame(card, props.rarity, 5, 0.16)
	if props.rarity == "legendary" then
		UI.shine(card, 6)
	end
	if props.state == "equipped" then
		UI.badge(card, "done", 26)
	end
	if props.isNew then
		UI.badge(card, "new", 24)
	end
	if props.selected then
		UI.new("UIStroke", {
			Name = "_Edge",
			Color = T.GoldHi,
			Thickness = 2.5,
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		}, card)
	end
	-- Hover lifts the card a little; press presses it in.
	UI.juice(card, { hover = 1.03, press = 0.97 })
	if props.onActivated then
		card.Activated:Connect(props.onActivated)
	end
	if parent then
		card.Parent = parent
	end
	return card
end

-- Old name (StoreUI.frame calls this).
UI.frame = UI.rarityFrame

---------------------------------------------------------------------------------------
-- Modal sheets (guide 8.5): a washi (or lacquer) card over a scrim, parented to the panel
-- window so a panel redraw that clears its body leaves it alone.

local openSheet: GuiObject? = nil

function UI.closeSheet()
	local sheet = openSheet
	openSheet = nil
	if sheet and sheet.Parent then
		local card = sheet:FindFirstChild("Card")
		if card and not UI.reducedMotion() then
			sheet.Active = false
			UI.play(sheet, UI.Motion.Close, { BackgroundTransparency = 1 })
			local s = card:FindFirstChild("Open")
			if s then
				UI.play(s, UI.Motion.Close, { Scale = 0.94 })
			end
			task.delay(0.14, function()
				sheet:Destroy()
			end)
		else
			sheet:Destroy()
		end
	end
end

function UI.sheetOpen(): boolean
	return openSheet ~= nil and (openSheet :: GuiObject).Parent ~= nil
end

UserInputService.InputBegan:Connect(function(input, processed)
	if openSheet and (input.KeyCode == Enum.KeyCode.Escape or input.KeyCode == Enum.KeyCode.ButtonB) then
		if not processed or input.KeyCode == Enum.KeyCode.ButtonB then
			UI.closeSheet()
		end
	end
end)

-- Opens a sheet over `window`; `build(content)` fills it. Returns the content frame.
-- `opts.material` = "washi" (default) | "lacquer".
function UI.sheet(
	window: GuiObject,
	title: string,
	build: (Frame) -> (),
	size: Vector2?,
	opts: { [string]: any }?
): Frame
	UI.closeSheet()
	local o = opts or {}
	local material = o.material or "washi"
	local dims = size or Vector2.new(560, 320)
	local shade = UI.scrim(window, 0.45, 20)
	shade.Name = "Sheet"
	local card = UI.panel({
		Name = "Card",
		material = material,
		sliceScale = if material == "lacquer" then 1 else nil,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(dims.X, dims.Y),
		ZIndex = 21,
		Active = true,
	}, shade)
	if material == "washi" then
		UI.grain(card, 0.88)
	end
	local open = UI.new("UIScale", { Name = "Open", Scale = if UI.reducedMotion() then 1 else 0.92 }, card)
	UI.play(open, UI.Motion.Open, { Scale = 1 })
	local paper = material == "washi"
	UI.text({
		Name = "Title",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 16),
		Size = UDim2.new(1, -140, 0, 34),
		FontFace = UI.Fonts.Display,
		TextSize = 26,
		TextColor3 = if paper then T.Ink else T.Bone,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Text = title,
		ZIndex = 22,
	}, card)
	UI.divider(card, {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 52),
		Size = UDim2.new(0.62, 0, 0, 10),
		color = if paper then T.Bronze else T.Gold,
	})
	local close = UI.iconButton({
		Name = "Close",
		kind = "close",
		visual = 38,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -6, 0, 4),
		ZIndex = 22,
	}, card)
	close.Activated:Connect(UI.closeSheet)
	local content = UI.new("Frame", {
		Name = "Content",
		Position = UDim2.fromOffset(24, 68),
		Size = UDim2.new(1, -48, 1, -88),
		BackgroundTransparency = 1,
		ZIndex = 22,
	}, card)
	if paper then
		content:SetAttribute("Washi", true)
	end
	openSheet = shade
	build(content)
	-- Everything inside sits above the shade.
	for _, child in card:GetDescendants() do
		if child:IsA("GuiObject") then
			child.ZIndex = math.max(child.ZIndex, 22)
		end
	end
	return content
end

export type ConfirmOpts = {
	title: string,
	text: string?,
	art: ((Frame) -> ())?,
	rarity: string?,
	price: { currency: string, amount: number }?,
	robux: number?,
	balance: number?, -- what the player has of price.currency
	yes: string,
	yesVariant: string?,
	onYes: () -> (),
	shortLabel: string?, -- the button when they can't afford it ("Get gems")
	onShort: (() -> ())?,
}

-- The purchase confirm (guide 8.5): art in its rarity frame, the price as the largest
-- thing, the balance after ("You have 1,250 → 850") or the shortfall in plain words,
-- then [Not now] and the action. Also takes the old form:
-- UI.confirm(window, title, text, yes, onYes).
function UI.confirm(
	window: GuiObject,
	titleOrOpts: string | ConfirmOpts,
	text: string?,
	yes: string?,
	onYes: (() -> ())?
)
	local o: ConfirmOpts
	if typeof(titleOrOpts) == "table" then
		o = titleOrOpts :: ConfirmOpts
	else
		o = { title = titleOrOpts :: string, text = text, yes = yes or "OK", onYes = onYes or function() end }
	end
	local price = o.price
	local style = price and (UI.Currency[price.currency] or UI.Currency.coins)
	local short = price ~= nil and o.balance ~= nil and (o.balance :: number) < price.amount
	local height = 230 + (if o.art then 104 else 0) + (if price or o.robux then 56 else 0) + (if o.text then 20 else 0)
	UI.sheet(window, o.title, function(content)
		local y = 0
		if o.art then
			local holder = UI.new("Frame", {
				Name = "Art",
				AnchorPoint = Vector2.new(0.5, 0),
				Position = UDim2.new(0.5, 0, 0, y),
				Size = UDim2.fromOffset(96, 96),
				BackgroundColor3 = T.Lacquer,
				BorderSizePixel = 0,
			}, content)
			UI.rarityGlow(holder, o.rarity, 1)
			local inner = UI.new("Frame", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.fromScale(0.78, 0.78),
				BackgroundTransparency = 1,
			}, holder)
			o.art(inner)
			UI.rarityFrame(holder, o.rarity, 3, 0.12)
			y += 104
		end
		if price and style then
			local row = UI.new("Frame", {
				Name = "PriceRow",
				AnchorPoint = Vector2.new(0.5, 0),
				Position = UDim2.new(0.5, 0, 0, y),
				Size = UDim2.fromOffset(0, 50),
				AutomaticSize = Enum.AutomaticSize.X,
				BackgroundTransparency = 1,
			}, content)
			UI.new("UIListLayout", {
				FillDirection = Enum.FillDirection.Horizontal,
				VerticalAlignment = Enum.VerticalAlignment.Center,
				Padding = UDim.new(0, 6),
			}, row)
			UI.new("ImageLabel", {
				Size = UDim2.fromOffset(50, 50),
				BackgroundTransparency = 1,
				Image = style.icon,
			}, row)
			UI.text({
				Name = "Price",
				Size = UDim2.fromOffset(0, 50),
				AutomaticSize = Enum.AutomaticSize.X,
				FontFace = UI.Fonts.Number,
				TextSize = 40,
				TextColor3 = style.deep,
				Text = UI.number(price.amount),
			}, row)
			y += 54
		elseif o.robux then
			UI.text({
				Name = "Price",
				AnchorPoint = Vector2.new(0.5, 0),
				Position = UDim2.new(0.5, 0, 0, y),
				Size = UDim2.new(1, 0, 0, 50),
				FontFace = UI.Fonts.Number,
				TextSize = 40,
				TextColor3 = T.GoldDeep,
				Text = `R$ {UI.number(o.robux :: number)}`,
			}, content)
			y += 54
		end
		if price and o.balance ~= nil then
			local have = o.balance :: number
			UI.text({
				Name = "Balance",
				Position = UDim2.fromOffset(0, y),
				Size = UDim2.new(1, 0, 0, 22),
				FontFace = UI.Fonts.Body,
				TextSize = 16,
				TextColor3 = if short then T.LacquerRed else T.Ink,
				Text = if short
					then `You have {UI.number(have)}  ·  need {UI.number(price.amount - have)} more {(
						style :: CurrencyStyle
					).name}`
					else `You have {UI.number(have)}  →  {UI.number(have - price.amount)} after`,
			}, content)
			y += 26
		end
		if o.text then
			UI.text({
				Name = "Text",
				Position = UDim2.fromOffset(0, y),
				Size = UDim2.new(1, 0, 1, -y - UI.Touch - 12),
				TextWrapped = true,
				TextYAlignment = Enum.TextYAlignment.Top,
				TextSize = 18,
				Text = o.text,
			}, content)
		end
		local cancel = UI.button({
			Name = "Cancel",
			variant = "washi",
			AnchorPoint = Vector2.new(0, 1),
			Position = UDim2.fromScale(0, 1),
			Size = UDim2.new(0.5, -8, 0, UI.Touch),
			Text = "Not now",
			sound = "Cancel",
		}, content)
		cancel.Activated:Connect(UI.closeSheet)
		local ok = UI.button({
			Name = "Confirm",
			variant = if short then "premium" else (o.yesVariant or (if o.robux then "premium" else "primary")),
			AnchorPoint = Vector2.new(1, 1),
			Position = UDim2.fromScale(1, 1),
			Size = UDim2.new(0.5, -8, 0, UI.Touch),
			Text = if short then (o.shortLabel or "Not enough") else o.yes,
			FontFace = UI.Fonts.Number,
		}, content)
		ok.Activated:Connect(function()
			UI.closeSheet()
			if short then
				if o.onShort then
					o.onShort()
				end
			else
				UI.sound(if price then "Purchase" else "Confirm")
				o.onYes()
			end
		end)
		if UserInputService.GamepadEnabled then
			GuiService.SelectedObject = cancel
		end
	end, Vector2.new(480, math.max(height, 250)))
end

---------------------------------------------------------------------------------------
-- Window chrome (Panels and the boss picker): title + crimson brush underline, a seigaiha
-- band on large windows, the tsuba close. Returns the pieces.

export type Chrome = { title: TextLabel, underline: ImageLabel, close: TextButton, band: ImageLabel? }

function UI.windowChrome(window: GuiObject, opts: { [string]: any }?): Chrome
	local o = opts or {}
	local title = UI.text({
		Name = "Title",
		Position = UDim2.fromOffset(28, 14),
		Size = UDim2.new(1, -110, 0, 42),
		TextXAlignment = Enum.TextXAlignment.Left,
		FontFace = UI.Fonts.Display,
		TextSize = 32,
		Text = o.title or "",
		ZIndex = 3,
	}, window)
	local underline = UI.brush(window, "underline", {
		Name = "TitleUnderline",
		Position = UDim2.fromOffset(20, 52),
		Size = UDim2.fromOffset(150, 16),
		color = T.Crimson,
		ZIndex = 3,
	})
	local band: ImageLabel? = nil
	local pattern = (Assets.Cosmetics.Patterns :: any).Seigaiha
	if typeof(pattern) == "string" then
		local b = UI.new("ImageLabel", {
			Name = "Band",
			Position = UDim2.fromOffset(14, 12),
			Size = UDim2.new(1, -28, 0, 56),
			BackgroundTransparency = 1,
			Image = pattern,
			ImageColor3 = T.Gold,
			ImageTransparency = 0.93,
			ScaleType = Enum.ScaleType.Tile,
			TileSize = UDim2.fromOffset(64, 64),
			ZIndex = 2,
		}, window)
		UI.new("UIGradient", {
			Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0.2),
				NumberSequenceKeypoint.new(0.6, 0.6),
				NumberSequenceKeypoint.new(1, 1),
			}),
		}, b)
		band = b
	end
	local close = UI.iconButton({
		Name = "Close",
		kind = "close",
		visual = 46,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -8, 0, 6),
		ZIndex = 4,
	}, window)
	return { title = title, underline = underline, close = close, band = band }
end

-- Plays a window's open motion (scale 0.94 -> 1 with a fade of its contents' scrim).
function UI.openMotion(window: GuiObject)
	if UI.reducedMotion() then
		return
	end
	local s = scaleOf(window, "Open")
	s.Scale = 0.94
	UI.play(s, UI.Motion.Open, { Scale = 1 })
end

return UI
