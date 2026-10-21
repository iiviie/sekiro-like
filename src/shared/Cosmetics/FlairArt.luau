--!strict
-- Painted art for the flex surfaces (banners on the duel intro card / Locker, nameplate frames
-- over the head), layered into a GUI frame the caller already built and coloured: a woven
-- pattern, the banner's brushed kanji and a framed edge. Colours stay the caller's (U's
-- Shared/Flair palette); this only adds texture. Works in any GuiObject (ScreenGui, SurfaceGui,
-- BillboardGui) on client or server.
--
--   FlairArt.decorateBanner(frame, "Wave", { cloth = c1, edge = c2, ink = c3 })
--   FlairArt.decoratePlate(frame, "S1Gold", edgeColour)
--
-- Both return the instances they added (named FlairPattern / FlairKanji / FlairFrame), and
-- calling again replaces them.

local Assets = require(script.Parent.Parent.Assets)

local C = Assets.Cosmetics

local FlairArt = {}

export type BannerArt = { pattern: string, kanji: string?, tile: number, alpha: number }

-- By banner ref (Catalog `banner.<ref>`): a pattern key (Assets.Cosmetics.Patterns), a kanji key
-- (Assets.Cosmetics.Kanji), the pattern's tile size in px and its opacity.
FlairArt.Banners = {
	Plain = { pattern = "Cloth", kanji = nil, tile = 128, alpha = 0.5 },
	Crane = { pattern = "Asanoha", kanji = "Crane", tile = 72, alpha = 0.16 },
	Wave = { pattern = "Seigaiha", kanji = "Wave", tile = 64, alpha = 0.22 },
	Mountain = { pattern = "Mountains", kanji = "Mountain", tile = 0, alpha = 0.3 },
	Bamboo = { pattern = "Bamboo", kanji = "Bamboo", tile = 96, alpha = 0.2 },
	Dragon = { pattern = "Uroko", kanji = "Dragon", tile = 48, alpha = 0.14 },
	Tiger = { pattern = "Tora", kanji = "Tiger", tile = 120, alpha = 0.3 },
	Oni = { pattern = "Kikko", kanji = "Oni", tile = 64, alpha = 0.18 },
	Thousand = { pattern = "Hishi", kanji = "Thousand", tile = 40, alpha = 0.16 },
	S1Gold = { pattern = "Kikko", kanji = "Gold", tile = 56, alpha = 0.2 },
	S1Jade = { pattern = "Asanoha", kanji = "Jade", tile = 64, alpha = 0.2 },
	S1Crimson = { pattern = "Seigaiha", kanji = "Crimson", tile = 56, alpha = 0.2 },
	S1Shogun = { pattern = "Uroko", kanji = "Shogun", tile = 44, alpha = 0.22 },
	S1Path = { pattern = "Mountains", kanji = "Path", tile = 0, alpha = 0.28 },
} :: { [string]: BannerArt }

-- Nameplates with ornate (kamon-cornered) frames, and the watermark kanji some carry.
FlairArt.OrnatePlates = {
	Ronin = "Hatamoto", -- the VIP plate (id plate.Ronin) reads 旗本
	S1Gold = "Gold",
	S1Jade = "Jade",
	S1Crimson = "Crimson",
	S1Shogun = "Shogun",
	S1Path = "Path",
} :: {
	[string]: string,
}

local function clear(frame: GuiObject)
	for _, name in { "FlairPattern", "FlairKanji", "FlairFrame" } do
		local old = frame:FindFirstChild(name)
		if old then
			old:Destroy()
		end
	end
end

local function image(frame: GuiObject, name: string, id: string, color: Color3, z: number): ImageLabel
	local label = Instance.new("ImageLabel")
	label.Name = name
	label.BackgroundTransparency = 1
	label.Image = id
	label.ImageColor3 = color
	label.Size = UDim2.fromScale(1, 1)
	label.ZIndex = frame.ZIndex + z
	label.Parent = frame
	return label
end

-- Adds the pattern, kanji and frame of banner `ref` to `frame` (any size; a tall nobori shape
-- reads best). `colors.ink` tints the kanji and pattern, `colors.edge` the frame.
function FlairArt.decorateBanner(
	frame: GuiObject,
	ref: string?,
	colors: { cloth: Color3, edge: Color3, ink: Color3 }
): { GuiObject }
	clear(frame)
	local art = FlairArt.Banners[ref or "Plain"] or FlairArt.Banners.Plain
	local added: { GuiObject } = {}
	local pattern = image(frame, "FlairPattern", C.Patterns[art.pattern], colors.ink, 1)
	pattern.ImageTransparency = 1 - art.alpha
	if art.tile > 0 then
		pattern.ScaleType = Enum.ScaleType.Tile
		pattern.TileSize = UDim2.fromOffset(art.tile, art.tile)
	else -- mountains: one range across the lower half
		pattern.ScaleType = Enum.ScaleType.Crop
		pattern.AnchorPoint = Vector2.new(0, 1)
		pattern.Position = UDim2.fromScale(0, 1)
		pattern.Size = UDim2.fromScale(1, 0.55)
	end
	table.insert(added, pattern)
	if art.kanji then
		local kanji = image(frame, "FlairKanji", C.Kanji[art.kanji], colors.ink, 2)
		kanji.ScaleType = Enum.ScaleType.Fit
		kanji.AnchorPoint = Vector2.new(0.5, 0.5)
		kanji.Position = UDim2.fromScale(0.5, 0.52)
		kanji.Size = UDim2.fromScale(0.86, 0.7)
		table.insert(added, kanji)
	end
	local edge = image(frame, "FlairFrame", C.BannerFrame, colors.edge, 3)
	edge.ScaleType = Enum.ScaleType.Slice
	edge.SliceCenter = Rect.new(48, 48, 208, 464)
	edge.SliceScale = 0.35
	table.insert(added, edge)
	return added
end

-- Adds nameplate `ref`'s frame (and a faint kanji watermark for the ornate ones) to `frame`.
function FlairArt.decoratePlate(frame: GuiObject, ref: string?, edge: Color3): { GuiObject }
	clear(frame)
	local added: { GuiObject } = {}
	local watermark = ref and FlairArt.OrnatePlates[ref]
	if watermark then
		local kanji = image(frame, "FlairKanji", C.Kanji[watermark], edge, 1)
		kanji.ScaleType = Enum.ScaleType.Fit
		kanji.ImageTransparency = 0.82
		kanji.AnchorPoint = Vector2.new(1, 0.5)
		kanji.Position = UDim2.new(1, -10, 0.5, 0)
		kanji.Size = UDim2.fromScale(0.3, 0.9)
		table.insert(added, kanji)
	end
	local border = image(frame, "FlairFrame", if watermark then C.PlateOrnate else C.PlatePlain, edge, 2)
	border.ScaleType = Enum.ScaleType.Slice
	border.SliceCenter = Rect.new(64, 40, 448, 88)
	border.SliceScale = 0.5
	table.insert(added, border)
	return added
end

return FlairArt
