--!strict
-- How the "flex" cosmetics look wherever they're shown: banner cloths (the duel intro card,
-- the Locker), nameplate frames (the name over your head) and title colours by rarity.
-- Display data only, keyed by Catalog `ref`; what a player owns and wears comes from the
-- server (Inventory / Loadout attributes). Used by the client panels, DuelHUD and the
-- server's overhead nameplate (LeaderboardService).

export type Banner = { cloth: Color3, edge: Color3, ink: Color3, motif: string }
export type Plate = { fill: Color3, edge: Color3, text: Color3 }

local function rgb(r: number, g: number, b: number): Color3
	return Color3.fromRGB(r, g, b)
end

local Flair = {}

-- Rarity colours (labels, title text, card accents).
Flair.Rarity = {
	common = rgb(196, 190, 180),
	uncommon = rgb(120, 196, 120),
	rare = rgb(110, 160, 240),
	epic = rgb(186, 120, 236),
	legendary = rgb(240, 196, 90),
} :: { [string]: Color3 }

-- The painted rarity frame each catalogue rarity uses (Assets.Icons.RarityFrames keys).
Flair.Frame = {
	common = "Common",
	uncommon = "Common",
	rare = "Rare",
	epic = "Epic",
	legendary = "Legendary",
} :: { [string]: string }

local function banner(cloth: Color3, edge: Color3, ink: Color3, motif: string): Banner
	return { cloth = cloth, edge = edge, ink = ink, motif = motif }
end

-- A banner is a hanging cloth with one large brushed character on it.
Flair.Banners = {
	Plain = banner(rgb(70, 58, 52), rgb(120, 100, 76), rgb(200, 186, 160), ""),
	Crane = banner(rgb(226, 220, 204), rgb(176, 34, 30), rgb(40, 34, 36), "鶴"),
	Wave = banner(rgb(46, 74, 120), rgb(220, 214, 196), rgb(232, 226, 210), "波"),
	Mountain = banner(rgb(78, 96, 84), rgb(200, 186, 150), rgb(236, 230, 214), "山"),
	Bamboo = banner(rgb(70, 112, 62), rgb(214, 196, 120), rgb(236, 236, 210), "竹"),
	Dragon = banner(rgb(28, 52, 64), rgb(232, 190, 92), rgb(240, 200, 110), "龍"),
	Tiger = banner(rgb(196, 120, 40), rgb(30, 24, 22), rgb(30, 24, 22), "虎"),
	Oni = banner(rgb(120, 26, 26), rgb(30, 22, 24), rgb(250, 230, 210), "鬼"),
	Thousand = banner(rgb(236, 232, 220), rgb(96, 176, 132), rgb(40, 34, 36), "千"),
	S1Gold = banner(rgb(60, 48, 28), rgb(232, 190, 92), rgb(240, 200, 110), "金"),
	S1Jade = banner(rgb(24, 64, 52), rgb(96, 176, 132), rgb(160, 230, 190), "翠"),
	S1Crimson = banner(rgb(92, 18, 20), rgb(220, 70, 60), rgb(250, 210, 200), "紅"),
	S1Shogun = banner(rgb(20, 16, 18), rgb(232, 190, 92), rgb(232, 190, 92), "将"),
	S1Path = banner(rgb(150, 40, 34), rgb(232, 190, 92), rgb(246, 236, 214), "道"),
} :: { [string]: Banner }

local function plate(fill: Color3, edge: Color3, text: Color3): Plate
	return { fill = fill, edge = edge, text = text }
end

-- A nameplate frame is the strip behind your name over your head.
Flair.Plates = {
	Plain = plate(rgb(28, 22, 24), rgb(150, 122, 82), rgb(232, 222, 200)),
	Ronin = plate(rgb(36, 20, 44), rgb(186, 120, 236), rgb(236, 220, 250)),
	S1Gold = plate(rgb(60, 46, 22), rgb(232, 190, 92), rgb(250, 230, 180)),
	S1Jade = plate(rgb(18, 52, 42), rgb(96, 176, 132), rgb(200, 240, 216)),
	S1Crimson = plate(rgb(70, 14, 16), rgb(220, 70, 60), rgb(250, 214, 204)),
	S1Shogun = plate(rgb(16, 12, 14), rgb(240, 196, 90), rgb(240, 196, 90)),
	S1Path = plate(rgb(110, 30, 26), rgb(232, 190, 92), rgb(246, 236, 214)),
} :: { [string]: Plate }

function Flair.banner(ref: string?): Banner
	return (ref and Flair.Banners[ref]) or Flair.Banners.Plain
end

function Flair.plate(ref: string?): Plate
	return (ref and Flair.Plates[ref]) or Flair.Plates.Plain
end

-- Part C's painted layers (Shared/Cosmetics/FlairArt): pattern, brushed kanji and framed
-- edge over these colours. Loaded on first use; nil if the module isn't there.
type FlairArtModule = {
	decorateBanner: (GuiObject, string?, { cloth: Color3, edge: Color3, ink: Color3 }) -> { GuiObject },
	decoratePlate: (GuiObject, string?, Color3) -> { GuiObject },
}
local artModule: FlairArtModule? = nil
local artTried = false
local function art(): FlairArtModule?
	if not artTried then
		artTried = true
		local cosmetics = script.Parent:FindFirstChild("Cosmetics")
		local module = cosmetics and cosmetics:FindFirstChild("FlairArt")
		if module and module:IsA("ModuleScript") then
			local ok, loaded = pcall(require, module)
			if ok and typeof(loaded) == "table" then
				artModule = loaded :: any
			end
		end
	end
	return artModule
end

-- Paints banner `ref` into `frame` (already coloured with Flair.banner(ref).cloth). Returns
-- true when the painted art was added (then hide any text motif of your own).
function Flair.decorateBanner(frame: GuiObject, ref: string?): boolean
	local module = art()
	if not module then
		return false
	end
	return pcall(module.decorateBanner, frame, ref, Flair.banner(ref))
end

-- Adds nameplate `ref`'s painted frame to `frame` (already filled with Flair.plate(ref).fill).
function Flair.decoratePlate(frame: GuiObject, ref: string?): boolean
	local module = art()
	if not module then
		return false
	end
	return pcall(module.decoratePlate, frame, ref, Flair.plate(ref).edge)
end

-- The ref part of a catalogue id ("banner.Wave" -> "Wave").
function Flair.ref(id: string?): string?
	if not id or id == "" then
		return nil
	end
	return string.match(id, "^[^.]+%.(.+)$")
end

return Flair
